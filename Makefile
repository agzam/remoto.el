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

E2E_PROFILES = vanilla fido vertico orderless evil embark
E2E = $(EMACS_BATCH) --directory . -l test/remoto-e2e.el
KEYS = $(EMACS_BATCH) --directory . -l test/remoto-keys.el -f remoto-keys-main

.PHONY: help test test-embark test-integration test-all deps lint check-autoloads check-compile compile clean sandbox test-e2e test-e2e-update test-e2e-record test-fixtures-codeberg test-keys test-keys-live

help:
	@echo "Available commands:"
	@echo "  make deps              Install dependencies"
	@echo "  make sandbox           Launch emacs -Q with remoto + embark loaded"
	@echo "  make test              Run unit tests"
	@echo "  make test-e2e          Type the E2E cases in every profile (-j6 runs them in parallel)"
	@echo "  make test-e2e-PROFILE  The same in one profile: $(E2E_PROFILES)"
	@echo "  make test-e2e-update   Rewrite test/e2e/expected from a run (-j6 too)"
	@echo "  make test-e2e-record   Record the GitHub answers test/e2e/fixtures.jsonl lacks (needs REMOTO_E2E_TOKEN and network)"
	@echo "  make test-keys         Type the E2E cases into emacs -nw -q under tmux, against GitHub (needs tmux and network)"
	@echo "  make test-keys-PROFILE The same in one profile; REMOTO_KEYS_MAIN=1 adds origin/main beside it"
	@echo "  make test-keys-live    Type the C-x C-f and C-x d cases into the running Emacs, through its server"
	@echo "  make test-fixtures-codeberg  Record test/fixtures/codeberg.jsonl from codeberg.org (needs network)"
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
	--eval "(package-install 'vertico)" \
	--eval "(package-install 'marginalia)" \
	--eval "(package-install 'evil)" \
	--eval "(package-install 'package-lint)"

deps: $(ELPA_DIR)

sandbox: $(ELPA_DIR)
	$(EMACS_SANDBOX) --directory . \
	--eval "(require 'embark)" \
	--eval "(require 'remoto)" \
	--eval "(require 'remoto-embark)" \
	--eval "(remoto-embark-register)" \
	--eval "(global-remoto-mode 1)" \
	--eval "(global-set-key (kbd \"C-.\") #'embark-act)" \
	--eval "(message \"remoto sandbox: M-x remoto-browse | C-x C-f /github:owner/repo | C-. embark-act\")"

test: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	--eval "(setq buttercup-stack-frame-style 'omit)" \
	-l test/remoto-tests.el \
	-l test/remoto-keys-tests.el \
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

test-e2e: $(addprefix test-e2e-,$(E2E_PROFILES))

test-e2e-%: $(ELPA_DIR)
	REMOTO_E2E_PROFILE=$* $(E2E)

test-e2e-update:
	$(MAKE) test-e2e REMOTO_E2E_UPDATE=1

# The answers the Codeberg conformance kit replays, asked of codeberg.org anonymously.
test-fixtures-codeberg: $(ELPA_DIR)
	$(EMACS_BATCH) -l test/record-codeberg-fixtures.el -f record-codeberg-fixtures

# One profile at a time: each run adds to the fixtures the next one reads.
test-e2e-record: $(ELPA_DIR)
	@test -n "$$REMOTO_E2E_TOKEN" || { echo "REMOTO_E2E_TOKEN must hold a GitHub token"; exit 1; }
	for p in $(E2E_PROFILES); do \
	  REMOTO_E2E_PROFILE=$$p REMOTO_E2E_UPDATE=1 $(E2E) || exit 1; \
	done

# Each profile in .keys/PROFILE, so -j runs them side by side; they share
# GitHub's rate limits.
test-keys: $(addprefix test-keys-,$(E2E_PROFILES))

test-keys-%: $(ELPA_DIR)
	REMOTO_KEYS_PROFILES=$* REMOTO_KEYS_DIR=.keys/$* $(KEYS)

# The running Emacs, through its server: keep off the keyboard while it types.
test-keys-live: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . -l test/remoto-keys.el -f remoto-keys-live-main

lint: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	--eval "(require 'package-lint)" \
	-f package-lint-batch-and-exit remoto.el remoto-github.el remoto-forgejo.el remoto-embark.el remoto-topic.el
	$(EMACS_BATCH) \
	--eval "(require 'checkdoc)" \
	--eval "(setq checkdoc-verb-check-experimental-flag t)" \
	--eval "(dolist (f '(\"remoto.el\" \"remoto-github.el\" \"remoto-forgejo.el\" \"remoto-embark.el\" \"remoto-topic.el\")) \
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
	--eval "(dolist (f '(\"remoto.el\" \"remoto-github.el\" \"remoto-forgejo.el\" \"remoto-embark.el\" \"remoto-topic.el\")) \
	           (unless (byte-compile-file f) (kill-emacs 1)))"
	rm -f remoto.elc remoto-github.elc remoto-forgejo.elc remoto-embark.elc remoto-topic.elc

compile: $(ELPA_DIR)
	@echo "Byte-compiling package files..."
	$(EMACS_BATCH) \
	--eval "(add-to-list 'load-path \".\")" \
	--eval "(byte-compile-file \"remoto.el\")"

clean:
	@echo "Cleaning compiled files..."
	rm -f *.elc test/*.elc
	rm -rf $(ELPA_DIR) $(SANDBOX) .keys
