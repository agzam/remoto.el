;;; remoto.el --- Browse GitHub repos without cloning -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2025 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Created: April 24, 2026
;; Version: 1.3.0
;; Keywords: tools vc
;; Homepage: https://github.com/agzam/remoto.el
;; Package-Requires: ((emacs "29.1") (ghub "4.0.0"))
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.

;;; Commentary:

;; remoto.el lets you browse any GitHub repository in Emacs as if it were
;; cloned locally - without cloning it.  It registers a virtual filesystem
;; via `file-name-handler-alist' that translates Emacs file operations into
;; GitHub API calls via the `ghub' library.
;;
;; Usage:
;;   M-x remoto-browse RET https://github.com/torvalds/linux RET
;;
;; Supports pasting any GitHub URL, git remote URL, or owner/repo shorthand.

;;; Code:

(require 'cl-lib)
(require 'files-x)
(require 'ghub)

;;;; Path parsing

(defconst remoto--path-regexp
  (rx bos "/github:"
      (group (+ (not (any "/@"))))      ; owner
      "/"
      (group (+ (not (any "/@:"))))     ; repo
      (? "@" (group (+ (not (any ":/"))))) ; ref (optional)
      ":"
      (group (* anything))              ; path
      eos)
  "Regexp matching canonical remoto paths.
Groups: 1=owner, 2=repo, 3=ref (maybe nil), 4=path.")

(defconst remoto--repo-delimiters
  '((?/ . files-default)
    (?@ . branches)
    (?# . issues))
  "Alist mapping delimiter characters after OWNER/REPO to completion levels.
`/' means browse files on default branch, `@' means pick a branch/tag,
`#' means browse issues/PRs.")

(cl-defstruct (remoto-path (:constructor remoto-path-create)
                           (:copier nil))
  "Parsed components of a remoto path."
  owner repo ref path)

(defun remoto--parse-path (filename)
  "Parse canonical remoto FILENAME into a `remoto-path' struct.
Returns nil if FILENAME does not match the canonical format."
  (when (string-match remoto--path-regexp filename)
    (remoto-path-create
     :owner (match-string 1 filename)
     :repo  (match-string 2 filename)
     :ref   (match-string 3 filename)
     :path  (let ((p (match-string 4 filename)))
              (if (or (null p) (string-empty-p p)) "/" p)))))

(defun remoto--canonical-path (parsed)
  "Build a canonical remoto path string from PARSED `remoto-path'."
  (format "/github:%s/%s%s:%s"
          (remoto-path-owner parsed)
          (remoto-path-repo parsed)
          (if (remoto-path-ref parsed)
              (concat "@" (remoto-path-ref parsed))
            "")
          (or (remoto-path-path parsed) "/")))

(defun remoto--repo-key (parsed)
  "Return cache key string for PARSED `remoto-path'.
Format: owner/repo@ref."
  (format "%s/%s@%s"
          (remoto-path-owner parsed)
          (remoto-path-repo parsed)
          (or (remoto-path-ref parsed) "HEAD")))

;;;; GitHub API

(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))

(defgroup remoto nil
  "Browse GitHub repos without cloning."
  :group 'tools
  :prefix "remoto-")

(defcustom remoto-github-auth nil
  "Auth token source for GitHub API requests via ghub.
nil means use the default ghub token (USERNAME^ghub in auth-source).
A symbol like `forge' uses that package's token instead.
A string is used as a literal token.
See ghub documentation for auth-source setup."
  :type '(choice (const :tag "Default ghub token" nil)
                 (symbol :tag "Package token name")
                 (string :tag "Literal token"))
  :group 'remoto)

(defcustom remoto-auth-timeout 2
  "Seconds to wait for auth-source token lookup before giving up.
When ghub's token lookup (which may trigger GPG decryption of
authinfo) exceeds this limit, remoto falls back to unauthenticated
access and caches the failure for the rest of the session.  Use
`remoto-reset-auth' to retry after adding a token."
  :type 'number
  :group 'remoto)

(defvar remoto--auth-failed nil
  "Non-nil when authenticated GitHub access has permanently failed.
Set on actual auth errors (missing token, 401), NOT on timeouts.
Causes `remoto--api' to skip token lookup and use unauthenticated
requests.  Reset with `remoto-reset-auth'.")

(defvar remoto--authenticated-user nil
  "Cached GitHub login of the authenticated user, or nil if unknown.
Set by `remoto--get-authenticated-user' on first successful lookup.
Cleared by `remoto-reset-auth'.")

(defun remoto--json-reader (_status)
  "Parse JSON response with list-type arrays for remoto compatibility.
Handles both header-present and header-stripped response buffers."
  (goto-char (point-min))
  ;; Skip HTTP headers if present; if no blank line found, the
  ;; buffer is already just the body (varies by Emacs/url.el version).
  (re-search-forward "^\r?\n" nil t)
  (let ((body (buffer-substring-no-properties (point) (point-max))))
    (unless (string-empty-p body)
      (json-parse-string
       (decode-coding-string body 'utf-8)
       :object-type 'alist
       :array-type 'list
       :null-object nil
       :false-object nil))))

(defun remoto--ghub-get (resource auth endpoint)
  "Call `ghub-get' on RESOURCE with AUTH, translating errors.
ENDPOINT is used in error messages for context."
  (condition-case err
      (let ((inhibit-message (not ghub-debug)))
        (ghub-get resource nil
                  :auth auth
                  :reader #'remoto--json-reader))
    (ghub-404
     (user-error "Remoto: not found: %s" endpoint))
    (ghub-403
     (user-error "Remoto: access denied (rate limit or permissions): %s" endpoint))
    (ghub-401
     (user-error "Remoto: authentication failed; configure ghub token in auth-source"))
    (ghub-http-error
     (user-error "Remoto: API error: %s" (error-message-string err)))))

(defun remoto--api (endpoint)
  "Call GitHub REST API ENDPOINT via ghub, return parsed JSON.
ENDPOINT should not have a leading slash - one is prepended
automatically.  When `remoto-github-auth' is nil (default) and no
token is found in auth-source, retries unauthenticated - public
repos work without any setup.  Signals `user-error' on HTTP
failures."
  (let* ((resource (concat "/" endpoint))
         (auth (if remoto--auth-failed 'none remoto-github-auth)))
    (if (eq auth 'none)
        (remoto--ghub-get resource 'none endpoint)
      (condition-case err
          ;; Only apply the auth timeout on the first call (before we
          ;; know whether auth works).  Once the authenticated user is
          ;; cached, auth-source won't block, so skip the timeout to
          ;; avoid aborting slow HTTP responses.
          (if remoto--authenticated-user
              (remoto--ghub-get resource auth endpoint)
            (let ((result (with-timeout (remoto-auth-timeout 'remoto--timed-out)
                            (remoto--ghub-get resource auth endpoint))))
              (when (eq result 'remoto--timed-out)
                (message "Remoto: auth lookup timed out; retrying next call (see `remoto-auth-timeout')")
                (setq result (remoto--ghub-get resource 'none endpoint)))
              result))
        ;; Re-raise API errors (404, 403, etc.) from remoto--ghub-get;
        ;; these are not auth failures.  Other user-errors (e.g. ghub's
        ;; "Cannot determine username") are auth config issues - fall
        ;; through to unauthenticated access.
        (user-error
         (if (string-prefix-p "Remoto:" (cadr err))
             (signal (car err) (cdr err))
           (setq remoto--auth-failed t)
           (message "Remoto: auth unavailable (%s); using unauthenticated access"
                    (error-message-string err))
           (remoto--ghub-get resource 'none endpoint)))
        (error
         (setq remoto--auth-failed t)
         (message "Remoto: auth unavailable (%s); using unauthenticated access"
                  (error-message-string err))
         (remoto--ghub-get resource 'none endpoint))))))

(defun remoto-reset-auth ()
  "Clear the auth failure cache, retrying token lookup on next API call.
Use after adding a GitHub token to auth-source."
  (interactive)
  (setq remoto--auth-failed nil)
  (setq remoto--authenticated-user nil)
  (message "Remoto: auth cache cleared; will retry token lookup on next request"))

(defun remoto--default-branch (owner repo)
  "Fetch the default branch for OWNER/REPO."
  (let ((data (remoto--api (format "repos/%s/%s" owner repo))))
    (alist-get 'default_branch data)))

(defconst remoto--dir-entry
  '((type . "tree") (size . 0) (sha . "") (mode . "040000"))
  "Alist for synthesized directory entries (root, intermediates, `.', `..').")

;;;; Tree cache

(defvar remoto--tree-cache (make-hash-table :test 'equal)
  "Cache: \"owner/repo@ref\" -> hash table of path -> entry plist.")

(defvar remoto--default-branch-cache (make-hash-table :test 'equal)
  "Cache: \"owner/repo\" -> default branch name.")

(defvar remoto--branches-cache (make-hash-table :test 'equal)
  "Cache: \"owner/repo\" -> (TIMESTAMP . BRANCH-NAMES).")

(defvar remoto--users-cache (make-hash-table :test 'equal)
  "Cache: query string -> (TIMESTAMP . USER-NAMES).
Entries expire after `remoto-search-cache-ttl' seconds.")


(defun remoto--resolve-ref (parsed)
  "Ensure PARSED `remoto-path' has a concrete ref, resolving if needed.
Returns a new `remoto-path' with ref filled in."
  (if (remoto-path-ref parsed)
      parsed
    (let* ((owner (remoto-path-owner parsed))
           (repo (remoto-path-repo parsed))
           (repo-id (format "%s/%s" owner repo))
           (branch (or (gethash repo-id remoto--default-branch-cache)
                       (let ((b (remoto--default-branch owner repo)))
                         (puthash repo-id b remoto--default-branch-cache)
                         b))))
      (remoto-path-create
       :owner owner :repo repo :ref branch
       :path (remoto-path-path parsed)))))

(defun remoto--fetch-tree (owner repo ref)
  "Fetch full tree for OWNER/REPO at REF from GitHub API.
Returns a hash table of path -> alist with keys type, size, sha, mode."
  (let* ((endpoint (format "repos/%s/%s/git/trees/%s?recursive=1" owner repo ref))
         (data (remoto--api endpoint))
         (entries (alist-get 'tree data))
         (truncated (alist-get 'truncated data))
         (table (make-hash-table :test 'equal :size (length entries))))
    (when (eq truncated t)
      (puthash "\0truncated" t table)
      (message "Remoto: tree truncated for %s/%s@%s, fetching dirs on demand"
               owner repo ref))
    ;; Root entry
    (puthash "" remoto--dir-entry table)
    (puthash "/" remoto--dir-entry table)
    ;; All entries from API
    (dolist (entry entries)
      (let ((path (alist-get 'path entry))
            (plist (list (cons 'type (alist-get 'type entry))
                         (cons 'size (or (alist-get 'size entry) 0))
                         (cons 'sha  (alist-get 'sha entry))
                         (cons 'mode (alist-get 'mode entry)))))
        (puthash path plist table)
        ;; Synthesize intermediate directories
        (let ((parts (split-string path "/" t)))
          (when (< 1 (length parts))
            (cl-loop for i from 1 below (length parts)
                     for dir = (mapconcat #'identity (seq-take parts i) "/")
                     unless (gethash dir table)
                     do (puthash dir remoto--dir-entry table))))))
    table))

(defun remoto--ensure-tree (parsed)
  "Ensure tree is cached for PARSED path, return the tree hash table."
  (let* ((resolved (remoto--resolve-ref parsed))
         (key (remoto--repo-key resolved)))
    (or (gethash key remoto--tree-cache)
        (let* ((tree (remoto--fetch-tree
                      (remoto-path-owner resolved)
                      (remoto-path-repo resolved)
                      (remoto-path-ref resolved))))
          (puthash key tree remoto--tree-cache)
          tree))))

(defun remoto--fetch-directory-contents (parsed dir-key tree)
  "Fetch DIR-KEY via Contents API for PARSED repo, merge into TREE.
On-demand fallback for repos whose recursive tree was truncated."
  (let* ((resolved (remoto--resolve-ref parsed))
         (endpoint (if (string-empty-p dir-key)
                       (format "repos/%s/%s/contents?ref=%s"
                               (remoto-path-owner resolved)
                               (remoto-path-repo resolved)
                               (remoto-path-ref resolved))
                     (format "repos/%s/%s/contents/%s?ref=%s"
                             (remoto-path-owner resolved)
                             (remoto-path-repo resolved)
                             (url-hexify-string dir-key)
                             (remoto-path-ref resolved))))
         (data (condition-case nil
                   (remoto--api endpoint)
                 (user-error nil))))
    (puthash (concat "\0fetched:" dir-key) t tree)
    ;; Contents API returns a list of alists for directories
    (when (and (consp data) (consp (caar data)))
      (dolist (entry data)
        (let* ((path (alist-get 'path entry))
               (api-type (alist-get 'type entry))
               (type (if (equal api-type "dir") "tree" "blob"))
               (plist (list (cons 'type type)
                            (cons 'size (or (alist-get 'size entry) 0))
                            (cons 'sha (or (alist-get 'sha entry) ""))
                            (cons 'mode (if (equal type "tree") "040000" "100644")))))
          ;; Keep existing entries from Trees API (they have richer mode info)
          (unless (gethash path tree)
            (puthash path plist tree)))))))

(defun remoto--tree-lookup-key (path)
  "Normalize PATH for tree hash-table lookup.
Strips leading/trailing slashes and collapses runs of slashes."
  (let ((p (replace-regexp-in-string "/+" "/" path)))
    (when (string-prefix-p "/" p)
      (setq p (substring p 1)))
    (when (and (not (string-empty-p p))
               (string-suffix-p "/" p))
      (setq p (substring p 0 (1- (length p)))))
    p))

(defun remoto--tree-entry (parsed)
  "Look up the tree entry for PARSED path.  Return plist or nil.
For truncated trees, fetches the parent directory on demand."
  (let* ((tree (remoto--ensure-tree parsed))
         (key (remoto--tree-lookup-key (remoto-path-path parsed))))
    (or (gethash key tree)
        (when (and (gethash "\0truncated" tree)
                   (not (string-empty-p key)))
          (let ((parent (if (string-search "/" key)
                            (remoto--tree-lookup-key
                             (file-name-directory (directory-file-name key)))
                          "")))
            (unless (gethash (concat "\0fetched:" parent) tree)
              (remoto--fetch-directory-contents parsed parent tree))
            (gethash key tree))))))

(defun remoto--tree-children (parsed)
  "List direct children of directory at PARSED path.
Returns list of (NAME . PLIST) for each child.
For truncated trees, fetches the directory on demand."
  (let* ((tree (remoto--ensure-tree parsed))
         (dir-path (remoto--tree-lookup-key (remoto-path-path parsed)))
         (_ (when (and (gethash "\0truncated" tree)
                       (not (gethash (concat "\0fetched:" dir-path) tree)))
              (remoto--fetch-directory-contents parsed dir-path tree)))
         (prefix (if (string-empty-p dir-path) "" (concat dir-path "/")))
         (prefix-len (length prefix)))
    (thread-last (hash-table-keys tree)
      (seq-filter (lambda (path)
                    (and (not (string-prefix-p "\0" path))
                         (string-prefix-p prefix path)
                         (not (equal path dir-path))
                         ;; Direct child: no more slashes after prefix
                         (not (string-search "/" (substring path prefix-len))))))
      (mapcar (lambda (path)
                (cons (substring path prefix-len)
                      (gethash path tree))))
      (seq-remove (lambda (child) (string-empty-p (car child))))
      (seq-sort (lambda (a b) (string< (car a) (car b)))))))

;;;; Path normalization helpers

(defun remoto--normalize-path (path)
  "Clean up PATH component: collapse double slashes, resolve . and .."
  (let* ((parts (split-string path "/" t))
         (result nil))
    (dolist (p parts)
      (cond
       ((equal p "."))
       ((equal p "..")
        (when result (pop result)))
       (t (push p result))))
    (let ((normalized (concat "/" (mapconcat #'identity (nreverse result) "/"))))
      ;; Preserve trailing slash for directories
      (if (and (string-suffix-p "/" path)
               (not (string-suffix-p "/" normalized)))
          (concat normalized "/")
        normalized))))

(defun remoto--file-name-prefix (filename)
  "Extract the /github:owner/repo@ref: prefix from FILENAME."
  (when (string-match (rx bos "/github:"
                          (+ (not ":"))
                          ":")
                      filename)
    (match-string 0 filename)))

;;;; File-name handler

(defun remoto-file-name-handler (operation &rest args)
  "Handle file OPERATION for remoto paths.
Dispatches to `remoto--handle-OPERATION' or falls through to defaults.
Pass remaining ARGS to the resolved handler."
  (if-let* ((handler (intern-soft (format "remoto--handle-%s" operation)))
            (_ (fboundp handler)))
      (apply handler args)
    ;; Fall through to default handler
    (let ((inhibit-file-name-handlers
           (cons #'remoto-file-name-handler
                 (and (eq inhibit-file-name-operation operation)
                      inhibit-file-name-handlers)))
          (inhibit-file-name-operation operation))
      (apply operation args))))

;;;; Read operations

(defun remoto--handle-file-exists-p (filename)
  "Return t if FILENAME exists or is openable.
Returns nil for paths that are mid-completion (no selection made yet),
which triggers Emacs's `confirm-nonexistent-file-or-buffer' on RET."
  (cond
   ;; /github: and /github:owner/ - directory-like, exist for navigation
   ((string-match (rx bos "/github:" (? "/") eos) filename) t)
   ((string-match (rx bos "/github:"
                      (+ (not (any "/:@#")))
                      "/" eos)
                  filename) t)
   ;; /github:owner/repo/ - openable as dired on default branch
   ((string-match (rx bos "/github:"
                      (+ (not (any "/:@#")))
                      "/"
                      (+ (not (any "/:@#")))
                      "/")
                  filename) t)
   ;; /github:owner/repo#NUM - specific issue ref, openable
   ((string-match (rx bos "/github:"
                      (+ (not (any "/:@#")))
                      "/"
                      (+ (not (any "/:@#")))
                      "#"
                      (+ digit) eos)
                  filename) t)
   ;; /github:owner/repo (bare) - NOT openable, still needs delimiter
   ((string-match (rx bos "/github:"
                      (+ (not (any "/:@#")))
                      "/"
                      (+ (not (any "/:@#")))
                      eos)
                  filename)
    nil)
   ;; /github:owner/repo# or /github:owner/repo@ - delimiter without selection
   ((string-match (rx bos "/github:"
                      (+ (not (any "/:@#")))
                      "/"
                      (+ (not (any "/:@#")))
                      (any "@#") eos)
                  filename)
    nil)
   ;; /github:owner# or /github:owner@ - no repo, invalid
   ((and (string-prefix-p "/github:" filename)
         (not (remoto--parse-path filename))
         (string-match (rx (any "@#") eos) filename))
    nil)
   ;; Full canonical path - check tree
   (t
    (when-let* ((parsed (remoto--parse-path filename)))
      (and (remoto--tree-entry parsed) t)))))

(defun remoto--handle-file-directory-p (filename)
  "Return t if FILENAME is a directory in the remote repo.
Also returns t for partial paths like /github: and /github:OWNER/."
  (cond
   ;; /github: is a virtual directory root
   ((string-match (rx bos "/github:" (? "/") eos) filename) t)
   ;; /github:owner/ is a virtual owner directory
   ((remoto--parse-partial-github-path
     (remoto--handle-file-name-as-directory filename))
    t)
   (t
    (when-let* ((parsed (remoto--parse-path filename))
                (entry (remoto--tree-entry parsed)))
      (equal "tree" (alist-get 'type entry))))))

(defun remoto--handle-file-accessible-directory-p (filename)
  "Return t if FILENAME is an accessible directory.
Delegates to `file-directory-p' - remote dirs are always readable."
  (remoto--handle-file-directory-p filename))

(defun remoto--handle-file-regular-p (filename)
  "Return t if FILENAME is a regular file in the remote repo."
  (when-let* ((parsed (remoto--parse-path filename))
              (entry (remoto--tree-entry parsed)))
    (equal "blob" (alist-get 'type entry))))

(defun remoto--handle-file-readable-p (filename)
  "Return non-nil if remote FILENAME is readable."
  (remoto--handle-file-exists-p filename))

(defun remoto--handle-file-writable-p (_filename)
  "Remote repos are never writable."
  nil)

(defun remoto--handle-file-attributes (filename &optional _id-format)
  "Return file attributes for FILENAME.
Synthesized from tree cache - timestamps are epoch 0."
  (when-let* ((parsed (remoto--parse-path filename))
              (entry (remoto--tree-entry parsed)))
    (let* ((dir? (equal "tree" (alist-get 'type entry)))
           (size (or (alist-get 'size entry) 0))
           (mode-str (or (alist-get 'mode entry) "100644"))
           (mode (string-to-number mode-str 8))
           ;; Use epoch 0 for all timestamps
           (time '(0 0 0 0)))
      ;; Return vector matching `file-attributes' format:
      ;; (type links uid gid atime mtime ctime size mode
      ;;  gid-change inode device)
      (list (if dir? t nil)      ; type: t=dir, nil=file
            1                    ; links
            0                    ; uid
            0                    ; gid
            time                 ; atime
            time                 ; mtime
            time                 ; ctime
            size                 ; size
            (format "%05o" mode) ; mode string
            nil                  ; gid-change
            0                    ; inode
            0))))               ; device

(defun remoto--handle-directory-files (directory &optional full match nosort count)
  "List files in remote DIRECTORY.
FULL, MATCH, NOSORT, COUNT as per `directory-files'."
  (when-let* ((parsed (remoto--parse-path directory)))
    (let ((names (append '("." "..")
                         (mapcar #'car (remoto--tree-children parsed)))))
      (when match
        (setq names (seq-filter (lambda (name)
                                  (string-match-p match name))
                                names)))
      (unless nosort
        (setq names (sort names #'string<)))
      (when count
        (setq names (seq-take names count)))
      (if full
          (let ((prefix (remoto--file-name-prefix directory))
                (dir-path (remoto-path-path parsed)))
            (mapcar (lambda (name)
                      (concat prefix
                              (remoto--normalize-path
                               (concat dir-path "/" name))))
                    names))
        names))))

(defun remoto--handle-directory-files-and-attributes
    (directory &optional full match nosort id-format)
  "Like `directory-files-and-attributes' for remote DIRECTORY.
Pass FULL, MATCH, NOSORT, and ID-FORMAT through unchanged."
  (let* ((parsed (remoto--parse-path directory))
         (prefix (remoto--file-name-prefix directory))
         (base-path (lambda (f)
                      (concat prefix
                              (remoto--normalize-path
                               (concat (remoto-path-path parsed) "/" f))))))
    (thread-last
      (remoto--handle-directory-files directory full match nosort)
      (mapcar (lambda (f)
                (cons f (remoto--handle-file-attributes
                         (if full f (funcall base-path f))
                         id-format)))))))

(defun remoto--parse-partial-github-path (directory)
  "Parse a partial /github: DIRECTORY for pre-repo completion.
Returns a plist with :level plus context keys, or nil.
Levels: `root', `owner', `repo' (branches/tags), `files-default', `issues'."
  (when (stringp directory)
    (cond
     ;; /github:
     ((string-match (rx bos "/github:" eos) directory)
      (list :level 'root :owner nil))
     ;; /github:owner/repo# - issues level (repo must contain no /:@#)
     ((string-match (rx bos "/github:"
                        (group (+ (not (any "/:@#"))))
                        "/"
                        (group (+ (not (any "/:@#"))))
                        "#" eos)
                    directory)
      (list :level 'issues
            :owner (match-string 1 directory)
            :repo (match-string 2 directory)))
     ;; /github:owner/repo@ - branches/tags level
     ((string-match (rx bos "/github:"
                        (group (+ (not (any "/:@#"))))
                        "/"
                        (group (+ (not (any "/:@#"))))
                        "@" (? "/") eos)
                    directory)
      (list :level 'repo
            :owner (match-string 1 directory)
            :repo (match-string 2 directory)))
     ;; /github:owner/repo/ or /github:owner/repo/subdir/ - files-default
     ((string-match (rx bos "/github:"
                        (group (+ (not (any "/:@#"))))
                        "/"
                        (group (+ (not (any ":@#"))))
                        "/" eos)
                    directory)
      ;; Distinguish owner/ (level=owner) from owner/repo/ (level=files-default)
      ;; The second group must be a repo name (no slashes) or repo/subpath
      (let ((owner (match-string 1 directory))
            (rest (match-string 2 directory)))
        (if (string-match-p "/" rest)
            ;; rest contains slash: owner/repo/subdir
            (let* ((slash-pos (string-match "/" rest))
                   (repo (substring rest 0 slash-pos)))
              (list :level 'files-default
                    :owner owner
                    :repo repo))
          ;; rest is just repo name
          (list :level 'files-default
                :owner owner
                :repo rest))))
     ;; /github:owner/ - owner level
     ((string-match (rx bos "/github:"
                        (group (+ (not (any "/:@#"))))
                        "/" eos)
                    directory)
      (list :level 'owner :owner (match-string 1 directory))))))

(defun remoto--handle-file-name-all-completions (file directory)
  "Return completions for FILE in remote DIRECTORY.
Handles multiple levels: user search at /github:, repo listing at
/github:OWNER/, branch/tag at /github:OWNER/REPO@, files at
/github:OWNER/REPO/, issues at /github:OWNER/REPO#, and file
listing within a repo.  Network calls are wrapped in
`while-no-input' so typing interrupts pending API requests
instead of blocking Emacs."
  (if-let* ((partial (remoto--parse-partial-github-path directory)))
      (pcase (plist-get partial :level)
        ('root
         ;; Empty query + authenticated: show user + orgs
         ;; Non-empty: search users/orgs matching FILE
         (if (string-empty-p file)
             (when-let* ((user remoto--authenticated-user))
               (let* ((orgs (remoto--fetch-user-orgs user))
                      (all (cons user orgs)))
                 (mapcar (lambda (u) (concat u "/")) all)))
           (let ((result (while-no-input (remoto--search-users file))))
             (when (listp result)
               (let ((filtered (thread-last result
                                 (seq-filter (lambda (u) (string-prefix-p file u))))))
                 ;; Pre-fetch repos for the top match so the cache is
                 ;; warm by the time the user types "/"
                 (when-let* ((top (car filtered)))
                   (remoto--prefetch-owner-repos top))
                 (mapcar (lambda (u) (concat u "/")) filtered))))))
        ('owner
         ;; Repo completion at /github:OWNER/
         (let* ((owner (plist-get partial :owner))
                (result (while-no-input
                          (if (string-empty-p file)
                              (remoto--recent-owner-repos owner)
                            (remoto--search-owner-repos owner file)))))
           (when (listp result) result)))
        ('repo
         ;; Branch + tag completion at /github:OWNER/REPO@
         (if (string-suffix-p ":" file)
             ;; Ref already selected (e.g. "main:") - exact match
             (list file)
           (let* ((owner (plist-get partial :owner))
                  (repo (plist-get partial :repo))
                  (branches (while-no-input
                              (remoto--fetch-branches owner repo)))
                  (tags (while-no-input
                          (remoto--fetch-tags owner repo))))
             (when (or (listp branches) (listp tags))
               (let ((branch-set (when (listp branches)
                                   (mapcar (lambda (b)
                                             (propertize (concat b ":")
                                                        'remoto-ref-type "branch"))
                                           branches)))
                     (tag-set (when (listp tags)
                                (mapcar (lambda (tg)
                                          (propertize (concat tg ":")
                                                     'remoto-ref-type "tag"))
                                        tags))))
                 (thread-last (append branch-set tag-set)
                   (seq-filter (lambda (r)
                                 (or (string-empty-p file)
                                     (string-prefix-p file r))))))))))
        ('files-default
         ;; File completion on default branch: /github:OWNER/REPO/[subdir/]
         (let* ((owner (plist-get partial :owner))
                (repo (plist-get partial :repo))
                (branch (while-no-input
                          (remoto--default-branch owner repo))))
           (when (and (stringp branch) (not (equal branch t)))
             ;; Extract subpath from directory after owner/repo/
             (let* ((repo-end (string-match
                               (rx (+ (not (any "/:@#")))
                                   "/"
                                   (+ (not (any "/:@#")))
                                   "/")
                               directory
                               (length "/github:")))
                    (subpath (if repo-end
                                (substring directory (match-end 0))
                              ""))
                    (canonical (format "/github:%s/%s@%s:/%s"
                                      owner repo branch subpath))
                    (parsed (remoto--parse-path canonical)))
               (when parsed
                 (remoto--ensure-tree parsed)
                 (thread-last (remoto--tree-children parsed)
                   (mapcar (lambda (child)
                             (if (equal "tree" (alist-get 'type (cdr child)))
                                 (concat (car child) "/")
                               (car child))))
                   (seq-filter (lambda (name)
                                 (string-prefix-p file name)))))))))
        ('issues
         ;; Issue/PR completion at /github:OWNER/REPO#
         (let* ((owner (plist-get partial :owner))
                (repo (plist-get partial :repo))
                (issues
                 (cond
                  ;; Empty query: show top open issues
                  ((string-empty-p file)
                   (while-no-input
                     (remoto--fetch-issues owner repo)))
                  ;; Numeric query: direct fetch + filter cached
                  ((string-match-p (rx bos (+ digit) eos) file)
                   (let* ((cached (while-no-input
                                    (remoto--fetch-issues owner repo)))
                          (direct (while-no-input
                                    (remoto--fetch-issue owner repo file)))
                          (results (if (listp cached) cached nil)))
                     (if direct
                         (cl-remove-duplicates
                          (cons direct results)
                          :key (lambda (i) (alist-get 'number i)))
                       results)))
                  ;; Text query: search
                  (t
                   (while-no-input
                     (remoto--search-issues owner repo file))))))
           (when (listp issues)
             (let* ((candidates
                     (mapcar (lambda (i)
                               (let* ((num (number-to-string (alist-get 'number i)))
                                      (is-pr (not (null (alist-get 'pull_request i))))
                                      (title (or (alist-get 'title i) ""))
                                      (state (or (alist-get 'state i) "")))
                                 (propertize num
                                             'remoto-issue-pr is-pr
                                             'remoto-issue-title title
                                             'remoto-issue-state state)))
                             issues))
                    (filtered
                     (if (or (string-empty-p file)
                             (string-match-p (rx bos (+ digit) eos) file))
                         (seq-filter (lambda (n) (string-prefix-p file n)) candidates)
                       candidates)))
               ;; Sort: PRs first, then issues; within each group by number descending
               (sort filtered
                     (lambda (a b)
                       (let ((a-pr (get-text-property 0 'remoto-issue-pr a))
                             (b-pr (get-text-property 0 'remoto-issue-pr b)))
                         (cond
                          ((and a-pr (not b-pr)) t)
                          ((and (not a-pr) b-pr) nil)
                          (t (> (string-to-number a) (string-to-number b))))))))))))
    ;; Full canonical path - existing behavior
    (when-let* ((parsed (remoto--parse-path directory)))
      (thread-last (remoto--tree-children parsed)
        (mapcar (lambda (child)
                  (if (equal "tree" (alist-get 'type (cdr child)))
                      (concat (car child) "/")
                    (car child))))
        (seq-filter (lambda (name)
                      (string-prefix-p file name)))))))

(defun remoto--handle-file-name-completion (file directory &optional predicate)
  "Complete FILE in remote DIRECTORY using optional PREDICATE.
Handles partial /github: paths for pre-repo completion.
PREDICATE may be a function, nil, or a string directory-prefix
passed through by `completion-file-name-table' - strings are
ignored since remoto paths always qualify."
  (let ((completions (remoto--handle-file-name-all-completions file directory))
        ;; completion-file-name-table passes the read-file-name
        ;; directory as a string predicate - not a callable filter
        (pred (if (stringp predicate) nil predicate)))
    (cond
     ((null completions) nil)
     ((null (cdr completions))
      (if (equal file (car completions)) t (car completions)))
     (t (try-completion file completions pred)))))

(defun remoto--handle-expand-file-name (name &optional dir)
  "Expand NAME relative to DIR for remoto paths."
  (let ((inhibit-file-name-handlers
         (cons #'remoto-file-name-handler
               (and (eq inhibit-file-name-operation 'expand-file-name)
                    inhibit-file-name-handlers)))
        (inhibit-file-name-operation 'expand-file-name))
    (cond
     ;; Already absolute remoto path
     ((string-prefix-p "/github:" name) name)
     ;; Local absolute or home-relative path - never resolve under remoto
     ((or (and (string-prefix-p "/" name)
              (not (string-prefix-p "/github:" name)))
          (string-prefix-p "~" name))
      (expand-file-name name))
     ;; Relative path under a remoto directory
     ((and dir (string-prefix-p "/github:" dir))
      (if-let* ((parsed (remoto--parse-path dir))
                (prefix (remoto--file-name-prefix dir)))
          (let* ((dir-path (remoto-path-path parsed))
                 (combined (concat dir-path "/" name)))
            (concat prefix (remoto--normalize-path combined)))
        ;; Partial path (e.g. /github:owner/ or /github:owner/repo@)
        (concat dir name)))
     ;; Not our path, delegate
     (t (expand-file-name name dir)))))

(defun remoto--handle-file-truename (filename &optional _counter _prev-dirs)
  "Return FILENAME as-is - no symlink resolution for remote repos."
  filename)

(defun remoto--handle-file-remote-p (filename &optional identification _connected)
  "Return remote identification for FILENAME.
Use IDENTIFICATION to select which remote field to report.
Handles partial paths for pre-repo completion."
  (when (string-prefix-p "/github:" filename)
    (if-let* ((parsed (remoto--parse-path filename))
              (prefix (remoto--file-name-prefix filename)))
        (pcase identification
          ('method "github")
          ('host (format "%s/%s" (remoto-path-owner parsed)
                         (remoto-path-repo parsed)))
          (_ prefix))
      ;; Partial path - still remote
      (pcase identification
        ('method "github")
        ('host "github.com")
        (_ "/github:")))))

(defun remoto--handle-file-name-directory (filename)
  "Return directory part of remote FILENAME.
Handles partial paths including # and files-default short forms."
  (cond
   ;; /github:owner/repo#query - # is delimiter, directory is up to and including #
   ((and (string-prefix-p "/github:" filename)
         (not (remoto--parse-path filename))
         (string-match (rx bos "/github:"
                           (+ (not (any "/:@#")))
                           "/"
                           (+ (not (any "/:@#")))
                           "#")
                       filename))
    (match-string 0 filename))
   ;; /github:owner/repo@... - treat repo@ as directory
   ((and (string-prefix-p "/github:" filename)
         (not (remoto--parse-path filename))
         (string-match (rx bos "/github:"
                           (+ (not (any "/:@#")))
                           "/"
                           (+ (not (any "/:@#")))
                           "@")
                       filename))
    (match-string 0 filename))
   ;; /github:owner/repo/... - files-default short form
   ((and (string-prefix-p "/github:" filename)
         (not (remoto--parse-path filename))
         (string-match (rx bos "/github:"
                           (+ (not (any "/:@#")))
                           "/"
                           (+ (not (any "/:@#")))
                           "/")
                       filename))
    (if (string-suffix-p "/" filename)
        filename
      ;; Find the last / and return everything up to and including it
      (let ((last-slash (string-match-p (rx "/" (+ (not "/")) eos) filename)))
        (if last-slash
            (substring filename 0 (1+ last-slash))
          filename))))
   ;; /github:owner/repo (bare, no delimiter) -> directory is /github:owner/
   ((and (string-prefix-p "/github:" filename)
         (not (remoto--parse-path filename))
         (string-match (rx bos "/github:"
                           (+ (not (any "/:@#")))
                           "/")
                       filename))
    (match-string 0 filename))
   ;; /github: or /github:owner or /github:owner-with-specials
   ;; Anything after /github: without a / is the owner query
   ((and (string-prefix-p "/github:" filename)
         (not (remoto--parse-path filename)))
    (if (string-match (rx bos "/github:" eos) filename)
        "/github:"
      "/github:"))
   ;; Full canonical path
   (t
    (when-let* ((parsed (remoto--parse-path filename))
                (prefix (remoto--file-name-prefix filename)))
      (let* ((path (remoto-path-path parsed))
             (dir (if (string-suffix-p "/" path)
                      path
                    (file-name-directory path))))
        (concat prefix (or dir "/")))))))

(defun remoto--handle-file-name-nondirectory (filename)
  "Return non-directory part of remote FILENAME.
Handles partial paths including # and files-default short forms."
  (cond
   ;; /github: -> ""
   ((string-match (rx bos "/github:" eos) filename) "")
   ;; /github:owner/repo#query - nondirectory is text after #
   ((and (string-prefix-p "/github:" filename)
         (not (remoto--parse-path filename))
         (string-match (rx bos "/github:"
                           (+ (not (any "/:@#")))
                           "/"
                           (+ (not (any "/:@#")))
                           "#"
                           (group (* anything)) eos)
                       filename))
    (match-string 1 filename))
   ;; /github:owner/repo@ -> ""
   ((and (string-prefix-p "/github:" filename)
         (not (remoto--parse-path filename))
         (string-match (rx bos "/github:"
                           (+ (not (any "/:@#")))
                           "/"
                           (+ (not (any "/:@#")))
                           "@" eos)
                       filename))
    "")
   ;; /github:owner/repo@branch -> "branch"
   ((and (string-prefix-p "/github:" filename)
         (not (remoto--parse-path filename))
         (string-match (rx bos "/github:"
                           (+ (not (any "/:@#")))
                           "/"
                           (+ (not (any "/:@#")))
                           "@"
                           (group (+ (not (any "/:@"))))
                           eos)
                       filename))
    (match-string 1 filename))
   ;; /github:owner/repo/path - files-default short form
   ((and (string-prefix-p "/github:" filename)
         (not (remoto--parse-path filename))
         (string-match (rx bos "/github:"
                           (+ (not (any "/:@#")))
                           "/"
                           (+ (not (any "/:@#")))
                           "/")
                       filename))
    ;; After repo/, extract the last component without re-entering handler
    (if (string-suffix-p "/" filename)
        ""
      (let ((last-slash (string-match-p (rx "/" (+ (not "/")) eos) filename)))
        (if last-slash
            (substring filename (1+ last-slash))
          ""))))
   ;; /github:owner/ -> ""
   ((and (string-prefix-p "/github:" filename)
         (string-suffix-p "/" filename)
         (not (remoto--parse-path filename)))
    "")
   ;; /github:owner/repo (bare, no delimiter) -> "repo"
   ((and (string-prefix-p "/github:" filename)
         (not (remoto--parse-path filename))
         (string-match (rx bos "/github:" (+ (not (any "/:@#"))) "/"
                           (group (+ (not (any "/:@#")))) eos)
                       filename))
    (match-string 1 filename))
   ;; /github:query - everything after /github: is the query (owner or owner#, etc.)
   ((and (not (remoto--parse-path filename))
         (string-match (rx bos "/github:" (group (+ anything)) eos) filename))
    (match-string 1 filename))
   ;; Full canonical path
   (t
    (if-let* ((parsed (remoto--parse-path filename)))
        (thread-last (remoto-path-path parsed)
          (directory-file-name)
          (file-name-nondirectory))
      (file-name-nondirectory filename)))))

;;;; File content fetching

(defun remoto--relative-path (path)
  "Strip leading slash from PATH for API requests."
  (if (string-prefix-p "/" path) (substring path 1) path))

(defvar remoto--content-cache (make-hash-table :test 'equal)
  "Cache: sha -> decoded file content string.")

(defun remoto--fetch-file-content (owner repo path ref)
  "Fetch content of file at PATH in OWNER/REPO@REF.
Uses Contents API for files under 1MB, Blobs API otherwise."
  (let* ((endpoint (format "repos/%s/%s/contents/%s?ref=%s"
                           owner repo
                           (url-hexify-string path) ref))
         (data (remoto--api endpoint))
         (sha (alist-get 'sha data))
         (cached (gethash sha remoto--content-cache)))
    (or cached
        (let* ((encoding (alist-get 'encoding data))
               (content
                (if (equal encoding "base64")
                    (let ((raw (alist-get 'content data)))
                      (decode-coding-string
                       (base64-decode-string (string-replace "\n" "" raw))
                       'utf-8))
                  ;; Too large - use Blobs API
                  (remoto--fetch-blob owner repo sha))))
          (puthash sha content remoto--content-cache)
          content))))

(defun remoto--fetch-blob (owner repo sha)
  "Fetch a git blob by SHA from OWNER/REPO.  Return decoded content."
  (let* ((endpoint (format "repos/%s/%s/git/blobs/%s" owner repo sha))
         (data (remoto--api endpoint))
         (raw (alist-get 'content data)))
    (decode-coding-string
     (base64-decode-string (string-replace "\n" "" raw))
     'utf-8)))

(defun remoto--handle-insert-file-contents
    (filename &optional visit beg end replace)
  "Insert contents of remote FILENAME into current buffer.
VISIT, BEG, END, REPLACE as per `insert-file-contents'."
  (let ((parsed (remoto--parse-path filename)))
    (unless parsed
      (error "Remoto: cannot parse path: %s" filename))
    (let* ((resolved (remoto--resolve-ref parsed))
           (path (remoto--relative-path (remoto-path-path resolved)))
           (content (remoto--fetch-file-content
                     (remoto-path-owner resolved)
                     (remoto-path-repo resolved)
                     path
                     (remoto-path-ref resolved))))
      (when replace (erase-buffer))
      (let* ((text (if (and beg end)
                       (substring content (1- beg) (1- end))
                     content))
             (len (length text)))
        (let ((pt (point)))
          (insert text)
          (goto-char pt))
        (when visit
          (setq buffer-file-name filename)
          (setq buffer-read-only t)
          (set-buffer-modified-p nil)
          (set-visited-file-modtime 0))
        (list filename len)))))

;;;; Dired integration

(defun remoto--mode-to-string (mode-str dir?)
  "Convert git MODE-STR to an ls-style permission string for DIR?."
  (cond
   (dir?                "drwxr-xr-x")
   ((equal mode-str "100755") "-rwxr-xr-x")
   ((equal mode-str "120000") "lrwxrwxrwx")
   (t                   "-rw-r--r--")))

(defun remoto--format-dired-entry (name plist)
  "Format a single Dired line for NAME with PLIST attributes.
No leading spaces - Dired and dired-subtree add their own."
  (let* ((dir? (equal "tree" (alist-get 'type plist)))
         (size (or (alist-get 'size plist) 0))
         (mode (or (alist-get 'mode plist) "100644"))
         (perms (remoto--mode-to-string mode dir?)))
    (format "%s  1 github github %8d Jan  1  2000 %s\n"
            perms size name)))

(defun remoto--handle-insert-directory
    (filename _switches &optional _wildcard full-directory-p)
  "Insert a Dired-format listing for remote FILENAME.
Use FULL-DIRECTORY-P to force directory-style output."
  (when-let* ((parsed (remoto--parse-path filename))
              (entry (remoto--tree-entry parsed)))
    (cond
     ((or full-directory-p
          (equal "tree" (alist-get 'type entry)))
      (insert "total 0\n")
      (insert (remoto--format-dired-entry "." remoto--dir-entry))
      (insert (remoto--format-dired-entry ".." remoto--dir-entry))
      (dolist (child (remoto--tree-children parsed))
        (insert (remoto--format-dired-entry (car child) (cdr child)))))
     (t
      (let ((name (file-name-nondirectory
                   (directory-file-name (remoto-path-path parsed)))))
        (insert (remoto--format-dired-entry name entry)))))))

(defun remoto--handle-file-local-copy (filename)
  "Download remote FILENAME to a temp file, return temp path."
  (when-let* ((parsed (remoto--parse-path filename))
              (resolved (remoto--resolve-ref parsed))
              (path (remoto--relative-path (remoto-path-path resolved)))
              (content (remoto--fetch-file-content
                        (remoto-path-owner resolved)
                        (remoto-path-repo resolved)
                        path
                        (remoto-path-ref resolved))))
    (let* ((ext (file-name-extension path t))
           (temp (make-temp-file "remoto-" nil ext)))
      (with-temp-file temp
        (insert content))
      temp)))

(defun remoto--handle-make-nearby-temp-file (prefix &optional dir-flag suffix)
  "Create a temp file using PREFIX in the system temp dir.
Pass DIR-FLAG and SUFFIX through to `make-temp-file'."
  (make-temp-file prefix dir-flag suffix))

;;;; Additional operations needed by dired and other Emacs internals

(defun remoto--handle-file-name-as-directory (filename)
  "Append / to FILENAME if not already present."
  (if (string-suffix-p "/" filename)
      filename
    (concat filename "/")))

(defun remoto--handle-directory-file-name (directory)
  "Strip trailing / from DIRECTORY."
  (if (and (string-suffix-p "/" directory)
           ;; Don't strip the / after the colon in /github:o/r@ref:/
           (not (string-suffix-p ":/" directory)))
      (substring directory 0 (1- (length directory)))
    directory))

(defun remoto--handle-file-name-case-insensitive-p (_filename)
  "GitHub repos are case-sensitive."
  nil)

(defun remoto--handle-vc-registered (_filename)
  "Remote files are not under local vc."
  nil)

(defun remoto--handle-make-directory (dir &optional _parents)
  "Ignore existing DIR and signal an error otherwise."
  (unless (remoto--handle-file-directory-p dir)
    (user-error "Remoto: repository is read-only")))

(defun remoto--handle-abbreviate-file-name (filename)
  "Return FILENAME as-is - no abbreviation for remote paths."
  filename)

(defun remoto--handle-unhandled-file-name-directory (_filename)
  "Return nil - no local equivalent for remote paths."
  nil)

;;;; Write operations (all read-only)

(defun remoto--read-only (&rest _args)
  "Signal that remote repos are read-only."
  (user-error "Remoto: repository is read-only"))

(defalias 'remoto--handle-write-region #'remoto--read-only)
(defalias 'remoto--handle-delete-file #'remoto--read-only)
(defalias 'remoto--handle-delete-directory #'remoto--read-only)
(defalias 'remoto--handle-rename-file #'remoto--read-only)
(defun remoto--handle-copy-file (file newname
                                      &optional ok-if-already-exists keep-time
                                      preserve-uid-gid preserve-permissions)
  "Copy FILE to NEWNAME. Works when destination is outside remoto.
OK-IF-ALREADY-EXISTS, KEEP-TIME, PRESERVE-UID-GID, and
PRESERVE-PERMISSIONS are passed through to `copy-file'."
  (if (string-match-p remoto--path-regexp newname)
      (remoto--read-only 'copy-file file newname)
    (let ((local-copy (remoto--handle-file-local-copy file)))
      (unless local-copy
        (error "Remoto: failed to download %s" file))
      (unwind-protect
          (let ((inhibit-file-name-handlers
                 (cons #'remoto-file-name-handler
                       (and (eq inhibit-file-name-operation 'copy-file)
                            inhibit-file-name-handlers)))
                (inhibit-file-name-operation 'copy-file))
            (copy-file local-copy newname ok-if-already-exists keep-time
                       preserve-uid-gid preserve-permissions))
        (when (file-exists-p local-copy)
          (delete-file local-copy))))))
(defalias 'remoto--handle-set-file-modes #'remoto--read-only)
(defalias 'remoto--handle-set-file-times #'remoto--read-only)

;;;; User input parsing

(defun remoto--parse-github-url (input)
  "Parse GitHub web INPUT into a `remoto-path' struct."
  (cond
   ((string-match
     (rx bos "https://github.com/"
         (group (+ (not "/")))
         "/"
         (group (+ (not (any "/#"))))
         (? "/" (or "tree" "blob") "/"
            (group (+ (not "/")))
            (? "/" (group (+ (not "#")))))
         (* nonl)
         eos)
     input)
    (remoto-path-create
     :owner (match-string 1 input)
     :repo (match-string 2 input)
     :ref (match-string 3 input)
     :path (concat "/" (or (match-string 4 input) ""))))
   ((string-match
     (rx bos "https://github.com/"
         (group (+ (not "/")))
         "/"
         (group (+ (not (any "/#. "))))
         (* (any "/."))
         eos)
     input)
    (remoto-path-create
     :owner (match-string 1 input)
     :repo (match-string 2 input)
     :ref nil
     :path "/"))))

(defun remoto--parse-git-remote (input)
  "Parse git remote INPUT into a `remoto-path' struct."
  (when (string-match
         (rx bos "git@github.com:"
             (group (+ (not "/")))
             "/"
             (group (+ (not (any "/ "))))
             eos)
         input)
    (let ((repo (match-string 2 input)))
      (remoto-path-create
       :owner (match-string 1 input)
       :repo (if (string-suffix-p ".git" repo)
                 (substring repo 0 -4)
               repo)
       :ref nil
       :path "/"))))

(defun remoto--parse-repo-shorthand (input)
  "Parse owner/repo INPUT into a `remoto-path' struct."
  (when (string-match
         (rx bos
             (group (+ (not (any "/@"))))
             "/"
             (group (+ (not (any "/@"))))
             (? "@" (group (+ nonl)))
             eos)
         input)
    (remoto-path-create
     :owner (match-string 1 input)
     :repo (match-string 2 input)
     :ref (match-string 3 input)
     :path "/")))

(defun remoto--parse-input (input)
  "Normalize user INPUT into a `remoto-path' struct.
Accept GitHub URLs, git remote URLs, or owner/repo shorthand."
  (let ((input (string-trim input)))
    (or (remoto--parse-github-url input)
        (remoto--parse-git-remote input)
        (remoto--parse-repo-shorthand input)
        (user-error "Remoto: cannot parse input: %s" input))))

;;;###autoload
(defun remoto-refresh ()
  "Invalidate cached tree for the current repo, re-fetch on next access."
  (interactive)
  (let* ((dir (or dired-directory default-directory))
         (parsed (remoto--parse-path dir)))
    (if parsed
        (let* ((resolved (remoto--resolve-ref parsed))
               (key (remoto--repo-key resolved)))
          (remhash key remoto--tree-cache)
          (remhash (format "%s/%s" (remoto-path-owner resolved)
                           (remoto-path-repo resolved))
                   remoto--branches-cache)
          (message "Remoto: cache cleared for %s" key)
          (when (derived-mode-p 'dired-mode)
            (revert-buffer)))
      (user-error "Remoto: not in a remoto buffer"))))

;;;###autoload
(defun remoto-copy-github-url ()
  "Copy the GitHub web URL for the current file/line to kill ring."
  (interactive)
  (let* ((file (or buffer-file-name
                   (when (derived-mode-p 'dired-mode)
                     (dired-get-filename nil t))
                   dired-directory
                   default-directory))
         (parsed (remoto--parse-path file)))
    (unless parsed
      (user-error "Remoto: not in a remoto buffer"))
    (let* ((resolved (remoto--resolve-ref parsed))
           (owner (remoto-path-owner resolved))
           (repo (remoto-path-repo resolved))
           (ref (remoto-path-ref resolved))
           (path (remoto--relative-path (remoto-path-path resolved)))
           (entry (remoto--tree-entry resolved))
           (type (if (and entry (equal "tree" (alist-get 'type entry)))
                     "tree" "blob"))
           (line-suffix (when (and (equal type "blob")
                                   (not (derived-mode-p 'dired-mode)))
                          (if (use-region-p)
                              (format "#L%d-L%d"
                                      (line-number-at-pos (region-beginning))
                                      (line-number-at-pos (region-end)))
                            (format "#L%d" (line-number-at-pos)))))
           (url (format "https://github.com/%s/%s/%s/%s/%s%s"
                        owner repo type ref path
                        (or line-suffix ""))))
      (kill-new url)
      (message "Copied: %s" url))))

;;;; Repository search

(defvar remoto--search-cache (make-hash-table :test 'equal)
  "Cache: query string -> (TIMESTAMP . RESULTS).
Entries expire after `remoto-search-cache-ttl' seconds.")

(defcustom remoto-search-cache-ttl 300
  "Seconds before search cache entries expire.
Set to 0 to disable caching."
  :type 'integer
  :group 'remoto)

(defun remoto--search-cache-get (key)
  "Return cached results for KEY if not expired.
Returns two values via list: (HIT-P RESULTS).  HIT-P is non-nil
when KEY was found and not expired.  RESULTS may be nil for
queries that returned zero results."
  (if-let* ((entry (gethash key remoto--search-cache))
            (timestamp (car entry))
            (fresh-p (or (zerop remoto-search-cache-ttl)
                         (< (- (float-time) timestamp) remoto-search-cache-ttl))))
      (list t (cdr entry))
    (when entry (remhash key remoto--search-cache))
    '(nil nil)))

(defun remoto--search-cache-put (key results)
  "Store RESULTS for KEY with current timestamp."
  (puthash key (cons (float-time) results) remoto--search-cache)
  results)

(defun remoto--search-query (input)
  "Build a GitHub search query string from INPUT.
When INPUT contains a slash, searches within that owner's repos.
Otherwise searches by repository name."
  (if-let* ((slash-pos (string-search "/" input))
            (owner (substring input 0 slash-pos))
            (repo-part (substring input (1+ slash-pos))))
      (if (string-empty-p repo-part)
          (format "user:%s" owner)
        (format "%s in:name user:%s" repo-part owner))
    (format "%s in:name" input)))

(defun remoto--fetch-branches (owner repo)
  "Fetch branch names for OWNER/REPO, cached per `remoto-search-cache-ttl'."
  (let* ((key (format "%s/%s" owner repo))
         (entry (gethash key remoto--branches-cache))
         (now (float-time)))
    (if (and entry
             (or (zerop remoto-search-cache-ttl)
                 (< (- now (car entry)) remoto-search-cache-ttl)))
        (cdr entry)
      (condition-case nil
          (let* ((endpoint (format "repos/%s/%s/branches?per_page=100" owner repo))
                 (data (remoto--api endpoint))
                 (branches (mapcar (lambda (item) (alist-get 'name item)) data)))
            (puthash key (cons now branches) remoto--branches-cache)
            branches)
        (user-error nil)))))

(defvar remoto--tags-cache (make-hash-table :test 'equal)
  "Cache for repository tags.  key -> (TIMESTAMP . TAGS-LIST).")

(defun remoto--fetch-tags (owner repo)
  "Fetch tag names for OWNER/REPO, cached per `remoto-search-cache-ttl'."
  (let* ((key (format "%s/%s" owner repo))
         (entry (gethash key remoto--tags-cache))
         (now (float-time)))
    (if (and entry
             (or (zerop remoto-search-cache-ttl)
                 (< (- now (car entry)) remoto-search-cache-ttl)))
        (cdr entry)
      (condition-case nil
          (let* ((endpoint (format "repos/%s/%s/tags?per_page=100" owner repo))
                 (data (remoto--api endpoint))
                 (tags (mapcar (lambda (item) (alist-get 'name item)) data)))
            (puthash key (cons now tags) remoto--tags-cache)
            tags)
        (user-error nil)))))

(defvar remoto--issues-cache (make-hash-table :test 'equal)
  "Cache for issue listings.  key -> (TIMESTAMP . ISSUES-ALIST).")

(defun remoto--fetch-issues (owner repo)
  "Fetch open issues+PRs for OWNER/REPO, cached."
  (let* ((key (format "%s/%s" owner repo))
         (entry (gethash key remoto--issues-cache))
         (now (float-time)))
    (if (and entry
             (or (zerop remoto-search-cache-ttl)
                 (< (- now (car entry)) remoto-search-cache-ttl)))
        (cdr entry)
      (condition-case nil
          (let* ((endpoint (format "repos/%s/%s/issues?state=open&sort=updated&per_page=30"
                                   owner repo))
                 (data (remoto--api endpoint)))
            (puthash key (cons now data) remoto--issues-cache)
            data)
        (user-error nil)))))

(defun remoto--search-issues (owner repo query)
  "Search issues+PRs in OWNER/REPO matching QUERY."
  (condition-case nil
      (let* ((endpoint (format "search/issues?q=%s+repo:%s/%s&per_page=30"
                               (url-hexify-string query) owner repo))
             (data (remoto--api endpoint)))
        (alist-get 'items data))
    (user-error nil)))

(defun remoto--fetch-issue (owner repo number)
  "Fetch single issue NUMBER from OWNER/REPO."
  (condition-case nil
      (remoto--api (format "repos/%s/%s/issues/%s" owner repo number))
    (user-error nil)))

(defun remoto--fetch-issue-comments (owner repo number)
  "Fetch comments for issue NUMBER from OWNER/REPO.
Returns list of comment alists, or nil on error."
  (condition-case nil
      (remoto--api (format "repos/%s/%s/issues/%s/comments" owner repo number))
    (user-error nil)))

(defun remoto--fetch-user-orgs (_user)
  "Fetch organization memberships for the authenticated user.
Uses /user/orgs which includes private memberships."
  (condition-case nil
      (let ((data (remoto--api "user/orgs?per_page=100")))
        (mapcar (lambda (item) (alist-get 'login item)) data))
    (user-error nil)))



(defun remoto--search-users (prefix)
  "Search GitHub users/orgs matching PREFIX, cached with TTL.
Returns a list of login strings. Requires at least 2 characters.
Uses client-side narrowing when a parent query is cached."
  (when (<= 2 (length prefix))
    (let ((prefix-down (downcase prefix)))
      ;; Check exact cache hit
      (pcase-let ((`(,hit ,results) (remoto--search-cache-get
                                      (concat "\0users:" prefix-down))))
        (if hit results
          ;; Try narrowing from a shorter cached query
          (let ((narrowed
                 (cl-loop for key being the hash-keys of remoto--users-cache
                          for entry = (gethash key remoto--users-cache)
                          when (and entry
                                    (string-prefix-p key prefix-down)
                                    (< (length key) (length prefix-down))
                                    (or (zerop remoto-search-cache-ttl)
                                        (< (- (float-time) (car entry))
                                           remoto-search-cache-ttl)))
                          return (seq-filter
                                  (lambda (u)
                                    (string-prefix-p prefix-down (downcase u)))
                                  (cdr entry)))))
            (if narrowed
                (progn
                  (puthash (concat "\0users:" prefix-down)
                           (cons (float-time) narrowed)
                           remoto--search-cache)
                  narrowed)
              ;; Fetch from API
              (condition-case nil
                  (let* ((endpoint (format "search/users?q=%s&per_page=30"
                                           (url-hexify-string prefix)))
                         (items (alist-get 'items (remoto--api endpoint)))
                         (results (mapcar (lambda (item) (alist-get 'login item))
                                          items)))
                    (puthash prefix-down (cons (float-time) results)
                             remoto--users-cache)
                    (puthash (concat "\0users:" prefix-down)
                             (cons (float-time) results)
                             remoto--search-cache)
                    results)
                (user-error nil)))))))))

(defvar remoto--prefetch-timer nil
  "Idle timer for speculative repo pre-fetching.")

(defun remoto--prefetch-owner-repos (owner)
  "Pre-fetch recent repos for OWNER on idle, warming the cache.
Cancels any previously scheduled pre-fetch."
  (when remoto--prefetch-timer
    (cancel-timer remoto--prefetch-timer))
  (setq remoto--prefetch-timer
        (run-with-idle-timer
         0.05 nil
         (lambda ()
           (setq remoto--prefetch-timer nil)
           ;; Wrap in while-no-input so typing interrupts the
           ;; synchronous HTTP call instead of blocking Emacs.
           (while-no-input
             (remoto--recent-owner-repos owner))))))

(defun remoto--recent-owner-repos (owner)
  "Fetch recently-updated repos for OWNER, cached with TTL.
Returns up to 30 repo name strings (propertized with description),
sorted by last push."
  (let* ((cache-key (format "\0repos-recent:%s" (downcase owner))))
    (pcase-let ((`(,hit ,results) (remoto--search-cache-get cache-key)))
      (if hit results
        (condition-case nil
            (let* ((q (url-hexify-string (format "user:%s" owner)))
                   (endpoint (format "search/repositories?q=%s&sort=updated&per_page=30" q))
                   (items (alist-get 'items (remoto--api endpoint)))
                   (repos (mapcar (lambda (item)
                                    (propertize (alist-get 'name item)
                                                'remoto-repo-desc
                                                (or (alist-get 'description item) "")))
                                  items)))
              (remoto--search-cache-put cache-key repos))
          (user-error nil))))))

(defun remoto--search-owner-repos (owner query)
  "Search OWNER's repos matching QUERY via GitHub search API.
Returns repo names. Requires at least 2 characters in QUERY.
Uses client-side narrowing when a parent query is cached."
  (when (<= 2 (length query))
    (let* ((owner-down (downcase owner))
           (query-down (downcase query))
           (cache-key (format "\0repos:%s/%s" owner-down query-down)))
      (pcase-let ((`(,hit ,results) (remoto--search-cache-get cache-key)))
        (if hit results
          ;; Try narrowing from a shorter cached query for same owner
          (let ((narrowed
                 (cl-loop for len from (1- (length query-down)) downto 2
                          for prefix = (substring query-down 0 len)
                          for pk = (format "\0repos:%s/%s" owner-down prefix)
                          for entry = (gethash pk remoto--search-cache)
                          when (and entry
                                    (or (zerop remoto-search-cache-ttl)
                                        (< (- (float-time) (car entry))
                                           remoto-search-cache-ttl)))
                          return (seq-filter
                                  (lambda (r)
                                    (string-search query-down (downcase r)))
                                  (cdr entry)))))
            (if narrowed
                (remoto--search-cache-put cache-key narrowed)
              ;; Fetch from API
              (condition-case nil
                  (let* ((q (url-hexify-string
                            (format "%s in:name user:%s" query owner)))
                         (endpoint (format "search/repositories?q=%s&per_page=100" q))
                         (items (alist-get 'items (remoto--api endpoint)))
                         (repos (mapcar (lambda (item)
                                          (propertize (alist-get 'name item)
                                                      'remoto-repo-desc
                                                      (or (alist-get 'description item) "")))
                                        items)))
                    (remoto--search-cache-put cache-key repos))
                (user-error nil)))))))))

(defun remoto--get-authenticated-user ()
  "Return the GitHub login of the authenticated user, or nil.
Caches the result for the session.  Returns nil when auth has
failed or the API call errors."
  (or remoto--authenticated-user
      (unless remoto--auth-failed
        (condition-case nil
            (when-let* ((data (remoto--api "user"))
                        (login (alist-get 'login data)))
              (setq remoto--authenticated-user login))
          (user-error nil)))))

(defun remoto--complete-branches (query at-pos)
  "Complete branch names for QUERY with @ at AT-POS.
Returns owner/repo@branch candidates matching the prefix after @."
  (let* ((repo-part (substring query 0 at-pos))
         (branch-prefix (substring query (1+ at-pos))))
    (when (string-match
           (rx bos (group (+ (not "/"))) "/" (group (+ nonl)) eos)
           repo-part)
      (when-let* ((branches (remoto--fetch-branches
                             (match-string 1 repo-part)
                             (match-string 2 repo-part))))
        (thread-last branches
          (seq-filter (lambda (b)
                        (or (string-empty-p branch-prefix)
                            (string-prefix-p branch-prefix b))))
          (mapcar (lambda (b) (format "%s@%s" repo-part b))))))))

(defun remoto--search-repos-fetch (query)
  "Fetch or retrieve cached repo search results for QUERY.
Returns a list of owner/repo strings, or nil."
  (when (<= 3 (length query))
    (if-let* ((cached (remoto--search-cache-get query))
              ((car cached)))
        (cadr cached)
      (if-let* ((parent (remoto--search-repos-from-parent query)))
          (cdr parent)
        (condition-case nil
            (let* ((endpoint (format "search/repositories?q=%s&per_page=30"
                                     (url-hexify-string
                                      (remoto--search-query query))))
                   (items (alist-get 'items (remoto--api endpoint)))
                   (results (mapcar (lambda (item) (alist-get 'full_name item))
                                    items)))
              (remoto--search-cache-put query results))
          (user-error nil))))))

(defun remoto--search-repos-from-parent (query)
  "Try narrowing a cached parent query to answer QUERY.
Returns (HIT-P . FILTERED-RESULTS) when a parent cache entry
exists, nil otherwise."
  (when-let* ((slash-pos (string-search "/" query))
              (parent-results
               (cl-loop for key being the hash-keys of remoto--search-cache
                        for entry = (remoto--search-cache-get key)
                        when (and (car entry)
                                  (string-prefix-p key query)
                                  (<= slash-pos (length key))
                                  (< (length key) (length query)))
                        return (cadr entry))))
    (cons t (seq-filter (lambda (name) (string-prefix-p query name))
                        parent-results))))

(defun remoto--search-repos (query &optional callback)
  "Search GitHub repositories matching QUERY.
Returns a list of owner/repo strings.  Requires at least 3 characters.
When QUERY contains `@', completes branch names for the specified repo.

When CALLBACK is non-nil, passes results to it instead of returning
them directly.  This supports consult's async dynamic collection
protocol."
  (let* ((at-pos (string-search "@" query))
         (results (if at-pos
                      (remoto--complete-branches query at-pos)
                    (remoto--search-repos-fetch query))))
    (if callback
        (funcall callback results)
      results)))

(defvar remoto--browse-history nil
  "Minibuffer history for `remoto-browse'.")

(defun remoto--repo-completion-table (string pred action)
  "Programmed completion table for GitHub repos and branches.
STRING is the current minibuffer input, PRED a filter predicate,
ACTION the completion action dispatched by `completing-read'."
  (if (eq action 'metadata)
      '(metadata (category . remoto-repo))
    (complete-with-action action (remoto--search-repos string) string pred)))

(defun remoto--read-repo ()
  "Read a GitHub repo from the minibuffer with search completion.
Type 3+ characters to trigger GitHub search.  Tab completes.
Append @ to complete branch names (e.g. owner/repo@<Tab>).
URLs and owner/repo shorthand can be typed directly."
  (completing-read "GitHub repo: "
                   #'remoto--repo-completion-table
                   nil nil nil
                   'remoto--browse-history))

;;;###autoload
(defun remoto-browse (input)
  "Browse a GitHub repository without cloning.
INPUT can be any GitHub URL, git remote URL, or owner/repo shorthand.
With interactive use, provides search completion - type 3+ characters
to search GitHub repositories."
  (interactive (list (remoto--read-repo)))
  (let* ((parsed (remoto--parse-input input))
         (resolved (remoto--resolve-ref parsed))
         (canonical (remoto--canonical-path resolved)))
    (if (equal "tree"
               (alist-get 'type (remoto--tree-entry resolved)))
        (dired canonical)
      (find-file canonical))))

;;;; GitHub input detection

(defun remoto--github-input-p (input)
  "Return non-nil if INPUT can look like a GitHub URL or shorthand."
  (and (stringp input)
       (string-match-p
        (rx bos
            (or "https://github.com/"
                "git@github.com:"
                (or "github.com/" "/github.com/")))
        input)))

(defun remoto--parse-partial-canonical (input)
  "Parse partial canonical INPUT like /github:OWNER/REPO[@REF].
Returns a `remoto-path' struct or nil."
  (cond
   ((string-match (rx bos "/github:"
                      (group (+ (not (any "/:@"))))
                      "/"
                      (group (+ (not (any "/:@"))))
                      (? "@" (group (+ (not (any "/:")))))
                      eos)
                  input)
    (remoto-path-create
     :owner (match-string 1 input)
     :repo (match-string 2 input)
     :ref (match-string 3 input)
     :path "/"))
   ;; Also handle with trailing /
   ((string-match (rx bos "/github:"
                      (group (+ (not (any "/:@"))))
                      "/"
                      (group (+ (not (any "/:@"))))
                      (? "@" (group (+ (not (any "/:")))))
                      "/" eos)
                  input)
    (remoto-path-create
     :owner (match-string 1 input)
     :repo (match-string 2 input)
     :ref (match-string 3 input)
     :path "/"))))

(defun remoto--maybe-rewrite (input)
  "If INPUT is a GitHub URL/shorthand, return canonical remoto path.
Also handles partial canonical paths like /github:OWNER/REPO.
Otherwise return INPUT unchanged."
  (cond
   ;; Already a full canonical path
   ((remoto--parse-path input) input)
   ;; Files-default short form: /github:owner/repo/ or /github:owner/repo/path
   ((and (string-prefix-p "/github:" input)
         (not (remoto--parse-path input))
         (string-match (rx bos "/github:"
                           (group (+ (not (any "/:@#"))))
                           "/"
                           (group (+ (not (any "/:@#"))))
                           "/" (group (* anything)) eos)
                       input))
    (let* ((owner (match-string 1 input))
           (repo (match-string 2 input))
           (subpath (match-string 3 input))
           (repo-id (format "%s/%s" owner repo))
           (branch (or (gethash repo-id remoto--default-branch-cache)
                       (let ((b (remoto--default-branch owner repo)))
                         (when b (puthash repo-id b remoto--default-branch-cache))
                         b))))
      (if branch
          (format "/github:%s/%s@%s:/%s" owner repo branch subpath)
        input)))
   ;; Partial canonical path: /github:owner/repo or /github:owner/repo@ref
   ((and (string-prefix-p "/github:" input)
         (remoto--parse-partial-canonical input))
    (let* ((parsed (remoto--parse-partial-canonical input))
           (resolved (remoto--resolve-ref parsed)))
      (remoto--canonical-path resolved)))
   ;; GitHub URL or shorthand
   ((remoto--github-input-p input)
    (let* ((clean (replace-regexp-in-string "\\`/?" "" input))
           (clean (cond
                   ((string-match-p "\\`github\\.com/" clean)
                    (concat "https://" clean))
                   (t clean)))
           (parsed (condition-case nil
                       (remoto--parse-input clean)
                     (error nil))))
      (cond
       (parsed
        (let ((resolved (remoto--resolve-ref parsed)))
          (remoto--canonical-path resolved)))
       (t input))))
   (t input)))

(defun remoto--dired-around-a (orig-fn dir-or-list &rest args)
  "Rewrite GitHub URLs to canonical remoto paths for Dired.
Call ORIG-FN with DIR-OR-LIST and ARGS after any rewrite."
  (if-let* ((dir (if (consp dir-or-list) (car dir-or-list) dir-or-list))
            (_ (remoto--github-input-p dir)))
      (let ((canonical (remoto--maybe-rewrite dir)))
        (apply orig-fn
               (if (consp dir-or-list)
                   (cons canonical (cdr dir-or-list))
                 canonical)
               args))
    (apply orig-fn dir-or-list args)))

(defun remoto--find-file-around-a (orig-fn filename &rest args)
  "Rewrite GitHub URLs to canonical remoto paths for `find-file'.
Intercepts #NUM patterns to display issues instead of file operations.
Call ORIG-FN with FILENAME and ARGS after any rewrite."
  (let ((rewritten (remoto--maybe-rewrite filename)))
    (if (string-match (rx "#" (group (+ digit)) eos) rewritten)
        (progn
          (remoto--require-issue)
          (remoto-issue-display
           (match-string 1 rewritten)
           (substring rewritten 0 (match-beginning 0))))
      (apply orig-fn rewritten args))))

(unless (advice-member-p #'remoto--dired-around-a 'dired)
  (advice-add 'dired :around #'remoto--dired-around-a))
(unless (advice-member-p #'remoto--find-file-around-a 'find-file-noselect)
  (advice-add 'find-file-noselect :around #'remoto--find-file-around-a))

;;;; Eager auth warm-up

(defun remoto--warm-auth ()
  "Pre-fetch the authenticated GitHub user in the background.
Runs on an idle timer so GPG decryption happens before the user
types anything, avoiding timeout-induced fallback to public-only
repo listings."
  (unless (or remoto--authenticated-user remoto--auth-failed)
    (remoto--get-authenticated-user)))

(run-with-idle-timer 2 nil #'remoto--warm-auth)

;;;; Handler registration

(defconst remoto--handler-regexp
  (rx bos "/github:")
  "Regexp matching remoto file paths.")

(unless (equal (cdr (assoc remoto--handler-regexp file-name-handler-alist))
               #'remoto-file-name-handler)
  (push (cons remoto--handler-regexp #'remoto-file-name-handler)
        file-name-handler-alist))

(defun remoto--completion-metadata (directory)
  "Return completion metadata alist for DIRECTORY, or nil.
Provides group-function and affixation-function for @ and # modes."
  (cond
   ;; Issues mode: /github:OWNER/REPO#
   ((string-match (rx (+ (not (any "/:@#"))) "/" (+ (not (any "/:@#"))) "#" eos)
                  directory)
    (let ((group-fn (lambda (candidate transform)
                      (if transform candidate
                        (if (get-text-property 0 'remoto-issue-pr candidate)
                            "Pull Request"
                          "Issue"))))
          (affix-fn (lambda (candidates)
                      (mapcar (lambda (c)
                                (let ((title (or (get-text-property 0 'remoto-issue-title c) ""))
                                      (state (or (get-text-property 0 'remoto-issue-state c) ""))
                                      (is-pr (get-text-property 0 'remoto-issue-pr c)))
                                  (list c
                                        (if is-pr "PR " "   ")
                                        (format " %s [%s]" title state))))
                              candidates))))
      `((group-function . ,group-fn)
        (affixation-function . ,affix-fn))))
   ;; Branches/tags mode: /github:OWNER/REPO@
   ((string-match (rx (+ (not (any "/:@#"))) "/" (+ (not (any "/:@#"))) "@" eos)
                  directory)
    (let ((group-fn (lambda (candidate transform)
                      (if transform candidate
                        (if (equal "tag" (get-text-property 0 'remoto-ref-type candidate))
                            "Tag"
                          "Branch")))))
      `((group-function . ,group-fn))))
   ;; Owner mode: /github:OWNER/ - repo descriptions
   ((string-match (rx "/github:" (+ (not (any "/:@#"))) "/" eos) directory)
    (let ((affix-fn (lambda (candidates)
                      (mapcar (lambda (c)
                                (let ((desc (or (get-text-property 0 'remoto-repo-desc c) "")))
                                  (list c "" (if (string-empty-p desc) ""
                                               (concat "  " desc)))))
                              candidates))))
      `((affixation-function . ,affix-fn))))))

(defun remoto--read-file-name-internal-a (orig string pred action)
  "Fix completion for /github: paths inside `read-file-name'.
Re-attaches the raw prefix that `substitute-in-file-name' strips,
so completion frameworks (Vertico, etc.) can match candidates
against the actual minibuffer content.
Injects completion metadata (grouping, affixation) for @ and # modes.
Args: ORIG, STRING, PRED, ACTION."
  (let ((effective (substitute-in-file-name string)))
    (cond
     ;; Non-github path - pass through.
     ((not (string-prefix-p "/github:" effective))
      (funcall orig string pred action))
     ;; Metadata action - inject our metadata for @ and # modes.
     ((eq action 'metadata)
      (let* ((dir (or (file-name-directory effective) ""))
             (extra (remoto--completion-metadata dir))
             (base (funcall orig string pred action))
             (base-alist (and (consp base) (eq (car base) 'metadata) (cdr base))))
        (if extra
            (cons 'metadata (append extra base-alist))
          (or base (cons 'metadata nil)))))
     ;; Non-standard action (boundaries, etc.) - pass through.
     ((not (memq action '(nil t lambda)))
      (funcall orig string pred action))
     ;; Standard completion action - fixup prefixes.
     (t
      (let* ((gh-pos (string-search "/github:" string))
             (raw-prefix (if (and gh-pos (< 0 gh-pos))
                             (substring string 0 gh-pos)
                           ""))
             (result (funcall orig effective pred action)))
        (pcase action
          ('t
           (let ((full-prefix (concat raw-prefix
                                      (or (file-name-directory effective) ""))))
             (mapcar (lambda (c) (concat full-prefix c)) result)))
          ('nil
           (cond
            ((eq result t) t)
            ((stringp result) (concat raw-prefix result))
            (t result)))
          ('lambda result)))))))

(advice-add 'read-file-name-internal :around
            #'remoto--read-file-name-internal-a)

;;;; Issue display (see remoto-issue.el for full implementation)

(declare-function remoto-issue-display "remoto-issue" (number repo-path))

(defun remoto--require-issue ()
  "Load remoto-issue if not already loaded."
  (require 'remoto-issue nil t))

;;;; Unload

(defun remoto-unload-function ()
  "Remove handler and advice installed by remoto."
  (setq file-name-handler-alist
        (assoc-delete-all remoto--handler-regexp file-name-handler-alist))
  (advice-remove 'dired #'remoto--dired-around-a)
  (advice-remove 'find-file-noselect #'remoto--find-file-around-a)
  (advice-remove 'read-file-name-internal #'remoto--read-file-name-internal-a)
  (clrhash remoto--tree-cache)
  (clrhash remoto--default-branch-cache)
  (clrhash remoto--branches-cache)
  (clrhash remoto--users-cache)
  (clrhash remoto--content-cache)
  (clrhash remoto--search-cache)
  (clrhash remoto--tags-cache)
  (clrhash remoto--issues-cache)
  nil)

(provide 'remoto)
;;; remoto.el ends here
