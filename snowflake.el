;;; snowflake.el --- Snowflake SQL REPL via Ghostel -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/snowflake.el
;; Keywords: tools processes terminals sql snowflake
;; Version: 0.1
;; Package-Requires: ((emacs "28.1") (ghostel "0.32"))

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; snowflake.el provides the sql.el SQLi workflow for Snowflake's
;; `snow sql' REPL, backed by a Ghostel terminal buffer instead of
;; comint, so the CLI's prompt_toolkit UI, paging and result
;; formatting all work natively.
;;
;; Enable `snowflake-minor-mode' in a `sql-mode' buffer and send the
;; region (C-c C-r), paragraph (C-c C-c), statement (C-c C-e), line
;; (C-c C-n) or whole buffer (C-c C-b) to a linked REPL buffer.
;; M-x snowflake starts (or switches to) a REPL for a connection from
;; `snow connection list'.  When the CLI exits (e.g. an expired
;; token), M-x snowflake-restart re-runs it in the same buffer.
;;
;; All commands are also reachable through the `snowflake-dispatch'
;; transient menu.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ghostel)
(require 'sql)
(require 'transient)

(eval-when-compile (require 'json))

;;; Customization

(defgroup snowflake nil
  "Snowflake SQL REPL via ghostel."
  :group 'sql
  :prefix "snowflake-")

(defcustom snowflake-cli-program "snow"
  "Name or path of the Snowflake CLI program."
  :type 'string)

(defcustom snowflake-cli-extra-args nil
  "Extra command line arguments passed to `snow sql'."
  :type '(repeat string))

(defcustom snowflake-default-connection nil
  "Connection name offered as default when starting a REPL.
When nil, the connection marked as default by the CLI is used."
  :type '(choice (const :tag "CLI default" nil) string))

(defcustom snowflake-buffer-name-format "*snowflake: %s*"
  "Format string for REPL buffer names.
%s is replaced with the connection name."
  :type 'string)

(defcustom snowflake-auto-terminate t
  "Whether to append a terminating \";\" to statements that lack one.
Never applies to \"!\"-commands like !source or !queries."
  :type 'boolean)

(defcustom snowflake-display-repl-buffer-function #'display-buffer
  "Function called with the REPL buffer after a send command.
When t, `pop-to-buffer' is called instead, selecting the REPL
window; when nil, the buffer is not displayed at all.  Send
commands called with a prefix argument always select the REPL
window, regardless of this option."
  :type '(choice (const :tag "Display buffer" display-buffer)
                 (const :tag "Display unless already visible"
                        snowflake-display-unless-visible)
                 (const :tag "Select buffer" t)
                 (const :tag "No display" nil)
                 (function :tag "Custom function")))

(defcustom snowflake-minor-mode-lighter " Snow"
  "Mode line lighter for `snowflake-minor-mode'."
  :type 'string)

(defcustom snowflake-set-sql-product t
  "Whether `snowflake-minor-mode' sets the buffer's SQL product.
When non-nil, enabling the minor mode in a `sql-mode' buffer that
follows the global default `ansi' product sets the buffer-local
`sql-product' to `snowflake'; disabling the mode reverts it.
Buffers with a buffer-local product (file-local variable, or set
with `sql-set-product' in that buffer) are left alone.  An `ansi'
product chosen by setting the global `sql-product' cannot be
distinguished from the untouched default and is switched too."
  :type 'boolean)

(defcustom snowflake-completion t
  "Whether `snowflake-minor-mode' enables completion at point.
Candidates are Snowflake keywords, functions and types plus the
tables, views and schemas of the buffer's connection, fetched
according to `snowflake-completion-fetch-trigger'."
  :type 'boolean)

(defcustom snowflake-completion-fetch-trigger 'connect
  "When to fetch completable database objects for a connection.
`connect' fetches when a buffer gets linked to a REPL,
`completion' on the first completion attempt, `manual' only via
`snowflake-refresh-completions'.  Fetches run asynchronously and
results are cached per connection."
  :type '(choice (const :tag "When buffer links to a REPL" connect)
                 (const :tag "On first completion attempt" completion)
                 (const :tag "Only on explicit refresh" manual)))

(defcustom snowflake-completion-object-scope 'schema
  "Where completable database objects are looked up.
`schema' lists the objects in the connection's default schema,
`database' those of the whole database."
  :type '(choice (const :tag "Default schema" schema)
                 (const :tag "Whole database" database)))

(defcustom snowflake-completion-qualified t
  "Whether to complete objects after a \"schema.\" qualifier.
The qualifying schema's objects are fetched on first use, unless
`snowflake-completion-fetch-trigger' is `manual'."
  :type 'boolean)

;;; Variables

(defvar-local snowflake-buffer nil
  "The snowflake REPL buffer statements from this buffer are sent to.
Set it interactively with `snowflake-set-buffer'.")

(defvar-local snowflake--connection nil
  "Connection name of this REPL buffer, or nil for the CLI default.
A buffer-local binding of this variable (even to nil) marks the
buffer as a snowflake REPL.")

(defvar snowflake--connections nil
  "Cached connection list, as returned by `snowflake--fetch-connections'.")

;;; Connections

(defun snowflake--parse-json (string)
  "Parse JSON STRING; objects become hash tables with string keys."
  (if (fboundp 'json-parse-string)
      (json-parse-string string)
    (require 'json)
    (let ((json-object-type 'hash-table))
      (json-read-from-string string))))

(defun snowflake--fetch-connections ()
  "Return connections from `snow connection list' as a list.
Each element is a cons (NAME . DEFAULT-P)."
  (with-temp-buffer
    (let ((exit (call-process snowflake-cli-program nil '(t nil) nil
                              "connection" "list" "--format" "json")))
      (unless (eql exit 0)
        (user-error "%s connection list failed (%s): %s"
                    snowflake-cli-program exit (string-trim (buffer-string))))
      (mapcar (lambda (conn)
                (cons (gethash "connection_name" conn)
                      (eq (gethash "is_default" conn) t)))
              (snowflake--parse-json (buffer-string))))))

(defun snowflake--connection-names (&optional refresh)
  "Return the list of connection names, fetching them once.
With REFRESH non-nil, discard the cache and fetch again."
  (when (or refresh (null snowflake--connections))
    (setq snowflake--connections (snowflake--fetch-connections)))
  (mapcar #'car snowflake--connections))

(defun snowflake--read-connection (&optional refresh)
  "Read a connection name in the minibuffer.
REFRESH is passed to `snowflake--connection-names'.  A name not in
the connection list is accepted as typed.  Returns nil for empty
input, meaning the CLI default connection."
  (let* ((failure nil)
         (names (condition-case err
                    (snowflake--connection-names refresh)
                  (error (setq failure (error-message-string err))
                         (message "%s" failure)
                         nil)))
         (default (or snowflake-default-connection
                      (car (rassq t snowflake--connections))
                      (car names)))
         ;; The minibuffer hides the message; show the failure in
         ;; the prompt as well.
         (prompt (if failure
                     (format "Connection (%s)"
                             (truncate-string-to-width failure 60))
                   "Connection"))
         (name (completing-read (format-prompt prompt default)
                                names nil nil nil nil default)))
    (unless (string-empty-p name) name)))

(defun snowflake-refresh-connections ()
  "Refresh the cached list of Snowflake connections."
  (interactive)
  (message "Snowflake connections: %s"
           (string-join (snowflake--connection-names t) ", ")))

;;; REPL lifecycle

(defun snowflake--repl-buffer-p (buffer)
  "Return non-nil if BUFFER is a snowflake REPL buffer."
  (and (buffer-live-p buffer)
       (local-variable-p 'snowflake--connection buffer)))

(defun snowflake--repl-live-p (buffer)
  "Return non-nil if BUFFER is a snowflake REPL with a live process."
  (and (snowflake--repl-buffer-p buffer)
       (process-live-p (buffer-local-value 'ghostel--process buffer))))

(defun snowflake--repl-buffers ()
  "Return all snowflake REPL buffers, live processes first."
  (let ((buffers (cl-remove-if-not #'snowflake--repl-buffer-p (buffer-list))))
    (cl-stable-sort buffers (lambda (a b)
                              (and (snowflake--repl-live-p a)
                                   (not (snowflake--repl-live-p b)))))))

(defun snowflake--buffer-name (connection)
  "Return the REPL buffer name for CONNECTION."
  (format snowflake-buffer-name-format (or connection "default")))

(defun snowflake--repl-buffer (connection)
  "Return the existing REPL buffer for CONNECTION, or nil.
Signal a `user-error' when a buffer occupies the REPL's name but
is no snowflake REPL, so it cannot be clobbered by `ghostel-exec'."
  (let ((buffer (get-buffer (snowflake--buffer-name connection))))
    (when (and buffer (not (snowflake--repl-buffer-p buffer)))
      (user-error "Buffer %s exists but is not a snowflake REPL"
                  (buffer-name buffer)))
    buffer))

(defun snowflake--on-repl-exit (buffer _event)
  "Notify the user that the REPL process in BUFFER exited."
  (when (buffer-live-p buffer)
    (message "Snowflake REPL (%s) exited — M-x snowflake-restart (token expired?)"
             (or (buffer-local-value 'snowflake--connection buffer) "default"))))

(defun snowflake--start-repl (connection &optional buffer)
  "Start `snow sql' for CONNECTION in BUFFER and return the buffer.
BUFFER defaults to a buffer named after CONNECTION (see
`snowflake-buffer-name-format').  A BUFFER whose process has exited
is reinitialized in place."
  (let ((buffer (or buffer
                    (snowflake--repl-buffer connection)
                    (get-buffer-create (snowflake--buffer-name connection)))))
    (ghostel-exec buffer snowflake-cli-program
                  (append (list "sql")
                          (when connection (list "-c" connection))
                          snowflake-cli-extra-args))
    (with-current-buffer buffer
      (setq-local ghostel-buffer-name-function nil
                  ghostel-kill-buffer-on-exit nil
                  snowflake--connection connection)
      (add-hook 'ghostel-exit-functions #'snowflake--on-repl-exit nil t))
    buffer))

;;;###autoload
(defun snowflake (connection)
  "Switch to a Snowflake REPL for CONNECTION, starting it if needed.
CONNECTION nil or \"\" means the CLI default connection.
Interactively, prompt for the connection; with a prefix argument,
refresh the connection list first.  When called from a `sql-mode'
buffer, link that buffer to the REPL and enable
`snowflake-minor-mode' in it."
  (interactive (list (snowflake--read-connection current-prefix-arg)))
  (let* ((connection (and connection (not (string-empty-p connection))
                          connection))
         (buffer (snowflake--repl-buffer connection))
         (sql-buf (when (derived-mode-p 'sql-mode) (current-buffer))))
    (if (and buffer (snowflake--repl-live-p buffer))
        nil
      (setq buffer (snowflake--start-repl connection buffer)))
    (when sql-buf
      (with-current-buffer sql-buf
        (snowflake-minor-mode 1)
        (snowflake--link-buffer buffer)))
    (pop-to-buffer buffer)))

;;;###autoload
(defalias 'snowflake-connect #'snowflake)

(defun snowflake-restart (&optional buffer)
  "Restart the `snow sql' process of REPL BUFFER in place.
BUFFER defaults to the current buffer if it is a REPL, the linked
`snowflake-buffer' otherwise.  A live process is killed after
confirmation; the same connection is started again in the same
buffer.  Use this when the CLI exited, e.g. on an expired token."
  (interactive)
  (let ((buffer (or buffer
                    (and (snowflake--repl-buffer-p (current-buffer))
                         (current-buffer))
                    (and (snowflake--repl-buffer-p snowflake-buffer)
                         snowflake-buffer)
                    (snowflake--read-repl-buffer "Restart REPL: "))))
    (unless (snowflake--repl-buffer-p buffer)
      (user-error "Not a snowflake REPL buffer: %s" buffer))
    (let ((proc (buffer-local-value 'ghostel--process buffer))
          (pid (buffer-local-value 'ghostel--pid buffer)))
      (when (process-live-p proc)
        (unless (yes-or-no-p (format "Kill running process in %s and restart? "
                                     (buffer-name buffer)))
          (user-error "Restart aborted"))
        ;; With ghostel's native PTY backend `ghostel--process' is only
        ;; an event pipe that cannot be signaled; the terminal child
        ;; must be killed through its OS pid.
        (if pid
            (signal-process pid 'SIGKILL)
          (kill-process proc))
        (cl-loop repeat 40 while (process-live-p proc)
                 do (sleep-for 0.05))
        (when (process-live-p proc)
          (user-error "Process in %s did not die" (buffer-name buffer)))))
    (snowflake--start-repl (buffer-local-value 'snowflake--connection buffer)
                           buffer)
    (message "Snowflake REPL (%s) restarted"
             (or (buffer-local-value 'snowflake--connection buffer) "default"))))

;;; Linking SQL buffers to REPLs

(defun snowflake--read-repl-buffer (prompt)
  "Read a snowflake REPL buffer name with PROMPT and return the buffer."
  (let ((buffers (snowflake--repl-buffers)))
    (unless buffers
      (user-error "No snowflake REPL buffer; start one with M-x snowflake"))
    (get-buffer (completing-read prompt (mapcar #'buffer-name buffers)
                                 nil t nil nil
                                 (buffer-name (car buffers))))))

(defun snowflake--live-repls ()
  "Return all snowflake REPL buffers with a live process."
  (cl-remove-if-not #'snowflake--repl-live-p (buffer-list)))

(defun snowflake--find-repl ()
  "Return a live REPL buffer for the current buffer, or nil.
Prefers the linked `snowflake-buffer'; otherwise returns the single
live REPL if there is exactly one."
  (if (snowflake--repl-live-p snowflake-buffer)
      snowflake-buffer
    (let ((live (snowflake--live-repls)))
      (when (null (cdr live))
        (car live)))))

(defun snowflake--ensure-repl ()
  "Return a live REPL buffer for the current buffer, creating one if needed.
A dead linked REPL is offered for in-place restart; with several live
REPLs the user picks one; with none a new REPL is started.  The
result is remembered in `snowflake-buffer'."
  (let ((repl
         (or (snowflake--find-repl)
             (cond
              ;; Linked buffer still exists but its process died.
              ((and (snowflake--repl-buffer-p snowflake-buffer)
                    (y-or-n-p (format "REPL %s is dead; restart it? "
                                      (buffer-name snowflake-buffer))))
               (snowflake-restart snowflake-buffer)
               snowflake-buffer)
              ;; Several live REPLs: never auto-pick.
              ((snowflake--live-repls)
               (snowflake--read-repl-buffer "Send to REPL: "))
              ;; No live REPL at all.
              ((y-or-n-p "No live snowflake REPL; start one? ")
               (snowflake--start-repl (snowflake--read-connection)))
              (t (user-error "No snowflake REPL"))))))
    (snowflake--link-buffer repl)))

(defun snowflake-set-buffer ()
  "Set the snowflake REPL buffer this buffer sends its statements to."
  (interactive)
  (snowflake--link-buffer (snowflake--read-repl-buffer "REPL buffer: "))
  (message "Sending to %s" (buffer-name snowflake-buffer)))

;;; Sending

(defvar snowflake--syntax-table
  (let ((table (make-syntax-table sql-mode-syntax-table)))
    ;; Double-quoted identifiers parse as strings; $ is a symbol
    ;; constituent ($1 stage refs, $var).
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?$ "_" table)
    table)
  "Syntax table for parsing Snowflake SQL strings.")

(defun snowflake--prepare-string (string)
  "Return STRING trimmed and terminated for the REPL.
Trailing whitespace is removed.  When `snowflake-auto-terminate' is
non-nil a missing \";\" is appended, except for \"!\"-commands and
input without any code.  Comments, string literals and quoted
identifiers are recognized via `snowflake--syntax-table'; when a
line comment follows the last code, the \";\" goes on a line of
its own so the comment cannot swallow it.  Input ending inside an
open string or \"/*\" comment is left alone, since no appended
\";\" could terminate it."
  (let ((string (string-trim-right string)))
    (if (or (string-empty-p string)
            (not snowflake-auto-terminate)
            (string-prefix-p "!" (string-trim-left string)))
        string
      (with-temp-buffer
        (insert string)
        (set-syntax-table snowflake--syntax-table)
        (let ((end-state (save-excursion (syntax-ppss (point-max)))))
          (if (or (nth 3 end-state)             ; open string
                  (and (nth 4 end-state)        ; open block comment:
                       (null (nth 7 end-state)))) ; style a, no \n end
              string
            ;; Move point after the last code character, skipping
            ;; whitespace and comments (string literals are code).
            ;; `syntax-ppss' moves point, hence the `save-excursion's.
            (goto-char (point-max))
            (skip-chars-backward " \t\n\r")
            (let (state)
              (while (and (not (bobp))
                          (setq state (save-excursion
                                        (syntax-ppss (1- (point)))))
                          (nth 4 state))
                (goto-char (nth 8 state))
                (skip-chars-backward " \t\n\r")))
            (cond ((or (bobp) (eq (char-before) ?\;)) string)
                  ((eql (point) (point-max)) (concat string ";"))
                  (t (concat string "\n;")))))))))

(defun snowflake-display-unless-visible (buffer)
  "Display BUFFER unless it is already shown on any visible frame.
A window on another frame or monitor counts as visible.  Intended
as `snowflake-display-repl-buffer-function'."
  (unless (get-buffer-window buffer 'visible)
    (display-buffer buffer)))

(defun snowflake--display-repl (repl select)
  "Display REPL buffer per `snowflake-display-repl-buffer-function'.
With SELECT non-nil, select its window unconditionally."
  (cond (select (pop-to-buffer repl))
        ((eq snowflake-display-repl-buffer-function t)
         (pop-to-buffer repl))
        ((not snowflake-display-repl-buffer-function) nil)
        ((functionp snowflake-display-repl-buffer-function)
         (funcall snowflake-display-repl-buffer-function repl))
        (t
         (message "Invalid setting of `snowflake-display-repl-buffer-function'")
         (pop-to-buffer repl))))

(defun snowflake--send (string &optional select)
  "Send STRING to the REPL of the current buffer.
Multi-line strings go through bracketed paste, single lines are sent
as raw keystrokes so they enter the REPL history naturally.  SELECT
is passed to `snowflake--display-repl'."
  (let ((repl (snowflake--ensure-repl))
        (string (snowflake--prepare-string string)))
    (when (string-empty-p string)
      (user-error "Nothing to send"))
    (with-current-buffer repl
      (if (string-search "\n" string)
          (progn (ghostel-paste-string string)
                 (ghostel-send-string "\r"))
        (ghostel-send-string
         (encode-coding-string (concat string "\r") 'utf-8))))
    (snowflake--display-repl repl select)))

(defun snowflake-send-region (start end &optional select)
  "Send the region between START and END to the REPL.
With prefix argument SELECT, also select the REPL window."
  (interactive "r\nP")
  (snowflake--send (buffer-substring-no-properties start end) select))

(defun snowflake-send-paragraph (&optional select)
  "Send the paragraph around point to the REPL.
With prefix argument SELECT, also select the REPL window."
  (interactive "P")
  (let ((start (save-excursion (backward-paragraph) (point)))
        (end (save-excursion (forward-paragraph) (point))))
    (snowflake-send-region start end select)))

(defun snowflake-send-buffer (&optional select)
  "Send the whole buffer to the REPL.
With prefix argument SELECT, also select the REPL window.  For very
large buffers prefer `snowflake-send-file', which uses !source."
  (interactive "P")
  (snowflake-send-region (point-min) (point-max) select))

(defun snowflake-send-string (string &optional select)
  "Read STRING in the minibuffer and send it to the REPL.
With prefix argument SELECT, also select the REPL window."
  (interactive (list (read-string "SQL: ") current-prefix-arg))
  (snowflake--send string select))

(defun snowflake-send-statement (&optional select)
  "Send the SQL statement around point to the REPL.
Statement boundaries come from `sql-beginning-of-statement' and
`sql-end-of-statement'.  With prefix argument SELECT, also select
the REPL window."
  (interactive "P")
  (let (start end)
    (save-excursion
      (sql-beginning-of-statement 1)
      (setq start (point))
      (sql-end-of-statement 1)
      (setq end (point)))
    (snowflake-send-region start end select)))

(defun snowflake-send-line-and-next (&optional select)
  "Send the current line to the REPL and move to the next code line.
With prefix argument SELECT, also select the REPL window."
  (interactive "P")
  (snowflake--send (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position))
                   select)
  (forward-line 1)
  (while (and (not (eobp)) (looking-at-p "[[:space:]]*$"))
    (forward-line 1))
  (back-to-indentation))

(defun snowflake--make-temp-file ()
  "Return a fresh temporary SQL file with a whitespace-free name.
When the variable `temporary-file-directory' contains whitespace,
the file is created under `user-emacs-directory' instead, since
!source takes its path argument verbatim."
  (let ((temporary-file-directory
         (if (string-match-p "[[:space:]]"
                             (expand-file-name temporary-file-directory))
             (let ((dir (expand-file-name "snowflake-tmp/"
                                          user-emacs-directory)))
               (make-directory dir t)
               dir)
           temporary-file-directory)))
    (make-temp-file "snowflake-" nil ".sql")))

(defun snowflake-send-file (file &optional select)
  "Send FILE to the REPL with !source.
Interactively, use the file the current buffer is visiting; prompt
for one with a prefix argument or when the buffer visits no file.
An unsaved or modified buffer is sent through a temporary file, as
is a file whose name contains whitespace, since !source takes its
argument verbatim.  SELECT is only meaningful when calling from
Lisp; interactively the prefix argument selects the file instead."
  (interactive
   (list (if (and buffer-file-name (not (buffer-modified-p))
                  (not current-prefix-arg))
             buffer-file-name
           (if (or current-prefix-arg (not (derived-mode-p 'sql-mode)))
               (read-file-name "Source SQL file: " nil nil t nil)
             (let ((file (snowflake--make-temp-file)))
               (write-region (point-min) (point-max) file nil 'silent)
               file)))))
  (let ((file (expand-file-name file)))
    (when (string-match-p "[[:space:]]" file)
      (let ((tmp (snowflake--make-temp-file)))
        (copy-file file tmp t)
        (setq file tmp)))
    (snowflake--send (format "!source %s" file) select)))

;;; REPL interaction from the SQL buffer

(defun snowflake-switch-to-repl ()
  "Switch to the REPL buffer of the current buffer, starting one if needed."
  (interactive)
  (pop-to-buffer (snowflake--ensure-repl)))

(defun snowflake-interrupt ()
  "Send an interrupt to the REPL without leaving the current buffer."
  (interactive)
  (with-current-buffer (snowflake--ensure-repl)
    (ghostel-send-key "c" "ctrl")))

;;; SQL product

(eval-and-compile
  (defconst snowflake-keywords
    '("asof" "at" "before" "caller" "changes" "clone" "comment" "copy"
      "exclude" "explain" "handler" "if" "iff" "ilike" "imports"
      "language" "lateral" "list" "match_recognize" "minus" "overwrite"
      "owner" "packages" "pipe" "pivot" "put" "qualify" "regexp"
      "remove" "rename" "resume" "returns" "rlike" "runtime_version"
      "sample" "secure" "show" "snapshot" "stage" "statement" "stream"
      "suspend" "swap" "tablesample" "task" "top" "transient"
      "truncate" "undrop" "unpivot" "unset" "use" "volatile"
      "warehouse")
    "Snowflake-specific keywords.")

  (defconst snowflake-types
    '("array" "binary" "byteint" "datetime" "geography" "geometry"
      "number" "object" "string" "text" "timestamp_ltz" "timestamp_ntz"
      "timestamp_tz" "variant" "vector")
    "Snowflake-specific data types.")

  (defconst snowflake-functions
    '("approx_count_distinct" "array_agg" "array_construct"
      "array_size" "convert_timezone" "current_account" "current_role"
      "current_warehouse" "date_trunc" "dateadd" "datediff" "flatten"
      "generator" "get_path" "hash" "last_query_id" "listagg" "nvl"
      "nvl2" "object_construct" "object_keys" "parse_json"
      "ratio_to_report" "result_scan" "seq1" "seq2" "seq4" "seq8"
      "split_to_table" "strtok_to_array" "sysdate" "time_slice"
      "to_variant" "try_cast" "try_parse_json" "try_to_date"
      "try_to_number" "typeof" "uniform" "zeroifnull")
    "Common Snowflake function names.")

  (defconst snowflake-statement-starter-words
    '("with" "use" "show" "describe" "desc" "copy" "put" "get" "list"
      "remove" "undrop" "truncate" "call" "execute" "begin" "commit"
      "rollback" "comment" "set" "unset" "explain")
    "Words that can start a Snowflake statement.")

  (defconst snowflake-ansi-keywords
    '("select" "from" "where" "group" "by" "order" "having" "join"
      "left" "right" "inner" "outer" "cross" "on" "union" "all"
      "distinct" "limit" "offset" "case" "when" "then" "else" "end"
      "and" "or" "not" "in" "is" "null" "like" "as" "asc" "desc"
      "insert" "into" "values" "update" "delete" "create" "replace"
      "table" "view" "drop" "alter" "grant" "revoke" "between"
      "exists" "partition" "over" "cast" "coalesce" "count")
    "Common ANSI SQL words offered as completion candidates.
Only used for completion; ANSI font-locking comes from sql.el."))

(defvar snowflake-font-lock-keywords
  (eval-when-compile
    (list
     ;; Snowflake-specific keywords; ANSI keywords are appended
     ;; automatically by `sql-product-font-lock'.
     (apply #'sql-font-lock-keywords-builder
            'font-lock-keyword-face nil snowflake-keywords)
     (apply #'sql-font-lock-keywords-builder
            'font-lock-type-face nil snowflake-types)
     (apply #'sql-font-lock-keywords-builder
            'font-lock-builtin-face nil snowflake-functions)))
  "Snowflake-specific keywords for font-locking in `sql-mode' buffers.")

(defvar snowflake-statement-starters
  (regexp-opt snowflake-statement-starter-words)
  "Additional statement starters for the `snowflake' SQL product.
ORed with the ANSI starters by `sql-statement-regexp'.")

(setq sql-product-alist (assq-delete-all 'snowflake sql-product-alist))
(sql-add-product 'snowflake "Snowflake"
                 :font-lock 'snowflake-font-lock-keywords
                 :statement 'snowflake-statement-starters
                 ;; $ is a symbol constituent ($1 stage refs, $var);
                 ;; double-quoted identifiers parse as strings.
                 :syntax-alist '((?$ . "_") (?\" . "\"")))

;;; Completion

(defvar snowflake--objects-error-cooldown 60
  "Seconds before a failed object fetch may be retried.")

(defvar snowflake--objects-cache (make-hash-table :test #'equal)
  "Completable database objects per connection.
Keys are (CONN-KEY . SUBKEY) where CONN-KEY is a connection name
or `:default' and SUBKEY is (:objects . SCOPE), `:schemas' or a
schema name.  Values are plists (:state STATE :candidates LIST
:time FLOAT :process PROC) with STATE one of `pending', `ready'
and `error'.")

(defvar-local snowflake--link-connection nil
  "Connection of the linked REPL at link time, as a list (NAME).
Kept so completion stays on that connection even after the REPL
buffer is killed; nil when the buffer was never linked.")

(defun snowflake--propertize-candidates (kind words)
  "Return copies of WORDS carrying KIND as `snowflake-kind' property."
  (mapcar (lambda (word) (propertize word 'snowflake-kind kind)) words))

(defvar snowflake--static-candidates
  (append
   (snowflake--propertize-candidates
    'keyword (delete-dups (append snowflake-ansi-keywords
                                  snowflake-keywords
                                  snowflake-statement-starter-words
                                  nil)))
   (snowflake--propertize-candidates 'type snowflake-types)
   (snowflake--propertize-candidates 'function snowflake-functions))
  "Keyword, type and function completion candidates.")

(defun snowflake--completion-connection ()
  "Return the connection name used for completion in this buffer.
In a REPL buffer, its own connection; otherwise the linked REPL's
connection (remembered even after the REPL buffer is killed), else
`snowflake-default-connection'.  nil means the CLI default."
  (cond ((local-variable-p 'snowflake--connection) snowflake--connection)
        ((snowflake--repl-buffer-p snowflake-buffer)
         (buffer-local-value 'snowflake--connection snowflake-buffer))
        (snowflake--link-connection (car snowflake--link-connection))
        (t snowflake-default-connection)))

(defun snowflake--objects-cache-key (connection subkey)
  "Return the `snowflake--objects-cache' key for CONNECTION and SUBKEY.
The `:objects' SUBKEY is qualified with the current
`snowflake-completion-object-scope', so changing the scope starts a
fresh cache entry."
  (cons (or connection :default)
        (if (eq subkey :objects)
            (cons :objects snowflake-completion-object-scope)
          subkey)))

(defun snowflake--cached-candidates (connection subkey)
  "Return ready candidates for CONNECTION's SUBKEY cache entry, else nil."
  (let ((entry (gethash (snowflake--objects-cache-key connection subkey)
                        snowflake--objects-cache)))
    (when (eq (plist-get entry :state) 'ready)
      (plist-get entry :candidates))))

(defun snowflake--parse-objects (json-string)
  "Return object completion candidates parsed from JSON-STRING.
JSON-STRING is the output of a \"show terse objects\" query; each
candidate carries its kind (`table', `view', ...) as a
`snowflake-kind' text property."
  (mapcar (lambda (row)
            (let ((kind (gethash "kind" row)))
              (propertize (gethash "name" row) 'snowflake-kind
                          ;; JSON null parses as :null, not nil.
                          (intern (downcase (if (stringp kind) kind
                                              "table"))))))
          (snowflake--parse-json json-string)))

(defun snowflake--parse-schemas (json-string)
  "Return schema name candidates parsed from JSON-STRING.
JSON-STRING is the output of a \"show terse schemas\" query."
  (mapcar (lambda (row)
            (propertize (gethash "name" row) 'snowflake-kind 'schema))
          (snowflake--parse-json json-string)))

(defun snowflake--quote-schema (name)
  "Return schema NAME quoted for SQL where necessary.
Each dot-separated part of a database-qualified NAME that is not a
plain unquoted identifier is double-quoted."
  (mapconcat (lambda (part)
               (let ((case-fold-search nil))
                 (if (string-match-p "\\`[A-Z_][A-Z0-9_$]*\\'" part)
                     part
                   (concat "\"" part "\""))))
             (split-string name "\\.") "."))

(defun snowflake--objects-query (subkey)
  "Return the SQL show-query fetching candidates for cache SUBKEY."
  (cond ((eq subkey :objects)
         (format "show terse objects in %s" snowflake-completion-object-scope))
        ((eq subkey :schemas) "show terse schemas in database")
        (t (format "show terse objects in schema %s"
                   (snowflake--quote-schema subkey)))))

(defun snowflake--stderr-summary (buffer)
  "Return a short one-line summary of stderr BUFFER."
  (let ((text (with-current-buffer buffer (buffer-string))))
    (setq text (replace-regexp-in-string "[│╭╮╰╯─┌┐└┘]" " " text))
    (setq text (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))
    (if (string-empty-p text)
        "exited abnormally"
      (truncate-string-to-width text 120))))

(defun snowflake--objects-sentinel (key entry stdout stderr verbose callback)
  "Return a fetch process sentinel storing its result under cache KEY.
The result is only stored while ENTRY is still the cached entry
for KEY, so a superseded fetch cannot clobber its successor.
STDOUT and STDERR are the process output buffers.  With VERBOSE
non-nil, message on success too.  CALLBACK, if non-nil, is called
with the candidates after a successful fetch."
  (lambda (process _event)
    (unless (process-live-p process)
      (unwind-protect
          (when (eq (gethash key snowflake--objects-cache) entry)
            (condition-case err
                (progn
                  (unless (eql (process-exit-status process) 0)
                    ;; Let the separate stderr pipe drain first.
                    (let ((errproc (get-buffer-process stderr)))
                      (cl-loop repeat 20
                               while (and errproc (process-live-p errproc))
                               do (accept-process-output errproc 0.05)))
                    (error "%s" (snowflake--stderr-summary stderr)))
                  (let* ((output (with-current-buffer stdout (buffer-string)))
                         (candidates (if (eq (cdr key) :schemas)
                                         (snowflake--parse-schemas output)
                                       (snowflake--parse-objects output))))
                    (puthash key (list :state 'ready :candidates candidates
                                       :time (float-time))
                             snowflake--objects-cache)
                    (when verbose
                      (message "Snowflake: cached %d completions for %s"
                               (length candidates)
                               (if (eq (car key) :default)
                                   "default"
                                 (car key))))
                    (when callback (funcall callback candidates))))
              (error
               ;; The stderr drain above yields; a forced refetch may
               ;; have replaced this entry in the meantime.
               (when (eq (gethash key snowflake--objects-cache) entry)
                 (puthash key (list :state 'error :time (float-time))
                          snowflake--objects-cache)
                 (message "Snowflake completion fetch failed: %s"
                          (error-message-string err))))))
        (when (buffer-live-p stdout) (kill-buffer stdout))
        (when (buffer-live-p stderr) (kill-buffer stderr))))))

(defun snowflake--fetch-objects (connection subkey
                                            &optional force verbose callback)
  "Asynchronously fetch completion candidates for CONNECTION.
SUBKEY selects the query (see `snowflake--objects-cache').  An
entry that is pending, ready, or errored within
`snowflake--objects-error-cooldown' is left alone; FORCE overrides
that, killing a still-running fetch.  VERBOSE and CALLBACK are
passed to the sentinel."
  (let* ((key (snowflake--objects-cache-key connection subkey))
         (entry (gethash key snowflake--objects-cache))
         (state (plist-get entry :state)))
    (when (and force (eq state 'pending))
      ;; Kill the superseded fetch; removing its entry first keeps
      ;; its sentinel from reporting the kill as a fetch failure.
      (remhash key snowflake--objects-cache)
      (setq state nil)
      (let ((proc (plist-get entry :process)))
        (when (process-live-p proc) (delete-process proc))))
    (unless (or (eq state 'pending)
                (and (not force)
                     (or (eq state 'ready)
                         (and (eq state 'error)
                              (< (- (float-time) (plist-get entry :time))
                                 snowflake--objects-error-cooldown)))))
      (let ((stdout (generate-new-buffer " *snowflake-objects*"))
            (stderr (generate-new-buffer " *snowflake-objects-stderr*"))
            (entry (list :state 'pending :time (float-time) :process nil)))
        (condition-case err
            (let ((proc (make-process
                         :name "snowflake-objects"
                         :buffer stdout
                         :stderr stderr
                         :noquery t
                         :command
                         (append (list snowflake-cli-program "sql")
                                 (when connection (list "-c" connection))
                                 (list "-q" (snowflake--objects-query subkey)
                                       "--format" "json"))
                         :sentinel (snowflake--objects-sentinel
                                    key entry stdout stderr verbose
                                    callback))))
              ;; Silence the stderr pipe's default sentinel, which
              ;; would append status noise to the buffer.
              (when-let* ((errproc (get-buffer-process stderr)))
                (set-process-sentinel errproc #'ignore)
                (set-process-query-on-exit-flag errproc nil))
              (plist-put entry :process proc)
              (puthash key entry snowflake--objects-cache))
          (error
           (kill-buffer stdout)
           (kill-buffer stderr)
           (puthash key (list :state 'error :time (float-time))
                    snowflake--objects-cache)
           (message "Snowflake completion fetch failed: %s"
                    (error-message-string err))))))))

(defun snowflake--link-buffer (repl)
  "Link the current buffer to REPL buffer and return it.
Sets `snowflake-buffer', remembers REPL's connection and, when
`snowflake-completion-fetch-trigger' is `connect', prefetches that
connection's completion candidates."
  (setq snowflake-buffer repl)
  (let ((connection (and (snowflake--repl-buffer-p repl)
                         (buffer-local-value 'snowflake--connection repl))))
    (setq snowflake--link-connection (list connection))
    (when (and snowflake-completion
               (eq snowflake-completion-fetch-trigger 'connect))
      (snowflake--fetch-objects connection :objects)
      (snowflake--fetch-objects connection :schemas)))
  repl)

(defun snowflake--completion-qualifier (start)
  "Return the qualifier directly before START, or nil.
A qualifier is one or more dot-separated symbols ending with \".\"
at START, e.g. \"myschema.\" or \"db.myschema.\", returned without
the trailing dot and in the case it was typed."
  (save-excursion
    (goto-char start)
    (while (eq (char-before) ?.)
      (forward-char -1)
      (skip-syntax-backward "w_"))
    (when (< (point) (1- start))
      (buffer-substring-no-properties (point) (1- start)))))

(defun snowflake--resolve-qualifier (qualifier schemas)
  "Return the schema name QUALIFIER refers to, or nil.
QUALIFIER is matched case-insensitively against the SCHEMAS
candidate list; without a match it is likely a table alias.  A
database-qualified \"db.schema\" QUALIFIER cannot be validated
against SCHEMAS and is returned upcased."
  (if (string-search "." qualifier)
      (upcase qualifier)
    (car (cl-member qualifier schemas :test #'cl-equalp))))

(defun snowflake-refresh-completions ()
  "Fetch (or refresh) completable objects for this buffer's connection.
When point follows the qualifier of a schema (or a
database-qualified one), that schema's objects are refreshed as
well, once the refreshed schema list confirms it is no table
alias."
  (interactive)
  (let* ((connection (snowflake--completion-connection))
         (qualifier (snowflake--completion-qualifier
                     (or (car (bounds-of-thing-at-point 'symbol)) (point)))))
    (snowflake--fetch-objects connection :objects 'force 'verbose)
    (snowflake--fetch-objects
     connection :schemas 'force nil
     (and qualifier
          (lambda (schemas)
            (when-let* ((subkey (snowflake--resolve-qualifier qualifier
                                                              schemas)))
              (snowflake--fetch-objects connection subkey
                                        'force 'verbose)))))))

(defun snowflake--completion-annotate (candidate)
  "Return the completion annotation for CANDIDATE."
  (when-let* ((kind (get-text-property 0 'snowflake-kind candidate)))
    (concat " " (capitalize (symbol-name kind)))))

(defun snowflake--completion-kind (candidate)
  "Return the `:company-kind' symbol for CANDIDATE."
  (pcase (get-text-property 0 'snowflake-kind candidate)
    ('keyword 'keyword)
    ('function 'function)
    ('type 'struct)
    ('view 'interface)
    ('schema 'module)
    (_ 'class)))

(defun snowflake-completion-at-point ()
  "Complete Snowflake keywords, functions, types and database objects.
Database objects come from the per-connection cache (see
`snowflake-completion-fetch-trigger').  After a \"schema.\"
qualifier only that schema's objects are offered."
  (unless (nth 8 (syntax-ppss))
    (let* ((bounds (bounds-of-thing-at-point 'symbol))
           (beg (or (car bounds) (point)))
           (end (or (cdr bounds) (point)))
           (connection (snowflake--completion-connection))
           (qualifier (and snowflake-completion-qualified
                           (snowflake--completion-qualifier beg)))
           (candidates
            (if qualifier
                (let* ((schemas (snowflake--cached-candidates
                                 connection :schemas))
                       (subkey (snowflake--resolve-qualifier qualifier
                                                             schemas)))
                  ;; The schema list gates alias-looking qualifiers;
                  ;; until it is cached, fetch it instead of firing a
                  ;; doomed per-alias object query.
                  (unless (eq snowflake-completion-fetch-trigger 'manual)
                    (unless schemas
                      (snowflake--fetch-objects connection :schemas))
                    (when subkey
                      (snowflake--fetch-objects connection subkey)))
                  (when subkey
                    (snowflake--cached-candidates connection subkey)))
              (when (eq snowflake-completion-fetch-trigger 'completion)
                (snowflake--fetch-objects connection :objects)
                (snowflake--fetch-objects connection :schemas))
              (append snowflake--static-candidates
                      (snowflake--cached-candidates connection :objects)
                      (snowflake--cached-candidates connection :schemas)))))
      (when candidates
        (list beg end
              (completion-table-case-fold candidates)
              :exclusive 'no
              :annotation-function #'snowflake--completion-annotate
              :company-kind #'snowflake--completion-kind)))))

;;; Minor mode

(defvar snowflake-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'snowflake-send-paragraph)
    (define-key map (kbd "C-c C-r") #'snowflake-send-region)
    (define-key map (kbd "C-c C-b") #'snowflake-send-buffer)
    (define-key map (kbd "C-c C-s") #'snowflake-send-string)
    (define-key map (kbd "C-c C-e") #'snowflake-send-statement)
    (define-key map (kbd "C-c C-n") #'snowflake-send-line-and-next)
    (define-key map (kbd "C-c C-f") #'snowflake-send-file)
    (define-key map (kbd "C-c C-z") #'snowflake-switch-to-repl)
    (define-key map (kbd "C-c C-j") #'snowflake-set-buffer)
    (define-key map (kbd "C-c C-k") #'snowflake-interrupt)
    map)
  "Keymap for `snowflake-minor-mode'.
Shadows the comint-oriented sql.el bindings.")

(defvar-local snowflake--product-set nil
  "Non-nil when `snowflake-minor-mode' set this buffer's `sql-product'.")

;;;###autoload
(define-minor-mode snowflake-minor-mode
  "Send SQL from this buffer to a Snowflake REPL in a ghostel terminal.
Meant to be enabled in `sql-mode' buffers; its keymap shadows the
comint-oriented sql.el send commands.  Unless
`snowflake-set-sql-product' is nil, buffers on the default `ansi'
product are switched to the `snowflake' product while the mode is
enabled (see `snowflake-set-sql-product' for the details)."
  :lighter snowflake-minor-mode-lighter
  :keymap snowflake-minor-mode-map
  (if snowflake-minor-mode
      (when snowflake-completion
        (add-hook 'completion-at-point-functions
                  #'snowflake-completion-at-point nil t))
    (remove-hook 'completion-at-point-functions
                 #'snowflake-completion-at-point t))
  (cond ((and snowflake-minor-mode
              snowflake-set-sql-product
              (derived-mode-p 'sql-mode)
              (eq sql-product 'ansi)
              (not (local-variable-p 'sql-product)))
         (setq snowflake--product-set t)
         (setq-local sql-product 'snowflake)
         (sql-highlight-product))
        ((and (not snowflake-minor-mode) snowflake--product-set)
         (setq snowflake--product-set nil)
         (when (eq sql-product 'snowflake)
           (kill-local-variable 'sql-product)
           (sql-highlight-product)))))

;;; Transient

;;;###autoload (autoload 'snowflake-dispatch "snowflake" nil t)
(transient-define-prefix snowflake-dispatch ()
  "Snowflake REPL commands."
  [["Connection"
    ("c" "Connect" snowflake)
    ("j" "Set REPL buffer" snowflake-set-buffer)
    ("g" "Refresh connections" snowflake-refresh-connections)
    ("o" "Refresh completions" snowflake-refresh-completions)]
   ["Send"
    ("p" "Paragraph" snowflake-send-paragraph)
    ("r" "Region" snowflake-send-region)
    ("e" "Statement" snowflake-send-statement)
    ("n" "Line and next" snowflake-send-line-and-next)
    ("b" "Buffer" snowflake-send-buffer)
    ("s" "String" snowflake-send-string)
    ("f" "File (!source)" snowflake-send-file)]
   ["REPL"
    ("z" "Switch to REPL" snowflake-switch-to-repl)
    ("k" "Interrupt" snowflake-interrupt)
    ("R" "Restart" snowflake-restart)]])

(provide 'snowflake)
;;; snowflake.el ends here
