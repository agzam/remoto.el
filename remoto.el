;;; remoto.el --- Browse GitHub repos without cloning -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2025 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Created: April 24, 2026
;; Version: 0.1.0
;; Keywords: tools vc
;; Homepage: https://github.com/agzam/remoto.el
;; Package-Requires: ((emacs "29.1"))
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.

;;; Commentary:

;; remoto.el lets you browse any GitHub repository in Emacs as if it were
;; cloned locally - without cloning it.  It registers a virtual filesystem
;; via `file-name-handler-alist' that translates Emacs file operations into
;; GitHub API calls via the `gh' CLI.
;;
;; Usage:
;;   M-x remoto-browse RET https://github.com/torvalds/linux RET
;;
;; Supports pasting any GitHub URL, git remote URL, or owner/repo shorthand.

;;; Code:

(require 'json)
(require 'cl-lib)

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

;;;; gh CLI wrapper

(defvar remoto--gh-executable (executable-find "gh")
  "Path to the gh CLI executable.")

(defun remoto--api (endpoint)
  "Call GitHub API ENDPOINT via gh CLI, return parsed JSON.
Signals an error on failure."
  (unless remoto--gh-executable
    (user-error "remoto: `gh' CLI not found; install from https://cli.github.com"))
  (with-temp-buffer
    (let ((exit-code
           (call-process remoto--gh-executable nil t nil
                         "api" endpoint)))
      (if (zerop exit-code)
          (progn
            (goto-char (point-min))
            (json-parse-buffer :object-type 'alist :array-type 'list))
        (let ((output (string-trim (buffer-string))))
          (cond
           ((string-match-p "HTTP 404" output)
            (user-error "remoto: repository not found: %s" endpoint))
           ((string-match-p "HTTP 403" output)
            (user-error "remoto: access denied (rate limit or permissions): %s" endpoint))
           ((string-match-p "authentication" output)
            (user-error "remoto: gh not authenticated; run `gh auth login'"))
           (t
            (user-error "remoto: gh api error (exit %d): %s" exit-code output))))))))

(defun remoto--default-branch (owner repo)
  "Fetch the default branch for OWNER/REPO."
  (let ((data (remoto--api (format "repos/%s/%s" owner repo))))
    (alist-get 'default_branch data)))

;;;; Tree cache

(defvar remoto--tree-cache (make-hash-table :test 'equal)
  "Cache: \"owner/repo@ref\" -> hash table of path -> entry plist.")

(defvar remoto--default-branch-cache (make-hash-table :test 'equal)
  "Cache: \"owner/repo\" -> default branch name.")

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
Returns a hash table of path -> plist with keys :type :size :sha :mode."
  (let* ((endpoint (format "repos/%s/%s/git/trees/%s?recursive=1" owner repo ref))
         (data (remoto--api endpoint))
         (entries (alist-get 'tree data))
         (truncated (alist-get 'truncated data))
         (table (make-hash-table :test 'equal :size (length entries))))
    (when (eq truncated t)
      (message "remoto: tree truncated for %s/%s@%s, large repo support limited"
               owner repo ref))
    ;; Root entry
    (puthash "" (list :type "tree" :size 0 :sha "" :mode "040000") table)
    (puthash "/" (list :type "tree" :size 0 :sha "" :mode "040000") table)
    ;; All entries from API
    (dolist (entry entries)
      (let ((path (alist-get 'path entry))
            (plist (list :type (alist-get 'type entry)
                         :size (or (alist-get 'size entry) 0)
                         :sha  (alist-get 'sha entry)
                         :mode (alist-get 'mode entry))))
        (puthash path plist table)
        ;; Synthesize intermediate directories
        (let ((parts (split-string path "/" t)))
          (when (< 1 (length parts))
            (cl-loop for i from 1 below (length parts)
                     for dir = (mapconcat #'identity (seq-take parts i) "/")
                     unless (gethash dir table)
                     do (puthash dir
                                 (list :type "tree" :size 0 :sha "" :mode "040000")
                                 table))))))
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

(defun remoto--tree-entry (parsed)
  "Look up the tree entry for PARSED path.  Returns plist or nil."
  (let* ((tree (remoto--ensure-tree parsed))
         (path (remoto-path-path parsed))
         ;; Normalize: strip leading slash for cache lookup
         (path (if (string-prefix-p "/" path) (substring path 1) path))
         ;; Collapse double slashes
         (path (replace-regexp-in-string "/+" "/" path))
         ;; Strip trailing slash
         (path (if (and (not (string-empty-p path))
                        (string-suffix-p "/" path))
                   (substring path 0 -1)
                 path)))
    (gethash path tree)))

(defun remoto--tree-children (parsed)
  "List direct children of directory at PARSED path.
Returns list of (NAME . PLIST) for each child."
  (let* ((tree (remoto--ensure-tree parsed))
         (dir-path (remoto-path-path parsed))
         ;; Normalize
         (dir-path (if (string-prefix-p "/" dir-path)
                       (substring dir-path 1) dir-path))
         (dir-path (if (and (not (string-empty-p dir-path))
                            (string-suffix-p "/" dir-path))
                       (substring dir-path 0 -1)
                     dir-path))
         (prefix (if (string-empty-p dir-path) "" (concat dir-path "/")))
         (prefix-len (length prefix))
         (result nil))
    (maphash
     (lambda (path plist)
       (when (and (string-prefix-p prefix path)
                  (not (equal path dir-path))
                  ;; Direct child: no more slashes after prefix
                  (not (string-search "/" (substring path prefix-len))))
         (let ((name (substring path prefix-len)))
           (unless (string-empty-p name)
             (push (cons name plist) result)))))
     tree)
    (sort result (lambda (a b) (string< (car a) (car b))))))

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
Dispatches to remoto--handle-OPERATION or falls through to defaults."
  (let ((handler (intern (format "remoto--handle-%s" operation))))
    (if (fboundp handler)
        (apply handler args)
      ;; Fall through to default handler
      (let ((inhibit-file-name-handlers
             (cons #'remoto-file-name-handler
                   (and (eq inhibit-file-name-operation operation)
                        inhibit-file-name-handlers)))
            (inhibit-file-name-operation operation))
        (apply operation args)))))

;;;; Read operations

(defun remoto--handle-file-exists-p (filename)
  "Return t if FILENAME exists in the remote repo."
  (let ((parsed (remoto--parse-path filename)))
    (and parsed (not (null (remoto--tree-entry parsed))))))

(defun remoto--handle-file-directory-p (filename)
  "Return t if FILENAME is a directory in the remote repo."
  (let ((parsed (remoto--parse-path filename)))
    (when parsed
      (let ((entry (remoto--tree-entry parsed)))
        (and entry (equal "tree" (plist-get entry :type)))))))

(defun remoto--handle-file-regular-p (filename)
  "Return t if FILENAME is a regular file in the remote repo."
  (let ((parsed (remoto--parse-path filename)))
    (when parsed
      (let ((entry (remoto--tree-entry parsed)))
        (and entry (equal "blob" (plist-get entry :type)))))))

(defun remoto--handle-file-readable-p (filename)
  "Remote files are readable if they exist."
  (remoto--handle-file-exists-p filename))

(defun remoto--handle-file-writable-p (_filename)
  "Remote repos are never writable."
  nil)

(defun remoto--handle-file-attributes (filename &optional _id-format)
  "Return file attributes for FILENAME.
Synthesized from tree cache - timestamps are epoch 0."
  (let ((parsed (remoto--parse-path filename)))
    (when parsed
      (let ((entry (remoto--tree-entry parsed)))
        (when entry
          (let* ((is-dir (equal "tree" (plist-get entry :type)))
                 (size (or (plist-get entry :size) 0))
                 (mode-str (or (plist-get entry :mode) "100644"))
                 (mode (string-to-number mode-str 8))
                 ;; Use epoch 0 for all timestamps
                 (time '(0 0 0 0)))
            ;; Return vector matching `file-attributes' format:
            ;; (type links uid gid atime mtime ctime size mode
            ;;  gid-change inode device)
            (list (if is-dir t nil)    ; type: t=dir, nil=file
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
                  0)))))))             ; device

(defun remoto--handle-directory-files (directory &optional full match nosort count)
  "List files in remote DIRECTORY.
FULL, MATCH, NOSORT, COUNT as per `directory-files'."
  (let ((parsed (remoto--parse-path directory)))
    (when parsed
      (let* ((children (remoto--tree-children parsed))
             (names (mapcar #'car children))
             (names (append '("." "..") names))
             (names (if match
                        (seq-filter (lambda (n) (string-match-p match n))
                                    names)
                      names))
             (names (if nosort names (sort names #'string<)))
             (names (if count (seq-take names count) names)))
        (if full
            (let ((prefix (remoto--file-name-prefix directory))
                  (dir-path (remoto-path-path parsed)))
              (mapcar (lambda (n)
                        (concat prefix
                                (remoto--normalize-path
                                 (concat dir-path "/" n))))
                      names))
          names)))))

(defun remoto--handle-directory-files-and-attributes
    (directory &optional full match nosort id-format)
  "Like `directory-files-and-attributes' for remote DIRECTORY."
  (let ((files (remoto--handle-directory-files directory full match nosort)))
    (mapcar (lambda (f)
              (cons f (remoto--handle-file-attributes
                       (if full f
                         (let ((prefix (remoto--file-name-prefix directory))
                               (parsed (remoto--parse-path directory)))
                           (concat prefix
                                   (remoto--normalize-path
                                    (concat (remoto-path-path parsed) "/" f)))))
                       id-format)))
            files)))

(defun remoto--handle-file-name-all-completions (file directory)
  "Return completions for FILE in remote DIRECTORY."
  (let ((parsed (remoto--parse-path directory)))
    (when parsed
      (let* ((children (remoto--tree-children parsed))
             (names (mapcar (lambda (c)
                              (if (equal "tree" (plist-get (cdr c) :type))
                                  (concat (car c) "/")
                                (car c)))
                            children)))
        (seq-filter (lambda (n) (string-prefix-p file n)) names)))))

(defun remoto--handle-file-name-completion (file directory &optional predicate)
  "Complete FILE in remote DIRECTORY."
  (let ((completions (remoto--handle-file-name-all-completions file directory)))
    (cond
     ((null completions) nil)
     ((null (cdr completions)) (car completions))
     (t (try-completion file completions predicate)))))

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
      (let* ((prefix (remoto--file-name-prefix dir))
             (parsed (remoto--parse-path dir))
             (dir-path (remoto-path-path parsed))
             (combined (concat dir-path "/" name)))
        (concat prefix (remoto--normalize-path combined))))
     ;; Not our path, delegate
     (t (expand-file-name name dir)))))

(defun remoto--handle-file-truename (filename &optional _counter _prev-dirs)
  "Return FILENAME as-is - no symlink resolution for remote repos."
  filename)

(defun remoto--handle-file-remote-p (filename &optional identification _connected)
  "Return remote identification for FILENAME."
  (when (remoto--parse-path filename)
    (let ((prefix (remoto--file-name-prefix filename)))
      (pcase identification
        ('method "github")
        ('host (let ((parsed (remoto--parse-path filename)))
                 (format "%s/%s" (remoto-path-owner parsed)
                         (remoto-path-repo parsed))))
        (_ prefix)))))

(defun remoto--handle-file-name-directory (filename)
  "Return directory part of remote FILENAME."
  (let ((parsed (remoto--parse-path filename)))
    (when parsed
      (let* ((prefix (remoto--file-name-prefix filename))
             (path (remoto-path-path parsed))
             (dir (if (string-suffix-p "/" path)
                      path
                    (file-name-directory path))))
        (concat prefix (or dir "/"))))))

(defun remoto--handle-file-name-nondirectory (filename)
  "Return non-directory part of remote FILENAME."
  (let ((parsed (remoto--parse-path filename)))
    (if parsed
        (let ((path (remoto-path-path parsed)))
          (file-name-nondirectory (directory-file-name path)))
      (file-name-nondirectory filename))))

;;;; File content fetching

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
  "Fetch a git blob by SHA from OWNER/REPO.  Returns decoded content."
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
      (error "remoto: cannot parse path: %s" filename))
    (let* ((resolved (remoto--resolve-ref parsed))
           (path (remoto-path-path resolved))
           (path (if (string-prefix-p "/" path) (substring path 1) path))
           (content (remoto--fetch-file-content
                     (remoto-path-owner resolved)
                     (remoto-path-repo resolved)
                     path
                     (remoto-path-ref resolved))))
      (when replace
        (erase-buffer))
      (let* ((text (if (and beg end)
                       (substring content (1- beg) (1- end))
                     content))
             (len (length text)))
        (insert text)
        (when visit
          (setq buffer-file-name filename)
          (setq buffer-read-only t)
          (set-buffer-modified-p nil)
          (set-visited-file-modtime 0))
        (list filename len)))))

;;;; Dired integration

(defun remoto--mode-to-string (mode-str is-dir)
  "Convert git MODE-STR to ls-style permission string."
  (cond
   (is-dir              "drwxr-xr-x")
   ((equal mode-str "100755") "-rwxr-xr-x")
   ((equal mode-str "120000") "lrwxrwxrwx")
   (t                   "-rw-r--r--")))

(defun remoto--format-dired-entry (name plist)
  "Format a single dired line for NAME with PLIST attributes.
No leading spaces - dired and dired-subtree add their own."
  (let* ((is-dir (equal "tree" (plist-get plist :type)))
         (size (or (plist-get plist :size) 0))
         (mode (or (plist-get plist :mode) "100644"))
         (perms (remoto--mode-to-string mode is-dir)))
    (format "%s  1 github github %8d Jan  1  2000 %s\n"
            perms size name)))

(defun remoto--handle-insert-directory
    (filename _switches &optional _wildcard full-directory-p)
  "Insert dired-format listing for remote FILENAME."
  (let ((parsed (remoto--parse-path filename)))
    (when parsed
      (if (or full-directory-p
              (equal "tree"
                     (plist-get (remoto--tree-entry parsed) :type)))
          ;; Directory listing
          (let ((children (remoto--tree-children parsed)))
            (insert "total 0\n")
            (insert (remoto--format-dired-entry
                     "." (list :type "tree" :size 0 :mode "040000")))
            (insert (remoto--format-dired-entry
                     ".." (list :type "tree" :size 0 :mode "040000")))
            (dolist (child children)
              (insert (remoto--format-dired-entry (car child) (cdr child)))))
        ;; Single file
        (let ((entry (remoto--tree-entry parsed))
              (name (file-name-nondirectory
                     (directory-file-name (remoto-path-path parsed)))))
          (when entry
            (insert (remoto--format-dired-entry name entry))))))))

(defun remoto--handle-file-local-copy (filename)
  "Download remote FILENAME to a temp file, return temp path."
  (let ((parsed (remoto--parse-path filename)))
    (when parsed
      (let* ((resolved (remoto--resolve-ref parsed))
             (path (remoto-path-path resolved))
             (path (if (string-prefix-p "/" path) (substring path 1) path))
             (ext (file-name-extension path t))
             (temp (make-temp-file "remoto-" nil ext))
             (content (remoto--fetch-file-content
                       (remoto-path-owner resolved)
                       (remoto-path-repo resolved)
                       path
                       (remoto-path-ref resolved))))
        (with-temp-file temp
          (insert content))
        temp))))

(defun remoto--handle-make-nearby-temp-file (prefix &optional dir-flag suffix)
  "Create temp file in system temp dir, ignoring remote path."
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
      (substring directory 0 -1)
    directory))

(defun remoto--handle-file-name-case-insensitive-p (_filename)
  "GitHub repos are case-sensitive."
  nil)

(defun remoto--handle-vc-registered (_filename)
  "Remote files are not under local vc."
  nil)

(defun remoto--handle-make-directory (dir &optional _parents)
  "No-op for existing dirs, error otherwise."
  (unless (remoto--handle-file-directory-p dir)
    (user-error "remoto: repository is read-only")))

(defun remoto--handle-abbreviate-file-name (filename)
  "Return FILENAME as-is - no abbreviation for remote paths."
  filename)

(defun remoto--handle-unhandled-file-name-directory (_filename)
  "Return nil - no local equivalent for remote paths."
  nil)

;;;; Write operations (all read-only)

(defun remoto--read-only (&rest _args)
  "Signal that remote repos are read-only."
  (user-error "remoto: repository is read-only"))

(defalias 'remoto--handle-write-region #'remoto--read-only)
(defalias 'remoto--handle-delete-file #'remoto--read-only)
(defalias 'remoto--handle-delete-directory #'remoto--read-only)
(defalias 'remoto--handle-rename-file #'remoto--read-only)
(defalias 'remoto--handle-copy-file #'remoto--read-only)
(defalias 'remoto--handle-set-file-modes #'remoto--read-only)
(defalias 'remoto--handle-set-file-times #'remoto--read-only)

;;;; User input parsing

(defun remoto--parse-input (input)
  "Normalize user INPUT into a `remoto-path' struct.
Accepts: GitHub URLs, git remote URLs, or owner/repo shorthand."
  (let ((input (string-trim input)))
    (cond
     ;; https://github.com/owner/repo/tree/ref/path
     ;; https://github.com/owner/repo/blob/ref/path
     ((string-match
       (rx bos "https://github.com/"
           (group (+ (not "/")))        ; owner
           "/"
           (group (+ (not (any "/#"))))  ; repo
           (? "/" (or "tree" "blob") "/"
              (group (+ (not "/")))     ; ref
              (? "/" (group (+ (not "#"))))) ; path (strip fragment)
           (* nonl)                     ; ignore #fragment
           eos)
       input)
      (remoto-path-create
       :owner (match-string 1 input)
       :repo  (match-string 2 input)
       :ref   (match-string 3 input)
       :path  (let ((p (match-string 4 input)))
                (concat "/" (or p "")))))
     ;; https://github.com/owner/repo (no tree/blob)
     ((string-match
       (rx bos "https://github.com/"
           (group (+ (not "/")))        ; owner
           "/"
           (group (+ (not (any "/#. "))))  ; repo
           (* (any "/."))               ; optional trailing .git or /
           eos)
       input)
      (remoto-path-create
       :owner (match-string 1 input)
       :repo  (match-string 2 input)
       :ref   nil
       :path  "/"))
     ;; git@github.com:owner/repo.git
     ((string-match
       (rx bos "git@github.com:"
           (group (+ (not "/")))        ; owner
           "/"
           (group (+ (not (any "./ "))))  ; repo
           (? ".git")
           eos)
       input)
      (remoto-path-create
       :owner (match-string 1 input)
       :repo  (match-string 2 input)
       :ref   nil
       :path  "/"))
     ;; owner/repo@ref
     ((string-match
       (rx bos
           (group (+ (not (any "/@"))))  ; owner
           "/"
           (group (+ (not (any "/@"))))  ; repo
           (? "@" (group (+ nonl)))     ; ref
           eos)
       input)
      (remoto-path-create
       :owner (match-string 1 input)
       :repo  (match-string 2 input)
       :ref   (match-string 3 input)
       :path  "/"))
     (t (user-error "remoto: cannot parse input: %s" input)))))

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
          (message "remoto: cache cleared for %s" key)
          (when (derived-mode-p 'dired-mode)
            (revert-buffer)))
      (user-error "remoto: not in a remoto buffer"))))

;;;###autoload
(defun remoto-copy-github-url ()
  "Copy the GitHub web URL for the current file/line to kill ring."
  (interactive)
  (let* ((file (or buffer-file-name dired-directory default-directory))
         (parsed (remoto--parse-path file)))
    (unless parsed
      (user-error "remoto: not in a remoto buffer"))
    (let* ((resolved (remoto--resolve-ref parsed))
           (owner (remoto-path-owner resolved))
           (repo (remoto-path-repo resolved))
           (ref (remoto-path-ref resolved))
           (path (remoto-path-path resolved))
           (path (if (string-prefix-p "/" path) (substring path 1) path))
           (entry (remoto--tree-entry resolved))
           (type (if (and entry (equal "tree" (plist-get entry :type)))
                     "tree" "blob"))
           (line-suffix (when (and (equal type "blob")
                                   (not (derived-mode-p 'dired-mode))
                                   (< 0 (line-number-at-pos)))
                          (format "#L%d" (line-number-at-pos))))
           (url (format "https://github.com/%s/%s/%s/%s/%s%s"
                        owner repo type ref path
                        (or line-suffix ""))))
      (kill-new url)
      (message "Copied: %s" url))))

;;;###autoload
(defun remoto-browse (input)
  "Browse a GitHub repository without cloning.
INPUT can be any GitHub URL, git remote URL, or owner/repo shorthand."
  (interactive "sGitHub repo (URL or owner/repo): ")
  (let* ((parsed (remoto--parse-input input))
         (resolved (remoto--resolve-ref parsed))
         (canonical (remoto--canonical-path resolved)))
    (if (equal "tree"
               (plist-get (remoto--tree-entry resolved) :type))
        (dired canonical)
      (find-file canonical))))

;;;; GitHub input detection

(defun remoto--github-input-p (input)
  "Return non-nil if INPUT looks like a GitHub URL or shorthand."
  (and (stringp input)
       (or (string-match-p "\\`https://github\\.com/" input)
           (string-match-p "\\`git@github\\.com:" input)
           (string-match-p "\\`github\\.com/" input)
           (string-match-p "\\`/github\\.com/" input))))

(defun remoto--maybe-rewrite (input)
  "If INPUT is a GitHub URL/shorthand, return canonical remoto path.
Otherwise return INPUT unchanged."
  (if (remoto--github-input-p input)
      (let* ((clean (replace-regexp-in-string "\\`/?" "" input))
             (clean (if (string-match-p "\\`github\\.com/" clean)
                        (concat "https://" clean)
                      clean))
             (parsed (condition-case nil
                         (remoto--parse-input clean)
                       (error nil))))
        (if parsed
            (let* ((resolved (remoto--resolve-ref parsed)))
              (remoto--canonical-path resolved))
          input))
    input))

(defun remoto--dired-around-a (orig-fn dir-or-list &rest args)
  "Rewrite GitHub URLs to canonical remoto paths for dired."
  (let ((dir (if (consp dir-or-list) (car dir-or-list) dir-or-list)))
    (if (remoto--github-input-p dir)
        (let ((canonical (remoto--maybe-rewrite dir)))
          (apply orig-fn
                 (if (consp dir-or-list)
                     (cons canonical (cdr dir-or-list))
                   canonical)
                 args))
      (apply orig-fn dir-or-list args))))

(defun remoto--find-file-around-a (orig-fn filename &rest args)
  "Rewrite GitHub URLs to canonical remoto paths for find-file."
  (apply orig-fn (remoto--maybe-rewrite filename) args))

;;;###autoload
(progn
  (advice-add 'dired :around #'remoto--dired-around-a)
  (advice-add 'find-file :around #'remoto--find-file-around-a)
  (advice-add 'find-file-noselect :around #'remoto--find-file-around-a))

;;;; Handler registration

(defconst remoto--handler-regexp
  (rx bos "/github:")
  "Regexp matching remoto file paths.")

;;;###autoload
(progn
  (push (cons remoto--handler-regexp #'remoto-file-name-handler)
        file-name-handler-alist))

(provide 'remoto)
;;; remoto.el ends here
