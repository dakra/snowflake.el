EMACS ?= emacs
GHOSTEL_DIR ?= $(HOME)/.emacs.d/lib/ghostel/lisp
COMPAT_DIR ?= $(HOME)/.emacs.d/lib/compat
LOAD_PATH = -L . -L $(GHOSTEL_DIR) -L $(COMPAT_DIR) -L test
ELS = snowflake.el

.PHONY: all compile checkdoc test clean

all: compile checkdoc test

compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) \
		--eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile $(ELS)

checkdoc:
	$(EMACS) -Q --batch \
		--eval '(setq checkdoc-verb-check-experimental-flag nil)' \
		--eval '(progn (checkdoc-file "snowflake.el") (when (get-buffer "*Warnings*") (kill-emacs 1)))'

test:
	$(EMACS) -Q --batch $(LOAD_PATH) -l test/snowflake-test.el \
		-f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
