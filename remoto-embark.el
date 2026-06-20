;;; remoto-embark.el --- Embark integration for remoto -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ag Ibragimov
;; Author: Ag Ibragimov

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Optional Embark integration for remoto.  An autoloaded hook activates it
;; automatically once Embark is loaded (see the registration at the end of
;; this file), and it has no hard dependency on Embark, so users without it
;; are unaffected.
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
(declare-function remoto--parse-path "remoto" (filename))
(declare-function remoto--normalize-shorthand "remoto" (path))
(declare-function remoto--forge-type "remoto" (path))
(declare-function remoto--forge-issue-url "remoto" (forge owner repo number))
(declare-function remoto--forge-owner-url "remoto" (forge owner &optional kind))
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
re-derives the type from the resolved path with `remoto--embark-classify',
so an owner, issue, branch, or directory listed under a broader category
routes to its own keymap.  The resolved path is canonicalized, so a `/gh:'
or file-name candidate becomes a canonical path.  Falls back to TYPE."
  (let ((path (remoto--embark-canonicalize
               (or (and (< 0 (length target))
                        (get-text-property 0 'remoto-target target))
                   target))))
    (cons (remoto--embark-classify path type) path)))

(defun remoto--embark-transform-ref (type target)
  "Embark transformer for ref targets: resolve TARGET's path, keep TYPE.
Unlike `remoto--embark-transform' it does not re-derive the type, so a
branch or tag stays a `remoto-branch' instead of collapsing to the
`remoto-repo' that its root path would otherwise classify as.  The
resolved path is canonicalized so a `/gh:' or file-name candidate becomes
a canonical path."
  (cons type (remoto--embark-canonicalize
              (or (and (< 0 (length target))
                       (get-text-property 0 'remoto-target target))
                  target))))

(defun remoto--embark-browse-transform (type target)
  "Embark transformer for the single-category `remoto-browse' table.
Resolves TARGET's `remoto-target' full path and dispatches it to a
per-type Embark target, so the one `remoto-browse' category reuses the
per-type keymaps.  Falls back to TYPE."
  (remoto--embark-transform type target))

;;;; Target classification and URL resolution

(defun remoto--embark-canonicalize (target)
  "Normalize a raw Embark TARGET string to a canonical remoto path.
Resolves the `/gh:' shorthand and the file-name forms `/github:OWNER/REPO',
`/github:OWNER/REPO@REF', and `/github:OWNER/REPO/PATH' to the canonical
`/github:OWNER/REPO[@REF]:/PATH', so an action behaves the same whichever
form Embark hands it (a typed `/gh:' or `/github:' path, a completion
candidate, or a `remoto-browse' result).  Owner, issue/PR, and
already-canonical targets pass through unchanged after shorthand expansion;
non-strings and unrecognized strings are returned as-is."
  (if (not (stringp target))
      target
    (let ((path (remoto--normalize-shorthand target)))
      (cond
       ((remoto--parse-path path) path)
       ((string-match-p (rx "#" (+ digit) eos) path) path)
       ((string-match (rx bos "/github:"
                          (group (+ (not (any "/@:#"))))           ; owner
                          "/"
                          (group (+ (not (any "/@:#"))))           ; repo
                          (group (? "@" (+ (not (any "/:#")))))    ; @ref
                          (group (* nonl))                         ; rest
                          eos)
                      path)
        (let ((rest (match-string 4 path)))
          (format "/github:%s/%s%s:%s"
                  (match-string 1 path) (match-string 2 path) (match-string 3 path)
                  (if (string-empty-p rest) "/" rest))))
       (t path)))))

(defun remoto--embark-classify (path fallback)
  "Return the Embark target type for the remoto PATH string, else FALLBACK.
Classifies by shape: an issue/PR (a trailing `#N'), a branch/tag (a bare
`@REF' root), an account/owner (`/FORGE:OWNER'), otherwise the repo,
directory, or file type from the context layer.  PATH is normalized with
`remoto--embark-canonicalize' first, so the shorthand and file-name forms
classify like the canonical one."
  (let ((path (remoto--embark-canonicalize path)))
    (cond
     ((string-match-p (rx "#" (+ digit) eos) path) 'remoto-issue)
     ((string-match-p (rx "@" (+ nonl) ":/" eos) path) 'remoto-branch)
     ((remoto--embark-owner-parts path) 'remoto-owner)
     (t (let ((ctx (ignore-errors (remoto--path-context path))))
          (or (and ctx (plist-get ctx :type)) fallback))))))

(defun remoto--embark-context (target)
  "Return the remoto context plist for TARGET, or signal a precise error.
Used by the repository- and file-specific actions, which need a parseable
`/FORGE:OWNER/REPO...' path; an owner or issue target raises a clear
message instead of a cryptic forge-lookup failure.  TARGET is normalized
with `remoto--embark-canonicalize' first, so the `/gh:' shorthand and the
file-name form resolve like the canonical one."
  (or (remoto--path-context (remoto--embark-canonicalize target))
      (user-error "Remoto: `%s' is not a repository, directory, or file target"
                  target)))

(defun remoto--embark-web-url (target)
  "Return the human-facing web URL for any remoto TARGET, or signal an error.
Handles every kind the generic copy/browse actions may receive - an
issue/PR, a repository/directory/file (via the context layer), or an
account/owner - in any input form (`/gh:' shorthand, file-name, or
canonical), normalized with `remoto--embark-canonicalize'.  This keeps
those actions working whatever Embark hands them, including through the
generic `remoto' fallback keymap."
  (let* ((path (remoto--embark-canonicalize target))
         (issue (remoto--embark-issue-parts path))
         (ctx (remoto--path-context path))
         (owner (remoto--embark-owner-parts path)))
    (cond
     (issue (apply #'remoto--forge-issue-url issue))
     (ctx (remoto--context-web-url ctx))
     (owner (apply #'remoto--forge-owner-url owner))
     (t (user-error "Remoto: no web URL for target `%s'" target)))))

;;;; Actions

;; Each action receives TARGET, a full canonical remoto path string - the
;; form Embark hands to an action.  Bodies go through remoto's
;; forge-agnostic context layer, so they are forge-agnostic too.

(defun remoto-embark-copy-url (target)
  "Copy the web URL for remoto TARGET to the kill ring.
TARGET may be a repository, directory, file, issue/PR, or owner."
  (interactive "sRemoto target: ")
  (remoto--kill-url (remoto--embark-web-url target)))

(defun remoto-embark-browse-url (target)
  "Open the web page for remoto TARGET in a browser.
TARGET may be a repository, directory, file, issue/PR, or owner."
  (interactive "sRemoto target: ")
  (browse-url (remoto--embark-web-url target)))

(defun remoto-embark-copy-repo-url (target)
  "Copy the repository web URL for remoto TARGET."
  (interactive "sRemoto target: ")
  (remoto--kill-url (remoto--context-url (remoto--embark-context target) 'repo)))

(defun remoto-embark-copy-ssh-url (target)
  "Copy the SSH clone URL for remoto TARGET."
  (interactive "sRemoto target: ")
  (remoto--kill-url (remoto--context-url (remoto--embark-context target) 'ssh)))

(defun remoto-embark-copy-https-url (target)
  "Copy the HTTPS clone URL for remoto TARGET."
  (interactive "sRemoto target: ")
  (remoto--kill-url (remoto--context-url (remoto--embark-context target) 'https)))

(defun remoto-embark-copy-history-url (target)
  "Copy the commit-history URL for remoto TARGET."
  (interactive "sRemoto target: ")
  (remoto--kill-url (remoto--context-url (remoto--embark-context target) 'history)))

(defun remoto-embark-copy-blame-url (target)
  "Copy the blame URL for remoto file TARGET."
  (interactive "sRemoto file: ")
  (let ((ctx (remoto--embark-context target)))
    (remoto--require-blob ctx "Blame")
    (remoto--kill-url (remoto--context-url ctx 'blame))))

(defun remoto-embark-copy-raw-url (target)
  "Copy the raw-content URL for remoto file TARGET."
  (interactive "sRemoto file: ")
  (let ((ctx (remoto--embark-context target)))
    (remoto--require-blob ctx "Raw URL")
    (remoto--kill-url (remoto--context-url ctx 'raw))))

(defun remoto-embark-copy-permalink (target)
  "Copy a permalink, pinned to the commit SHA, for remoto file TARGET."
  (interactive "sRemoto file: ")
  (let* ((ctx (remoto--embark-context target))
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
  (remoto--kill-url (remoto--context-url (remoto--embark-context target) 'tree)))

(defun remoto-embark-browse-branch (target)
  "Open the web page for the remoto ref (branch/tag) TARGET in a browser."
  (interactive "sRemoto ref: ")
  (browse-url (remoto--context-url (remoto--embark-context target) 'tree)))

(defun remoto-embark-browse-compare (target)
  "Open the compare view for the remoto ref (branch/tag) TARGET."
  (interactive "sRemoto ref: ")
  (browse-url (remoto--context-url (remoto--embark-context target) 'compare)))

(defun remoto-embark-new-pr (target)
  "Open the new-pull-request page for the remoto ref (branch/tag) TARGET."
  (interactive "sRemoto ref: ")
  (browse-url (remoto--context-url (remoto--embark-context target) 'new-pr)))

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

(defun remoto--embark-owner-parts (target)
  "Return (FORGE OWNER) for an account TARGET like /github:OWNER."
  (when (string-match (rx "/" (+ (not (any ":"))) ":"
                          (group (+ (not (any "/")))) (? "/") eos)
                      target)
    ;; Bind the owner before `remoto--forge-type', whose own `string-match'
    ;; would otherwise clobber the match data.
    (let ((owner (match-string 1 target)))
      (list (remoto--forge-type target) owner))))

(defun remoto-embark-browse-owner (target)
  "Open the account/organization page for the remoto owner TARGET."
  (interactive "sRemoto owner: ")
  (browse-url (apply #'remoto--forge-owner-url (remoto--embark-owner-parts target))))

(defun remoto-embark-copy-owner-url (target)
  "Copy the account/organization page URL for the remoto owner TARGET."
  (interactive "sRemoto owner: ")
  (remoto--kill-url (apply #'remoto--forge-owner-url
                           (remoto--embark-owner-parts target))))

(defun remoto-embark-browse-owner-repos (target)
  "Open the repositories page for the remoto owner TARGET in a browser."
  (interactive "sRemoto owner: ")
  (browse-url (apply #'remoto--forge-owner-url
                     (append (remoto--embark-owner-parts target) '(owner-repos)))))

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
  (let* ((ctx (remoto--embark-context target))
         (url (remoto--context-url ctx remoto-clone-url-type))
         (dest (read-directory-name "Clone into: " nil nil nil
                                    (plist-get ctx :repo))))
    (remoto--clone url dest)))

;;;; Keymaps

(defvar-keymap remoto-embark-repo-map
  :doc "Embark actions for remoto repository targets."
  "y" #'remoto-embark-copy-url
  "b" #'remoto-embark-browse-url
  "s" #'remoto-embark-copy-ssh-url
  "h" #'remoto-embark-copy-https-url
  "H" #'remoto-embark-copy-history-url
  "c" #'remoto-embark-clone)

(defvar-keymap remoto-embark-branch-map
  :doc "Embark actions for remoto branch/tag (ref) targets."
  "y" #'remoto-embark-copy-branch-url
  "b" #'remoto-embark-browse-branch
  "d" #'remoto-embark-browse-compare
  "n" #'remoto-embark-new-pr)

(defvar-keymap remoto-embark-dir-map
  :doc "Embark actions for remoto directory targets."
  "y" #'remoto-embark-copy-url
  "b" #'remoto-embark-browse-url
  "H" #'remoto-embark-copy-history-url)

(defvar-keymap remoto-embark-file-map
  :doc "Embark actions for remoto file targets."
  "y" #'remoto-embark-copy-url
  "b" #'remoto-embark-browse-url
  "B" #'remoto-embark-copy-blame-url
  "P" #'remoto-embark-copy-permalink
  "r" #'remoto-embark-copy-raw-url
  "H" #'remoto-embark-copy-history-url)

(defvar-keymap remoto-embark-issue-map
  :doc "Embark actions for remoto issue/PR targets."
  "o" #'remoto-embark-open-issue
  "b" #'remoto-embark-browse-issue
  "y" #'remoto-embark-copy-issue-url
  "d" #'remoto-embark-browse-pr-diff
  "R" #'remoto-embark-copy-issue-ref)

(defvar-keymap remoto-embark-owner-map
  :doc "Embark actions for remoto account/organization targets."
  "b" #'remoto-embark-browse-owner
  "y" #'remoto-embark-copy-owner-url
  "r" #'remoto-embark-browse-owner-repos)

;;;; Registration (only once Embark is loaded)

;;;###autoload
(defun remoto-embark-register ()
  "Register remoto's Embark target types, keymaps, and transformers.
Called automatically once Embark is loaded; exposed for eager or manual
setup.  Idempotent: every step uses `add-to-list' or `define-key', so
calling it more than once is harmless."
  (add-to-list 'embark-keymap-alist '(remoto-repo remoto-embark-repo-map))
  (add-to-list 'embark-keymap-alist '(remoto-dir remoto-embark-dir-map))
  (add-to-list 'embark-keymap-alist '(remoto-file remoto-embark-file-map))
  (add-to-list 'embark-keymap-alist '(remoto-branch remoto-embark-branch-map))
  (add-to-list 'embark-keymap-alist '(remoto-issue remoto-embark-issue-map))
  (add-to-list 'embark-keymap-alist '(remoto-owner remoto-embark-owner-map))
  ;; Fallback for the generic `remoto' completion category: reuse the repo
  ;; actions.  The generic copy/browse actions resolve any target kind, so an
  ;; owner or issue candidate that lands here still works.
  (add-to-list 'embark-keymap-alist '(remoto remoto-embark-repo-map))
  (add-to-list 'embark-target-finders #'remoto--embark-target-finder)
  (add-to-list 'embark-transformer-alist '(remoto-repo . remoto--embark-transform))
  (add-to-list 'embark-transformer-alist '(remoto-file . remoto--embark-transform))
  (add-to-list 'embark-transformer-alist '(remoto-branch . remoto--embark-transform-ref))
  (add-to-list 'embark-transformer-alist '(remoto-issue . remoto--embark-transform-ref))
  (add-to-list 'embark-transformer-alist '(remoto-owner . remoto--embark-transform-ref))
  (add-to-list 'embark-transformer-alist '(remoto . remoto--embark-transform))
  (add-to-list 'embark-transformer-alist '(remoto-browse . remoto--embark-browse-transform))
  (define-key embark-url-map "R" #'remoto-embark-open-in-remoto))

;; Activate as soon as Embark is available.  The cookie copies this form into
;; the generated autoloads, so the integration works off the bat for anyone
;; who has Embark - with no manual `require' - while Embark stays a
;; non-runtime dependency: nothing here loads until Embark itself loads.
;; Going through the autoloaded `remoto-embark-register' (rather than
;; `(require 'remoto-embark)') avoids a load recursion when this file is
;; itself loaded with Embark already present.
;;;###autoload
(with-eval-after-load 'embark
  (remoto-embark-register))

(provide 'remoto-embark)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-embark.el ends here
