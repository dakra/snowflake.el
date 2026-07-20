# snowflake.el

[![CI](https://github.com/dakra/snowflake.el/actions/workflows/ci.yml/badge.svg)](https://github.com/dakra/snowflake.el/actions/workflows/ci.yml)

Write SQL in a `sql-mode` buffer and send it to a
[Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index)
`snow sql` REPL running in a [Ghostel](https://github.com/dakra/ghostel)
terminal buffer. The sql.el SQLi workflow, but with a real terminal
instead of comint, so the CLI's prompt_toolkit UI, paging and result
formatting all work natively.

## Features

- `M-x snowflake-connect` starts (or switches to) a REPL for any
  connection from `snow connection list`, one REPL buffer per
  connection.  Called from a `sql-mode` buffer it links that buffer to
  the REPL and enables `snowflake-minor-mode` in it.
- `snowflake-minor-mode` on top of `sql-mode` sends region, paragraph,
  statement, line, buffer or file to the linked REPL.
- Registers a `snowflake` sql.el product: `SQL[Snowflake]` mode line
  and highlighting for Snowflake keywords, types and functions on top
  of the ANSI ones.  The minor mode switches `sql-mode` buffers to it
  automatically; opt out with `snowflake-set-sql-product`.
- Completion at point (works with corfu, company's capf backend or
  plain `C-M-i`): SQL keywords, Snowflake functions and types, plus
  the tables, views and schemas of the buffer's connection, fetched
  asynchronously via the CLI and cached per connection
  (`snowflake-completion-fetch-trigger`).  Typing `other_schema.`
  fetches and completes that schema's objects
  (`snowflake-completion-qualified`).  Column completion after table
  aliases is not supported.
- Statements get a terminating `;` appended when missing
  (`snowflake-auto-terminate`); `!`-commands like `!queries` are left
  untouched.
- Multi-line statements are sent via bracketed paste, single lines as
  keystrokes so they enter the REPL history naturally.
- SQL errors the REPL reports for sent statements are highlighted in
  the source buffer: compilation errors with a `line L at position P`
  location get a wave underline on the offending token, other errors
  underline the whole sent text; the full message is shown in the
  echo area and as tooltip on the highlight.  Clear with
  `snowflake-clear-errors` (`C-c C-l`) or by sending again; disable
  with `snowflake-highlight-errors`, adapt the error detection with
  `snowflake-error-regexp`.
- `M-x snowflake-restart` re-runs `snow sql` in the same buffer after
  the CLI exits, e.g. when an auth token expired.
- `M-x snowflake` transient menu with all commands.

## Installation

### use-package

```elisp
(use-package snowflake
  :vc (:url "https://github.com/dakra/snowflake.el" :rev :newest)
  :hook (sql-mode . snowflake-minor-mode)
  :custom
  (snowflake-default-connection "dbb-dev"))
```

## Key bindings

`snowflake-minor-mode` shadows the comint-oriented sql.el bindings:

| Key       | Command                        |
|-----------|--------------------------------|
| `C-c C-c` | `snowflake-send-paragraph`     |
| `C-c C-r` | `snowflake-send-region`        |
| `C-c C-b` | `snowflake-send-buffer`        |
| `C-c C-s` | `snowflake-send-string`        |
| `C-c C-e` | `snowflake-send-statement`     |
| `C-c C-n` | `snowflake-send-line-and-next` |
| `C-c C-f` | `snowflake-send-file`          |
| `C-c C-z` | `snowflake-switch-to-repl`     |
| `C-c C-j` | `snowflake-set-buffer`         |
| `C-c C-k` | `snowflake-interrupt`          |
| `C-c C-l` | `snowflake-clear-errors`       |

All send commands accept a prefix argument to also select the REPL
window, except `snowflake-send-file`, where the prefix argument
prompts for the file instead; without it the window is displayed per
`snowflake-display-repl-buffer-function` (a function called with the
buffer, `t` for `pop-to-buffer`, or `nil` for no display — same
contract as `sql-display-sqli-buffer-function`).
`snowflake-display-unless-visible` displays the REPL only when it is
not already shown on some frame, e.g. on another monitor.

Unbound commands: `snowflake-connect`, `snowflake-restart`,
`snowflake-refresh-connections`, `snowflake-refresh-completions`,
`snowflake` (transient menu).

## Configuration

```elisp
(setq snowflake-cli-program "snow"                ; Snowflake CLI executable
      snowflake-cli-extra-args nil                ; extra args for `snow sql'
      snowflake-default-connection nil            ; nil = CLI default connection
      snowflake-auto-terminate t                  ; append missing ";"
      snowflake-highlight-errors t                ; highlight REPL errors in the source
      snowflake-error-regexp "^\\(?:Error occurred: \\)?\\([0-9]\\{6\\}\\) (\\([0-9A-Z]\\{5\\}\\)): " ; error header
      snowflake-set-sql-product t                 ; switch buffers to the snowflake dialect
      snowflake-completion t                      ; completion at point in the minor mode
      snowflake-completion-fetch-trigger 'connect ; fetch objects on REPL link
      snowflake-completion-object-scope 'schema   ; complete the default schema's objects
      snowflake-completion-qualified  t           ; schema.<TAB> completes that schema
      ;; #'display-buffer, t, nil or e.g. skip if on other monitor
      snowflake-display-repl-buffer-function #'snowflake-display-unless-visible)

```

## Notes

- For very large scripts prefer `snowflake-send-file` (`C-c C-f`),
  which uses the REPL's `!source` command instead of pasting.
- Error highlighting maps `line L at position P` locations relative
  to the first code token of the sent text — leading whitespace and
  comments don't count, matching how the CLI numbers statement
  lines.  When several statements are sent at
  once the CLI reports lines per failing statement, so highlights for
  any statement but the first can land on the wrong line (the
  message shown is still correct).  `snowflake-send-string` and
  `snowflake-send-file` (`!source`) don't highlight at all — their
  text has no buffer positions to map back to.

## License

GPLv3
