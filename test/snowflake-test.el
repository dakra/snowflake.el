;;; snowflake-test.el --- Tests for snowflake.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Kraus <daniel@kraus.my>

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

;; Batch-safe unit tests.  Integration tests that need a running
;; ghostel terminal are driven interactively via elate.

;;; Code:

(require 'ert)
(require 'snowflake)

(defconst snowflake-test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this test file.")

;;; snowflake--prepare-string

(ert-deftest snowflake-test-prepare-appends-terminator ()
  (let ((snowflake-auto-terminate t))
    (should (equal (snowflake--prepare-string "select 1")
                   "select 1;"))))

(ert-deftest snowflake-test-prepare-keeps-existing-terminator ()
  (let ((snowflake-auto-terminate t))
    (should (equal (snowflake--prepare-string "select 1;")
                   "select 1;"))))

(ert-deftest snowflake-test-prepare-trims-trailing-whitespace ()
  (let ((snowflake-auto-terminate t))
    (should (equal (snowflake--prepare-string "select 1;  \n\n")
                   "select 1;"))
    (should (equal (snowflake--prepare-string "select 1 \n")
                   "select 1;"))))

(ert-deftest snowflake-test-prepare-skips-bang-commands ()
  (let ((snowflake-auto-terminate t))
    (should (equal (snowflake--prepare-string "!queries")
                   "!queries"))
    (should (equal (snowflake--prepare-string "  !source /tmp/foo.sql\n")
                   "  !source /tmp/foo.sql"))))

(ert-deftest snowflake-test-prepare-auto-terminate-off ()
  (let ((snowflake-auto-terminate nil))
    (should (equal (snowflake--prepare-string "select 1\n")
                   "select 1"))))

(ert-deftest snowflake-test-prepare-multiline ()
  (let ((snowflake-auto-terminate t))
    (should (equal (snowflake--prepare-string
                    "with t as (select 1 as x)\nselect * from t\n")
                   "with t as (select 1 as x)\nselect * from t;"))))

(ert-deftest snowflake-test-prepare-trailing-comment ()
  (let ((snowflake-auto-terminate t))
    ;; A ";" appended to the last line would be commented out.
    (should (equal (snowflake--prepare-string "select 1 -- check")
                   "select 1 -- check\n;"))
    (should (equal (snowflake--prepare-string "select 1\n-- done")
                   "select 1\n-- done\n;"))
    ;; Already terminated before the comment: left alone.
    (should (equal (snowflake--prepare-string "select 1; -- check")
                   "select 1; -- check"))
    (should (equal (snowflake--prepare-string "select 1;\n-- done")
                   "select 1;\n-- done"))))

(ert-deftest snowflake-test-prepare-empty-input ()
  (let ((snowflake-auto-terminate t))
    ;; No stray ";" for input without code; `snowflake--send' then
    ;; signals \"Nothing to send\" for the empty results.
    (should (equal (snowflake--prepare-string "") ""))
    (should (equal (snowflake--prepare-string "   \n  \n") ""))
    (should (equal (snowflake--prepare-string "-- just a comment")
                   "-- just a comment"))))

(ert-deftest snowflake-test-prepare-string-literals ()
  (let ((snowflake-auto-terminate t))
    ;; "--" inside a string literal is not a comment.
    (should (equal (snowflake--prepare-string "select 'a--b' from t;")
                   "select 'a--b' from t;"))
    (should (equal (snowflake--prepare-string "select 'a--b' from t")
                   "select 'a--b' from t;"))
    ;; The same holds for double-quoted identifiers.
    (should (equal (snowflake--prepare-string "select \"a--b\" from t;")
                   "select \"a--b\" from t;"))
    (should (equal (snowflake--prepare-string "select \"a--b\" from t")
                   "select \"a--b\" from t;"))))

(ert-deftest snowflake-test-prepare-open-string-or-comment ()
  (let ((snowflake-auto-terminate t))
    ;; A ";" appended after an open string or "/*" comment would be
    ;; swallowed; such input is left alone.
    (should (equal (snowflake--prepare-string "select 1 /* explain later")
                   "select 1 /* explain later"))
    (should (equal (snowflake--prepare-string "select 'abc")
                   "select 'abc"))
    ;; A closed block comment is skipped like a line comment.
    (should (equal (snowflake--prepare-string "select 1 /* c */")
                   "select 1 /* c */\n;"))))

(ert-deftest snowflake-test-prepare-crlf ()
  (let ((snowflake-auto-terminate t))
    (should (equal (snowflake--prepare-string "select 1;\r\n-- done")
                   "select 1;\r\n-- done"))
    (should (equal (snowflake--prepare-string "select 1\r\n-- done")
                   "select 1\r\n-- done\n;"))))

;;; Error detection

(ert-deftest snowflake-test-parse-errors-line-pos ()
  (with-temp-buffer
    (insert " > select 1 fromm t;\n"
            "001003 (42000): 01b2f927-0000-c952-0000-a86d0032222e: "
            "SQL compilation error:\n"
            "syntax error line 2 at position 7 unexpected 'FROMM'.\n"
            "\n"
            " > ")
    (let ((errors (snowflake--parse-errors (point-min) (point-max))))
      (should (= (length errors) 1))
      (let ((err (car errors)))
        (should (= (plist-get err :line) 2))
        (should (= (plist-get err :pos) 7))
        (should (string-prefix-p "001003 (42000)" (plist-get err :message)))
        (should (string-suffix-p "unexpected 'FROMM'."
                                 (plist-get err :message)))))))

(ert-deftest snowflake-test-parse-errors-real-cli-format ()
  ;; The interactive CLI prefixes headers with "Error occurred: " and
  ;; terminates the error with the next prompt, no blank line.
  (with-temp-buffer
    (insert " > select * fromm mytable;\n"
            "\n"
            "Error occurred: 001003 (42000): "
            "01c5d78d-0107-79b5-0001-4b263e084a3a: SQL compilation error:\n"
            "syntax error line 1 at position 9 unexpected 'fromm'.\n"
            " > ")
    (let ((errors (snowflake--parse-errors (point-min) (point-max))))
      (should (= (length errors) 1))
      (should (= (plist-get (car errors) :line) 1))
      (should (= (plist-get (car errors) :pos) 9))
      (should (string-prefix-p "Error occurred: 001003"
                               (plist-get (car errors) :message)))))
  ;; CLI chatter like "Error occurred: SQL rendering error" has no
  ;; "NNNNNN (SQLSTATE):" header and is not an error.
  (with-temp-buffer
    (insert "Unknown command: exit\n"
            "Error occurred: SQL rendering error\n"
            " > ")
    (should-not (snowflake--parse-errors (point-min) (point-max)))))

(defconst snowflake-test--wrap-newline
  (propertize "\n" 'ghostel-wrap t)
  "A newline as ghostel inserts it when soft-wrapping a long line.")

(ert-deftest snowflake-test-parse-errors-wrapped-location ()
  ;; The terminal hard-wraps the CLI's long header lines at the
  ;; window width — even mid-number.  Ghostel marks those newlines
  ;; with the `ghostel-wrap' property; the location and the message
  ;; must come out unbroken.
  (with-temp-buffer
    (insert "Error occurred: 000904 (42000): "
            "01c5d797-0107-7a7c-0001-4b263e084a3a: "
            "SQL compilation error: error line 1 at position 1"
            snowflake-test--wrap-newline
            "0\n"
            "invalid identifier 'FF'\n"
            " > ")
    (let ((errors (snowflake--parse-errors (point-min) (point-max))))
      (should (= (length errors) 1))
      (should (= (plist-get (car errors) :line) 1))
      (should (= (plist-get (car errors) :pos) 10))
      (should (string-match-p "at position 10\ninvalid identifier"
                              (plist-get (car errors) :message)))))
  ;; A wrap point inside a word instead of a number.
  (with-temp-buffer
    (insert "001003 (42000): x: SQL compilation error:\n"
            "syntax error line 2 at positio"
            snowflake-test--wrap-newline
            "n 7 unexpected 'FROMM'.\n"
            "\n")
    (let ((errors (snowflake--parse-errors (point-min) (point-max))))
      (should (= (length errors) 1))
      (should (= (plist-get (car errors) :line) 2))
      (should (= (plist-get (car errors) :pos) 7))))
  ;; A wrap-continuation line is never an error terminator, even
  ;; when it happens to look like a prompt.
  (with-temp-buffer
    (insert "001003 (42000): x: SQL compilation error:\n"
            "syntax error line 2 at position 7 unexpected '="
            snowflake-test--wrap-newline
            ">'.\n"
            "\n")
    (let ((errors (snowflake--parse-errors (point-min) (point-max))))
      (should (= (length errors) 1))
      (should (string-suffix-p "unexpected '=>'."
                               (plist-get (car errors) :message))))))

(ert-deftest snowflake-test-parse-errors-no-location ()
  ;; Errors without a "line L at position P" location, e.g. a
  ;; nonexistent table, still carry the full message.
  (with-temp-buffer
    (insert "002003 (42S02): 01b2f927-0000: SQL compilation error:\n"
            "Object 'NOPE' does not exist or not authorized.\n"
            "\n")
    (let ((errors (snowflake--parse-errors (point-min) (point-max))))
      (should (= (length errors) 1))
      (should-not (plist-get (car errors) :line))
      (should-not (plist-get (car errors) :pos))
      (should (string-match-p "does not exist"
                              (plist-get (car errors) :message))))))

(ert-deftest snowflake-test-parse-errors-multiple ()
  ;; A second header directly after an error terminates the first.
  (with-temp-buffer
    (insert "001003 (42000): x: SQL compilation error:\n"
            "syntax error line 1 at position 7 unexpected 'FROMM'.\n"
            "000904 (42000): y: SQL compilation error: "
            "error line 3 at position 2\n"
            "invalid identifier 'ZAP'.\n"
            "\n"
            " > ")
    (let ((errors (snowflake--parse-errors (point-min) (point-max))))
      (should (= (length errors) 2))
      (should (= (plist-get (car errors) :line) 1))
      (should (= (plist-get (car errors) :pos) 7))
      (should (= (plist-get (cadr errors) :line) 3))
      (should (= (plist-get (cadr errors) :pos) 2))
      (should (string-match-p "ZAP" (plist-get (cadr errors) :message))))))

(ert-deftest snowflake-test-parse-errors-none ()
  (with-temp-buffer
    (insert " > select 1;\n+---+\n| 1 |\n+---+\n1 Row(s) produced.\n > ")
    (should-not (snowflake--parse-errors (point-min) (point-max)))))

(ert-deftest snowflake-test-parse-errors-incomplete ()
  ;; An error without terminator is still being printed; it is only
  ;; returned once the following blank/prompt line arrived.
  (with-temp-buffer
    (insert "001003 (42000): x: SQL compilation error:\n"
            "syntax error line 1 at position 7")
    (should-not (snowflake--parse-errors (point-min) (point-max)))
    (goto-char (point-max))
    (insert "\n\n > ")
    (let ((errors (snowflake--parse-errors (point-min) (point-max))))
      (should (= (length errors) 1))
      (should (= (plist-get (car errors) :pos) 7)))))

(ert-deftest snowflake-test-parse-errors-end-positions ()
  ;; :end lets the caller advance the scan start past reported errors.
  (with-temp-buffer
    (insert "001003 (42000): x: SQL compilation error:\n"
            "syntax error line 1 at position 0 unexpected 'X'.\n"
            "\n")
    (let* ((errors (snowflake--parse-errors (point-min) (point-max)))
           (end (plist-get (car errors) :end)))
      (should (= (length errors) 1))
      ;; Scanning again from :end finds nothing new.
      (should-not (snowflake--parse-errors end (point-max))))))

(ert-deftest snowflake-test-error-region ()
  (with-temp-buffer
    (insert "select 1\nfromm t;\n")
    (let ((beg (copy-marker (point-min))))
      ;; Line/column math lands on the whole token.
      (let ((region (snowflake--error-region (current-buffer) beg 2 0)))
        (should (equal (buffer-substring (car region) (cdr region))
                       "fromm")))
      ;; Symbol syntax: underscores belong to the token.
      (erase-buffer)
      (insert "select syntax_error from t;\n")
      (let ((region (snowflake--error-region (current-buffer) beg 1 7)))
        (should (equal (buffer-substring (car region) (cdr region))
                       "syntax_error"))))))

(ert-deftest snowflake-test-error-region-mid-line-start ()
  ;; A region starting mid-line offsets line-1 positions by the
  ;; marker's column.
  (with-temp-buffer
    (insert "select 1; select fromm t;\n")
    (goto-char (point-min))
    (search-forward "; ")
    (let* ((beg (copy-marker (point)))
           (region (snowflake--error-region (current-buffer) beg 1 7)))
      (should (equal (buffer-substring (car region) (cdr region))
                     "fromm")))))

(ert-deftest snowflake-test-error-region-token-bounds ()
  (with-temp-buffer
    (insert "select ??? from t;\n")
    (let ((beg (copy-marker (point-min))))
      ;; Non-symbol characters still get a 1-char highlight.
      (let ((region (snowflake--error-region (current-buffer) beg 1 7)))
        (should (equal (buffer-substring (car region) (cdr region)) "?")))
      ;; A position past the end of the line clamps into it.
      (let ((region (snowflake--error-region (current-buffer) beg 1 99)))
        (should (= (cdr region) (1- (point-max))))
        (should (= (car region) (- (point-max) 2)))))))

(ert-deftest snowflake-test-error-region-leading-trivia ()
  ;; The CLI numbers lines from the statement's first code token, so
  ;; blank lines and comments at the start of the sent region (e.g. a
  ;; paragraph send) do not count.
  (with-temp-buffer
    (sql-mode)
    (insert "\n-- context\nSELECT 1, ff;\n")
    (let* ((beg (copy-marker (point-min)))
           (region (snowflake--error-region (current-buffer) beg 1 10)))
      (should (equal (buffer-substring (car region) (cdr region)) "ff")))
    ;; Indentation before the statement does not count either.
    (erase-buffer)
    (insert "\n-- context\n  SELECT 1, ff;\n")
    (let* ((beg (copy-marker (point-min)))
           (region (snowflake--error-region (current-buffer) beg 1 10)))
      (should (equal (buffer-substring (car region) (cdr region)) "ff")))
    ;; Later lines count from the first code line as well.
    (erase-buffer)
    (insert "\n-- context\nSELECT 1,\nff2;\n")
    (let* ((beg (copy-marker (point-min)))
           (region (snowflake--error-region (current-buffer) beg 2 0)))
      (should (equal (buffer-substring (car region) (cdr region)) "ff2")))))

(ert-deftest snowflake-test-highlight-fallback-skips-trivia ()
  ;; The whole-region fallback for errors without a location leaves
  ;; leading blank lines and comments unhighlighted too.
  (with-temp-buffer
    (sql-mode)
    (insert "\n-- context\n  select * from nope;  \n")
    ;; The region includes leading trivia, indentation and trailing
    ;; whitespace/newline; the overlay must not.
    (snowflake--highlight-errors
     (list (current-buffer)
           (copy-marker (point-min))
           (copy-marker (point-max) t))
     (list (list :message "002003 (42S02): nope" :line nil :pos nil
                 :end 1)))
    (let ((ov (car snowflake--error-overlays)))
      (should (equal (buffer-substring (overlay-start ov) (overlay-end ov))
                     "select * from nope;")))))

(ert-deftest snowflake-test-error-region-fallback ()
  (with-temp-buffer
    (insert "select 1;\n")
    (let ((beg (copy-marker (point-min))))
      ;; No location or one outside the buffer: nil, the caller
      ;; highlights the whole sent region instead.
      (should-not (snowflake--error-region (current-buffer) beg nil nil))
      (should-not (snowflake--error-region (current-buffer) beg 99 0)))
    (let ((dead (generate-new-buffer "snowflake-test-dead"))
          (beg (copy-marker (point-min))))
      (kill-buffer dead)
      (should-not (snowflake--error-region dead beg 1 0)))))

(ert-deftest snowflake-test-highlight-and-clear ()
  (with-temp-buffer
    (insert "select fromm t;\n")
    (let ((src (current-buffer)))
      (snowflake--highlight-errors
       (list src (copy-marker (point-min)) (copy-marker (1- (point-max))))
       (list (list :message "001003 (42000): boom" :line 1 :pos 7 :end 1)
             (list :message "002003 (42S02): nope" :line nil :pos nil
                   :end 1)))
      (should (= (length snowflake--error-overlays) 2))
      (let* ((token (cl-find 5 snowflake--error-overlays
                             :key (lambda (ov) (- (overlay-end ov)
                                                  (overlay-start ov)))))
             (whole (car (remq token snowflake--error-overlays))))
        ;; The located error sits on its token, the other one covers
        ;; the whole sent region.
        (should (equal (buffer-substring (overlay-start token)
                                         (overlay-end token))
                       "fromm"))
        (should (eq (overlay-get token 'face) 'snowflake-error))
        (should (equal (overlay-get token 'help-echo)
                       "001003 (42000): boom"))
        (should (= (overlay-start whole) (point-min)))
        (should (= (overlay-end whole) (1- (point-max))))
        (should (equal (overlay-get whole 'help-echo)
                       "002003 (42S02): nope"))
        (snowflake-clear-errors)
        (should-not snowflake--error-overlays)
        (should-not (overlay-buffer token))
        (should-not (overlay-buffer whole))))))

(ert-deftest snowflake-test-scan-output-marker-regression ()
  ;; Ghostel's full redraws (e.g. on reflow) collapse the output-start
  ;; marker backwards; the integer floor keeps rescans from reporting
  ;; the same error twice.
  (let ((repl (generate-new-buffer "snowflake-test-repl"))
        (src (generate-new-buffer "snowflake-test-src")))
    (unwind-protect
        (progn
          (with-current-buffer src
            (insert "select syntax_error from t;\n"))
          (with-current-buffer repl
            (insert " > select syntax_error from t;\n")
            (setq-local snowflake--error-source
                        (list src
                              (with-current-buffer src
                                (copy-marker (point-min)))
                              (with-current-buffer src
                                (copy-marker (point-max) t))))
            (setq-local snowflake--output-start (copy-marker (point-max)))
            (setq-local snowflake--output-floor (point-max))
            (insert "001003 (42000): x: SQL compilation error:\n"
                    "syntax error line 1 at position 7 "
                    "unexpected 'syntax_error'.\n"
                    "\n > "))
          (snowflake--scan-output repl)
          (let ((overlays (buffer-local-value 'snowflake--error-overlays
                                              src)))
            (should (= (length overlays) 1))
            (should (equal (with-current-buffer src
                             (buffer-substring
                              (overlay-start (car overlays))
                              (overlay-end (car overlays))))
                           "syntax_error")))
          ;; Simulate a redraw collapsing the marker to point-min.
          (with-current-buffer repl
            (set-marker snowflake--output-start (point-min)))
          (snowflake--scan-output repl)
          (should (= (length (buffer-local-value 'snowflake--error-overlays
                                                 src))
                     1)))
      (kill-buffer repl)
      (kill-buffer src))))

;;; Statement boundaries

(ert-deftest snowflake-test-send-statement-at-point-min ()
  ;; `sql-beginning-of-statement' recurses endlessly at buffer start;
  ;; `snowflake-send-statement' must not trip over that.
  (with-temp-buffer
    (sql-mode)
    (insert "select syntax_error from t;")
    (goto-char (point-min))
    (let (sent)
      (cl-letf (((symbol-function 'snowflake--send)
                 (lambda (string &rest _) (setq sent string))))
        (snowflake-send-statement))
      (should (equal sent "select syntax_error from t;")))))

;;; Displaying the REPL

(ert-deftest snowflake-test-display-repl ()
  (let (displayed popped)
    (cl-letf (((symbol-function 'display-buffer)
               (lambda (buf &rest _) (setq displayed buf)))
              ((symbol-function 'pop-to-buffer)
               (lambda (buf &rest _) (setq popped buf))))
      (let ((snowflake-display-repl-buffer-function nil))
        (snowflake--display-repl (current-buffer) nil)
        (should-not displayed)
        (should-not popped))
      (let ((snowflake-display-repl-buffer-function #'display-buffer))
        (snowflake--display-repl (current-buffer) nil)
        (should (eq displayed (current-buffer))))
      (let ((snowflake-display-repl-buffer-function t))
        (snowflake--display-repl (current-buffer) nil)
        (should (eq popped (current-buffer))))
      ;; A prefix argument selects even when display is off.
      (setq popped nil)
      (let ((snowflake-display-repl-buffer-function nil))
        (snowflake--display-repl (current-buffer) 'select)
        (should (eq popped (current-buffer)))))))

(ert-deftest snowflake-test-display-unless-visible ()
  (let (displayed gbw-args)
    (cl-letf (((symbol-function 'display-buffer)
               (lambda (buf &rest _) (setq displayed buf)))
              ((symbol-function 'get-buffer-window)
               (lambda (&rest args) (setq gbw-args args) nil)))
      (snowflake-display-unless-visible (current-buffer))
      ;; Windows on other frames count: ALL-FRAMES must be `visible'.
      (should (equal gbw-args (list (current-buffer) 'visible)))
      (should (eq displayed (current-buffer))))
    (setq displayed nil)
    (cl-letf (((symbol-function 'display-buffer)
               (lambda (buf &rest _) (setq displayed buf)))
              ((symbol-function 'get-buffer-window) (lambda (&rest _) t)))
      (snowflake-display-unless-visible (current-buffer))
      (should-not displayed))))

;;; Connection discovery

(ert-deftest snowflake-test-connection-names ()
  (let ((snowflake-cli-program (expand-file-name "fake-snow"
                                                 snowflake-test-directory))
        (snowflake--connections nil))
    (should (equal (snowflake--connection-names)
                   '("dbb-dev" "dbb-test" "dbb-prod")))
    ;; The default connection is flagged in the cache.
    (should (equal (car (rassq t snowflake--connections)) "dbb-test"))))

(ert-deftest snowflake-test-connection-names-cached ()
  (let ((snowflake-cli-program "/nonexistent/snow")
        (snowflake--connections '(("cached" . t))))
    ;; Cache hit: the (broken) CLI is not called.
    (should (equal (snowflake--connection-names) '("cached")))
    ;; Refresh bypasses the cache and surfaces the CLI error.
    (should-error (snowflake--connection-names t))))

(ert-deftest snowflake-test-connection-list-failure ()
  (let ((snowflake-cli-program "false"))
    (should-error (snowflake--fetch-connections) :type 'user-error)))

;;; REPL buffer predicates

(ert-deftest snowflake-test-repl-buffer-p ()
  (with-temp-buffer
    (should-not (snowflake--repl-buffer-p (current-buffer)))
    (setq-local snowflake--connection nil)
    ;; A buffer-local binding, even nil, marks a REPL buffer.
    (should (snowflake--repl-buffer-p (current-buffer)))))

(ert-deftest snowflake-test-repl-buffer-p-dead-buffer ()
  (let ((buffer (generate-new-buffer "snowflake-test")))
    (kill-buffer buffer)
    (should-not (snowflake--repl-buffer-p buffer))
    (should-not (snowflake--repl-buffer-p nil))))

(ert-deftest snowflake-test-buffer-name ()
  (should (equal (snowflake--buffer-name "dbb-dev") "*snowflake: dbb-dev*"))
  (should (equal (snowflake--buffer-name nil) "*snowflake: default*")))

(ert-deftest snowflake-test-repl-buffer-name-clash ()
  ;; A non-REPL buffer occupying the REPL's name must not be handed
  ;; to `ghostel-exec'.
  (let ((buffer (get-buffer-create "*snowflake: default*")))
    (unwind-protect
        (should-error (snowflake--repl-buffer nil) :type 'user-error)
      (kill-buffer buffer)))
  (should-not (snowflake--repl-buffer nil))
  (let ((buffer (get-buffer-create "*snowflake: default*")))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local snowflake--connection nil)
          (should (eq (snowflake--repl-buffer nil) buffer)))
      (kill-buffer buffer))))

;;; SQL product

(ert-deftest snowflake-test-product-registered ()
  (should (assoc 'snowflake sql-product-alist))
  (should (equal (sql-get-product-feature 'snowflake :name) "Snowflake"))
  ;; :font-lock is an indirect feature; it resolves through
  ;; `snowflake-font-lock-keywords' to a non-empty keyword list.
  (let ((keywords (sql-get-product-feature 'snowflake :font-lock)))
    (should (consp keywords))
    (should (cl-every #'consp keywords))))

(ert-deftest snowflake-test-statement-regexp ()
  (let ((regexp (sql-statement-regexp 'snowflake)))
    (should (string-match-p regexp "copy into t from @stage"))
    (should (string-match-p regexp "show tables"))
    (should (string-match-p regexp "with t as (select 1) select * from t"))
    ;; ANSI starters still match.
    (should (string-match-p regexp "select 1"))
    (should-not (string-match-p regexp "foo bar"))))

(ert-deftest snowflake-test-font-lock-and-mode-line ()
  (with-temp-buffer
    (sql-mode)
    (setq-local sql-product 'snowflake)
    (sql-highlight-product)
    (insert "select 1 qualify row_number() over (order by 1) = 1;\n"
            "create table t (v variant);\n"
            "show tables;\n")
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "qualify")
    (should (eq (get-text-property (match-beginning 0) 'face)
                'font-lock-keyword-face))
    (search-forward "variant")
    (should (eq (get-text-property (match-beginning 0) 'face)
                'font-lock-type-face))
    (search-forward "show")
    (should (eq (get-text-property (match-beginning 0) 'face)
                'font-lock-keyword-face))
    (should (equal mode-name "SQL[Snowflake]"))))

;;; Minor mode SQL product switching

(ert-deftest snowflake-test-minor-mode-sets-product ()
  (let ((global-product (default-value 'sql-product)))
    (with-temp-buffer
      (sql-mode)
      (snowflake-minor-mode 1)
      (should (eq sql-product 'snowflake))
      (should (local-variable-p 'sql-product))
      (should (equal mode-name "SQL[Snowflake]")))
    ;; The global product is untouched.
    (should (eq (default-value 'sql-product) global-product))))

(ert-deftest snowflake-test-minor-mode-restores-product-on-disable ()
  (with-temp-buffer
    (sql-mode)
    (snowflake-minor-mode 1)
    (should (eq sql-product 'snowflake))
    (snowflake-minor-mode -1)
    (should (eq sql-product 'ansi))
    (should-not (local-variable-p 'sql-product))
    (should (equal mode-name "SQL[ANSI]"))))

(ert-deftest snowflake-test-minor-mode-disable-keeps-user-product ()
  (with-temp-buffer
    (sql-mode)
    (snowflake-minor-mode 1)
    ;; The user switches products while the mode is on.
    (setq-local sql-product 'postgres)
    (snowflake-minor-mode -1)
    (should (eq sql-product 'postgres))))

(ert-deftest snowflake-test-minor-mode-keeps-buffer-local-ansi ()
  (with-temp-buffer
    (sql-mode)
    ;; Buffer-local ansi (e.g. from a file-local variable) counts as
    ;; an explicit choice.
    (setq-local sql-product 'ansi)
    (snowflake-minor-mode 1)
    (should (eq sql-product 'ansi))))

(ert-deftest snowflake-test-minor-mode-set-product-disabled ()
  (let ((snowflake-set-sql-product nil))
    (with-temp-buffer
      (sql-mode)
      (snowflake-minor-mode 1)
      (should-not (eq sql-product 'snowflake)))))

(ert-deftest snowflake-test-minor-mode-keeps-explicit-product ()
  (with-temp-buffer
    (sql-mode)
    (setq-local sql-product 'postgres)
    (snowflake-minor-mode 1)
    (should (eq sql-product 'postgres))))

;;; Completion

(defmacro snowflake-test--with-sql-buffer (&rest body)
  "Run BODY in a temporary `sql-mode' buffer with completion set up.
The CLI is fake-snow, the object cache is fresh, the fetch trigger
is `manual' (rebind inside BODY before enabling differently) and
`snowflake-minor-mode' is enabled."
  (declare (indent 0) (debug t))
  `(let ((snowflake-cli-program (expand-file-name "fake-snow"
                                                  snowflake-test-directory))
         (snowflake-completion t)
         (snowflake-completion-fetch-trigger 'manual)
         (snowflake--objects-cache (make-hash-table :test #'equal)))
     (with-temp-buffer
       (sql-mode)
       (snowflake-minor-mode 1)
       ,@body)))

(defun snowflake-test--wait-for-fetch (connection subkey)
  "Wait until CONNECTION's SUBKEY cache entry is no longer pending."
  (let ((key (snowflake--objects-cache-key connection subkey))
        (deadline (+ (float-time) 5)))
    (while (and (eq (plist-get (gethash key snowflake--objects-cache) :state)
                    'pending)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (plist-get (gethash key snowflake--objects-cache) :state)))

(defun snowflake-test--capf-candidates (prefix)
  "Return all completions of PREFIX from `snowflake-completion-at-point'."
  (let ((capf (snowflake-completion-at-point)))
    (and capf (all-completions prefix (nth 2 capf) nil))))

(ert-deftest snowflake-test-parse-objects ()
  (let ((candidates (snowflake--parse-objects
                     "[{\"name\": \"T1\", \"kind\": \"TABLE\"},
                       {\"name\": \"V1\", \"kind\": \"VIEW\"}]")))
    (should (equal candidates '("T1" "V1")))
    (should (eq (get-text-property 0 'snowflake-kind (car candidates))
                'table))
    (should (eq (get-text-property 0 'snowflake-kind (cadr candidates))
                'view)))
  ;; JSON null kind (parses as :null, not nil) falls back to table.
  (let ((candidates (snowflake--parse-objects
                     "[{\"name\": \"T\", \"kind\": null}]")))
    (should (eq (get-text-property 0 'snowflake-kind (car candidates))
                'table)))
  (should (equal (snowflake--parse-schemas "[{\"name\": \"PUBLIC\"}]")
                 '("PUBLIC")))
  (should-error (snowflake--parse-objects "not json")))

(ert-deftest snowflake-test-completion-qualifier ()
  (with-temp-buffer
    (sql-mode)
    (insert "select 1 from Reporting.ev")
    (should (equal (snowflake--completion-qualifier (- (point) 2))
                   "Reporting"))
    (erase-buffer)
    (insert "select 1 from otherdb.reporting.")
    (should (equal (snowflake--completion-qualifier (point))
                   "otherdb.reporting"))
    (erase-buffer)
    (insert "select 1 ")
    (should-not (snowflake--completion-qualifier (point)))))

(ert-deftest snowflake-test-resolve-qualifier ()
  (let ((schemas '("PUBLIC" "my_schema")))
    ;; Case-insensitive match returns the actual schema name.
    (should (equal (snowflake--resolve-qualifier "public" schemas) "PUBLIC"))
    (should (equal (snowflake--resolve-qualifier "MY_SCHEMA" schemas)
                   "my_schema"))
    ;; Unknown plain qualifier: likely a table alias.
    (should-not (snowflake--resolve-qualifier "t" schemas))
    (should-not (snowflake--resolve-qualifier "t" nil))
    ;; Database-qualified names bypass the schema list.
    (should (equal (snowflake--resolve-qualifier "otherdb.reporting" nil)
                   "OTHERDB.REPORTING"))))

(ert-deftest snowflake-test-objects-query-quoting ()
  (should (equal (snowflake--objects-query "REPORTING")
                 "show terse objects in schema REPORTING"))
  (should (equal (snowflake--objects-query "OTHERDB.REPORTING")
                 "show terse objects in schema OTHERDB.REPORTING"))
  ;; Anything that is no plain unquoted identifier is quoted.
  (should (equal (snowflake--objects-query "my_schema")
                 "show terse objects in schema \"my_schema\""))
  (should (equal (snowflake--objects-query "MY SCHEMA")
                 "show terse objects in schema \"MY SCHEMA\""))
  (should (equal (snowflake--objects-query "2024_DATA")
                 "show terse objects in schema \"2024_DATA\""))
  (should (equal (snowflake--objects-query "OTHERDB.my schema")
                 "show terse objects in schema OTHERDB.\"my schema\"")))

(ert-deftest snowflake-test-refresh-skips-aliases ()
  (snowflake-test--with-sql-buffer
    (insert "select t.co")
    (snowflake-refresh-completions)
    (should (eq (snowflake-test--wait-for-fetch nil :objects) 'ready))
    ;; Resolution runs against the refreshed schema list, which does
    ;; not contain the alias qualifier "t".
    (should (eq (snowflake-test--wait-for-fetch nil :schemas) 'ready))
    (accept-process-output nil 0.2)
    (should-not (gethash (snowflake--objects-cache-key nil "T")
                         snowflake--objects-cache))
    (should-not (gethash (snowflake--objects-cache-key nil "t")
                         snowflake--objects-cache))))

(ert-deftest snowflake-test-refresh-chains-qualifier-fetch ()
  (snowflake-test--with-sql-buffer
    ;; Cold cache: the schema qualifier resolves against the freshly
    ;; fetched schema list, then that schema's objects are fetched.
    (insert "select 1 from reporting.")
    (snowflake-refresh-completions)
    (should (eq (snowflake-test--wait-for-fetch nil :schemas) 'ready))
    (should (eq (snowflake-test--wait-for-fetch nil "REPORTING") 'ready))
    (should (member "EVENTS"
                    (snowflake--cached-candidates nil "REPORTING")))))

(ert-deftest snowflake-test-capf-static ()
  (snowflake-test--with-sql-buffer
    (insert "sel")
    (let ((capf (snowflake-completion-at-point)))
      (should (equal (nth 0 capf) (- (point) 3)))
      (should (equal (nth 1 capf) (point)))
      (let ((all (all-completions "sel" (nth 2 capf) nil)))
        (should (member "select" all)))
      (should (equal (plist-get (nthcdr 3 capf) :exclusive) 'no)))
    (should (equal (snowflake--completion-annotate
                    (car (member "select" snowflake--static-candidates)))
                   " Keyword"))
    (should (equal (snowflake--completion-annotate
                    (car (member "variant" snowflake--static-candidates)))
                   " Type"))
    (should (equal (snowflake--completion-annotate
                    (car (member "parse_json" snowflake--static-candidates)))
                   " Function"))
    ;; Manual trigger: no fetch was started.
    (should (zerop (hash-table-count snowflake--objects-cache)))))

(ert-deftest snowflake-test-capf-case-fold ()
  (snowflake-test--with-sql-buffer
    (insert "SEL")
    (should (member "select" (snowflake-test--capf-candidates "SEL")))))

(ert-deftest snowflake-test-fetch-objects-async ()
  (snowflake-test--with-sql-buffer
    (snowflake--fetch-objects nil :objects)
    (should (eq (snowflake-test--wait-for-fetch nil :objects) 'ready))
    (insert "ord")
    (let ((all (snowflake-test--capf-candidates "ord")))
      (should (member "ORDERS" all))
      (should (member "ORDERS_V" all)))
    (let* ((candidates (snowflake--cached-candidates nil :objects))
           (orders (car (member "ORDERS" candidates)))
           (orders-v (car (member "ORDERS_V" candidates))))
      (should (equal (snowflake--completion-annotate orders) " Table"))
      (should (equal (snowflake--completion-annotate orders-v) " View"))
      (should (eq (snowflake--completion-kind orders) 'class))
      (should (eq (snowflake--completion-kind orders-v) 'interface)))))

(ert-deftest snowflake-test-fetch-in-flight ()
  (snowflake-test--with-sql-buffer
    (let ((calls 0))
      (cl-letf* ((real-make-process (symbol-function 'make-process))
                 ((symbol-function 'make-process)
                  (lambda (&rest args)
                    (cl-incf calls)
                    (apply real-make-process args))))
        (snowflake--fetch-objects nil :objects)
        (snowflake--fetch-objects nil :objects)
        (should (= calls 1)))
      (snowflake-test--wait-for-fetch nil :objects))))

(ert-deftest snowflake-test-fetch-force-kills-pending ()
  (snowflake-test--with-sql-buffer
    ;; Start a hanging fetch.
    (let ((process-environment (cons "FAKE_SNOW_SLEEP=30"
                                     process-environment)))
      (snowflake--fetch-objects nil :objects))
    (let* ((key (snowflake--objects-cache-key nil :objects))
           (entry (gethash key snowflake--objects-cache))
           (proc (plist-get entry :process)))
      (should (eq (plist-get entry :state) 'pending))
      (should (process-live-p proc))
      ;; A forced refetch kills the hung process and starts over.
      (snowflake--fetch-objects nil :objects 'force)
      (should-not (process-live-p proc))
      (should-not (eq (gethash key snowflake--objects-cache) entry))
      (should (eq (snowflake-test--wait-for-fetch nil :objects) 'ready)))))

(ert-deftest snowflake-test-objects-cache-scope-key ()
  (snowflake-test--with-sql-buffer
    (let ((snowflake-completion-object-scope 'schema))
      (snowflake--fetch-objects nil :objects)
      (should (eq (snowflake-test--wait-for-fetch nil :objects) 'ready)))
    ;; A different scope starts from a fresh cache entry.
    (let ((snowflake-completion-object-scope 'database))
      (should-not (snowflake--cached-candidates nil :objects)))))

(ert-deftest snowflake-test-fetch-failure ()
  (snowflake-test--with-sql-buffer
    (let ((process-environment (cons "FAKE_SNOW_FAIL=1" process-environment)))
      (snowflake--fetch-objects nil :objects)
      (should (eq (snowflake-test--wait-for-fetch nil :objects) 'error))
      ;; Static candidates keep working.
      (insert "sel")
      (should (member "select" (snowflake-test--capf-candidates "sel")))
      ;; Error cooldown: a non-forced fetch does not restart.
      (snowflake--fetch-objects nil :objects)
      (should (eq (plist-get (gethash (snowflake--objects-cache-key
                                       nil :objects)
                                      snowflake--objects-cache)
                             :state)
                  'error)))))

(ert-deftest snowflake-test-capf-qualified ()
  (snowflake-test--with-sql-buffer
    (let ((snowflake-completion-fetch-trigger 'completion))
      ;; Seed the schema list so the qualifier is known.
      (snowflake--fetch-objects nil :schemas)
      (should (eq (snowflake-test--wait-for-fetch nil :schemas) 'ready))
      (insert "select 1 from reporting.ev")
      ;; First attempt starts the schema fetch, result pending.
      (snowflake-completion-at-point)
      (should (eq (snowflake-test--wait-for-fetch nil "REPORTING") 'ready))
      (let ((all (snowflake-test--capf-candidates "ev")))
        (should (member "EVENTS" all))
        ;; Statics are not offered after a qualifier.
        (should-not (member "select" all))))))

(ert-deftest snowflake-test-capf-qualified-unknown-schema ()
  (snowflake-test--with-sql-buffer
    (let ((snowflake-completion-fetch-trigger 'completion))
      (snowflake--fetch-objects nil :schemas)
      (should (eq (snowflake-test--wait-for-fetch nil :schemas) 'ready))
      (insert "select t.co")
      (snowflake-completion-at-point)
      ;; "T" is no known schema: no fetch was started for it.
      (should-not (gethash (snowflake--objects-cache-key nil "T")
                           snowflake--objects-cache)))))

(ert-deftest snowflake-test-minor-mode-capf-hook ()
  (snowflake-test--with-sql-buffer
    (should (memq #'snowflake-completion-at-point
                  completion-at-point-functions))
    (snowflake-minor-mode -1)
    (should-not (memq #'snowflake-completion-at-point
                      completion-at-point-functions)))
  (let ((snowflake-completion nil))
    (with-temp-buffer
      (sql-mode)
      (snowflake-minor-mode 1)
      (should-not (memq #'snowflake-completion-at-point
                        completion-at-point-functions)))))

(ert-deftest snowflake-test-capf-in-comment ()
  (snowflake-test--with-sql-buffer
    (insert "-- sel")
    (should-not (snowflake-completion-at-point))))

(ert-deftest snowflake-test-completion-connection ()
  (let ((repl (generate-new-buffer "snowflake-test-repl")))
    (unwind-protect
        (with-temp-buffer
          (let ((snowflake-default-connection "from-default"))
            (should (equal (snowflake--completion-connection) "from-default"))
            (with-current-buffer repl
              (setq-local snowflake--connection "dbb-dev")
              ;; A REPL buffer completes for its own connection.
              (should (equal (snowflake--completion-connection) "dbb-dev")))
            (snowflake--link-buffer repl)
            (should (equal (snowflake--completion-connection) "dbb-dev"))
            ;; The link's connection survives the REPL buffer's death.
            (kill-buffer repl)
            (should (equal (snowflake--completion-connection) "dbb-dev"))))
      (when (buffer-live-p repl) (kill-buffer repl)))))

(ert-deftest snowflake-test-link-buffer-connect-trigger ()
  (snowflake-test--with-sql-buffer
    (let ((snowflake-completion-fetch-trigger 'connect)
          (repl (generate-new-buffer "snowflake-test-repl")))
      (unwind-protect
          (progn
            (with-current-buffer repl
              (setq-local snowflake--connection "dbb-dev"))
            (snowflake--link-buffer repl)
            (should (eq snowflake-buffer repl))
            (should (eq (snowflake-test--wait-for-fetch "dbb-dev" :objects)
                        'ready))
            (should (eq (snowflake-test--wait-for-fetch "dbb-dev" :schemas)
                        'ready)))
        (kill-buffer repl)))))

(provide 'snowflake-test)
;;; snowflake-test.el ends here
