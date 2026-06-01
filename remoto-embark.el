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
(declare-function remoto--parse-input "remoto" (input))
(declare-function remoto--canonical-path "remoto" (parsed))
(declare-function remoto--forge-type "remoto" (path))
(declare-function remoto--forge-issue-url "remoto" (forge owner repo number))
(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))
(defvar dired-directory)

;; Embark variables this file registers into.  Declared so it byte-compiles
;; without Embark installed; their real definitions come from Embark.
(defvar embark-keymap-alist)
(defvar embark-target-finders)
(defvar embark-transformer-alist)
(defvar embark-url-map)

;;;; Options

(defcustom remoto-clone-url-type 'https
  "Clone URL kind used by `remoto-embark-clone'.
`https' works for any public repository without SSH keys; `ssh' uses the
`git@host:owner/repo.git' form."
  :type '(choice (const :tag "HTTPS" https) (const :tag "SSH" ssh))
  :group 'remoto)

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

(defun remoto--embark-transform (type target)
  "Embark transformer: resolve a completion TARGET to its full remoto path.
Reads the `remoto-target' text property attached to remoto completion
candidates (so actions work on a bare minibuffer/collect candidate) and
re-derives the type from the resolved path, so a directory listed under
the `remoto-file' category becomes a `remoto-dir' target.  Falls back to
TARGET and TYPE unchanged."
  (let* ((path (or (and (< 0 (length target))
                        (get-text-property 0 'remoto-target target))
                   target))
         (ctx (ignore-errors (remoto--path-context path)))
         (rtype (or (and ctx (plist-get ctx :type)) type)))
    (cons rtype path)))

(defun remoto--embark-transform-ref (type target)
  "Embark transformer for ref targets: resolve TARGET's path, keep TYPE.
Unlike `remoto--embark-transform' it does not re-derive the type, so a
branch or tag stays a `remoto-branch' instead of collapsing to the
`remoto-repo' that its root path would otherwise classify as."
  (cons type (or (and (< 0 (length target))
                      (get-text-property 0 'remoto-target target))
                 target)))

(defun remoto--embark-browse-transform (type target)
  "Embark transformer for the single-category `remoto-browse' table.
Reads TARGET's `remoto-target' full path and dispatches it to a per-type
target: an issue (trailing `#N'), a branch (a bare `@REF' root), else a
repo/dir/file via the path context.  Lets the one `remoto-browse'
category reuse the per-type keymaps.  Falls back to TYPE."
  (let ((path (or (and (< 0 (length target))
                       (get-text-property 0 'remoto-target target))
                  target)))
    (cond
     ((string-match-p (rx "#" (+ digit) eos) path)
      (cons 'remoto-issue path))
     ((string-match-p (rx "@" (+ nonl) ":/" eos) path)
      (cons 'remoto-branch path))
     (t (let* ((ctx (ignore-errors (remoto--path-context path)))
               (rtype (or (and ctx (plist-get ctx :type)) type)))
          (cons rtype path))))))

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

(defun remoto-embark-open-in-remoto (url)
  "Open the forge URL (or `owner/repo' shorthand) URL in remoto.
Parses URL with `remoto--parse-input' and visits the canonical remoto
path; a directory opens Dired and the ref resolves lazily."
  (interactive "sForge URL: ")
  (find-file (remoto--canonical-path (remoto--parse-input url))))

(defun remoto-embark-copy-branch-url (target)
  "Copy the web URL for the remoto ref (branch/tag) TARGET."
  (interactive "sRemoto ref: ")
  (remoto--kill-url (remoto--context-url (remoto--path-context target) 'tree)))

(defun remoto-embark-browse-branch (target)
  "Open the web page for the remoto ref (branch/tag) TARGET in a browser."
  (interactive "sRemoto ref: ")
  (browse-url (remoto--context-url (remoto--path-context target) 'tree)))

(defun remoto-embark-browse-compare (target)
  "Open the compare view for the remoto ref (branch/tag) TARGET."
  (interactive "sRemoto ref: ")
  (browse-url (remoto--context-url (remoto--path-context target) 'compare)))

(defun remoto-embark-new-pr (target)
  "Open the new-pull-request page for the remoto ref (branch/tag) TARGET."
  (interactive "sRemoto ref: ")
  (browse-url (remoto--context-url (remoto--path-context target) 'new-pr)))

(defun remoto-embark-open-issue (target)
  "Open the remoto issue/PR TARGET (a /github:OWNER/REPO#N path) in remoto.
This routes to the remoto-topic display via `find-file'."
  (interactive "sRemoto issue: ")
  (find-file target))

(defun remoto-embark-copy-issue-ref (target)
  "Copy the OWNER/REPO#N reference for the remoto issue/PR TARGET."
  (interactive "sRemoto issue: ")
  (if (string-match (rx "/" (+ (not (any ":"))) ":"
                        (group (+ (not (any "/")))) "/"
                        (group (+ (not (any "#")))) "#" (group (+ digit)))
                    target)
      (remoto--kill-url (format "%s/%s#%s"
                                (match-string 1 target)
                                (match-string 2 target)
                                (match-string 3 target)))
    (user-error "Remoto: not an issue target: %s" target)))

(defun remoto--embark-issue-parts (target)
  "Return (FORGE OWNER REPO NUMBER) for an issue TARGET like /github:O/R#N."
  (when (string-match (rx "/" (+ (not (any ":"))) ":"
                          (group (+ (not (any "/")))) "/"
                          (group (+ (not (any "#")))) "#" (group (+ digit)))
                      target)
    ;; Bind the match strings before `remoto--forge-type', which runs its
    ;; own `string-match' and would otherwise clobber the match data.
    (let ((owner (match-string 1 target))
          (repo (match-string 2 target))
          (number (match-string 3 target)))
      (list (remoto--forge-type target) owner repo number))))

(defun remoto-embark-browse-issue (target)
  "Open the web page for the remoto issue/PR TARGET in a browser."
  (interactive "sRemoto issue: ")
  (browse-url (apply #'remoto--forge-issue-url (remoto--embark-issue-parts target))))

(defun remoto-embark-copy-issue-url (target)
  "Copy the web URL for the remoto issue/PR TARGET."
  (interactive "sRemoto issue: ")
  (remoto--kill-url (apply #'remoto--forge-issue-url
                           (remoto--embark-issue-parts target))))

(defun remoto-embark-browse-pr-diff (target)
  "Open the PR files-diff page for the remoto issue/PR TARGET in a browser.
For an issue the forge redirects to the issue page."
  (interactive "sRemoto PR: ")
  (browse-url (apply #'remoto--forge-issue-url
                     (append (remoto--embark-issue-parts target) '(pr-diff)))))

(defun remoto--clone (url dest)
  "Clone URL into DEST asynchronously, showing progress in a buffer."
  (let ((buffer (get-buffer-create "*remoto-clone*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer)))
    (set-process-sentinel
     (start-process "remoto-clone" buffer "git" "clone" url dest)
     (lambda (_proc event) (message "remoto clone %s: %s" dest (string-trim event))))
    (display-buffer buffer)))

(defun remoto-embark-clone (target)
  "Clone the repository for remoto TARGET into a chosen directory.
The clone URL kind is governed by `remoto-clone-url-type'."
  (interactive "sRemoto repo: ")
  (let* ((ctx (remoto--path-context target))
         (url (remoto--context-url ctx remoto-clone-url-type))
         (dest (read-directory-name "Clone into: " nil nil nil
                                    (plist-get ctx :repo))))
    (remoto--clone url dest)))

;;;; Keymaps

(defvar-keymap remoto-embark-repo-map
  :doc "Embark actions for remoto repository targets."
  "u" #'remoto-embark-copy-url
  "w" #'remoto-embark-browse-url
  "c" #'remoto-embark-clone
  "s" #'remoto-embark-copy-ssh-url
  "g" #'remoto-embark-copy-https-url
  "h" #'remoto-embark-copy-history-url)

(defvar-keymap remoto-embark-branch-map
  :doc "Embark actions for remoto branch/tag (ref) targets."
  "u" #'remoto-embark-copy-branch-url
  "w" #'remoto-embark-browse-branch
  "c" #'remoto-embark-browse-compare
  "n" #'remoto-embark-new-pr)

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

(defvar-keymap remoto-embark-issue-map
  :doc "Embark actions for remoto issue/PR targets."
  "o" #'remoto-embark-open-issue
  "w" #'remoto-embark-browse-issue
  "u" #'remoto-embark-copy-issue-url
  "d" #'remoto-embark-browse-pr-diff
  "y" #'remoto-embark-copy-issue-ref)

;;;; Registration (only once Embark is loaded)

(with-eval-after-load 'embark
  (add-to-list 'embark-keymap-alist '(remoto-repo remoto-embark-repo-map))
  (add-to-list 'embark-keymap-alist '(remoto-dir remoto-embark-dir-map))
  (add-to-list 'embark-keymap-alist '(remoto-file remoto-embark-file-map))
  (add-to-list 'embark-keymap-alist '(remoto-branch remoto-embark-branch-map))
  (add-to-list 'embark-keymap-alist '(remoto-issue remoto-embark-issue-map))
  (add-to-list 'embark-target-finders #'remoto--embark-target-finder)
  (add-to-list 'embark-transformer-alist '(remoto-repo . remoto--embark-transform))
  (add-to-list 'embark-transformer-alist '(remoto-file . remoto--embark-transform))
  (add-to-list 'embark-transformer-alist '(remoto-branch . remoto--embark-transform-ref))
  (add-to-list 'embark-transformer-alist '(remoto-issue . remoto--embark-transform-ref))
  (add-to-list 'embark-transformer-alist '(remoto-browse . remoto--embark-browse-transform))
  (define-key embark-url-map "R" #'remoto-embark-open-in-remoto))

(provide 'remoto-embark)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-embark.el ends here
