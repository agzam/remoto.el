# Every emacs invocation sandboxes user-emacs-directory: neither -Q nor
# --batch relocates it, so stray runs would write into the real ~/.emacs.d
SANDBOX = $(CURDIR)/.sandbox
ELPA_DIR = $(CURDIR)/.elpa

EMACS_BATCH = emacs -Q --batch --init-directory $(SANDBOX) \
	--eval "(setq package-user-dir \"$(ELPA_DIR)\")" \
	--eval "(require 'package)" \
	--eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))" \
	--eval "(package-initialize)"

EMACS_SANDBOX = emacs -Q --init-directory $(SANDBOX) \
	--eval "(setq package-user-dir \"$(ELPA_DIR)\")" \
	--eval "(require 'package)" \
	--eval "(package-initialize)"

.PHONY: help test test-embark test-integration test-all deps lint check-autoloads check-compile compile clean sandbox

help:
	@echo "Available commands:"
	@echo "  make deps              Install dependencies"
	@echo "  make sandbox           Launch emacs -Q with remoto + embark loaded"
	@echo "  make test              Run unit tests"
	@echo "  make test-integration  Run integration tests (needs network)"
	@echo "  make test-all          Run all tests"
	@echo "  make lint              package-lint and checkdoc the package files"
	@echo "  make compile           Byte-compile the package"
	@echo "  make check-autoloads   Generate and load autoloads"
	@echo "  make check-compile     Check for clean byte-compilation"
	@echo "  make clean             Remove compiled files"

$(ELPA_DIR):
	@echo "Installing dependencies..."
	$(EMACS_BATCH) \
	--eval "(package-refresh-contents)" \
	--eval "(package-install 'ghub)" \
	--eval "(package-install 'buttercup)" \
	--eval "(package-install 'embark)" \
	--eval "(package-install 'orderless)" \
	--eval "(package-install 'package-lint)"

deps: $(ELPA_DIR)

sandbox: $(ELPA_DIR)
	$(EMACS_SANDBOX) --directory . \
	--eval "(require 'embark)" \
	--eval "(require 'remoto)" \
	--eval "(require 'remoto-embark)" \
	--eval "(remoto-embark-register)" \
	--eval "(global-set-key (kbd \"C-.\") #'embark-act)" \
	--eval "(message \"remoto sandbox: M-x remoto-browse | C-x C-f /github:owner/repo | C-. embark-act\")"

test: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	--eval "(setq buttercup-stack-frame-style 'omit)" \
	-l test/remoto-tests.el \
	--funcall buttercup-run

test-embark: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	--eval "(setq buttercup-stack-frame-style 'omit)" \
	-l test/remoto-embark-tests.el \
	--funcall buttercup-run

test-integration: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	--eval "(setq buttercup-stack-frame-style 'omit)" \
	-l test/remoto-integration-tests.el \
	--funcall buttercup-run

test-all: test test-embark test-integration

lint: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	--eval "(require 'package-lint)" \
	-f package-lint-batch-and-exit remoto.el remoto-embark.el remoto-topic.el
	$(EMACS_BATCH) \
	--eval "(require 'checkdoc)" \
	--eval "(setq checkdoc-verb-check-experimental-flag t)" \
	--eval "(dolist (f '(\"remoto.el\" \"remoto-embark.el\" \"remoto-topic.el\")) \
	           (with-current-buffer (find-file-noselect f) \
	             (check-parens) \
	             (checkdoc-current-buffer t)))" \
	--eval "(when-let* ((buf (get-buffer \"*Style Warnings*\")) \
	                    (text (with-current-buffer buf (buffer-string))) \
	                    (_ (string-match-p \"[.]el:[0-9]+:\" text))) \
	           (princ text) \
	           (kill-emacs 1))"

check-autoloads:
	@echo "Generating and loading autoloads..."
	rm -f remoto-autoloads.el
	$(EMACS_BATCH) \
	--eval "(require 'loaddefs-gen)" \
	--eval "(loaddefs-generate \"$(CURDIR)\" (expand-file-name \"remoto-autoloads.el\" \"$(CURDIR)\"))" \
	--eval "(load (expand-file-name \"remoto-autoloads.el\" \"$(CURDIR)\") nil 'nomessage)"

check-compile: $(ELPA_DIR) check-autoloads
	@echo "Checking byte-compilation..."
	$(EMACS_BATCH) \
	--eval "(setq byte-compile-error-on-warn t)" \
	--eval "(add-to-list 'load-path \".\")" \
	--eval "(dolist (f '(\"remoto.el\" \"remoto-embark.el\" \"remoto-topic.el\")) \
	           (unless (byte-compile-file f) (kill-emacs 1)))"
	rm -f remoto.elc remoto-embark.elc remoto-topic.elc

compile: $(ELPA_DIR)
	@echo "Byte-compiling package files..."
	$(EMACS_BATCH) \
	--eval "(add-to-list 'load-path \".\")" \
	--eval "(byte-compile-file \"remoto.el\")"

clean:
	@echo "Cleaning compiled files..."
	rm -f *.elc test/*.elc
	rm -rf $(ELPA_DIR) $(SANDBOX)
