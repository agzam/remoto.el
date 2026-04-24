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

(defun remoto--gh-executable ()
  "Return path to the gh CLI, or nil."
  (executable-find "gh"))

(defun remoto--api (endpoint)
  "Call GitHub API ENDPOINT via gh CLI, return parsed JSON.
Signals an error on failure."
  (let ((gh (remoto--gh-executable)))
    (unless gh
      (user-error "remoto: `gh' CLI not found; install from https://cli.github.com"))
    (with-temp-buffer
      (let ((exit-code
             (call-process gh nil t nil
                           "api" endpoint)))
        (if (zerop exit-code)
            (progn
              (goto-char (point-min))
              (json-parse-buffer :object-type 'alist :array-type 'list))
          (let ((output (string-trim (buffer-string))))
            (cond
             ((string-match-p "HTTP 404" output)
              (user-error "Remoto: repository not found: %s" endpoint))
             ((string-match-p "HTTP 403" output)
              (user-error "Remoto: access denied (rate limit or permissions): %s" endpoint))
             ((string-match-p "authentication" output)
              (user-error "Remoto: gh not authenticated; run `gh auth login'"))
             (t
              (user-error "Remoto: gh api error (exit %d): %s" exit-code output)))))))))

(defun remoto--default-branch (owner repo)
  "Fetch the default branch for OWNER/REPO."
  (let ((data (remoto--api (format "repos/%s/%s" owner repo))))
    (alist-get 'default_branch data)))

(defconst remoto--dir-entry
  '(:type "tree" :size 0 :sha "" :mode "040000")
  "Plist for synthesized directory entries (root, intermediates, `.', `..').")

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
    (puthash "" remoto--dir-entry table)
    (puthash "/" remoto--dir-entry table)
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
  "Look up the tree entry for PARSED path.  Return plist or nil."
  (let* ((tree (remoto--ensure-tree parsed))
         (key (remoto--tree-lookup-key (remoto-path-path parsed))))
    (gethash key tree)))

(defun remoto--tree-children (parsed)
  "List direct children of directory at PARSED path.
Returns list of (NAME . PLIST) for each child."
  (let* ((tree (remoto--ensure-tree parsed))
         (dir-path (remoto--tree-lookup-key (remoto-path-path parsed)))
         (prefix (if (string-empty-p dir-path) "" (concat dir-path "/")))
         (prefix-len (length prefix)))
    (sort
     (thread-last (hash-table-keys tree)
       (seq-filter (lambda (path)
                     (and (string-prefix-p prefix path)
                          (not (equal path dir-path))
                          ;; Direct child: no more slashes after prefix
                          (not (string-search "/" (substring path prefix-len))))))
       (mapcar (lambda (path)
                 (cons (substring path prefix-len)
                       (gethash path tree))))
       (seq-remove (lambda (child)
                     (string-empty-p (car child)))))
     (lambda (a b)
       (string< (car a) (car b))))))

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
  "Return t if FILENAME exists in the remote repo."
  (when-let* ((parsed (remoto--parse-path filename)))
    (not (null (remoto--tree-entry parsed)))))

(defun remoto--handle-file-directory-p (filename)
  "Return t if FILENAME is a directory in the remote repo."
  (when-let* ((parsed (remoto--parse-path filename))
              (entry (remoto--tree-entry parsed)))
    (equal "tree" (plist-get entry :type))))

(defun remoto--handle-file-regular-p (filename)
  "Return t if FILENAME is a regular file in the remote repo."
  (when-let* ((parsed (remoto--parse-path filename))
              (entry (remoto--tree-entry parsed)))
    (equal "blob" (plist-get entry :type))))

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
    (let* ((dir? (equal "tree" (plist-get entry :type)))
           (size (or (plist-get entry :size) 0))
           (mode-str (or (plist-get entry :mode) "100644"))
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

(defun remoto--handle-file-name-all-completions (file directory)
  "Return completions for FILE in remote DIRECTORY."
  (when-let* ((parsed (remoto--parse-path directory)))
    (thread-last (remoto--tree-children parsed)
      (mapcar (lambda (child)
                (if (equal "tree" (plist-get (cdr child) :type))
                    (concat (car child) "/")
                  (car child))))
      (seq-filter (lambda (name)
                    (string-prefix-p file name))))))

(defun remoto--handle-file-name-completion (file directory &optional predicate)
  "Complete FILE in remote DIRECTORY using optional PREDICATE."
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
  "Return remote identification for FILENAME.
Use IDENTIFICATION to select which remote field to report."
  (when-let* ((parsed (remoto--parse-path filename))
              (prefix (remoto--file-name-prefix filename)))
    (pcase identification
      ('method "github")
      ('host (format "%s/%s" (remoto-path-owner parsed)
                     (remoto-path-repo parsed)))
      (_ prefix))))

(defun remoto--handle-file-name-directory (filename)
  "Return directory part of remote FILENAME."
  (when-let* ((parsed (remoto--parse-path filename))
              (prefix (remoto--file-name-prefix filename)))
    (let* ((path (remoto-path-path parsed))
           (dir (if (string-suffix-p "/" path)
                    path
                  (file-name-directory path))))
      (concat prefix (or dir "/")))))

(defun remoto--handle-file-name-nondirectory (filename)
  "Return non-directory part of remote FILENAME."
  (if-let* ((parsed (remoto--parse-path filename)))
      (thread-last (remoto-path-path parsed)
        (directory-file-name)
        (file-name-nondirectory))
    (file-name-nondirectory filename)))

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
           (path (remoto-path-path resolved))
           (path (if (string-prefix-p "/" path) (substring path 1) path))
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
        (insert text)
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
  (let* ((dir? (equal "tree" (plist-get plist :type)))
         (size (or (plist-get plist :size) 0))
         (mode (or (plist-get plist :mode) "100644"))
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
          (equal "tree" (plist-get entry :type)))
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
              (path (remoto-path-path resolved))
              (path (if (string-prefix-p "/" path) (substring path 1) path))
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
(defalias 'remoto--handle-copy-file #'remoto--read-only)
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
             (group (+ (not (any "./ "))))
             (? ".git")
             eos)
         input)
    (remoto-path-create
     :owner (match-string 1 input)
     :repo (match-string 2 input)
     :ref nil
     :path "/")))

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
          (message "Remoto: cache cleared for %s" key)
          (when (derived-mode-p 'dired-mode)
            (revert-buffer)))
      (user-error "Remoto: not in a remoto buffer"))))

;;;###autoload
(defun remoto-copy-github-url ()
  "Copy the GitHub web URL for the current file/line to kill ring."
  (interactive)
  (let* ((file (or buffer-file-name dired-directory default-directory))
         (parsed (remoto--parse-path file)))
    (unless parsed
      (user-error "Remoto: not in a remoto buffer"))
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
                                   (not (derived-mode-p 'dired-mode)))
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
  "Return non-nil if INPUT can look like a GitHub URL or shorthand."
  (and (stringp input)
       (not (null
             (string-match-p
              (rx bos
                  (or "https://github.com/"
                      "git@github.com:"
                      (or "github.com/" "/github.com/")))
              input)))))

(defun remoto--maybe-rewrite (input)
  "If INPUT is a GitHub URL/shorthand, return canonical remoto path.
Otherwise return INPUT unchanged."
  (cond
   ((not (remoto--github-input-p input)) input)
   (t
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
       (t input))))))

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
Call ORIG-FN with FILENAME and ARGS after any rewrite."
  (apply orig-fn (remoto--maybe-rewrite filename) args))

(unless (advice-member-p #'remoto--dired-around-a 'dired)
  (advice-add 'dired :around #'remoto--dired-around-a))
(unless (advice-member-p #'remoto--find-file-around-a 'find-file-noselect)
  (advice-add 'find-file-noselect :around #'remoto--find-file-around-a))

;;;; Handler registration

(defconst remoto--handler-regexp
  (rx bos "/github:")
  "Regexp matching remoto file paths.")

(unless (equal (cdr (assoc remoto--handler-regexp file-name-handler-alist))
               #'remoto-file-name-handler)
  (push (cons remoto--handler-regexp #'remoto-file-name-handler)
        file-name-handler-alist))

;;;; Unload

(defun remoto-unload-function ()
  "Remove handler and advice installed by remoto."
  (setq file-name-handler-alist
        (assoc-delete-all remoto--handler-regexp file-name-handler-alist))
  (advice-remove 'dired #'remoto--dired-around-a)
  (advice-remove 'find-file-noselect #'remoto--find-file-around-a)
  nil)

(provide 'remoto)
;;; remoto.el ends here
