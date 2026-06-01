;;; remoto-embark.el --- Embark integration for remoto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ag Ibragimov
;; Author: Ag Ibragimov

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Optional Embark integration for remoto.  It is loaded only when Embark
;; is present (remoto arranges this via `with-eval-after-load'), and it has
;; no hard dependency on Embark, so users without it are unaffected.
;;
;; It defines forge-agnostic Embark target types - `remoto-repo',
;; `remoto-dir', `remoto-file' - for remoto file and Dired buffers, with
;; keymaps of actions that copy or open the corresponding web and clone
;; URLs.  Actions reuse remoto's forge-agnostic context layer, so they work
;; across forges without change.

;;; Code:

(require 'remoto)

(declare-function remoto--path-context "remoto" (path &optional line-start line-end))
(declare-function remoto--context-url "remoto" (ctx kind &optional ref))
(declare-function remoto--context-web-url "remoto" (ctx))
(declare-function remoto--kill-url "remoto" (url))
(declare-function remoto--require-blob "remoto" (ctx what))
(declare-function remoto--resolve-commit-sha "remoto" (owner repo ref))
(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))
(defvar dired-directory)

;; Embark variables this file registers into.  Declared so it byte-compiles
;; without Embark installed; their real definitions come from Embark.
(defvar embark-keymap-alist)
(defvar embark-target-finders)

;;;; Target detection

(defun remoto--embark-target-at-point ()
  "Return (TYPE . PATH) for the remoto target in the current buffer, or nil.
TYPE is one of `remoto-repo', `remoto-dir', `remoto-file'.  Works in remoto
file buffers and in Dired (the entry at point, else the directory)."
  (when-let* ((path (if (derived-mode-p 'dired-mode)
                        (or (dired-get-filename nil t)
                            (and (stringp dired-directory) dired-directory))
                      buffer-file-name))
              (ctx (ignore-errors (remoto--path-context path))))
    (cons (plist-get ctx :type) path)))

(defun remoto--embark-target-finder ()
  "Embark target finder for remoto file and Dired buffers.
Return (TYPE PATH), where TYPE is a remoto target symbol and PATH is the
full canonical remoto path."
  (when-let* ((target (remoto--embark-target-at-point)))
    (list (car target) (cdr target))))

;;;; Actions

;; Each action receives TARGET, a full canonical remoto path string - the
;; form Embark hands to an action.  Bodies go through remoto's
;; forge-agnostic context layer, so they are forge-agnostic too.

(defun remoto-embark-copy-url (target)
  "Copy the web URL for remoto TARGET to the kill ring."
  (interactive "sRemoto target: ")
  (remoto--kill-url (remoto--context-web-url (remoto--path-context target))))

(defun remoto-embark-browse-url (target)
  "Open the web page for remoto TARGET in a browser."
  (interactive "sRemoto target: ")
  (browse-url (remoto--context-web-url (remoto--path-context target))))

(defun remoto-embark-copy-repo-url (target)
  "Copy the repository web URL for remoto TARGET."
  (interactive "sRemoto target: ")
  (remoto--kill-url (remoto--context-url (remoto--path-context target) 'repo)))

(defun remoto-embark-copy-ssh-url (target)
  "Copy the SSH clone URL for remoto TARGET."
  (interactive "sRemoto target: ")
  (remoto--kill-url (remoto--context-url (remoto--path-context target) 'ssh)))

(defun remoto-embark-copy-https-url (target)
  "Copy the HTTPS clone URL for remoto TARGET."
  (interactive "sRemoto target: ")
  (remoto--kill-url (remoto--context-url (remoto--path-context target) 'https)))

(defun remoto-embark-copy-history-url (target)
  "Copy the commit-history URL for remoto TARGET."
  (interactive "sRemoto target: ")
  (remoto--kill-url (remoto--context-url (remoto--path-context target) 'history)))

(defun remoto-embark-copy-blame-url (target)
  "Copy the blame URL for remoto file TARGET."
  (interactive "sRemoto file: ")
  (let ((ctx (remoto--path-context target)))
    (remoto--require-blob ctx "Blame")
    (remoto--kill-url (remoto--context-url ctx 'blame))))

(defun remoto-embark-copy-raw-url (target)
  "Copy the raw-content URL for remoto file TARGET."
  (interactive "sRemoto file: ")
  (let ((ctx (remoto--path-context target)))
    (remoto--require-blob ctx "Raw URL")
    (remoto--kill-url (remoto--context-url ctx 'raw))))

(defun remoto-embark-copy-permalink (target)
  "Copy a permalink, pinned to the commit SHA, for remoto file TARGET."
  (interactive "sRemoto file: ")
  (let* ((ctx (remoto--path-context target))
         (sha (remoto--resolve-commit-sha (plist-get ctx :owner)
                                          (plist-get ctx :repo)
                                          (plist-get ctx :ref))))
    (remoto--kill-url (remoto--context-url ctx (plist-get ctx :kind) sha))))

;;;; Keymaps

(defvar-keymap remoto-embark-repo-map
  :doc "Embark actions for remoto repository targets."
  "u" #'remoto-embark-copy-url
  "w" #'remoto-embark-browse-url
  "s" #'remoto-embark-copy-ssh-url
  "g" #'remoto-embark-copy-https-url
  "h" #'remoto-embark-copy-history-url)

(defvar-keymap remoto-embark-dir-map
  :doc "Embark actions for remoto directory targets."
  "u" #'remoto-embark-copy-url
  "w" #'remoto-embark-browse-url
  "h" #'remoto-embark-copy-history-url)

(defvar-keymap remoto-embark-file-map
  :doc "Embark actions for remoto file targets."
  "u" #'remoto-embark-copy-url
  "w" #'remoto-embark-browse-url
  "b" #'remoto-embark-copy-blame-url
  "p" #'remoto-embark-copy-permalink
  "r" #'remoto-embark-copy-raw-url
  "h" #'remoto-embark-copy-history-url)

;;;; Registration (only once Embark is loaded)

(with-eval-after-load 'embark
  (add-to-list 'embark-keymap-alist '(remoto-repo remoto-embark-repo-map))
  (add-to-list 'embark-keymap-alist '(remoto-dir remoto-embark-dir-map))
  (add-to-list 'embark-keymap-alist '(remoto-file remoto-embark-file-map))
  (add-to-list 'embark-target-finders #'remoto--embark-target-finder))

(provide 'remoto-embark)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-embark.el ends here
