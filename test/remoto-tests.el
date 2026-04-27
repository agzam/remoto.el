;;; remoto-tests.el --- Tests for remoto.el -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for remoto - browse GitHub repos without cloning.
;;
;;; Code:

(require 'buttercup)
(require 'remoto)

;;; Helpers

(defvar remoto-test--mock-tree
  '(("README.md" ((type . "blob") (size . 500) (sha . "aaa") (mode . "100644")))
    ("src" ((type . "tree") (size . 0) (sha . "bbb") (mode . "040000")))
    ("src/main.el" ((type . "blob") (size . 1234) (sha . "ccc") (mode . "100644")))
    ("src/utils.el" ((type . "blob") (size . 567) (sha . "ddd") (mode . "100644")))
    ("bin/run" ((type . "blob") (size . 42) (sha . "eee") (mode . "100755")))
    ("bin" ((type . "tree") (size . 0) (sha . "fff") (mode . "040000")))
    ("" ((type . "tree") (size . 0) (sha . "") (mode . "040000")))
    ("/" ((type . "tree") (size . 0) (sha . "") (mode . "040000"))))
  "Mock tree data for tests.")

(defun remoto-test--install-mock-tree ()
  "Install mock tree into the cache."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry remoto-test--mock-tree)
      (puthash (car entry) (cadr entry) table))
    (puthash "testowner/testrepo@main" table remoto--tree-cache)))

(defmacro remoto-test-with-cache (&rest body)
  "Run BODY with a mock tree cache installed."
  (declare (indent 0))
  `(let ((remoto--tree-cache (make-hash-table :test 'equal))
         (remoto--default-branch-cache (make-hash-table :test 'equal))
         (remoto--content-cache (make-hash-table :test 'equal))
         (remoto--branches-cache (make-hash-table :test 'equal))
         (remoto--search-cache (make-hash-table :test 'equal))
         (remoto--users-cache (make-hash-table :test 'equal))
         (remoto--user-repos-cache (make-hash-table :test 'equal))
         (remoto--authenticated-user nil))
     (puthash "testowner/testrepo" "main" remoto--default-branch-cache)
     (remoto-test--install-mock-tree)
     ,@body))

;;; Path parsing

(describe "remoto--parse-path"
  (it "parses full canonical path"
    (let ((p (remoto--parse-path "/github:torvalds/linux@master:/kernel/main.c")))
      (expect (remoto-path-owner p) :to-equal "torvalds")
      (expect (remoto-path-repo p) :to-equal "linux")
      (expect (remoto-path-ref p) :to-equal "master")
      (expect (remoto-path-path p) :to-equal "/kernel/main.c")))

  (it "parses path without ref"
    (let ((p (remoto--parse-path "/github:magit/magit:/")))
      (expect (remoto-path-owner p) :to-equal "magit")
      (expect (remoto-path-repo p) :to-equal "magit")
      (expect (remoto-path-ref p) :to-be nil)
      (expect (remoto-path-path p) :to-equal "/")))

  (it "defaults empty path to /"
    (let ((p (remoto--parse-path "/github:a/b@main:")))
      (expect (remoto-path-path p) :to-equal "/")))

  (it "returns nil for non-remoto paths"
    (expect (remoto--parse-path "/home/user/file.el") :to-be nil)
    (expect (remoto--parse-path "https://github.com/a/b") :to-be nil)))

(describe "remoto--canonical-path"
  (it "round-trips a full path"
    (let* ((input "/github:torvalds/linux@v6.5:/Makefile")
           (parsed (remoto--parse-path input)))
      (expect (remoto--canonical-path parsed) :to-equal input)))

  (it "omits @ref when ref is nil"
    (let ((p (remoto-path-create :owner "a" :repo "b" :ref nil :path "/")))
      (expect (remoto--canonical-path p) :to-equal "/github:a/b:/"))))

;;; User input parsing

(describe "remoto--parse-input"
  (it "parses https://github.com/owner/repo"
    (let ((p (remoto--parse-input "https://github.com/torvalds/linux")))
      (expect (remoto-path-owner p) :to-equal "torvalds")
      (expect (remoto-path-repo p) :to-equal "linux")
      (expect (remoto-path-path p) :to-equal "/")))

  (it "parses tree URL with ref and path"
    (let ((p (remoto--parse-input "https://github.com/torvalds/linux/tree/master/kernel")))
      (expect (remoto-path-ref p) :to-equal "master")
      (expect (remoto-path-path p) :to-equal "/kernel")))

  (it "parses blob URL and strips fragment"
    (let ((p (remoto--parse-input "https://github.com/torvalds/linux/blob/master/README#L10-L20")))
      (expect (remoto-path-ref p) :to-equal "master")
      (expect (remoto-path-path p) :to-equal "/README")))

  (it "parses git@github.com:owner/repo.git"
    (let ((p (remoto--parse-input "git@github.com:torvalds/linux.git")))
      (expect (remoto-path-owner p) :to-equal "torvalds")
      (expect (remoto-path-repo p) :to-equal "linux")))

  (it "parses git remote with dotted repo name"
    (let ((p (remoto--parse-input "git@github.com:agzam/remoto.el.git")))
      (expect (remoto-path-owner p) :to-equal "agzam")
      (expect (remoto-path-repo p) :to-equal "remoto.el"))
    (let ((p (remoto--parse-input "git@github.com:agzam/remoto.el")))
      (expect (remoto-path-owner p) :to-equal "agzam")
      (expect (remoto-path-repo p) :to-equal "remoto.el")))

  (it "parses owner/repo shorthand"
    (let ((p (remoto--parse-input "torvalds/linux")))
      (expect (remoto-path-owner p) :to-equal "torvalds")
      (expect (remoto-path-repo p) :to-equal "linux")))

  (it "parses owner/repo@ref shorthand"
    (let ((p (remoto--parse-input "torvalds/linux@v6.5")))
      (expect (remoto-path-ref p) :to-equal "v6.5")))

  (it "signals on unparseable input"
    (expect (remoto--parse-input "not a repo") :to-throw 'user-error)))

;;; GitHub input detection

(describe "remoto--github-input-p"
  (it "detects https URLs"
    (expect (remoto--github-input-p "https://github.com/a/b") :to-be-truthy))

  (it "detects git SSH URLs"
    (expect (remoto--github-input-p "git@github.com:a/b.git") :to-be-truthy))

  (it "detects /github.com/ paths"
    (expect (remoto--github-input-p "/github.com/a/b") :to-be-truthy))

  (it "rejects local paths"
    (expect (remoto--github-input-p "/home/user/file") :not :to-be-truthy))

  (it "rejects nil"
    (expect (remoto--github-input-p nil) :not :to-be-truthy)))

;;; Tree cache operations

(describe "remoto--tree-entry"
  (it "finds a file entry"
    (remoto-test-with-cache
      (let* ((entry (remoto--tree-entry
                     (remoto--parse-path "/github:testowner/testrepo@main:/README.md")))
             (entry-type (alist-get 'type entry))
             (entry-size (alist-get 'size entry)))
        (expect entry :to-be-truthy)
        (expect entry-type :to-equal "blob")
        (expect entry-size :to-equal 500))))

  (it "finds a directory entry"
    (remoto-test-with-cache
      (let* ((entry (remoto--tree-entry
                     (remoto--parse-path "/github:testowner/testrepo@main:/src")))
             (entry-type (alist-get 'type entry)))
        (expect entry :to-be-truthy)
        (expect entry-type :to-equal "tree"))))

  (it "finds root entry"
    (remoto-test-with-cache
      (let* ((entry (remoto--tree-entry
                     (remoto--parse-path "/github:testowner/testrepo@main:/")))
             (entry-type (alist-get 'type entry)))
        (expect entry :to-be-truthy)
        (expect entry-type :to-equal "tree"))))

  (it "returns nil for nonexistent paths"
    (remoto-test-with-cache
      (expect (remoto--tree-entry
               (remoto--parse-path "/github:testowner/testrepo@main:/nope.txt"))
              :to-be nil)))

  (it "handles double slashes"
    (remoto-test-with-cache
      (let ((entry (remoto--tree-entry
                    (remoto--parse-path "/github:testowner/testrepo@main:/src//main.el"))))
        (expect entry :to-be-truthy)
        (expect (alist-get 'sha entry) :to-equal "ccc")))))

(describe "remoto--tree-children"
  (it "lists root children"
    (remoto-test-with-cache
      (let ((children (remoto--tree-children
                       (remoto--parse-path "/github:testowner/testrepo@main:/"))))
        (expect (length children) :to-equal 3)
        (expect (mapcar #'car children) :to-equal '("README.md" "bin" "src")))))

  (it "lists subdirectory children"
    (remoto-test-with-cache
      (let ((children (remoto--tree-children
                       (remoto--parse-path "/github:testowner/testrepo@main:/src/"))))
        (expect (length children) :to-equal 2)
        (expect (mapcar #'car children) :to-equal '("main.el" "utils.el"))))))

;;; Truncated tree fallback

(describe "truncated tree on-demand fetch"
  (it "fetches parent directory for missing file entry"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--content-cache (make-hash-table :test 'equal)))
      (puthash "testowner/testrepo" "main" remoto--default-branch-cache)
      ;; Simulate a truncated tree with only root and src dir
      (let ((table (make-hash-table :test 'equal)))
        (puthash "" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "/" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "src" '((type . "tree") (size . 0) (sha . "bbb") (mode . "040000")) table)
        (puthash "\0truncated" t table)
        (puthash "testowner/testrepo@main" table remoto--tree-cache))
      ;; Mock the API call for on-demand fetch
      (spy-on 'remoto--api :and-call-fake
              (lambda (endpoint)
                (cond
                 ((string-match-p "contents/src" endpoint)
                  '(((name . "main.el") (path . "src/main.el")
                     (type . "file") (size . 1234) (sha . "ccc"))
                    ((name . "utils.el") (path . "src/utils.el")
                     (type . "file") (size . 567) (sha . "ddd"))))
                 (t nil))))
      ;; Looking up src/main.el should trigger on-demand fetch
      (let* ((entry (remoto--tree-entry
                     (remoto--parse-path "/github:testowner/testrepo@main:/src/main.el")))
             (entry-type (alist-get 'type entry)))
        (expect entry :to-be-truthy)
        (expect entry-type :to-equal "blob")
        (expect (alist-get 'sha entry) :to-equal "ccc"))))

  (it "fetches directory children on demand"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--content-cache (make-hash-table :test 'equal)))
      (puthash "testowner/testrepo" "main" remoto--default-branch-cache)
      (let ((table (make-hash-table :test 'equal)))
        (puthash "" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "/" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "src" '((type . "tree") (size . 0) (sha . "bbb") (mode . "040000")) table)
        (puthash "\0truncated" t table)
        (puthash "testowner/testrepo@main" table remoto--tree-cache))
      (spy-on 'remoto--api :and-call-fake
              (lambda (endpoint)
                (cond
                 ((string-match-p "contents/src" endpoint)
                  '(((name . "main.el") (path . "src/main.el")
                     (type . "file") (size . 1234) (sha . "ccc"))
                    ((name . "utils.el") (path . "src/utils.el")
                     (type . "file") (size . 567) (sha . "ddd"))))
                 (t nil))))
      (let ((children (remoto--tree-children
                       (remoto--parse-path "/github:testowner/testrepo@main:/src/"))))
        (expect (length children) :to-equal 2)
        (expect (mapcar #'car children) :to-equal '("main.el" "utils.el")))))

  (it "excludes internal markers from root children"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--content-cache (make-hash-table :test 'equal)))
      (puthash "testowner/testrepo" "main" remoto--default-branch-cache)
      (let ((table (make-hash-table :test 'equal)))
        (puthash "" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "/" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "README.md" '((type . "blob") (size . 500) (sha . "aaa") (mode . "100644")) table)
        (puthash "src" '((type . "tree") (size . 0) (sha . "bbb") (mode . "040000")) table)
        (puthash "\0truncated" t table)
        (puthash "\0fetched:" t table)
        (puthash "testowner/testrepo@main" table remoto--tree-cache))
      (let* ((children (remoto--tree-children
                        (remoto--parse-path "/github:testowner/testrepo@main:/")))
             (names (mapcar #'car children)))
        (expect (length children) :to-equal 2)
        (expect names :to-equal '("README.md" "src")))))

  (it "does not re-fetch already fetched directories"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--content-cache (make-hash-table :test 'equal))
          (api-call-count 0))
      (puthash "testowner/testrepo" "main" remoto--default-branch-cache)
      (let ((table (make-hash-table :test 'equal)))
        (puthash "" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "/" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "src" '((type . "tree") (size . 0) (sha . "bbb") (mode . "040000")) table)
        (puthash "\0truncated" t table)
        (puthash "testowner/testrepo@main" table remoto--tree-cache))
      (spy-on 'remoto--api :and-call-fake
              (lambda (endpoint)
                (when (string-match-p "contents/src" endpoint)
                  (setq api-call-count (1+ api-call-count))
                  '(((name . "main.el") (path . "src/main.el")
                     (type . "file") (size . 1234) (sha . "ccc"))))))
      ;; First access triggers fetch
      (remoto--tree-entry
       (remoto--parse-path "/github:testowner/testrepo@main:/src/main.el"))
      ;; Second access should not re-fetch
      (remoto--tree-entry
       (remoto--parse-path "/github:testowner/testrepo@main:/src/main.el"))
      (expect api-call-count :to-equal 1))))

;;; File operations via handler

(describe "file operations"
  (it "file-exists-p returns t for existing files"
    (remoto-test-with-cache
      (expect (file-exists-p "/github:testowner/testrepo@main:/README.md") :to-be-truthy)))

  (it "file-exists-p returns nil for missing files"
    (remoto-test-with-cache
      (expect (file-exists-p "/github:testowner/testrepo@main:/nope.txt") :not :to-be-truthy)))

  (it "file-directory-p returns t for directories"
    (remoto-test-with-cache
      (expect (file-directory-p "/github:testowner/testrepo@main:/src") :to-be-truthy)))

  (it "file-directory-p returns nil for files"
    (remoto-test-with-cache
      (expect (file-directory-p "/github:testowner/testrepo@main:/README.md") :not :to-be-truthy)))

  (it "file-regular-p returns t for files"
    (remoto-test-with-cache
      (expect (file-regular-p "/github:testowner/testrepo@main:/README.md") :to-be-truthy)))

  (it "file-writable-p always returns nil"
    (remoto-test-with-cache
      (expect (file-writable-p "/github:testowner/testrepo@main:/README.md") :not :to-be-truthy)))

  (it "file-remote-p returns the prefix"
    (remoto-test-with-cache
      (expect (file-remote-p "/github:testowner/testrepo@main:/README.md")
              :to-equal "/github:testowner/testrepo@main:")))

  (it "file-attributes returns correct size"
    (remoto-test-with-cache
      (let ((attrs (file-attributes "/github:testowner/testrepo@main:/README.md")))
        (expect (file-attribute-size attrs) :to-equal 500))))

  (it "file-attributes returns t type for directories"
    (remoto-test-with-cache
      (let ((attrs (file-attributes "/github:testowner/testrepo@main:/src")))
        (expect (file-attribute-type attrs) :to-be t))))

  (it "directory-files lists entries with . and .."
    (remoto-test-with-cache
      (let ((files (directory-files "/github:testowner/testrepo@main:/")))
        (expect (member "." files) :to-be-truthy)
        (expect (member ".." files) :to-be-truthy)
        (expect (member "README.md" files) :to-be-truthy)
        (expect (member "src" files) :to-be-truthy))))

  (it "file-name-all-completions works for partial input"
    (remoto-test-with-cache
      (let ((completions (file-name-all-completions "s" "/github:testowner/testrepo@main:/")))
        (expect (member "src/" completions) :to-be-truthy))))

  (it "expand-file-name resolves relative paths"
    (remoto-test-with-cache
      (expect (expand-file-name "main.el" "/github:testowner/testrepo@main:/src/")
              :to-equal "/github:testowner/testrepo@main:/src/main.el")))

  (it "expand-file-name does not clobber local absolute paths"
    (remoto-test-with-cache
      (let ((default-directory "/github:testowner/testrepo@main:/"))
        (expect (expand-file-name "/tmp/foo")
                :to-equal "/tmp/foo"))))

  (it "insert-file-contents does not move point"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-content
              :and-return-value "line one\nline two\nline three\n")
      (with-temp-buffer
        (let ((pt (point)))
          (remoto--handle-insert-file-contents
           "/github:testowner/testrepo@main:/README.md")
          (expect (point) :to-equal pt)
          (expect (buffer-string) :to-equal "line one\nline two\nline three\n"))))))

;;; Dired listing format

(describe "remoto--format-dired-entry"
  (it "formats a file entry"
    (let ((line (remoto--format-dired-entry
                 "file.el" '((type . "blob") (size . 1234) (mode . "100644")))))
      (expect line :to-match "^-rw-r--r--")
      (expect line :to-match "1234")
      (expect line :to-match "file\\.el")))

  (it "formats a directory entry"
    (let ((line (remoto--format-dired-entry
                 "src" '((type . "tree") (size . 0) (mode . "040000")))))
      (expect line :to-match "^drwxr-xr-x")))

  (it "formats an executable entry"
    (let ((line (remoto--format-dired-entry
                 "run" '((type . "blob") (size . 42) (mode . "100755")))))
      (expect line :to-match "^-rwxr-xr-x"))))

;;; Read-only enforcement

(describe "read-only operations"
  (it "write-region signals read-only"
    (remoto-test-with-cache
      (expect (write-region "" nil "/github:testowner/testrepo@main:/foo")
              :to-throw 'user-error)))

  (it "delete-file signals read-only"
    (remoto-test-with-cache
      (expect (delete-file "/github:testowner/testrepo@main:/README.md")
              :to-throw 'user-error)))

  (it "make-directory succeeds for existing dirs"
    (remoto-test-with-cache
      (expect (make-directory "/github:testowner/testrepo@main:/src") :not :to-throw)))

  (it "make-directory signals for new dirs"
    (remoto-test-with-cache
      (expect (make-directory "/github:testowner/testrepo@main:/newdir")
              :to-throw 'user-error))))

;;; copy-file

(describe "copy-file"
  (it "copies remoto file to local destination"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-content :and-return-value "mock file content")
      (let ((dest (make-temp-file "remoto-copy-test-")))
        (unwind-protect
            (progn
              (copy-file "/github:testowner/testrepo@main:/src/main.el" dest t)
              (expect (with-temp-buffer
                        (insert-file-contents dest)
                        (buffer-string))
                      :to-equal "mock file content"))
          (delete-file dest)))))

  (it "signals read-only when destination is remoto"
    (remoto-test-with-cache
      (expect (copy-file "/github:testowner/testrepo@main:/src/main.el"
                         "/github:testowner/testrepo@main:/src/copy.el")
              :to-throw 'user-error)))

  (it "signals read-only when copying local file to remoto"
    (remoto-test-with-cache
      (let ((src (make-temp-file "remoto-copy-src-")))
        (unwind-protect
            (expect (copy-file src "/github:testowner/testrepo@main:/dest.el")
                    :to-throw 'user-error)
          (delete-file src))))))

;;; Path normalization

(describe "remoto--normalize-path"
  (it "collapses double slashes"
    (expect (remoto--normalize-path "/a//b/c") :to-equal "/a/b/c"))

  (it "resolves . and .."
    (expect (remoto--normalize-path "/a/./b/../c") :to-equal "/a/c"))

  (it "preserves trailing slash"
    (expect (remoto--normalize-path "/a/b/") :to-equal "/a/b/"))

  (it "handles root"
    (expect (remoto--normalize-path "/") :to-equal "/")))

;;; remoto-copy-github-url

(describe "remoto-copy-github-url"
  (it "copies file URL with line number from a file buffer"
    (remoto-test-with-cache
      (let ((buffer-file-name "/github:testowner/testrepo@main:/src/main.el"))
        (with-temp-buffer
          (insert "line1\nline2\nline3\n")
          (setq-local buffer-file-name "/github:testowner/testrepo@main:/src/main.el")
          (goto-char (point-min))
          (forward-line 2)
          (remoto-copy-github-url)
          (expect (car kill-ring)
                  :to-equal "https://github.com/testowner/testrepo/blob/main/src/main.el#L3")))))

  (it "copies file URL with line range when region is active"
    (remoto-test-with-cache
      (with-temp-buffer
        (insert "line1\nline2\nline3\nline4\nline5\n")
        (setq-local buffer-file-name "/github:testowner/testrepo@main:/src/main.el")
        (goto-char (point-min))
        (forward-line 1)
        (set-mark (point))
        (forward-line 2)
        (activate-mark)
        (remoto-copy-github-url)
        (deactivate-mark)
        (expect (car kill-ring)
                :to-equal "https://github.com/testowner/testrepo/blob/main/src/main.el#L2-L4"))))

  (it "copies directory URL from dired with point on a directory"
    (remoto-test-with-cache
      (with-temp-buffer
        (dired-mode)
        (setq-local dired-directory "/github:testowner/testrepo@main:/")
        (spy-on 'dired-get-filename :and-return-value
                "/github:testowner/testrepo@main:/src")
        (remoto-copy-github-url)
        (expect (car kill-ring)
                :to-equal "https://github.com/testowner/testrepo/tree/main/src"))))

  (it "copies file URL from dired with point on a file"
    (remoto-test-with-cache
      (with-temp-buffer
        (dired-mode)
        (setq-local dired-directory "/github:testowner/testrepo@main:/")
        (spy-on 'dired-get-filename :and-return-value
                "/github:testowner/testrepo@main:/README.md")
        (remoto-copy-github-url)
        (expect (car kill-ring)
                :to-equal "https://github.com/testowner/testrepo/blob/main/README.md"))))

  (it "falls back to dired-directory when point is not on a file"
    (remoto-test-with-cache
      (with-temp-buffer
        (dired-mode)
        (setq-local dired-directory "/github:testowner/testrepo@main:/")
        (spy-on 'dired-get-filename :and-return-value nil)
        (remoto-copy-github-url)
        (expect (car kill-ring)
                :to-equal "https://github.com/testowner/testrepo/tree/main/"))))

  (it "signals error outside remoto buffers"
    (with-temp-buffer
      (expect (remoto-copy-github-url) :to-throw 'user-error))))

;;; Repository search

(describe "remoto--fetch-branches"
  (it "fetches branch names from API"
    (spy-on 'remoto--api :and-return-value
            '(((name . "main") (commit . ((sha . "abc"))))
              ((name . "develop") (commit . ((sha . "def"))))
              ((name . "feature/x") (commit . ((sha . "ghi"))))))
    (let ((remoto--branches-cache (make-hash-table :test 'equal)))
      (expect (remoto--fetch-branches "torvalds" "linux")
              :to-equal '("main" "develop" "feature/x"))))

  (it "caches results"
    (let ((remoto--branches-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint)
                (setq call-count (1+ call-count))
                '(((name . "main")))))
      (remoto--fetch-branches "torvalds" "linux")
      (remoto--fetch-branches "torvalds" "linux")
      (expect call-count :to-equal 1)))

  (it "returns nil on API errors"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_endpoint)
              (user-error "not found")))
    (let ((remoto--branches-cache (make-hash-table :test 'equal)))
      (expect (remoto--fetch-branches "no" "repo") :to-be nil))))

(describe "remoto--search-repos"
  (it "returns nil for short queries"
    (expect (remoto--search-repos "") :to-be nil)
    (expect (remoto--search-repos "ab") :to-be nil))

  (it "builds search query from input"
    (expect (remoto--search-query "torvalds") :to-equal "torvalds in:name")
    (expect (remoto--search-query "torvalds/") :to-equal "user:torvalds")
    (expect (remoto--search-query "torvalds/lin") :to-equal "lin in:name user:torvalds"))

  (it "parses search API response into owner/repo list"
    (spy-on 'remoto--api :and-return-value
            '((items . (((full_name . "torvalds/linux"))
                        ((full_name . "torvalds/subsurface"))))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (expect (remoto--search-repos "torvalds")
              :to-equal '("torvalds/linux" "torvalds/subsurface"))))

  (it "caches results for repeated queries"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint)
                (setq call-count (1+ call-count))
                '((items . (((full_name . "torvalds/linux")))))))
      (remoto--search-repos "torvalds")
      (remoto--search-repos "torvalds")
      (expect call-count :to-equal 1)))

  (it "filters cached results when query narrows past a slash"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint)
                (setq call-count (1+ call-count))
                '((items . (((full_name . "agzam/spacehammer"))
                            ((full_name . "agzam/dotfiles"))
                            ((full_name . "agzam/remoto.el")))))))
      ;; First call hits the API
      (let ((results (remoto--search-repos "agzam")))
        (expect (length results) :to-equal 3))
      ;; Query with slash filters cached results, no new API call
      (let ((results (remoto--search-repos "agzam/spa")))
        (expect results :to-equal '("agzam/spacehammer"))
        (expect call-count :to-equal 1))
      ;; Further narrowing still uses cache
      (let ((results (remoto--search-repos "agzam/spaceh")))
        (expect results :to-equal '("agzam/spacehammer"))
        (expect call-count :to-equal 1))
      ;; No match returns empty list, still no API call
      (let ((results (remoto--search-repos "agzam/zzz")))
        (expect results :to-be nil)
        (expect call-count :to-equal 1))))

  (it "does not filter from short prefix cache without slash"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint)
                (setq call-count (1+ call-count))
                '((items . (((full_name . "agzam/spacehammer")))))))
      ;; "agz" hits the API
      (remoto--search-repos "agz")
      ;; "agzam" should NOT filter from "agz" cache - different search
      (remoto--search-repos "agzam")
      (expect call-count :to-equal 2)))

  (it "returns nil on API errors"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_endpoint)
              (user-error "network error")))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (expect (remoto--search-repos "torvalds") :to-be nil)))

  (it "expires cache entries after TTL"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-search-cache-ttl 1)
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint)
                (setq call-count (1+ call-count))
                '((items . (((full_name . "torvalds/linux")))))))
      (remoto--search-repos "torvalds")
      (expect call-count :to-equal 1)
      ;; Manually expire the entry by backdating the timestamp
      (let ((entry (gethash "torvalds" remoto--search-cache)))
        (setcar entry (- (float-time) 10)))
      ;; Next call should re-fetch
      (remoto--search-repos "torvalds")
      (expect call-count :to-equal 2)))

  (it "caches empty results without re-hitting API"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint)
                (setq call-count (1+ call-count))
                '((items))))
      (remoto--search-repos "zzzznotfound")
      (remoto--search-repos "zzzznotfound")
      (expect call-count :to-equal 1)))

  (it "delivers results via callback when provided"
    (spy-on 'remoto--api :and-return-value
            '((items . (((full_name . "torvalds/linux"))))))
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (captured nil))
      (remoto--search-repos "torvalds"
                            (lambda (results) (setq captured results)))
      (expect captured :to-equal '("torvalds/linux"))))

  (it "completes branch names when query contains @"
    (spy-on 'remoto--fetch-branches :and-return-value
            '("main" "develop" "dont-use-gh"))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (expect (remoto--search-repos "agzam/remoto.el@")
              :to-equal '("agzam/remoto.el@main"
                          "agzam/remoto.el@develop"
                          "agzam/remoto.el@dont-use-gh"))))

  (it "filters branches by prefix after @"
    (spy-on 'remoto--fetch-branches :and-return-value
            '("main" "develop" "dont-use-gh"))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (expect (remoto--search-repos "agzam/remoto.el@don")
              :to-equal '("agzam/remoto.el@dont-use-gh"))))

  (it "returns nil for @ query without valid owner/repo"
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (expect (remoto--search-repos "noslash@main") :to-be nil))))

(describe "remoto--repo-completion-table"
  (it "returns search results via completion protocol"
    (spy-on 'remoto--search-repos :and-return-value
            '("torvalds/linux" "torvalds/subsurface"))
    (let ((result (remoto--repo-completion-table "torvalds" nil t)))
      (expect result :to-equal '("torvalds/linux" "torvalds/subsurface"))))

  (it "returns metadata"
    (expect (remoto--repo-completion-table "" nil 'metadata)
            :to-equal '(metadata (category . remoto-repo)))))

(describe "remoto--read-repo"
  (it "returns completing-read result directly"
    (spy-on 'completing-read :and-return-value "torvalds/linux")
    (expect (remoto--read-repo) :to-equal "torvalds/linux"))

  (it "allows URLs as direct input"
    (spy-on 'completing-read :and-return-value "https://github.com/torvalds/linux")
    (expect (remoto--read-repo) :to-equal "https://github.com/torvalds/linux"))

  (it "allows owner/repo@ref as direct input"
    (spy-on 'completing-read :and-return-value "agzam/remoto.el@dont-use-gh")
    (expect (remoto--read-repo) :to-equal "agzam/remoto.el@dont-use-gh")))

;;; Auth fallback

(describe "remoto--api auth fallback"
  (it "falls back to unauthenticated when auth times out but does not cache failure"
    (let ((remoto--auth-failed nil)
          (remoto-github-auth nil)
          (remoto-auth-timeout 0.3))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (if (eq (plist-get args :auth) 'none)
                    '((name . "test-repo"))
                  (sleep-for 5))))
      (expect (remoto--api "repos/owner/repo") :to-equal '((name . "test-repo")))
      (expect remoto--auth-failed :to-be nil)))

  (it "falls back to unauthenticated on auth error"
    (let ((remoto--auth-failed nil)
          (remoto-github-auth nil)
          (remoto-auth-timeout 5))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (if (eq (plist-get args :auth) 'none)
                    '((name . "test-repo"))
                  (error "Package ghub requires a Github API token"))))
      (expect (remoto--api "repos/owner/repo") :to-equal '((name . "test-repo")))
      (expect remoto--auth-failed :to-be-truthy)))

  (it "skips auth when failure is cached"
    (let ((remoto--auth-failed t)
          (remoto-github-auth nil)
          (remoto-auth-timeout 5)
          (auth-used nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (push (plist-get args :auth) auth-used)
                '((name . "test-repo"))))
      (remoto--api "repos/owner/repo")
      (expect auth-used :to-equal '(none))))

  (it "clears cache with remoto-reset-auth"
    (let ((remoto--auth-failed t))
      (remoto-reset-auth)
      (expect remoto--auth-failed :to-be nil)))

  (it "does not cache failure when auth succeeds"
    (let ((remoto--auth-failed nil)
          (remoto-github-auth nil)
          (remoto-auth-timeout 5))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                '((name . "test-repo"))))
      (remoto--api "repos/owner/repo")
      (expect remoto--auth-failed :to-be nil))))

(describe "remoto--ghub-get message suppression"
  (it "suppresses messages when ghub-debug is nil"
    (let ((ghub-debug nil)
          (captured-inhibit nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (setq captured-inhibit inhibit-message)
                '((result . t))))
      (remoto--ghub-get "/repos/owner/repo" 'none "repos/owner/repo")
      (expect captured-inhibit :to-be t)))

  (it "allows messages when ghub-debug is t"
    (let ((ghub-debug t)
          (captured-inhibit nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (setq captured-inhibit inhibit-message)
                '((result . t))))
      (remoto--ghub-get "/repos/owner/repo" 'none "repos/owner/repo")
      (expect captured-inhibit :to-be nil))))

;;; Partial path parsing

(describe "remoto--parse-partial-github-path"
  (it "parses /github: as root level"
    (let ((result (remoto--parse-partial-github-path "/github:")))
      (expect (plist-get result :level) :to-equal 'root)
      (expect (plist-get result :owner) :to-be nil)))

  (it "parses /github:owner/ as owner level"
    (let ((result (remoto--parse-partial-github-path "/github:foobar/")))
      (expect (plist-get result :level) :to-equal 'owner)
      (expect (plist-get result :owner) :to-equal "foobar")))

  (it "returns nil for bare /github:owner (no trailing slash)"
    (expect (remoto--parse-partial-github-path "/github:foobar") :to-be nil))

  (it "returns nil for full canonical paths"
    (expect (remoto--parse-partial-github-path "/github:a/b@main:/src") :to-be nil))

  (it "parses /github:owner/repo@ as repo level"
    (let ((result (remoto--parse-partial-github-path "/github:torvalds/linux@")))
      (expect (plist-get result :level) :to-equal 'repo)
      (expect (plist-get result :owner) :to-equal "torvalds")
      (expect (plist-get result :repo) :to-equal "linux")))

  (it "returns nil for /github:owner/repo (no @)"
    (expect (remoto--parse-partial-github-path "/github:a/b") :to-be nil)))

(describe "remoto--parse-partial-canonical"
  (it "parses /github:owner/repo without ref"
    (let ((p (remoto--parse-partial-canonical "/github:torvalds/linux")))
      (expect (remoto-path-owner p) :to-equal "torvalds")
      (expect (remoto-path-repo p) :to-equal "linux")
      (expect (remoto-path-ref p) :to-be nil)
      (expect (remoto-path-path p) :to-equal "/")))

  (it "parses /github:owner/repo@ref"
    (let ((p (remoto--parse-partial-canonical "/github:torvalds/linux@v6.5")))
      (expect (remoto-path-owner p) :to-equal "torvalds")
      (expect (remoto-path-repo p) :to-equal "linux")
      (expect (remoto-path-ref p) :to-equal "v6.5")))

  (it "parses with trailing slash"
    (let ((p (remoto--parse-partial-canonical "/github:torvalds/linux/")))
      (expect (remoto-path-owner p) :to-equal "torvalds")
      (expect (remoto-path-repo p) :to-equal "linux")))

  (it "returns nil for full canonical path"
    (expect (remoto--parse-partial-canonical "/github:a/b@main:/src") :to-be nil))

  (it "returns nil for /github: alone"
    (expect (remoto--parse-partial-canonical "/github:") :to-be nil)))

;;; Partial path file operations

(describe "partial path file operations"
  (it "file-directory-p returns t for /github:"
    (expect (remoto--handle-file-directory-p "/github:") :to-be t))

  (it "file-directory-p returns t for /github:owner/"
    (expect (remoto--handle-file-directory-p "/github:foobar/") :to-be t))

  (it "file-exists-p returns t for /github:"
    (expect (remoto--handle-file-exists-p "/github:") :to-be t))

  (it "file-exists-p returns t for /github:owner/"
    (expect (remoto--handle-file-exists-p "/github:foobar/") :to-be t))

  (it "file-remote-p returns /github: for partial paths"
    (expect (remoto--handle-file-remote-p "/github:foobar/") :to-equal "/github:"))

  (it "file-remote-p returns method for partial paths"
    (expect (remoto--handle-file-remote-p "/github:foobar/" 'method) :to-equal "github"))

  (it "file-name-directory returns /github: for /github:foo"
    (expect (remoto--handle-file-name-directory "/github:foo") :to-equal "/github:"))

  (it "file-name-directory returns /github:owner/ for /github:owner/repo"
    (expect (remoto--handle-file-name-directory "/github:foobar/zapzop")
            :to-equal "/github:foobar/"))

  (it "file-name-directory returns /github:owner/repo@ for /github:owner/repo@ref"
    (expect (remoto--handle-file-name-directory "/github:foobar/zapzop@main")
            :to-equal "/github:foobar/zapzop@"))

  (it "file-name-nondirectory returns empty for /github:"
    (expect (remoto--handle-file-name-nondirectory "/github:") :to-equal ""))

  (it "file-name-nondirectory returns owner for /github:owner"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar") :to-equal "foobar"))

  (it "file-name-nondirectory returns empty for /github:owner/"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar/") :to-equal ""))

  (it "file-name-nondirectory returns repo for /github:owner/repo"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar/zapzop")
            :to-equal "zapzop"))

  (it "file-name-nondirectory returns ref for /github:owner/repo@ref"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar/zapzop@main")
            :to-equal "main")))

;;; User search

(describe "remoto--search-users"
  (it "returns nil for short queries"
    (expect (remoto--search-users "") :to-be nil)
    (expect (remoto--search-users "a") :to-be nil))

  (it "fetches users from search API"
    (spy-on 'remoto--api :and-return-value
            '((items . (((login . "torvalds"))
                        ((login . "torgeirhelge"))))))
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto--users-cache (make-hash-table :test 'equal)))
      (expect (remoto--search-users "tor")
              :to-equal '("torvalds" "torgeirhelge"))))

  (it "caches results and avoids repeat API calls"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto--users-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint)
                (setq call-count (1+ call-count))
                '((items . (((login . "torvalds")))))))
      (remoto--search-users "tor")
      (remoto--search-users "tor")
      (expect call-count :to-equal 1)))

  (it "narrows cached results for longer prefixes"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto--users-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint)
                (setq call-count (1+ call-count))
                '((items . (((login . "torvalds"))
                            ((login . "torgeirhelge")))))))
      (remoto--search-users "tor")
      (let ((result (remoto--search-users "torv")))
        (expect result :to-equal '("torvalds"))
        (expect call-count :to-equal 1))))

  (it "returns nil on API errors"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_) (user-error "network")))
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto--users-cache (make-hash-table :test 'equal)))
      (expect (remoto--search-users "tor") :to-be nil))))

;;; User repos

(describe "remoto--fetch-user-repos"
  (it "fetches repo names from API"
    (spy-on 'remoto--api :and-return-value
            '(((name . "linux") (full_name . "torvalds/linux"))
              ((name . "subsurface") (full_name . "torvalds/subsurface"))))
    (let ((remoto--user-repos-cache (make-hash-table :test 'equal))
          (remoto--auth-failed t))
      (expect (remoto--fetch-user-repos "torvalds")
              :to-equal '("linux" "subsurface"))))

  (it "caches results"
    (let ((remoto--user-repos-cache (make-hash-table :test 'equal))
          (remoto--auth-failed t)
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint)
                (setq call-count (1+ call-count))
                '(((name . "linux")))))
      (remoto--fetch-user-repos "torvalds")
      (remoto--fetch-user-repos "torvalds")
      (expect call-count :to-equal 1)))

  (it "returns nil on API errors"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_) (user-error "not found")))
    (let ((remoto--user-repos-cache (make-hash-table :test 'equal))
          (remoto--auth-failed t))
      (expect (remoto--fetch-user-repos "nouser") :to-be nil))))

(describe "remoto--get-authenticated-user"
  (it "returns login from /user endpoint"
    (let ((remoto--authenticated-user nil)
          (remoto--auth-failed nil))
      (spy-on 'remoto--api :and-return-value '((login . "agzam")))
      (expect (remoto--get-authenticated-user) :to-equal "agzam")))

  (it "caches the result for subsequent calls"
    (let ((remoto--authenticated-user nil)
          (remoto--auth-failed nil)
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_)
                (setq call-count (1+ call-count))
                '((login . "agzam"))))
      (remoto--get-authenticated-user)
      (remoto--get-authenticated-user)
      (expect call-count :to-equal 1)))

  (it "returns nil when auth has failed"
    (let ((remoto--authenticated-user nil)
          (remoto--auth-failed t))
      (spy-on 'remoto--api)
      (expect (remoto--get-authenticated-user) :to-be nil)
      (expect 'remoto--api :not :to-have-been-called)))

  (it "returns nil on API error"
    (let ((remoto--authenticated-user nil)
          (remoto--auth-failed nil))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_) (user-error "auth failed")))
      (expect (remoto--get-authenticated-user) :to-be nil))))

(describe "remoto--fetch-user-repos with authenticated user"
  (it "uses /user/repos endpoint for authenticated user's own repos"
    (let ((remoto--user-repos-cache (make-hash-table :test 'equal))
          (remoto--authenticated-user "torvalds")
          (remoto--auth-failed nil)
          (endpoint-called nil))
      (spy-on 'remoto--api :and-call-fake
              (lambda (ep)
                (setq endpoint-called ep)
                '(((name . "linux") (full_name . "torvalds/linux"))
                  ((name . "private-proj") (full_name . "torvalds/private-proj")))))
      (remoto--fetch-user-repos "torvalds")
      (expect endpoint-called :to-equal "user/repos?per_page=100&sort=updated&type=owner")))

  (it "uses /user/repos endpoint case-insensitively"
    (let ((remoto--user-repos-cache (make-hash-table :test 'equal))
          (remoto--authenticated-user "Torvalds")
          (remoto--auth-failed nil)
          (endpoint-called nil))
      (spy-on 'remoto--api :and-call-fake
              (lambda (ep)
                (setq endpoint-called ep)
                '(((name . "linux")))))
      (remoto--fetch-user-repos "torvalds")
      (expect endpoint-called :to-equal "user/repos?per_page=100&sort=updated&type=owner")))

  (it "uses /users/{owner}/repos for other users"
    (let ((remoto--user-repos-cache (make-hash-table :test 'equal))
          (remoto--authenticated-user "agzam")
          (remoto--auth-failed nil)
          (endpoint-called nil))
      (spy-on 'remoto--api :and-call-fake
              (lambda (ep)
                (setq endpoint-called ep)
                '(((name . "linux")))))
      (remoto--fetch-user-repos "torvalds")
      (expect endpoint-called :to-equal "users/torvalds/repos?per_page=100&sort=updated")))

  (it "skips self-detection when auth has failed"
    (let ((remoto--user-repos-cache (make-hash-table :test 'equal))
          (remoto--authenticated-user nil)
          (remoto--auth-failed t)
          (endpoint-called nil))
      (spy-on 'remoto--api :and-call-fake
              (lambda (ep)
                (setq endpoint-called ep)
                '(((name . "linux")))))
      (remoto--fetch-user-repos "torvalds")
      (expect endpoint-called :to-equal "users/torvalds/repos?per_page=100&sort=updated"))))

(describe "remoto-reset-auth clears authenticated user"
  (it "clears cached authenticated user"
    (let ((old-auth remoto--auth-failed)
          (old-user remoto--authenticated-user))
      (unwind-protect
          (progn
            (setq remoto--auth-failed t
                  remoto--authenticated-user "agzam")
            (remoto-reset-auth)
            (expect remoto--authenticated-user :to-be nil)
            (expect remoto--auth-failed :to-be nil))
        (setq remoto--auth-failed old-auth
              remoto--authenticated-user old-user)))))

;;; Auth timeout resilience

(describe "auth timeout does not poison session"
  (it "retries auth on the next API call after a timeout"
    (let ((remoto--auth-failed nil)
          (remoto-github-auth nil)
          (remoto-auth-timeout 0.3)
          (call-count 0))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (setq call-count (1+ call-count))
                (if (eq (plist-get args :auth) 'none)
                    '((name . "test-repo"))
                  ;; First auth attempt times out, second succeeds
                  (if (< call-count 3)
                      (sleep-for 5)
                    '((name . "test-repo"))))))
      ;; First call: auth times out, falls back to unauthenticated
      (remoto--api "repos/owner/repo")
      ;; Second call: should retry auth (not skip it)
      (let ((remoto-auth-timeout 5))
        (remoto--api "repos/owner/repo"))
      ;; ghub-get was called with non-none auth on the second attempt
      (expect remoto--auth-failed :to-be nil)))

  (it "does not cache repo results when auth state is uncertain"
    (let ((remoto--user-repos-cache (make-hash-table :test 'equal))
          (remoto--authenticated-user nil)
          (remoto--auth-failed nil))
      ;; Simulate: get-authenticated-user returns nil (timeout),
      ;; but auth hasn't permanently failed
      (spy-on 'remoto--get-authenticated-user :and-return-value nil)
      (spy-on 'remoto--api :and-return-value
              '(((name . "public-repo") (full_name . "agzam/public-repo"))))
      (let ((repos (remoto--fetch-user-repos "agzam")))
        ;; Returns results for this call
        (expect repos :to-equal '("public-repo"))
        ;; But does NOT cache them (auth was uncertain)
        (expect (gethash "agzam" remoto--user-repos-cache) :to-be nil))))

  (it "caches repo results when auth succeeds"
    (let ((remoto--user-repos-cache (make-hash-table :test 'equal))
          (remoto--authenticated-user "agzam")
          (remoto--auth-failed nil))
      (spy-on 'remoto--api :and-return-value
              '(((name . "private-repo") (full_name . "agzam/private-repo"))))
      (remoto--fetch-user-repos "agzam")
      (expect (gethash "agzam" remoto--user-repos-cache) :to-be-truthy)))

  (it "caches repo results when auth permanently failed"
    (let ((remoto--user-repos-cache (make-hash-table :test 'equal))
          (remoto--authenticated-user nil)
          (remoto--auth-failed t))
      (spy-on 'remoto--api :and-return-value
              '(((name . "public-repo") (full_name . "agzam/public-repo"))))
      (remoto--fetch-user-repos "agzam")
      ;; Auth permanently failed - we know this is the public endpoint,
      ;; safe to cache
      (expect (gethash "agzam" remoto--user-repos-cache) :to-be-truthy)))

  (it "second completion call gets private repos after GPG agent warms up"
    (let ((remoto--user-repos-cache (make-hash-table :test 'equal))
          (remoto--authenticated-user nil)
          (remoto--auth-failed nil)
          (auth-call-count 0))
      ;; First call: get-authenticated-user fails (GPG timeout)
      ;; Second call: succeeds (GPG agent has passphrase)
      (spy-on 'remoto--get-authenticated-user :and-call-fake
              (lambda ()
                (setq auth-call-count (1+ auth-call-count))
                (if (< auth-call-count 2)
                    nil
                  (setq remoto--authenticated-user "agzam")
                  "agzam")))
      (spy-on 'remoto--api :and-call-fake
              (lambda (endpoint)
                (if (string-prefix-p "user/repos" endpoint)
                    '(((name . "private-repo")) ((name . "public-repo")))
                  '(((name . "public-repo"))))))
      ;; First call: no auth, public endpoint, NOT cached
      (let ((repos1 (remoto--fetch-user-repos "agzam")))
        (expect repos1 :to-equal '("public-repo"))
        (expect (gethash "agzam" remoto--user-repos-cache) :to-be nil))
      ;; Second call: auth works, private endpoint, cached
      (let ((repos2 (remoto--fetch-user-repos "agzam")))
        (expect repos2 :to-equal '("private-repo" "public-repo"))
        (expect (gethash "agzam" remoto--user-repos-cache) :to-be-truthy)))))

;;; Partial path file operations - repo@ level

(describe "repo@ level partial path operations"
  (it "file-exists-p returns t for /github:owner/repo@"
    (expect (remoto--handle-file-exists-p "/github:foobar/zapzop@") :to-be t))

  (it "file-directory-p returns t for /github:owner/repo@"
    (expect (remoto--handle-file-directory-p "/github:foobar/zapzop@") :to-be t))

  (it "file-name-directory returns /github:owner/repo@ for /github:owner/repo@"
    (expect (remoto--handle-file-name-directory "/github:foobar/zapzop@")
            :to-equal "/github:foobar/zapzop@"))

  (it "file-name-nondirectory returns empty for /github:owner/repo@"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar/zapzop@")
            :to-equal "")))

;;; End-to-end completion flow

(describe "end-to-end completion flow"
  (it "completes owner -> repo -> branch -> file sequentially"
    (remoto-test-with-cache
      ;; Step 1: /github: + "tor" -> user completions
      (spy-on 'remoto--search-users :and-return-value '("torvalds"))
      (let ((users (remoto--handle-file-name-all-completions "tor" "/github:")))
        (expect users :to-equal '("torvalds/")))

      ;; Step 2: /github:torvalds/ + "" -> repo completions
      (spy-on 'remoto--fetch-user-repos :and-return-value '("linux" "subsurface"))
      (let ((repos (remoto--handle-file-name-all-completions "" "/github:torvalds/")))
        (expect repos :to-equal '("linux" "subsurface")))

      ;; Step 3: verify path splitting for orderless at repo@ boundary
      (expect (remoto--handle-file-name-directory "/github:torvalds/linux@")
              :to-equal "/github:torvalds/linux@")
      (expect (remoto--handle-file-name-nondirectory "/github:torvalds/linux@")
              :to-equal "")

      ;; Step 4: /github:torvalds/linux@ + "" -> branch completions
      (spy-on 'remoto--fetch-branches :and-return-value '("master" "stable"))
      (let ((branches (remoto--handle-file-name-all-completions
                       "" "/github:torvalds/linux@")))
        (expect branches :to-equal '("master:" "stable:")))

      ;; Step 5: /github:torvalds/linux@master:/ + "s" -> file completions
      (let ((files (remoto--handle-file-name-all-completions
                    "s" "/github:testowner/testrepo@main:/")))
        (expect (member "src/" files) :to-be-truthy))))

  (it "orderless-style: fetches all candidates then filters client-side"
    ;; This simulates what orderless does: file-name-all-completions "" dir
    ;; then filters the full list client-side
    (spy-on 'remoto--fetch-user-repos :and-return-value
            '("linux" "subsurface" "libdc-for-dirk"))
    ;; orderless calls with empty file, gets everything
    (let ((all (remoto--handle-file-name-all-completions "" "/github:torvalds/")))
      (expect (length all) :to-equal 3)
      ;; Then filters client-side
      (let ((filtered (seq-filter (lambda (r) (string-prefix-p "lin" r)) all)))
        (expect filtered :to-equal '("linux"))))))

;;; Pre-repo completions

(describe "pre-repo file-name-all-completions"
  (it "returns user completions at /github: root"
    (spy-on 'remoto--search-users :and-return-value '("torvalds" "torgeirhelge"))
    (let ((completions (remoto--handle-file-name-all-completions "tor" "/github:")))
      (expect completions :to-equal '("torvalds/" "torgeirhelge/"))))

  (it "filters user results by prefix"
    (spy-on 'remoto--search-users :and-return-value '("torvalds" "torgeirhelge"))
    (let ((completions (remoto--handle-file-name-all-completions "torv" "/github:")))
      (expect completions :to-equal '("torvalds/"))))

  (it "returns nil for empty user query"
    (let ((completions (remoto--handle-file-name-all-completions "" "/github:")))
      (expect completions :to-be nil)))

  (it "returns repo completions at /github:owner/"
    (spy-on 'remoto--fetch-user-repos :and-return-value '("linux" "subsurface"))
    (let ((completions (remoto--handle-file-name-all-completions "" "/github:torvalds/")))
      (expect completions :to-equal '("linux" "subsurface"))))

  (it "filters repos by prefix"
    (spy-on 'remoto--fetch-user-repos :and-return-value '("linux" "subsurface"))
    (let ((completions (remoto--handle-file-name-all-completions "lin" "/github:torvalds/")))
      (expect completions :to-equal '("linux"))))

  (it "returns branch completions at repo@ directory"
    (spy-on 'remoto--fetch-branches :and-return-value '("main" "develop"))
    (let ((completions (remoto--handle-file-name-all-completions
                        "" "/github:torvalds/linux@")))
      (expect completions :to-equal '("main:" "develop:"))))

  (it "filters branches by prefix at repo@ directory"
    (spy-on 'remoto--fetch-branches :and-return-value '("main" "develop"))
    (let ((completions (remoto--handle-file-name-all-completions
                        "dev" "/github:torvalds/linux@")))
      (expect completions :to-equal '("develop:"))))

  (it "returns exact match for completed branch:"
    (let ((completions (remoto--handle-file-name-all-completions
                        "main:" "/github:torvalds/linux@")))
      (expect completions :to-equal '("main:"))))

  (it "falls through to tree-based completion for full canonical paths"
    (remoto-test-with-cache
      (let ((completions (remoto--handle-file-name-all-completions
                          "s" "/github:testowner/testrepo@main:/")))
        (expect (member "src/" completions) :to-be-truthy)))))

(describe "pre-repo file-name-completion"
  (it "returns common prefix for multiple matches"
    (spy-on 'remoto--search-users :and-return-value '("torvalds" "torgeirhelge"))
    (expect (remoto--handle-file-name-completion "tor" "/github:")
            :to-equal "tor"))

  (it "returns single match directly"
    (spy-on 'remoto--search-users :and-return-value '("torvalds"))
    (expect (remoto--handle-file-name-completion "tor" "/github:")
            :to-equal "torvalds/"))

  (it "returns nil for no matches"
    (spy-on 'remoto--search-users :and-return-value nil)
    (expect (remoto--handle-file-name-completion "zzz" "/github:")
            :to-be nil)))

;;; Dired integration

(describe "dired-noselect on remoto paths"
  (it "does not error on connection-local variables"
    (remoto-test-with-cache
      (let ((buf (dired-noselect "/github:testowner/testrepo@main:/")))
        (unwind-protect
            (progn
              (expect buf :to-be-truthy)
              (expect (buffer-live-p buf) :to-be-truthy)
              (with-current-buffer buf
                (expect major-mode :to-equal 'dired-mode)
                (expect (buffer-string) :to-match "README\\.md")))
          (kill-buffer buf))))))

;;; maybe-rewrite for partial canonical paths

(describe "remoto--maybe-rewrite with partial canonical paths"
  (it "rewrites /github:owner/repo to canonical path"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "torvalds/linux" "master" remoto--default-branch-cache)
      (expect (remoto--maybe-rewrite "/github:torvalds/linux")
              :to-equal "/github:torvalds/linux@master:/")))

  (it "rewrites /github:owner/repo@ref to canonical path"
    (expect (remoto--maybe-rewrite "/github:torvalds/linux@v6.5")
            :to-equal "/github:torvalds/linux@v6.5:/"))

  (it "leaves full canonical paths unchanged"
    (expect (remoto--maybe-rewrite "/github:torvalds/linux@master:/src")
            :to-equal "/github:torvalds/linux@master:/src"))

  (it "leaves non-github paths unchanged"
    (expect (remoto--maybe-rewrite "/home/user/file") :to-equal "/home/user/file")))

(provide 'remoto-tests)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-tests.el ends here
