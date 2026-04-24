.PHONY: help test deps check-compile compile clean

define DEPS_SCRIPT
(progn
(require 'package)
(add-to-list 'package-archives '("melpa" . "http://melpa.org/packages/"))
(package-initialize)
(package-refresh-contents)
(package-install 'buttercup))
endef
export DEPS_SCRIPT

help:
	@echo "Available commands:"
	@echo "  make deps          Install dependencies"
	@echo "  make test          Run the tests"
	@echo "  make compile       Byte-compile the package"
	@echo "  make check-compile Check for clean byte-compilation"
	@echo "  make clean         Remove compiled files"

deps:
	@echo "Installing dependencies"
	emacs --batch --eval "$$DEPS_SCRIPT"

test:
	emacs --batch --funcall package-initialize --directory . \
	--eval '(add-to-list '\''load-path "..")' \
	--funcall buttercup-run-discover

check-compile: deps
	@echo "Checking byte-compilation..."
	emacs -Q --batch \
	--eval "(require 'package)" \
	--eval "(setq package-user-dir \"$(CURDIR)/.elpa\")" \
	--eval "(add-to-list 'package-archives '(\"melpa\" . \"http://melpa.org/packages/\"))" \
	--eval "(package-initialize)" \
	--eval "(setq byte-compile-error-on-warn t)" \
	--eval "(add-to-list 'load-path \".\")" \
	--eval "(byte-compile-file \"remoto.el\")"

compile:
	@echo "Byte-compiling package files..."
	emacs --batch \
	--eval "(add-to-list 'load-path \".\")" \
	--eval "(byte-compile-file \"remoto.el\")"

clean:
	@echo "Cleaning compiled files..."
	rm -f *.elc test/*.elc
	rm -rf .elpa
