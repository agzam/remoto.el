ELPA_DIR = $(CURDIR)/.elpa

EMACS_BATCH = emacs -Q --batch \
	--eval "(setq package-user-dir \"$(ELPA_DIR)\")" \
	--eval "(require 'package)" \
	--eval "(add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\"))" \
	--eval "(package-initialize)"

.PHONY: help test test-integration test-all deps check-autoloads check-compile compile clean

help:
	@echo "Available commands:"
	@echo "  make deps              Install dependencies"
	@echo "  make test              Run unit tests"
	@echo "  make test-integration  Run integration tests (needs network)"
	@echo "  make test-all          Run all tests"
	@echo "  make compile           Byte-compile the package"
	@echo "  make check-autoloads   Generate and load autoloads"
	@echo "  make check-compile     Check for clean byte-compilation"
	@echo "  make clean             Remove compiled files"

$(ELPA_DIR):
	@echo "Installing dependencies..."
	$(EMACS_BATCH) \
	--eval "(package-refresh-contents)" \
	--eval "(package-install 'ghub)" \
	--eval "(package-install 'buttercup)"

deps: $(ELPA_DIR)

test: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	-l test/remoto-tests.el \
	--funcall buttercup-run

test-integration: $(ELPA_DIR)
	$(EMACS_BATCH) --directory . \
	-l test/remoto-integration-tests.el \
	--funcall buttercup-run

test-all: test test-integration

check-autoloads:
	@echo "Generating and loading autoloads..."
	rm -f remoto-autoloads.el
	emacs -Q --batch \
	--eval "(setq generated-autoload-file (expand-file-name \"remoto-autoloads.el\" \"$(CURDIR)\"))" \
	--eval "(update-directory-autoloads \"$(CURDIR)\")" \
	--eval "(load generated-autoload-file nil 'nomessage)"

check-compile: $(ELPA_DIR) check-autoloads
	@echo "Checking byte-compilation..."
	$(EMACS_BATCH) \
	--eval "(setq byte-compile-error-on-warn t)" \
	--eval "(add-to-list 'load-path \".\")" \
	--eval "(byte-compile-file \"remoto.el\")"

compile: $(ELPA_DIR)
	@echo "Byte-compiling package files..."
	$(EMACS_BATCH) \
	--eval "(add-to-list 'load-path \".\")" \
	--eval "(byte-compile-file \"remoto.el\")"

clean:
	@echo "Cleaning compiled files..."
	rm -f *.elc test/*.elc
	rm -rf $(ELPA_DIR)
