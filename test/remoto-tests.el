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
;; Soft: present once remoto-embark.el exists; tests below fail (not error)
;; until then, keeping the rest of the suite runnable.
(require 'remoto-embark nil t)

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
         (remoto--dir-contents-cache (make-hash-table :test 'equal))
         (remoto--file-commits-cache (make-hash-table :test 'equal))
         (remoto--auth-failed nil)
         (remoto--authenticated-user nil))
     (puthash "testowner/testrepo" "main" remoto--default-branch-cache)
     (remoto-test--install-mock-tree)
     ,@body))

;;; JSON reader

(describe "remoto--json-reader"
  (it "parses a valid JSON object"
    (with-temp-buffer
      (insert "{\"foo\": 42}")
      (let ((result (remoto--json-reader nil)))
        (expect (alist-get 'foo result) :to-equal 42))))

  (it "skips HTTP headers before JSON body"
    (with-temp-buffer
      (insert "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\": true}")
      (let ((result (remoto--json-reader nil)))
        (expect (alist-get 'ok result) :to-equal t)
        (expect result :to-be-truthy))))

  (it "returns nil for HTML error pages instead of signaling"
    (with-temp-buffer
      (insert "<!DOCTYPE html><html><body>{not json at all</body></html>")
      (expect (remoto--json-reader nil) :to-be nil)))

  (it "returns nil for empty buffer"
    (with-temp-buffer
      (expect (remoto--json-reader nil) :to-be nil)))

  (it "returns arrays as lists"
    (with-temp-buffer
      (insert "[1, 2, 3]")
      (expect (remoto--json-reader nil) :to-equal '(1 2 3)))))

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

  (it "expand-file-name handles partial /github:owner/ dir"
    (expect (expand-file-name "somerepo" "/github:owner/")
            :to-equal "/github:owner/somerepo"))

  (it "expand-file-name handles partial /github:owner/repo@ dir"
    (expect (expand-file-name "main:" "/github:owner/repo@")
            :to-equal "/github:owner/repo@main:"))

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

;;; Forge URL building

(describe "remoto--forge-type"
  (it "maps the github prefix"
    (expect (remoto--forge-type "/github:o/r@main:/x.el") :to-be 'github))

  (it "maps the gh shorthand prefix"
    (expect (remoto--forge-type "/gh:o/r:/x.el") :to-be 'github))

  (it "returns nil for non-remoto input"
    (expect (remoto--forge-type "/home/me/x.el") :to-be nil)
    (expect (remoto--forge-type nil) :to-be nil)))

(describe "remoto--forge-url"
  (it "builds a blob URL with a single line"
    (expect (remoto--forge-url 'github 'blob "o" "r" "main" "src/main.el" 3 nil)
            :to-equal "https://github.com/o/r/blob/main/src/main.el#L3"))

  (it "builds a blob URL with a line range"
    (expect (remoto--forge-url 'github 'blob "o" "r" "main" "src/main.el" 2 4)
            :to-equal "https://github.com/o/r/blob/main/src/main.el#L2-L4"))

  (it "builds a blob URL with no line fragment"
    (expect (remoto--forge-url 'github 'blob "o" "r" "main" "src/main.el" nil nil)
            :to-equal "https://github.com/o/r/blob/main/src/main.el"))

  (it "builds a tree URL"
    (expect (remoto--forge-url 'github 'tree "o" "r" "main" "src" nil nil)
            :to-equal "https://github.com/o/r/tree/main/src"))

  (it "builds a blame URL with a line"
    (expect (remoto--forge-url 'github 'blame "o" "r" "main" "src/main.el" 3 nil)
            :to-equal "https://github.com/o/r/blame/main/src/main.el#L3"))

  (it "builds a raw URL"
    (expect (remoto--forge-url 'github 'raw "o" "r" "main" "src/main.el" nil nil)
            :to-equal "https://raw.githubusercontent.com/o/r/main/src/main.el"))

  (it "builds a history URL"
    (expect (remoto--forge-url 'github 'history "o" "r" "main" "src/main.el" nil nil)
            :to-equal "https://github.com/o/r/commits/main/src/main.el"))

  (it "builds the repo web URL"
    (expect (remoto--forge-url 'github 'repo "o" "r" nil nil nil nil)
            :to-equal "https://github.com/o/r"))

  (it "builds the SSH clone URL"
    (expect (remoto--forge-url 'github 'ssh "o" "r" nil nil nil nil)
            :to-equal "git@github.com:o/r.git"))

  (it "builds the HTTPS clone URL"
    (expect (remoto--forge-url 'github 'https "o" "r" nil nil nil nil)
            :to-equal "https://github.com/o/r.git"))

  (it "signals for an unknown forge"
    (expect (remoto--forge-url 'bogus 'blob "o" "r" "main" "x" nil nil)
            :to-throw 'user-error)))

;;; remoto--path-context and target classification

(describe "remoto--path-context"
  (it "classifies a repo root as remoto-repo without resolving the ref"
    (remoto-test-with-cache
      (let ((ctx (remoto--path-context "/github:testowner/testrepo:/")))
        (expect (plist-get ctx :type) :to-be 'remoto-repo)
        (expect (plist-get ctx :owner) :to-equal "testowner")
        (expect (plist-get ctx :repo) :to-equal "testrepo")
        ;; root targets stay unresolved (no ref/tree API needed)
        (expect (plist-get ctx :ref) :to-be nil)
        (expect (plist-get ctx :path) :to-equal ""))))

  (it "classifies a directory as remoto-dir"
    (remoto-test-with-cache
      (let ((ctx (remoto--path-context "/github:testowner/testrepo@main:/src")))
        (expect (plist-get ctx :type) :to-be 'remoto-dir)
        (expect (plist-get ctx :kind) :to-be 'tree)
        (expect (plist-get ctx :path) :to-equal "src"))))

  (it "classifies a file as remoto-file"
    (remoto-test-with-cache
      (let ((ctx (remoto--path-context "/github:testowner/testrepo@main:/src/main.el")))
        (expect (plist-get ctx :type) :to-be 'remoto-file)
        (expect (plist-get ctx :kind) :to-be 'blob)
        (expect (plist-get ctx :path) :to-equal "src/main.el"))))

  (it "keeps line info only for file targets"
    (remoto-test-with-cache
      (let ((file (remoto--path-context "/github:testowner/testrepo@main:/src/main.el" 5 7))
            (dir (remoto--path-context "/github:testowner/testrepo@main:/src" 5 7)))
        (expect (plist-get file :line-start) :to-be 5)
        (expect (plist-get file :line-end) :to-be 7)
        (expect (plist-get dir :line-start) :to-be nil)
        (expect (plist-get dir :line-end) :to-be nil))))

  (it "returns nil for a non-remoto path"
    (expect (remoto--path-context "/home/me/x.el") :to-be nil)))

(describe "remoto--context-web-url"
  (it "uses the repo web URL for a repo target"
    (remoto-test-with-cache
      (expect (remoto--context-web-url
               (remoto--path-context "/github:testowner/testrepo@main:/"))
              :to-equal "https://github.com/testowner/testrepo")))

  (it "uses the tree URL for a directory target"
    (remoto-test-with-cache
      (expect (remoto--context-web-url
               (remoto--path-context "/github:testowner/testrepo@main:/src"))
              :to-equal "https://github.com/testowner/testrepo/tree/main/src")))

  (it "uses the blob URL (with line) for a file target"
    (remoto-test-with-cache
      (expect (remoto--context-web-url
               (remoto--path-context "/github:testowner/testrepo@main:/src/main.el" 3 nil))
              :to-equal "https://github.com/testowner/testrepo/blob/main/src/main.el#L3"))))

;;; remoto-copy-url

(describe "remoto-copy-url"
  (it "copies file URL with line number from a file buffer"
    (remoto-test-with-cache
      (with-temp-buffer
        (insert "line1\nline2\nline3\n")
        (setq-local buffer-file-name "/github:testowner/testrepo@main:/src/main.el")
        (goto-char (point-min))
        (forward-line 2)
        (remoto-copy-url)
        (expect (car kill-ring)
                :to-equal "https://github.com/testowner/testrepo/blob/main/src/main.el#L3"))))

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
        (remoto-copy-url)
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
        (remoto-copy-url)
        (expect (car kill-ring)
                :to-equal "https://github.com/testowner/testrepo/tree/main/src"))))

  (it "copies file URL from dired with point on a file"
    (remoto-test-with-cache
      (with-temp-buffer
        (dired-mode)
        (setq-local dired-directory "/github:testowner/testrepo@main:/")
        (spy-on 'dired-get-filename :and-return-value
                "/github:testowner/testrepo@main:/README.md")
        (remoto-copy-url)
        (expect (car kill-ring)
                :to-equal "https://github.com/testowner/testrepo/blob/main/README.md"))))

  (it "falls back to dired-directory when point is not on a file"
    (remoto-test-with-cache
      (with-temp-buffer
        (dired-mode)
        (setq-local dired-directory "/github:testowner/testrepo@main:/")
        (spy-on 'dired-get-filename :and-return-value nil)
        (remoto-copy-url)
        (expect (car kill-ring)
                :to-equal "https://github.com/testowner/testrepo/tree/main/"))))

  (it "signals error outside remoto buffers"
    (with-temp-buffer
      (expect (remoto-copy-url) :to-throw 'user-error))))

(describe "remoto-copy-github-url (obsolete alias)"
  (it "still copies the file URL via the new command"
    (remoto-test-with-cache
      (with-temp-buffer
        (insert "line1\nline2\nline3\n")
        (setq-local buffer-file-name "/github:testowner/testrepo@main:/src/main.el")
        (goto-char (point-min))
        (forward-line 2)
        (remoto-copy-github-url)
        (expect (car kill-ring)
                :to-equal "https://github.com/testowner/testrepo/blob/main/src/main.el#L3")))))

;;; remoto-copy-blame-url

(describe "remoto-copy-blame-url"
  (it "copies the blame URL with the current line"
    (remoto-test-with-cache
      (with-temp-buffer
        (insert "line1\nline2\nline3\n")
        (setq-local buffer-file-name "/github:testowner/testrepo@main:/src/main.el")
        (goto-char (point-min))
        (forward-line 2)
        (remoto-copy-blame-url)
        (expect (car kill-ring)
                :to-equal "https://github.com/testowner/testrepo/blame/main/src/main.el#L3"))))

  (it "signals when invoked on a directory"
    (remoto-test-with-cache
      (with-temp-buffer
        (dired-mode)
        (setq-local dired-directory "/github:testowner/testrepo@main:/")
        (spy-on 'dired-get-filename :and-return-value
                "/github:testowner/testrepo@main:/src")
        (expect (remoto-copy-blame-url) :to-throw 'user-error)))))

;;; remoto-copy-permalink

(describe "remoto-copy-permalink"
  (it "copies a URL pinned to the resolved commit SHA"
    (remoto-test-with-cache
      (spy-on 'remoto--api :and-return-value '((sha . "abc123def456")))
      (with-temp-buffer
        (insert "line1\nline2\nline3\n")
        (setq-local buffer-file-name "/github:testowner/testrepo@main:/src/main.el")
        (goto-char (point-min))
        (forward-line 2)
        (remoto-copy-permalink)
        (expect (car kill-ring)
                :to-equal
                "https://github.com/testowner/testrepo/blob/abc123def456/src/main.el#L3")))))

;;; remoto-copy-raw-url

(describe "remoto-copy-raw-url"
  (it "copies the raw content URL for a file"
    (remoto-test-with-cache
      (with-temp-buffer
        (setq-local buffer-file-name "/github:testowner/testrepo@main:/src/main.el")
        (remoto-copy-raw-url)
        (expect (car kill-ring)
                :to-equal
                "https://raw.githubusercontent.com/testowner/testrepo/main/src/main.el"))))

  (it "signals when invoked on a directory"
    (remoto-test-with-cache
      (with-temp-buffer
        (dired-mode)
        (setq-local dired-directory "/github:testowner/testrepo@main:/")
        (spy-on 'dired-get-filename :and-return-value
                "/github:testowner/testrepo@main:/src")
        (expect (remoto-copy-raw-url) :to-throw 'user-error)))))

;;; remoto-copy-history-url

(describe "remoto-copy-history-url"
  (it "copies the file history URL"
    (remoto-test-with-cache
      (with-temp-buffer
        (setq-local buffer-file-name "/github:testowner/testrepo@main:/src/main.el")
        (remoto-copy-history-url)
        (expect (car kill-ring)
                :to-equal "https://github.com/testowner/testrepo/commits/main/src/main.el"))))

  (it "copies the directory history URL from dired"
    (remoto-test-with-cache
      (with-temp-buffer
        (dired-mode)
        (setq-local dired-directory "/github:testowner/testrepo@main:/")
        (spy-on 'dired-get-filename :and-return-value
                "/github:testowner/testrepo@main:/src")
        (remoto-copy-history-url)
        (expect (car kill-ring)
                :to-equal "https://github.com/testowner/testrepo/commits/main/src")))))

;;; remoto-browse-url

(describe "remoto-browse-url"
  (it "opens the file web page in a browser"
    (remoto-test-with-cache
      (spy-on 'browse-url)
      (with-temp-buffer
        (insert "line1\nline2\nline3\n")
        (setq-local buffer-file-name "/github:testowner/testrepo@main:/src/main.el")
        (goto-char (point-min))
        (forward-line 2)
        (remoto-browse-url)
        (expect 'browse-url :to-have-been-called-with
                "https://github.com/testowner/testrepo/blob/main/src/main.el#L3")))))

;;; remoto-mode

(describe "remoto-mode"
  (it "toggles on and off"
    (with-temp-buffer
      (remoto-mode 1)
      (expect remoto-mode :to-be-truthy)
      (remoto-mode -1)
      (expect remoto-mode :to-be nil)))

  (it "auto-enables for a remoto file path"
    (with-temp-buffer
      (setq-local buffer-file-name "/github:o/r@main:/x.el")
      (remoto--maybe-enable-mode)
      (expect remoto-mode :to-be-truthy)
      (remoto-mode -1)))

  (it "does not enable for a normal file path"
    (with-temp-buffer
      (setq-local buffer-file-name "/home/me/x.el")
      (remoto--maybe-enable-mode)
      (expect remoto-mode :to-be nil)))

  (it "leaves remoto-mode-map empty (no reserved C-c LETTER bindings)"
    (expect (keymapp remoto-mode-map) :to-be-truthy)
    (expect remoto-mode-map :to-equal (make-sparse-keymap))
    (expect (lookup-key remoto-mode-map (kbd "C-c")) :to-be nil))

  (it "groups the url commands in remoto-command-map"
    (expect (keymapp remoto-command-map) :to-be-truthy)
    (expect (lookup-key remoto-command-map "u") :to-be 'remoto-copy-url)
    (expect (lookup-key remoto-command-map "b") :to-be 'remoto-copy-blame-url)
    (expect (lookup-key remoto-command-map "p") :to-be 'remoto-copy-permalink)
    (expect (lookup-key remoto-command-map "r") :to-be 'remoto-copy-raw-url)
    (expect (lookup-key remoto-command-map "h") :to-be 'remoto-copy-history-url)
    (expect (lookup-key remoto-command-map "w") :to-be 'remoto-browse-url)))

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

  (it "populates cache via async callback"
    (spy-on 'remoto--debounce :and-call-fake (lambda (_key fn) (funcall fn)))
    (spy-on 'remoto--api-async :and-call-fake
            (lambda (_endpoint callback)
              (funcall callback '((items . (((full_name . "torvalds/linux"))
                                            ((full_name . "torvalds/subsurface"))))))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      ;; First call triggers async, returns nil (cache empty)
      (remoto--search-repos "torvalds")
      ;; Cache now populated; second call returns results
      (expect (remoto--search-repos "torvalds")
              :to-equal '("torvalds/linux" "torvalds/subsurface"))))

  (it "returns cached results without scheduling async"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (puthash "torvalds" (cons (float-time) '("torvalds/linux"))
               remoto--search-cache)
      (expect (remoto--search-repos "torvalds")
              :to-equal '("torvalds/linux"))
      (expect 'remoto--debounce :not :to-have-been-called)))

  (it "delegates an owner/repo-prefix query to the shared owner-repos engine"
    (spy-on 'remoto--search-owner-repos :and-return-value
            '("spacehammer" "spaceship"))
    (expect (remoto--search-repos "agzam/space")
            :to-equal '("agzam/spacehammer" "agzam/spaceship"))
    (expect 'remoto--search-owner-repos
            :to-have-been-called-with "agzam" "space"))

  (it "delegates an owner/ query (no repo part) to recent-owner-repos"
    (spy-on 'remoto--recent-owner-repos :and-return-value '("dotfiles"))
    (expect (remoto--search-repos "agzam/")
            :to-equal '("agzam/dotfiles"))
    (expect 'remoto--recent-owner-repos :to-have-been-called-with "agzam"))

  (it "performs the precise owner search even when a capped parent is cached"
    ;; Regression: a cached owner/ listing (user:owner, capped at the page
    ;; size) previously short-circuited and hid repos beyond the cap (e.g.
    ;; qlik-trial/stitch-*).  Delegating to remoto--search-owner-repos, which
    ;; always issues the precise query, makes that impossible.
    (spy-on 'remoto--search-owner-repos :and-return-value
            '("stitch-environments" "stitch-agent-service"))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (puthash "qlik-trial/"
               (cons (float-time) '("qlik-trial/aaa" "qlik-trial/bbb"))
               remoto--search-cache)
      (expect (remoto--search-repos "qlik-trial/stitch-")
              :to-equal '("qlik-trial/stitch-environments"
                          "qlik-trial/stitch-agent-service"))
      (expect 'remoto--search-owner-repos
              :to-have-been-called-with "qlik-trial" "stitch-")))

  (it "schedules async for non-narrowable cache miss"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      ;; "agz" has no cache and no parent - schedules async
      (expect (remoto--search-repos "agz") :to-be nil)
      (expect 'remoto--debounce :to-have-been-called)))

  (it "returns nil on cache miss (async pending)"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (expect (remoto--search-repos "torvalds") :to-be nil)))

  (it "expires cache entries after TTL"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-search-cache-ttl 1))
      ;; Populate cache with backdated timestamp
      (puthash "torvalds" (cons (- (float-time) 10) '("torvalds/linux"))
               remoto--search-cache)
      ;; Expired entry should not be returned
      (spy-on 'remoto--debounce)
      (expect (remoto--search-repos "torvalds") :to-be nil)))

  (it "caches empty results without re-scheduling async"
    (spy-on 'remoto--debounce :and-call-fake (lambda (_key fn) (funcall fn)))
    (spy-on 'remoto--api-async :and-call-fake
            (lambda (_endpoint callback)
              (funcall callback '((items)))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      ;; First call: async populates cache with nil results
      (remoto--search-repos "zzzznotfound")
      ;; Reset spy to track second call
      (spy-on 'remoto--debounce)
      ;; Second call hits cache (empty results)
      (remoto--search-repos "zzzznotfound")
      (expect 'remoto--debounce :not :to-have-been-called)))

  (it "delivers results via callback when provided"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (captured nil))
      ;; Pre-populate cache so search-repos-fetch returns immediately
      (puthash "torvalds" (cons (float-time) '("torvalds/linux"))
               remoto--search-cache)
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

  (it "returns metadata with category for plain search"
    (let ((meta (remoto--repo-completion-table "" nil 'metadata)))
      (expect (alist-get 'category (cdr meta)) :to-equal 'remoto-browse)))

  (it "returns issue metadata for # mode"
    (let ((meta (remoto--repo-completion-table "foo/bar#" nil 'metadata)))
      (expect (alist-get 'group-function (cdr meta)) :to-be-truthy)
      (expect (alist-get 'affixation-function (cdr meta)) :to-be-truthy)))

  (it "returns branch metadata for @ mode"
    (let ((meta (remoto--repo-completion-table "foo/bar@" nil 'metadata)))
      (expect (alist-get 'group-function (cdr meta)) :to-be-truthy)))

  (it "returns issue completions for # delimiter"
    (spy-on 'remoto--fetch-issues :and-return-value
            '(((number . 42) (title . "Fix bug") (state . "open"))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((result (remoto--repo-completion-table "foo/bar#" nil t)))
        (expect (length result) :to-equal 1)
        (expect (car result) :to-match "#42"))))

  (it "returns branch completions for @ delimiter"
    (spy-on 'remoto--fetch-branches :and-return-value '("main" "develop"))
    (spy-on 'remoto--fetch-tags :and-return-value '("v1.0"))
    (let ((result (remoto--repo-completion-table "foo/bar@" nil t)))
      (expect (length result) :to-equal 3)
      (expect (seq-some (lambda (r) (string-match-p "@main" r)) result) :to-be-truthy)
      (expect (seq-some (lambda (r) (string-match-p "@v1.0" r)) result) :to-be-truthy)))

  (it "filters branches by prefix after @"
    (spy-on 'remoto--fetch-branches :and-return-value '("main" "develop"))
    (spy-on 'remoto--fetch-tags :and-return-value nil)
    (let ((result (remoto--repo-completion-table "foo/bar@dev" nil t)))
      (expect (length result) :to-equal 1)
      (expect (car result) :to-match "@develop")))

  (it "issue completions carry text properties"
    (spy-on 'remoto--fetch-issues :and-return-value
            '(((number . 99) (title . "Important PR") (state . "open")
               (pull_request (url . "http://...")))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let* ((result (remoto--repo-completion-table "foo/bar#" nil t))
             (c (car result)))
        (expect (get-text-property 0 'remoto-topic-pr c) :to-be-truthy)
        (expect (get-text-property 0 'remoto-topic-title c) :to-equal "Important PR"))))

  (it "returns file completions for / delimiter"
    (spy-on 'remoto--default-branch :and-return-value "main")
    (spy-on 'remoto--fetch-dir-children-light :and-return-value
            '(("README.md" . ((type . "blob") (size . 500)))
              ("src" . ((type . "tree") (size . 0)))))
    (let ((result (remoto--repo-completion-table "foo/bar/" nil t)))
      (expect (length result) :to-equal 2)
      (expect (seq-some (lambda (r) (string-suffix-p "README.md" r)) result)
              :to-be-truthy)
      (expect (seq-some (lambda (r) (string-suffix-p "src/" r)) result)
              :to-be-truthy)))

  (it "search results carry repo descriptions"
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      ;; Pre-populate cache with propertized results (as async would)
      (puthash "torvalds"
               (cons (float-time)
                     (list (propertize "torvalds/linux"
                                       'remoto-repo-desc "Linux kernel")))
               remoto--search-cache)
      (let ((result (remoto--repo-completion-table "torvalds" nil t)))
        (expect (car result) :to-equal "torvalds/linux")
        (expect (get-text-property 0 'remoto-repo-desc (car result))
                :to-equal "Linux kernel")))))

(describe "remoto--browse-parse-input"
  (it "parses plain search"
    (pcase-let ((`(,mode ,owner ,repo ,query)
                 (remoto--browse-parse-input "torvalds")))
      (expect mode :to-equal 'search)
      (expect owner :to-be nil)
      (expect query :to-equal "torvalds")))

  (it "parses @ mode"
    (pcase-let ((`(,mode ,owner ,repo ,query)
                 (remoto--browse-parse-input "foo/bar@main")))
      (expect mode :to-equal 'branches)
      (expect owner :to-equal "foo")
      (expect repo :to-equal "bar")
      (expect query :to-equal "main")))

  (it "parses # mode"
    (pcase-let ((`(,mode ,owner ,repo ,query)
                 (remoto--browse-parse-input "foo/bar#42")))
      (expect mode :to-equal 'issues)
      (expect owner :to-equal "foo")
      (expect repo :to-equal "bar")
      (expect query :to-equal "42")))

  (it "parses empty # query"
    (pcase-let ((`(,mode ,_o ,_r ,query)
                 (remoto--browse-parse-input "foo/bar#")))
      (expect mode :to-equal 'issues)
      (expect query :to-equal "")))

  (it "parses empty @ query"
    (pcase-let ((`(,mode ,_o ,_r ,query)
                 (remoto--browse-parse-input "foo/bar@")))
      (expect mode :to-equal 'branches)
      (expect query :to-equal "")))

  (it "parses / mode"
    (pcase-let ((`(,mode ,owner ,repo ,query)
                 (remoto--browse-parse-input "foo/bar/")))
      (expect mode :to-equal 'files)
      (expect owner :to-equal "foo")
      (expect repo :to-equal "bar")
      (expect query :to-equal "")))

  (it "parses / mode with subpath"
    (pcase-let ((`(,mode ,owner ,repo ,query)
                 (remoto--browse-parse-input "foo/bar/src/main.el")))
      (expect mode :to-equal 'files)
      (expect owner :to-equal "foo")
      (expect repo :to-equal "bar")
      (expect query :to-equal "src/main.el")))

  (it "handles repo with dots in # mode"
    (pcase-let ((`(,mode ,owner ,repo ,query)
                 (remoto--browse-parse-input "agzam/remoto.el#")))
      (expect mode :to-equal 'issues)
      (expect repo :to-equal "remoto.el"))))

(describe "remoto--require-topic"
  (it "loads remoto-topic from the package directory"
    (let ((loaded nil))
      (spy-on 'require :and-call-fake
              (lambda (feature &rest _) (when (eq feature 'remoto-topic) (setq loaded t))))
      (let ((featurep-orig (symbol-function 'featurep)))
        (cl-letf (((symbol-function 'featurep)
                   (lambda (f &rest r)
                     (if (eq f 'remoto-topic) nil
                       (apply featurep-orig f r)))))
          (remoto--require-topic)
          (expect loaded :to-be t))))))

(describe "remoto-browse issue dispatch"
  (it "calls remoto-topic-display for #NUM input"
    (spy-on 'remoto-topic-display :and-return-value (generate-new-buffer "*test*"))
    (spy-on 'remoto--require-topic)
    (remoto-browse "foo/bar#42")
    (expect 'remoto-topic-display :to-have-been-called-with
            "42" "/github:foo/bar")
    (kill-buffer "*test*"))

  (it "opens dired for plain owner/repo"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--tree-cache (make-hash-table :test 'equal)))
      (puthash "torvalds/linux" "master" remoto--default-branch-cache)
      (spy-on 'remoto--fetch-tree :and-return-value (make-hash-table :test 'equal))
      (spy-on 'dired)
      (spy-on 'remoto--tree-entry :and-return-value '((type . "tree")))
      (remoto-browse "torvalds/linux")
      (expect 'dired :to-have-been-called)))

  (it "opens dired for owner/repo@ref"
    (spy-on 'dired)
    (spy-on 'remoto--tree-entry :and-return-value '((type . "tree")))
    (remoto-browse "torvalds/linux@v6.5")
    (expect 'dired :to-have-been-called))

  (it "opens dired for owner/repo/ files mode"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "testowner/testrepo" "main" remoto--default-branch-cache)
      (spy-on 'dired)
      (spy-on 'remoto--tree-entry :and-return-value '((type . "tree")))
      (remoto-browse "testowner/testrepo/")
      (expect 'dired :to-have-been-called)))

  (it "opens file for owner/repo/path/file.el"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "testowner/testrepo" "main" remoto--default-branch-cache)
      (spy-on 'find-file)
      (spy-on 'remoto--tree-entry :and-return-value '((type . "blob")))
      (remoto-browse "testowner/testrepo/src/main.el")
      (expect 'find-file :to-have-been-called))))

(describe "remoto--read-repo"
  (it "returns completing-read result directly"
    (spy-on 'completing-read :and-return-value "torvalds/linux")
    (expect (remoto--read-repo) :to-equal "torvalds/linux"))

  (it "allows URLs as direct input"
    (spy-on 'completing-read :and-return-value "https://github.com/torvalds/linux")
    (expect (remoto--read-repo) :to-equal "https://github.com/torvalds/linux"))

  (it "allows owner/repo@ref as direct input"
    (spy-on 'completing-read :and-return-value "agzam/remoto.el@dont-use-gh")
    (expect (remoto--read-repo) :to-equal "agzam/remoto.el@dont-use-gh"))

  (it "allows owner/repo#NUM as direct input"
    (spy-on 'completing-read :and-return-value "agzam/remoto.el#42")
    (expect (remoto--read-repo) :to-equal "agzam/remoto.el#42")))

(describe "remoto--browse-metadata"
  (it "provides affixation for search mode with repo descriptions"
    (let ((meta (remoto--browse-metadata "torvalds")))
      (expect (alist-get 'category (cdr meta)) :to-equal 'remoto-browse)
      (expect (alist-get 'affixation-function (cdr meta)) :to-be-truthy)))

  (it "affixation shows repo descriptions in search mode"
    (let* ((meta (remoto--browse-metadata "torvalds"))
           (affix-fn (alist-get 'affixation-function (cdr meta)))
           (candidates (list (propertize "torvalds/linux"
                                         'remoto-repo-desc "Unix-like OS kernel")))
           (result (funcall affix-fn candidates)))
      (expect (length result) :to-equal 1)
      (expect (car (car result)) :to-equal "torvalds/linux")
      ;; suffix should contain the description
      (expect (nth 2 (car result)) :to-match "Unix-like OS kernel")))

  (it "provides affixation for issues mode"
    (let ((meta (remoto--browse-metadata "foo/bar#")))
      (expect (alist-get 'affixation-function (cdr meta)) :to-be-truthy)
      (expect (alist-get 'group-function (cdr meta)) :to-be-truthy)))

  (it "provides grouping for branches mode"
    (let ((meta (remoto--browse-metadata "foo/bar@")))
      (expect (alist-get 'group-function (cdr meta)) :to-be-truthy))))

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

    (it "signals user-error on auth error instead of silent fallback"
      (let ((remoto--auth-failed nil)
            (remoto--effective-auth nil)
            (remoto-github-auth nil)
            (remoto-auth-timeout 5))
        (spy-on 'ghub-get :and-call-fake
                (lambda (_resource &optional _params &rest _args)
                  (error "Package ghub requires a Github API token")))
        (spy-on 'remoto--find-github-token :and-return-value nil)
        (expect (remoto--api "repos/owner/repo")
                :to-throw 'user-error)))

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

(describe "remoto--json-reader"
  (it "parses valid JSON"
    (with-temp-buffer
      (insert "{\"login\": \"agzam\"}")
      (expect (remoto--json-reader nil)
              :to-equal '((login . "agzam")))))

  (it "returns nil for buffers with no JSON delimiters"
    (with-temp-buffer
      (insert "plain text no braces")
      (expect (remoto--json-reader nil) :to-be nil)))

  (it "returns nil on malformed JSON"
    (with-temp-buffer
      (insert "{broken")
      (expect (remoto--json-reader nil) :to-be nil)))

  (it "returns nil on truncated JSON"
    (with-temp-buffer
      (insert "{\"name\": ")
      (expect (remoto--json-reader nil) :to-be nil))))

(describe "remoto--ghub-get json-error handling"
  (it "translates json-parse-error to user-error"
    (spy-on 'ghub-get :and-call-fake
            (lambda (_resource &optional _params &rest _args)
              (signal 'json-parse-error '("unexpected character"))))
    (expect (remoto--ghub-get "/repos/owner/repo" 'none "repos/owner/repo")
            :to-throw 'user-error))

  (it "translates json-end-of-file to user-error"
    (spy-on 'ghub-get :and-call-fake
            (lambda (_resource &optional _params &rest _args)
              (signal 'json-end-of-file '("premature end"))))
    (expect (remoto--ghub-get "/repos/owner/repo" 'none "repos/owner/repo")
            :to-throw 'user-error)))

(describe "remoto--find-github-token"
  (it "finds token at api.github.com with ^forge suffix"
    (spy-on 'ghub--username :and-return-value "testuser")
    (spy-on 'auth-source-search :and-call-fake
            (lambda (&rest args)
              (let ((host (plist-get args :host))
                    (user (plist-get args :user)))
                (when (and (equal host "api.github.com")
                           (equal user "testuser^forge"))
                  (list (list :secret "ghp_found_token"))))))
    (expect (remoto--find-github-token) :to-equal "ghp_found_token"))

  (it "returns nil when no token found anywhere"
    (spy-on 'ghub--username :and-return-value "testuser")
    (spy-on 'auth-source-search :and-return-value nil)
    (expect (remoto--find-github-token) :to-be nil))

  (it "returns nil when username cannot be determined"
    (spy-on 'ghub--username :and-call-fake
            (lambda (&rest _) (error "Cannot determine username")))
    (expect (remoto--find-github-token) :to-be nil)))

(describe "remoto--warm-auth"
  (it "caches authenticated user and token on success"
    (let ((remoto--authenticated-user nil)
          (remoto--auth-failed nil)
          (remoto--effective-auth nil))
      (spy-on 'remoto--find-github-token :and-return-value "ghp_fake_token")
      (spy-on 'ghub-get :and-return-value '((login . "agzam")))
      (spy-on 'message)
      (remoto--warm-auth)
      (expect remoto--authenticated-user :to-equal "agzam")
      (expect remoto--effective-auth :to-equal "ghp_fake_token")
      (expect remoto--auth-failed :to-be nil)))

  (it "does not set auth-failed when no token found"
    (let ((remoto--authenticated-user nil)
          (remoto--auth-failed nil)
          (remoto--effective-auth nil)
          (remoto-github-auth nil))
      (spy-on 'remoto--find-github-token :and-return-value nil)
      (spy-on 'message)
      (remoto--warm-auth)
      ;; warm-auth is opportunistic; missing token should NOT lock out
      ;; auth permanently - remoto--api will try ghub's own resolution.
      (expect remoto--auth-failed :to-be nil)
      (expect remoto--authenticated-user :to-be nil)))

  (it "sets auth-failed when API call fails with found token"
    (let ((remoto--authenticated-user nil)
          (remoto--auth-failed nil)
          (remoto--effective-auth nil))
      (spy-on 'remoto--find-github-token :and-return-value "ghp_bad_token")
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (error "401 Unauthorized")))
      (spy-on 'message)
      (remoto--warm-auth)
      (expect remoto--auth-failed :to-be-truthy)
      (expect remoto--effective-auth :to-be nil)))

  (it "skips when user already cached"
    (let ((remoto--authenticated-user "agzam")
          (remoto--auth-failed nil))
      (spy-on 'remoto--find-github-token)
      (remoto--warm-auth)
      (expect 'remoto--find-github-token :not :to-have-been-called)))

  (it "skips when auth already failed"
    (let ((remoto--authenticated-user nil)
          (remoto--auth-failed t))
      (spy-on 'remoto--find-github-token)
      (remoto--warm-auth)
      (expect 'remoto--find-github-token :not :to-have-been-called)))

  (it "uses literal remoto-github-auth string directly"
    (let ((remoto--authenticated-user nil)
          (remoto--auth-failed nil)
          (remoto--effective-auth nil)
          (remoto-github-auth "ghp_explicit_token"))
      (spy-on 'remoto--find-github-token)
      (spy-on 'ghub-get :and-return-value '((login . "agzam")))
      (remoto--warm-auth)
      (expect 'remoto--find-github-token :not :to-have-been-called)
      (expect remoto--effective-auth :to-equal "ghp_explicit_token"))))

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

;;; /gh: shorthand alias

(describe "/gh: shorthand alias"
  (it "normalizes a /gh: prefix to canonical /github:"
    (expect (remoto--normalize-shorthand "/gh:foobar/zapzop@main:/f.el")
            :to-equal "/github:foobar/zapzop@main:/f.el"))

  (it "leaves canonical /github: paths unchanged"
    (expect (remoto--normalize-shorthand "/github:foobar/")
            :to-equal "/github:foobar/"))

  (it "leaves unrelated strings unchanged"
    (expect (remoto--normalize-shorthand "/etc/passwd") :to-equal "/etc/passwd"))

  (it "passes non-string arguments through untouched"
    (expect (remoto--normalize-shorthand 42) :to-equal 42))

  (it "handler regexp matches /gh: at the start"
    (expect (string-match-p remoto--handler-regexp "/gh:foobar/") :to-be 0))

  (it "handler regexp still matches canonical /github:"
    (expect (string-match-p remoto--handler-regexp "/github:foobar/") :to-be 0))

  (it "handler regexp does not match lookalike prefixes"
    (expect (string-match-p remoto--handler-regexp "/ghostly:x") :to-be nil))

  (it "dispatches file-directory-p for /gh: like /github:"
    (expect (remoto-file-name-handler 'file-directory-p "/gh:") :to-be t))

  (it "dispatches file-exists-p for /gh:owner/ like /github:owner/"
    (expect (remoto-file-name-handler 'file-exists-p "/gh:foobar/") :to-be t))

  (it "file-remote-p on /gh: returns the canonical /github: prefix"
    (expect (remoto-file-name-handler 'file-remote-p "/gh:foobar/")
            :to-equal "/github:"))

  (it "file-remote-p method on /gh: is github"
    (expect (remoto-file-name-handler 'file-remote-p "/gh:foobar/" 'method)
            :to-equal "github"))

  (it "file-name-directory normalizes /gh: to /github:"
    (expect (remoto-file-name-handler 'file-name-directory "/gh:foobar/zapzop")
            :to-equal "/github:foobar/"))

  (it "routes /gh: through the public file API like /github:"
    (expect (file-remote-p "/gh:foobar/" 'method) :to-equal "github")
    (expect (file-remote-p "/gh:foobar/")
            :to-equal (file-remote-p "/github:foobar/"))))

;;; User search

(describe "remoto--search-users"
  (it "returns nil for queries below min-search-chars"
    (let ((remoto-min-search-chars 3))
      (expect (remoto--search-users "") :to-be nil)
      (expect (remoto--search-users "a") :to-be nil)
      (expect (remoto--search-users "ab") :to-be nil)))

  (it "schedules async fetch on cache miss, returns nil"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto--users-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      (expect (remoto--search-users "tor") :to-be nil)
      (expect 'remoto--debounce :to-have-been-called)))

  (it "populates cache via async callback"
    ;; Make debounce execute immediately, mock api-async to invoke callback
    (spy-on 'remoto--debounce :and-call-fake (lambda (_key fn) (funcall fn)))
    (spy-on 'remoto--api-async :and-call-fake
            (lambda (_endpoint callback)
              (funcall callback '((items . (((login . "torvalds") (type . "User"))
                                            ((login . "torgeirhelge") (type . "User"))))))))
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto--users-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      ;; First call: triggers async, returns nil
      (remoto--search-users "tor")
      ;; Cache should now be populated by the callback
      (expect (remoto--search-users "tor")
              :to-equal '("torvalds" "torgeirhelge"))))

  (it "returns cached results without async call"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto--users-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      ;; Pre-populate cache
      (puthash "\0users:tor" (cons (float-time) '("torvalds" "torgeirhelge"))
               remoto--search-cache)
      (expect (remoto--search-users "tor")
              :to-equal '("torvalds" "torgeirhelge"))
      ;; Should not have scheduled any async fetch
      (expect 'remoto--debounce :not :to-have-been-called)))

  (it "narrows cached results for longer prefixes without API call"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto--users-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      ;; Seed the users-cache with a shorter query
      (puthash "tor" (cons (float-time) '("torvalds" "torgeirhelge"))
               remoto--users-cache)
      (let ((result (remoto--search-users "torv")))
        (expect result :to-equal '("torvalds"))
        (expect 'remoto--debounce :not :to-have-been-called)))))

;;; Owner repo search

(describe "remoto--search-owner-repos"
  (it "returns nil for empty query"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      (expect (remoto--search-owner-repos "torvalds" "") :to-be nil)))

  (it "narrows from recent-repos cache below min-search-chars"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3)
          (remoto-repo-cache-ttl 1800))
      ;; Seed recent-repos cache
      (puthash "\0repos-recent:torvalds"
               (cons (float-time) '("linux" "libfdt" "subsurface"))
               remoto--search-cache)
      ;; Short query ("li") narrows from recent cache
      (expect (remoto--search-owner-repos "torvalds" "li")
              :to-equal '("linux" "libfdt"))))

  (it "schedules async fetch on cache miss"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      (expect (remoto--search-owner-repos "torvalds" "lin") :to-be nil)
      (expect 'remoto--debounce :to-have-been-called)))

  (it "populates cache via async callback"
    (spy-on 'remoto--debounce :and-call-fake (lambda (_key fn) (funcall fn)))
    (spy-on 'remoto--api-async :and-call-fake
            (lambda (_endpoint callback)
              (funcall callback '((items . (((name . "linux"))
                                            ((name . "libfdt"))))))))
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      (remoto--search-owner-repos "torvalds" "lin")
      ;; Cache now populated
      (expect (remoto--search-owner-repos "torvalds" "lin")
              :to-equal '("linux" "libfdt"))))

  (it "returns cached results without async call"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      (puthash "\0repos:torvalds/lin"
               (cons (float-time) '("linux" "libfdt"))
               remoto--search-cache)
      (expect (remoto--search-owner-repos "torvalds" "lin")
              :to-equal '("linux" "libfdt"))
      (expect 'remoto--debounce :not :to-have-been-called)))

  (it "narrows cached results for longer query"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      ;; Seed with shorter query
      (puthash "\0repos:torvalds/li"
               (cons (float-time) '("linux" "libfdt"))
               remoto--search-cache)
      (let ((result (remoto--search-owner-repos "torvalds" "lin")))
        (expect result :to-equal '("linux"))
        (expect 'remoto--debounce :not :to-have-been-called)))))

(describe "remoto--extract-search-repos"
  (it "extracts repo names with description properties"
    (let* ((data '((items . (((name . "linux") (description . "kernel"))
                              ((name . "uemacs") (description . nil))))))
           (repos (remoto--extract-search-repos data)))
      (expect (length repos) :to-equal 2)
      (expect (car repos) :to-equal "linux")
      (expect (get-text-property 0 'remoto-repo-desc (car repos))
              :to-equal "kernel")
      (expect (get-text-property 0 'remoto-repo-desc (cadr repos))
              :to-equal "")))

  (it "uses alternate name key when provided"
    (let* ((data '((items . (((full_name . "torvalds/linux")
                               (description . "kernel"))))))
           (repos (remoto--extract-search-repos data 'full_name)))
      (expect (car repos) :to-equal "torvalds/linux"))))

(describe "remoto--search-owner-repos-sync"
  (it "returns repos and populates cache on success"
    (spy-on 'remoto--api :and-return-value
            '((items . (((name . "linux") (description . "kernel"))
                         ((name . "libfdt") (description . ""))))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((result (remoto--search-owner-repos-sync "torvalds" "lin")))
        (expect (length result) :to-equal 2)
        (expect (car result) :to-equal "linux")
        ;; Cache should be warm now
        (pcase-let ((`(,hit ,cached) (remoto--search-cache-get
                                       "\0repos:torvalds/lin")))
          (expect hit :to-be-truthy)
          (expect (length cached) :to-equal 2)))))

  (it "returns nil on API error without signaling"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_) (error "network error")))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (expect (remoto--search-owner-repos-sync "torvalds" "lin")
              :to-be nil))))

(describe "remoto--recent-owner-repos-sync"
  (it "returns repos and populates cache on success"
    (spy-on 'remoto--api :and-return-value
            '((items . (((name . "linux") (description . "kernel"))))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((result (remoto--recent-owner-repos-sync "torvalds")))
        (expect (length result) :to-equal 1)
        (expect (car result) :to-equal "linux")
        ;; Cache should be warm
        (pcase-let ((`(,hit ,_) (remoto--search-cache-get
                                  "\0repos-recent:torvalds"
                                  remoto-repo-cache-ttl)))
          (expect hit :to-be-truthy)))))

  (it "returns nil on API error without signaling"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_) (error "network error")))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (expect (remoto--recent-owner-repos-sync "torvalds")
              :to-be nil))))

(describe "owner-level sync fallback in file-name-all-completions"
  (it "falls back to sync search when async returns nil"
    (spy-on 'remoto--search-owner-repos :and-return-value nil)
    (spy-on 'remoto--search-owner-repos-sync :and-return-value '("linux"))
    (let ((completions (remoto--handle-file-name-all-completions
                        "lin" "/github:torvalds/")))
      (expect completions :to-equal '("linux/"))
      (expect 'remoto--search-owner-repos-sync
              :to-have-been-called-with "torvalds" "lin")))

  (it "falls back to sync recent repos when async returns nil"
    (spy-on 'remoto--recent-owner-repos :and-return-value nil)
    (spy-on 'remoto--recent-owner-repos-sync :and-return-value '("linux"))
    (let ((completions (remoto--handle-file-name-all-completions
                        "" "/github:torvalds/")))
      (expect completions :to-equal '("linux/"))
      (expect 'remoto--recent-owner-repos-sync
              :to-have-been-called-with "torvalds")))

  (it "skips sync fallback when async has results"
    (spy-on 'remoto--search-owner-repos :and-return-value '("linux"))
    (spy-on 'remoto--search-owner-repos-sync)
    (let ((completions (remoto--handle-file-name-all-completions
                        "lin" "/github:torvalds/")))
      (expect completions :to-equal '("linux/"))
      (expect 'remoto--search-owner-repos-sync :not :to-have-been-called)))

  (it "skips sync search below min-search-chars"
    (let ((remoto-min-search-chars 3))
      (spy-on 'remoto--search-owner-repos :and-return-value nil)
      (spy-on 'remoto--search-owner-repos-sync)
      (remoto--handle-file-name-all-completions "li" "/github:torvalds/")
      (expect 'remoto--search-owner-repos-sync :not :to-have-been-called))))

(describe "completion-category-overrides registration"
  (it "registers remoto category with partial-completion style"
    (let ((entry (assq 'remoto completion-category-overrides)))
      (expect entry :to-be-truthy)
      (expect (cdr (assq 'styles (cdr entry)))
              :to-equal '(partial-completion basic)))))

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

;;; Partial path file operations - repo@ level

(describe "repo@ level partial path operations"
  (it "file-exists-p returns nil for /github:owner/repo@ (delimiter without selection)"
    (expect (remoto--handle-file-exists-p "/github:foobar/zapzop@") :not :to-be-truthy))

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

      ;; Step 2: /github:torvalds/ + "lin" -> repo completions (with trailing /)
      (spy-on 'remoto--search-owner-repos :and-return-value '("linux"))
      (let ((repos (remoto--handle-file-name-all-completions "lin" "/github:torvalds/")))
        (expect repos :to-equal '("linux/")))

      ;; Step 3: verify path splitting for orderless at repo@ boundary
      (expect (remoto--handle-file-name-directory "/github:torvalds/linux@")
              :to-equal "/github:torvalds/linux@")
      (expect (remoto--handle-file-name-nondirectory "/github:torvalds/linux@")
              :to-equal "")

      ;; Step 4: /github:torvalds/linux@ + "" -> branch + tag completions
      (spy-on 'remoto--fetch-branches :and-return-value '("master" "stable"))
      (spy-on 'remoto--fetch-tags :and-return-value nil)
      (let ((branches (remoto--handle-file-name-all-completions
                       "" "/github:torvalds/linux@")))
        (expect branches :to-equal '("master:" "stable:")))

      ;; Step 5: /github:torvalds/linux@master:/ + "s" -> file completions
      (let ((files (remoto--handle-file-name-all-completions
                    "s" "/github:testowner/testrepo@main:/")))
        (expect (member "src/" files) :to-be-truthy))))

  (it "orderless-style: searches then filters client-side"
    ;; This simulates what orderless does with the new search-based approach
    (spy-on 'remoto--search-owner-repos :and-return-value
            '("linux" "libdc-for-dirk"))
    ;; orderless calls with a query, gets matching repos
    (let ((all (remoto--handle-file-name-all-completions "li" "/github:torvalds/")))
      (expect (length all) :to-equal 2)
      ;; Then filters client-side (prefix still matches through trailing /)
      (let ((filtered (seq-filter (lambda (r) (string-prefix-p "lin" r)) all)))
        (expect filtered :to-equal '("linux/"))))))

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

  (it "schedules pre-fetch for top user match"
    (spy-on 'remoto--search-users :and-return-value '("torvalds" "torgeirhelge"))
    (spy-on 'remoto--prefetch-owner-repos)
    (remoto--handle-file-name-all-completions "tor" "/github:")
    (expect 'remoto--prefetch-owner-repos :to-have-been-called-with "torvalds"))

  (it "returns nil for empty user query"
    (let ((completions (remoto--handle-file-name-all-completions "" "/github:")))
      (expect completions :to-be nil)))

  (it "returns recent repos for empty query at /github:owner/"
    (spy-on 'remoto--recent-owner-repos :and-return-value '("linux" "uemacs"))
    (let ((completions (remoto--handle-file-name-all-completions "" "/github:torvalds/")))
      (expect completions :to-equal '("linux/" "uemacs/"))
      (expect 'remoto--recent-owner-repos :to-have-been-called-with "torvalds")))

  (it "searches repos by query"
    (spy-on 'remoto--search-owner-repos :and-return-value '("linux"))
    (let ((completions (remoto--handle-file-name-all-completions "lin" "/github:torvalds/")))
      (expect completions :to-equal '("linux/"))))

  (it "returns branch+tag completions at repo@ directory"
    (spy-on 'remoto--fetch-branches :and-return-value '("main" "develop"))
    (spy-on 'remoto--fetch-tags :and-return-value nil)
    (let ((completions (remoto--handle-file-name-all-completions
                        "" "/github:torvalds/linux@")))
      (expect completions :to-equal '("main:" "develop:"))))

  (it "filters branches by prefix at repo@ directory"
    (spy-on 'remoto--fetch-branches :and-return-value '("main" "develop"))
    (spy-on 'remoto--fetch-tags :and-return-value nil)
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

;;; ====================================================================
;;; TDD tests for v2 features: delimiter dispatch, #issues, @tags,
;;; files-default, file-exists-p tightening, edge cases
;;; ====================================================================

;;; E2E test helper

(defun remoto-test--complete (input)
  "Simulate completion for INPUT, return candidates.
Exercises the full chain: file-name-directory -> file-name-nondirectory
-> file-name-all-completions."
  (let* ((dir (remoto-file-name-handler 'file-name-directory input))
         (file (remoto-file-name-handler 'file-name-nondirectory input))
         (completions (remoto-file-name-handler
                       'file-name-all-completions file dir)))
    completions))

(defun remoto-test--tab-complete (input)
  "Simulate TAB completion for INPUT, return completed string.
Returns the full path after completion, or INPUT if no completion."
  (let* ((dir (remoto-file-name-handler 'file-name-directory input))
         (file (remoto-file-name-handler 'file-name-nondirectory input))
         (completion (remoto-file-name-handler
                      'file-name-completion file dir)))
    (if (and completion (stringp completion))
        (concat dir completion)
      input)))

;;; ---- Partial path parsing: new levels ----

(describe "remoto--parse-partial-github-path new levels"
  ;; files-default: /github:owner/repo/
  (it "parses /github:owner/repo/ as files-default level"
    (let ((result (remoto--parse-partial-github-path "/github:foobar/zapato/")))
      (expect (plist-get result :level) :to-equal 'files-default)
      (expect (plist-get result :owner) :to-equal "foobar")
      (expect (plist-get result :repo) :to-equal "zapato")))

  (it "parses /github:owner/repo/subdir/ as files-default level"
    (let ((result (remoto--parse-partial-github-path "/github:foobar/zapato/src/")))
      (expect (plist-get result :level) :to-equal 'files-default)
      (expect (plist-get result :owner) :to-equal "foobar")
      (expect (plist-get result :repo) :to-equal "zapato")))

  ;; issues: /github:owner/repo#
  (it "parses /github:owner/repo# as issues level"
    (let ((result (remoto--parse-partial-github-path "/github:foobar/zapato#")))
      (expect (plist-get result :level) :to-equal 'issues)
      (expect (plist-get result :owner) :to-equal "foobar")
      (expect (plist-get result :repo) :to-equal "zapato")))

  ;; delimiter without repo - invalid
  (it "returns nil for /github:owner# (no repo)"
    (expect (remoto--parse-partial-github-path "/github:foobar#") :to-be nil))

  (it "returns nil for /github:owner@ (no repo)"
    (expect (remoto--parse-partial-github-path "/github:foobar@") :to-be nil))

  ;; repo with special characters
  (it "parses repo with dots"
    (let ((result (remoto--parse-partial-github-path "/github:agzam/remoto.el#")))
      (expect (plist-get result :level) :to-equal 'issues)
      (expect (plist-get result :repo) :to-equal "remoto.el")))

  (it "parses repo with hyphens"
    (let ((result (remoto--parse-partial-github-path "/github:foo/my-repo@")))
      (expect (plist-get result :level) :to-equal 'repo)
      (expect (plist-get result :repo) :to-equal "my-repo")))

  (it "parses repo with underscores"
    (let ((result (remoto--parse-partial-github-path "/github:foo/my_repo/")))
      (expect (plist-get result :level) :to-equal 'files-default)
      (expect (plist-get result :repo) :to-equal "my_repo")))

  ;; empty/degenerate segments
  (it "returns nil for /github:/"
    (expect (remoto--parse-partial-github-path "/github:/") :to-be nil))

  (it "returns nil for /github://"
    (expect (remoto--parse-partial-github-path "/github://") :to-be nil))

  (it "returns nil for /github:foo/#"
    (expect (remoto--parse-partial-github-path "/github:foo/#") :to-be nil))

  (it "returns nil for /github:foo/# (empty repo before #)"
    (expect (remoto--parse-partial-github-path "/github:foo/#") :to-be nil))

  ;; existing levels still work
  (it "still parses /github: as root"
    (let ((result (remoto--parse-partial-github-path "/github:")))
      (expect (plist-get result :level) :to-equal 'root)))

  (it "still parses /github:owner/ as owner"
    (let ((result (remoto--parse-partial-github-path "/github:foobar/")))
      (expect (plist-get result :level) :to-equal 'owner)))

  (it "still parses /github:owner/repo@ as repo (branches)"
    (let ((result (remoto--parse-partial-github-path "/github:foobar/zapato@")))
      (expect (plist-get result :level) :to-equal 'repo))))

;;; ---- file-name-directory with # delimiter ----

(describe "file-name-directory with # delimiter"
  (it "returns /github:owner/repo# for /github:owner/repo#"
    (expect (remoto--handle-file-name-directory "/github:foobar/zapato#")
            :to-equal "/github:foobar/zapato#"))

  (it "returns /github:owner/repo# for /github:owner/repo#42"
    (expect (remoto--handle-file-name-directory "/github:foobar/zapato#42")
            :to-equal "/github:foobar/zapato#"))

  (it "returns /github:owner/repo# for /github:owner/repo#fix-bug"
    (expect (remoto--handle-file-name-directory "/github:foobar/zapato#fix-bug")
            :to-equal "/github:foobar/zapato#"))

  ;; # without repo - treat as part of owner query
  (it "returns /github: for /github:foo#"
    (expect (remoto--handle-file-name-directory "/github:foo#")
            :to-equal "/github:"))

  ;; existing @ behavior unchanged
  (it "still handles /github:owner/repo@ correctly"
    (expect (remoto--handle-file-name-directory "/github:foobar/zapato@")
            :to-equal "/github:foobar/zapato@"))

  (it "still handles /github:owner/repo@branch correctly"
    (expect (remoto--handle-file-name-directory "/github:foobar/zapato@main")
            :to-equal "/github:foobar/zapato@")))

;;; ---- file-name-nondirectory with # delimiter ----

(describe "file-name-nondirectory with # delimiter"
  (it "returns empty for /github:owner/repo#"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar/zapato#")
            :to-equal ""))

  (it "returns 42 for /github:owner/repo#42"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar/zapato#42")
            :to-equal "42"))

  (it "returns fix-bug for /github:owner/repo#fix-bug"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar/zapato#fix-bug")
            :to-equal "fix-bug"))

  ;; # without repo - not a valid delimiter, part of owner query
  (it "returns foo# for /github:foo# (no repo, literal)"
    (expect (remoto--handle-file-name-nondirectory "/github:foo#")
            :to-equal "foo#"))

  ;; existing @ behavior unchanged
  (it "still returns empty for /github:owner/repo@"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar/zapato@")
            :to-equal ""))

  (it "still returns branch for /github:owner/repo@branch"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar/zapato@main")
            :to-equal "main")))

;;; ---- file-name-directory/nondirectory for files-default ----

(describe "file-name-directory for files-default (short form)"
  (it "returns /github:owner/repo/ for /github:owner/repo/"
    (expect (remoto--handle-file-name-directory "/github:foobar/zapato/")
            :to-equal "/github:foobar/zapato/"))

  (it "returns /github:owner/repo/ for /github:owner/repo/src"
    (expect (remoto--handle-file-name-directory "/github:foobar/zapato/src")
            :to-equal "/github:foobar/zapato/"))

  (it "returns /github:owner/repo/src/ for /github:owner/repo/src/"
    (expect (remoto--handle-file-name-directory "/github:foobar/zapato/src/")
            :to-equal "/github:foobar/zapato/src/"))

  (it "returns /github:owner/repo/src/ for /github:owner/repo/src/file.el"
    (expect (remoto--handle-file-name-directory "/github:foobar/zapato/src/file.el")
            :to-equal "/github:foobar/zapato/src/")))

(describe "file-name-nondirectory for files-default (short form)"
  (it "returns empty for /github:owner/repo/"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar/zapato/")
            :to-equal ""))

  (it "returns src for /github:owner/repo/src"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar/zapato/src")
            :to-equal "src"))

  (it "returns file.el for /github:owner/repo/src/file.el"
    (expect (remoto--handle-file-name-nondirectory "/github:foobar/zapato/src/file.el")
            :to-equal "file.el")))

;;; ---- file-exists-p tightening ----

(describe "file-exists-p tightened for non-openable paths"
  ;; Should return nil (not openable)
  (it "returns nil for bare /github:owner/repo (no delimiter)"
    (expect (remoto--handle-file-exists-p "/github:foobar/zapato")
            :not :to-be-truthy))

  (it "returns nil for /github:owner# (no repo)"
    (expect (remoto--handle-file-exists-p "/github:foobar#")
            :not :to-be-truthy))

  (it "returns nil for /github:owner@ (no repo)"
    (expect (remoto--handle-file-exists-p "/github:foobar@")
            :not :to-be-truthy))

  (it "returns nil for /github:owner/repo# (delimiter without selection)"
    (expect (remoto--handle-file-exists-p "/github:foobar/zapato#")
            :not :to-be-truthy))

  (it "returns nil for /github:owner/repo@ (delimiter without selection)"
    (expect (remoto--handle-file-exists-p "/github:foobar/zapato@")
            :not :to-be-truthy))

  ;; Should return t (openable)
  (it "returns t for /github:"
    (expect (remoto--handle-file-exists-p "/github:") :to-be t))

  (it "returns t for /github:owner/"
    (expect (remoto--handle-file-exists-p "/github:foobar/") :to-be t))

  (it "returns t for /github:owner/repo/ (files-default, openable as dired)"
    (expect (remoto--handle-file-exists-p "/github:foobar/zapato/") :to-be t))

  (it "returns t for existing canonical file"
    (remoto-test-with-cache
      (expect (remoto--handle-file-exists-p
               "/github:testowner/testrepo@main:/README.md")
              :to-be t)))

  (it "returns t for /github:owner/repo#42 (specific issue ref)"
    (expect (remoto--handle-file-exists-p "/github:foobar/zapato#42")
            :to-be t)))

;;; ---- Lightweight directory fetch ----

(describe "remoto--fetch-dir-children-light"
  (it "fetches top-level directory contents"
    (spy-on 'remoto--api :and-return-value
            '(((name . "README.md") (type . "file") (size . 500) (sha . "aaa"))
              ((name . "src") (type . "dir") (size . 0) (sha . "bbb"))
              ((name . "Makefile") (type . "file") (size . 200) (sha . "ccc"))))
    (let ((remoto--dir-contents-cache (make-hash-table :test 'equal)))
      (let ((children (remoto--fetch-dir-children-light "owner" "repo" "main" "")))
        (expect (length children) :to-equal 3)
        (expect (assoc "README.md" children) :to-be-truthy)
        (expect (assoc "src" children) :to-be-truthy)
        (expect (equal "tree" (alist-get 'type (cdr (assoc "src" children))))
                :to-be t))))

  (it "caps results at 20 entries"
    (let ((many-entries (cl-loop for i from 1 to 30
                                 collect `((name . ,(format "file%d.el" i))
                                           (type . "file") (size . 100) (sha . "x")))))
      (spy-on 'remoto--api :and-return-value many-entries)
      (let ((remoto--dir-contents-cache (make-hash-table :test 'equal)))
        (let ((children (remoto--fetch-dir-children-light "owner" "repo" "main" "")))
          (expect (length children) :to-equal 20)))))

  (it "caches results"
    (let ((remoto--dir-contents-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint)
                (setq call-count (1+ call-count))
                '(((name . "a.el") (type . "file") (size . 10) (sha . "x")))))
      (remoto--fetch-dir-children-light "owner" "repo" "main" "")
      (remoto--fetch-dir-children-light "owner" "repo" "main" "")
      (expect call-count :to-equal 1)))

  (it "returns nil on API error"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_) (user-error "not found")))
    (let ((remoto--dir-contents-cache (make-hash-table :test 'equal)))
      (expect (remoto--fetch-dir-children-light "owner" "repo" "main" "")
              :to-be nil)))

  (it "fetches subdirectory contents"
    (spy-on 'remoto--api :and-return-value
            '(((name . "main.el") (type . "file") (size . 1000) (sha . "aa"))
              ((name . "utils.el") (type . "file") (size . 500) (sha . "bb"))))
    (let ((remoto--dir-contents-cache (make-hash-table :test 'equal)))
      (let ((children (remoto--fetch-dir-children-light "owner" "repo" "main" "src")))
        (expect (length children) :to-equal 2)
        (expect (assoc "main.el" children) :to-be-truthy)))))

;;; ---- Completion: files-default level ----

(describe "completion at files-default level"
  (it "lists root files for /github:owner/repo/"
    (remoto-test-with-cache
      (spy-on 'remoto--default-branch :and-return-value "main")
      (spy-on 'remoto--fetch-dir-children-light :and-return-value
              '(("README.md" (type . "blob") (size . 500))
                ("src" (type . "tree") (size . 0))
                ("bin" (type . "tree") (size . 0))))
      (let ((completions (remoto--handle-file-name-all-completions
                          "" "/github:testowner/testrepo/")))
        (expect (member "README.md" completions) :to-be-truthy)
        (expect (member "src/" completions) :to-be-truthy)
        (expect (member "bin/" completions) :to-be-truthy))))

  (it "filters root files by substring match"
    (remoto-test-with-cache
      (spy-on 'remoto--default-branch :and-return-value "main")
      (spy-on 'remoto--fetch-dir-children-light :and-return-value
              '(("README.md" (type . "blob") (size . 500))
                ("src" (type . "tree") (size . 0))
                ("bin" (type . "tree") (size . 0))))
      (let ((completions (remoto--handle-file-name-all-completions
                          "src" "/github:testowner/testrepo/")))
        (expect (member "src/" completions) :to-be-truthy)
        (expect (member "README.md" completions) :not :to-be-truthy))))

  (it "uses substring matching, not prefix"
    (remoto-test-with-cache
      (spy-on 'remoto--default-branch :and-return-value "main")
      (spy-on 'remoto--fetch-dir-children-light :and-return-value
              '(("README.md" (type . "blob") (size . 500))
                ("CONTRIBUTING.md" (type . "blob") (size . 200))))
      (let ((completions (remoto--handle-file-name-all-completions
                          "ME" "/github:testowner/testrepo/")))
        ;; Both contain "ME"
        (expect (member "README.md" completions) :to-be-truthy))))

  (it "lists subdirectory files"
    (remoto-test-with-cache
      (spy-on 'remoto--default-branch :and-return-value "main")
      (spy-on 'remoto--fetch-dir-children-light :and-return-value
              '(("main.el" (type . "blob") (size . 1000))
                ("utils.el" (type . "blob") (size . 500))))
      (let ((completions (remoto--handle-file-name-all-completions
                          "" "/github:testowner/testrepo/src/")))
        (expect (member "main.el" completions) :to-be-truthy)
        (expect (member "utils.el" completions) :to-be-truthy))))

  (it "returns empty for nonexistent subdirectory"
    (remoto-test-with-cache
      (spy-on 'remoto--default-branch :and-return-value "main")
      (spy-on 'remoto--fetch-dir-children-light :and-return-value nil)
      (let ((completions (remoto--handle-file-name-all-completions
                          "" "/github:testowner/testrepo/nope/")))
        (expect completions :to-be nil))))

  (it "returns empty when default branch resolution fails"
    (remoto-test-with-cache
      (spy-on 'remoto--default-branch :and-return-value nil)
      (let ((completions (remoto--handle-file-name-all-completions
                          "" "/github:testowner/testrepo/")))
        (expect completions :to-be nil))))

  (it "does not call remoto--ensure-tree (no recursive fetch)"
    (remoto-test-with-cache
      (spy-on 'remoto--default-branch :and-return-value "main")
      (spy-on 'remoto--fetch-dir-children-light :and-return-value
              '(("a.el" (type . "blob") (size . 10))))
      (spy-on 'remoto--ensure-tree)
      (remoto--handle-file-name-all-completions "" "/github:testowner/testrepo/")
      (expect 'remoto--ensure-tree :not :to-have-been-called))))

;;; ---- Completion: issues level ----

(describe "completion at issues level"
  (it "lists issues/PRs for /github:owner/repo#"
    (spy-on 'remoto--fetch-issues :and-return-value
            '(((number . 42) (title . "Fix parser bug") (pull_request))
              ((number . 10) (title . "Add docs"))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((completions (remoto--handle-file-name-all-completions
                          "" "/github:foobar/zapato#")))
        (expect (member "42" completions) :to-be-truthy)
        (expect (member "10" completions) :to-be-truthy))))

  (it "filters issues by text search"
    (spy-on 'remoto--search-issues :and-return-value
            '(((number . 42) (title . "Fix parser bug") (pull_request))
              ((number . 99) (title . "Fix typo"))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((completions (remoto--handle-file-name-all-completions
                          "fix" "/github:foobar/zapato#")))
        (expect (member "42" completions) :to-be-truthy)
        (expect (member "99" completions) :to-be-truthy))))

  (it "returns direct issue for numeric query"
    (spy-on 'remoto--fetch-issue :and-return-value
            '((number . 42) (title . "Fix parser bug")))
    (spy-on 'remoto--fetch-issues :and-return-value
            '(((number . 1) (title . "First issue"))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((completions (remoto--handle-file-name-all-completions
                          "42" "/github:foobar/zapato#")))
        (expect (member "42" completions) :to-be-truthy))))

  (it "returns empty when repo returns 404"
    (spy-on 'remoto--fetch-issues :and-return-value nil)
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((completions (remoto--handle-file-name-all-completions
                          "" "/github:foobar/nonexistent#")))
        (expect completions :to-be nil))))

  (it "returns empty for /github:owner# (no repo)"
    (let ((completions (remoto-test--complete "/github:foobar#")))
      (expect completions :to-be nil))))

;;; ---- Completion: branches + tags grouped ----

(describe "completion at @ level with branches and tags"
  (it "returns both branches and tags"
    (spy-on 'remoto--fetch-branches :and-return-value '("main" "develop"))
    (spy-on 'remoto--fetch-tags :and-return-value '("v1.0.0" "v2.0.0"))
    (let ((completions (remoto--handle-file-name-all-completions
                        "" "/github:foobar/zapato@")))
      (expect (member "main:" completions) :to-be-truthy)
      (expect (member "develop:" completions) :to-be-truthy)
      (expect (member "v1.0.0:" completions) :to-be-truthy)
      (expect (member "v2.0.0:" completions) :to-be-truthy)))

  (it "filters branches and tags by prefix"
    (spy-on 'remoto--fetch-branches :and-return-value '("main" "develop"))
    (spy-on 'remoto--fetch-tags :and-return-value '("v1.0.0" "v2.0.0"))
    (let ((completions (remoto--handle-file-name-all-completions
                        "v" "/github:foobar/zapato@")))
      (expect (member "main:" completions) :not :to-be-truthy)
      (expect (member "v1.0.0:" completions) :to-be-truthy)
      (expect (member "v2.0.0:" completions) :to-be-truthy)))

  (it "returns empty when both branches and tags fail"
    (spy-on 'remoto--fetch-branches :and-return-value nil)
    (spy-on 'remoto--fetch-tags :and-return-value nil)
    (let ((completions (remoto--handle-file-name-all-completions
                        "" "/github:foobar/zapato@")))
      (expect completions :to-be nil))))

;;; ---- E2E completion scenarios ----

(describe "E2E completion: happy paths"
  (it "owner -> repo -> files (default branch)"
    (remoto-test-with-cache
      ;; Step 1: find user
      (spy-on 'remoto--search-users :and-return-value '("testowner"))
      (expect (remoto-test--complete "/github:test")
              :to-equal '("testowner/"))

      ;; Step 2: find repo (trailing / marks repos as navigable dirs)
      (spy-on 'remoto--recent-owner-repos :and-return-value '("testrepo"))
      (expect (remoto-test--complete "/github:testowner/")
              :to-equal '("testrepo/"))

      ;; Step 3: list files on default branch (uses lightweight Contents API)
      (spy-on 'remoto--default-branch :and-return-value "main")
      (spy-on 'remoto--fetch-dir-children-light :and-return-value
              '(("README.md" . ((type . "blob") (size . 500)))
                ("src" . ((type . "tree") (size . 0)))))
      (let ((completions (remoto-test--complete "/github:testowner/testrepo/")))
        (expect (member "README.md" completions) :to-be-truthy)
        (expect (member "src/" completions) :to-be-truthy))))

  (it "owner -> repo -> # -> issues"
    (spy-on 'remoto--fetch-issues :and-return-value
            '(((number . 5) (title . "Bug report") (pull_request))
              ((number . 3) (title . "Feature request"))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((completions (remoto-test--complete "/github:foobar/zapato#")))
        (expect (member "5" completions) :to-be-truthy)
        (expect (member "3" completions) :to-be-truthy))))

  (it "owner -> repo -> @ -> branches+tags -> files"
    (remoto-test-with-cache
      ;; Branch listing includes tags
      (spy-on 'remoto--fetch-branches :and-return-value '("main" "develop"))
      (spy-on 'remoto--fetch-tags :and-return-value '("v1.0"))
      (let ((completions (remoto-test--complete "/github:testowner/testrepo@")))
        (expect (member "main:" completions) :to-be-truthy)
        (expect (member "v1.0:" completions) :to-be-truthy))

      ;; After selecting branch, list files
      (let ((completions (remoto-test--complete "/github:testowner/testrepo@main:/")))
        (expect (member "src/" completions) :to-be-truthy)))))

(describe "E2E completion: edge cases"
  ;; Delimiter without repo
  (it "returns nil for /github:foo#"
    (spy-on 'remoto--search-users :and-return-value nil)
    (expect (remoto-test--complete "/github:foo#") :to-be nil))

  (it "returns nil for /github:foo@"
    (spy-on 'remoto--search-users :and-return-value nil)
    (expect (remoto-test--complete "/github:foo@") :to-be nil))

  (it "returns nil for /github:foo#42"
    (spy-on 'remoto--search-users :and-return-value nil)
    (expect (remoto-test--complete "/github:foo#42") :to-be nil))

  ;; Nonexistent resources
  (it "returns nil for nonexistent repo issues"
    (spy-on 'remoto--fetch-issues :and-return-value nil)
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (expect (remoto-test--complete "/github:foo/nonexistent#") :to-be nil)))

  ;; Double slash normalization
  (it "handles /github:foo//bar gracefully"
    (spy-on 'remoto--search-owner-repos :and-return-value '("bar"))
    ;; Double slash should normalize - file-name-directory handles it
    (let ((dir (remoto--handle-file-name-directory "/github:foo//bar")))
      (expect dir :to-be-truthy)))

  ;; Mixed delimiters - first after repo wins
  (it "/github:foo/bar/@ treats @ as literal file char"
    (remoto-test-with-cache
      (spy-on 'remoto--default-branch :and-return-value "main")
      ;; In files-default mode, @ is a literal filename character
      (let ((dir (remoto--handle-file-name-directory "/github:testowner/testrepo/@")))
        (expect dir :to-equal "/github:testowner/testrepo/"))))

  (it "/github:foo/bar@# treats # as literal branch char"
    ;; In branch mode, # is part of branch name query
    (expect (remoto--handle-file-name-directory "/github:foo/bar@#")
            :to-equal "/github:foo/bar@")
    (expect (remoto--handle-file-name-nondirectory "/github:foo/bar@#")
            :to-equal "#"))

  (it "/github:foo/bar## treats second # as literal"
    ;; First # is delimiter, second is part of query
    (expect (remoto--handle-file-name-directory "/github:foo/bar##")
            :to-equal "/github:foo/bar#")
    (expect (remoto--handle-file-name-nondirectory "/github:foo/bar##")
            :to-equal "#"))

  ;; Case insensitivity
  (it "handles uppercase owner/repo"
    (spy-on 'remoto--fetch-issues :and-return-value
            '(((number . 1) (title . "Test"))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((completions (remoto-test--complete "/github:FOO/BAR#")))
        (expect (member "1" completions) :to-be-truthy))))

  ;; Repo with dots
  (it "handles repo with dots in issues mode"
    (spy-on 'remoto--fetch-issues :and-return-value
            '(((number . 7) (title . "Setup"))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((completions (remoto-test--complete "/github:agzam/remoto.el#")))
        (expect (member "7" completions) :to-be-truthy))))

  ;; Empty /github:
  (it "/github: with empty query returns nil (current behavior)"
    (let ((completions (remoto-test--complete "/github:")))
      (expect completions :to-be nil))))

;;; ---- TAB completion behavior ----

(describe "TAB completion at each level"
  (it "completes unique owner with /"
    (spy-on 'remoto--search-users :and-return-value '("torvalds"))
    (expect (remoto-test--tab-complete "/github:tor")
            :to-equal "/github:torvalds/"))

  (it "completes common owner prefix"
    (spy-on 'remoto--search-users :and-return-value '("torvalds" "torgeirhelge"))
    (expect (remoto-test--tab-complete "/github:tor")
            :to-equal "/github:tor"))

  (it "completes unique repo"
    (spy-on 'remoto--search-owner-repos :and-return-value '("linux"))
    (expect (remoto-test--tab-complete "/github:torvalds/lin")
            :to-equal "/github:torvalds/linux/"))

  (it "completes unique branch with :"
    (spy-on 'remoto--fetch-branches :and-return-value '("main"))
    (spy-on 'remoto--fetch-tags :and-return-value nil)
    (expect (remoto-test--tab-complete "/github:foo/bar@ma")
            :to-equal "/github:foo/bar@main:"))

  (it "completes unique issue number"
    (spy-on 'remoto--fetch-issues :and-return-value
            '(((number . 42) (title . "Bug"))))
    (spy-on 'remoto--fetch-issue :and-return-value nil)
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (expect (remoto-test--tab-complete "/github:foo/bar#4")
              :to-equal "/github:foo/bar#42")))

  (it "returns input unchanged when no matches"
    (spy-on 'remoto--search-users :and-return-value nil)
    (expect (remoto-test--tab-complete "/github:zzz")
            :to-equal "/github:zzz")))

;;; ---- file-exists-p for RET behavior ----

(describe "file-exists-p RET guard scenarios"
  ;; These paths should trigger [Confirm] in the minibuffer
  ;; because file-exists-p returns nil
  (it "bare owner/repo triggers confirm (nil)"
    (expect (remoto--handle-file-exists-p "/github:foo/bar")
            :not :to-be-truthy))

  (it "delimiter without selection triggers confirm (nil)"
    (expect (remoto--handle-file-exists-p "/github:foo/bar#")
            :not :to-be-truthy)
    (expect (remoto--handle-file-exists-p "/github:foo/bar@")
            :not :to-be-truthy))

  (it "delimiter without repo triggers confirm (nil)"
    (expect (remoto--handle-file-exists-p "/github:foo#")
            :not :to-be-truthy)
    (expect (remoto--handle-file-exists-p "/github:foo@")
            :not :to-be-truthy))

  ;; These should NOT trigger confirm
  (it "specific issue ref does not trigger confirm"
    (expect (remoto--handle-file-exists-p "/github:foo/bar#42")
            :to-be t))

  (it "repo with trailing / does not trigger confirm"
    (expect (remoto--handle-file-exists-p "/github:foo/bar/")
            :to-be t))

  (it "canonical file path does not trigger confirm"
    (remoto-test-with-cache
      (expect (remoto--handle-file-exists-p
               "/github:testowner/testrepo@main:/README.md")
              :to-be t))))

;;; ---- Error handling during completion ----

(describe "error handling during completion"
  (it "API error during issue listing returns nil"
    (spy-on 'remoto--fetch-issues :and-return-value nil)
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((completions (remoto--handle-file-name-all-completions
                          "" "/github:foo/bar#")))
        (expect completions :to-be nil))))

  (it "API error during branch listing returns nil"
    (spy-on 'remoto--fetch-branches :and-return-value nil)
    (spy-on 'remoto--fetch-tags :and-return-value nil)
    (let ((completions (remoto--handle-file-name-all-completions
                        "" "/github:foo/bar@")))
      (expect completions :to-be nil)))

  (it "API error during files-default listing returns nil"
    (remoto-test-with-cache
      (spy-on 'remoto--default-branch :and-return-value nil)
      (let ((completions (remoto--handle-file-name-all-completions
                          "" "/github:foo/bar/")))
        (expect completions :to-be nil)))))

;;; ---- Path normalization on open ----

(describe "path normalization for files-default"
  (it "rewrites /github:owner/repo/ to canonical form"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "foobar/zapato" "main" remoto--default-branch-cache)
      (expect (remoto--maybe-rewrite "/github:foobar/zapato/")
              :to-equal "/github:foobar/zapato@main:/")))

  (it "rewrites /github:owner/repo/path to canonical form"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "foobar/zapato" "main" remoto--default-branch-cache)
      (expect (remoto--maybe-rewrite "/github:foobar/zapato/src/main.el")
              :to-equal "/github:foobar/zapato@main:/src/main.el"))))

;;; ---- Issue/PR opening via #NUM ----

(describe "opening issues via #NUM"
  (it "detects #NUM pattern in find-file-noselect advice"
    ;; When /github:owner/repo#42 is passed to find-file-noselect,
    ;; it should NOT try to open as a regular file.
    ;; Instead it should call remoto-topic-display.
    (spy-on 'remoto-topic-display)
    (spy-on 'remoto--maybe-rewrite :and-return-value "/github:foo/bar#42")
    ;; Simulate what the advice does
    (let ((filename "/github:foo/bar#42"))
      (when (string-match (rx "#" (group (+ digit)) eos) filename)
        (remoto-topic-display
         (match-string 1 filename)
         (substring filename 0 (match-beginning 0)))))
    (expect 'remoto-topic-display :to-have-been-called)))

;;; ---- Root completion enhancement ----

(describe "root completion with user orgs"
  (it "shows user orgs when authenticated and query is empty"
    (spy-on 'remoto--fetch-user-orgs :and-return-value '("qlik-oss" "nebula-contrib"))
    (let ((remoto--authenticated-user "agzam"))
      (let ((completions (remoto--handle-file-name-all-completions "" "/github:")))
        (expect (member "agzam/" completions) :to-be-truthy)
        (expect (member "qlik-oss/" completions) :to-be-truthy)
        (expect (member "nebula-contrib/" completions) :to-be-truthy))))

  (it "falls back to nil when not authenticated"
    (let ((remoto--authenticated-user nil))
      (spy-on 'remoto--search-users :and-return-value nil)
      (let ((completions (remoto--handle-file-name-all-completions "" "/github:")))
        (expect completions :to-be nil)))))

;;; ---- Issue cache ----

(describe "issue cache"
  (it "caches issue listing results"
    (let ((remoto--issues-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint)
                (setq call-count (1+ call-count))
                '(((number . 1) (title . "Bug")))))
      (remoto--fetch-issues "foo" "bar")
      (remoto--fetch-issues "foo" "bar")
      (expect call-count :to-equal 1)))

  (it "returns nil on API error"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_) (user-error "not found")))
    (let ((remoto--issues-cache (make-hash-table :test 'equal)))
      (expect (remoto--fetch-issues "foo" "nonexistent") :to-be nil))))

;;; ---- find-file-noselect intercepts #NUM paths ----

(describe "find-file-noselect intercepts #NUM paths"
  (it "routes /github:owner/repo#NUM to remoto-topic-display"
    (spy-on 'remoto-topic-display :and-return-value (generate-new-buffer "*test*"))
    (spy-on 'remoto--require-topic)
    (find-file-noselect "/github:testowner/testrepo#42")
    (expect 'remoto-topic-display :to-have-been-called-with "42" "/github:testowner/testrepo")
    (kill-buffer "*test*"))

  (it "does NOT intercept paths without #NUM (passes to orig)"
    (spy-on 'remoto-topic-display)
    (spy-on 'remoto--maybe-rewrite :and-return-value "/github:testowner/testrepo@main:/README.md")
    ;; This would error in real use but we just check topic-display wasn't called
    (ignore-errors (find-file-noselect "/github:testowner/testrepo@main:/README.md"))
    (expect 'remoto-topic-display :not :to-have-been-called)))

;;; ---- parse-partial-canonical rejects #NUM paths ----

(describe "parse-partial-canonical rejects # delimiter"
  (it "returns nil for /github:owner/repo#123"
    (expect (remoto--parse-partial-canonical "/github:agzam/spacehammer#193") :to-be nil))
  (it "still parses /github:owner/repo without #"
    (expect (remoto--parse-partial-canonical "/github:agzam/spacehammer") :not :to-be nil)))

;;; ---- maybe-rewrite preserves #NUM paths ----

(describe "maybe-rewrite preserves #NUM paths"
  (it "returns /github:owner/repo#NUM unchanged"
    (expect (remoto--maybe-rewrite "/github:foo/bar#42")
            :to-equal "/github:foo/bar#42"))
  (it "returns /github:owner/repo#999 unchanged"
    (expect (remoto--maybe-rewrite "/github:foo/bar#999")
            :to-equal "/github:foo/bar#999")))

;;; ---- Completion annotations (affixation-function) ----

(describe "completion annotations"
  (it "provides repo descriptions at owner level"
    (let* ((meta (remoto--completion-metadata "/github:testowner/"))
           (affix-fn (alist-get 'affixation-function meta))
           (candidate (propertize "myrepo" 'remoto-repo-desc "A cool repo")))
      (expect affix-fn :not :to-be nil)
      (let ((result (funcall affix-fn (list candidate))))
        ;; Should have non-empty suffix
        (expect (string-match-p "A cool repo" (nth 2 (car result))) :to-be-truthy))))

  (it "provides issue/PR titles at issues level"
    (let* ((meta (remoto--completion-metadata "/github:foo/bar#"))
           (affix-fn (alist-get 'affixation-function meta))
           (candidate (propertize "42" 'remoto-topic-title "Fix bug"
                                      'remoto-topic-state "open"
                                      'remoto-topic-pr nil)))
      (expect affix-fn :not :to-be nil)
      (let ((result (funcall affix-fn (list candidate))))
        (expect (string-match-p "Fix bug" (nth 2 (car result))) :to-be-truthy)
        (expect (string-match-p "open" (nth 2 (car result))) :to-be-truthy))))

  (it "provides group-function for branches/tags"
    (let* ((meta (remoto--completion-metadata "/github:foo/bar@"))
           (group-fn (alist-get 'group-function meta))
           (branch (propertize "main:" 'remoto-ref-type "branch"))
           (tag (propertize "v1.0:" 'remoto-ref-type "tag")))
      (expect group-fn :not :to-be nil)
      (expect (funcall group-fn branch nil) :to-equal "Branch")
      (expect (funcall group-fn tag nil) :to-equal "Tag")))

  (it "provides user/org type at root level"
    (let* ((meta (remoto--completion-metadata "/github:"))
           (affix-fn (alist-get 'affixation-function meta))
           (user (propertize "agzam/" 'remoto-acct-type "User"))
           (org (propertize "myorg/" 'remoto-acct-type "Organization")))
      (expect affix-fn :not :to-be nil)
      (let ((result (funcall affix-fn (list user org))))
        (expect (string-match-p "User" (nth 2 (car result))) :to-be-truthy)
        (expect (string-match-p "Organization" (nth 2 (cadr result))) :to-be-truthy))))

  (it "uses remoto category to avoid marginalia override"
    (let* ((directory "/github:testowner/"))
      ;; When metadata is injected, category should be 'remoto
      ;; This is tested via read-file-name-internal but we can check
      ;; that completion-metadata returns our custom metadata
      (expect (remoto--completion-metadata directory) :not :to-be nil))))

;;; ---- remoto--affixate ----

(describe "annotation alignment"
  (it "uses display property for alignment"
    (let ((items '(("short" "" "desc1")
                   ("a-much-longer-name" "" "desc2"))))
      (let ((result (remoto--affixate items)))
        ;; Both suffixes use (space :align-to N) display property
        (expect (get-text-property 0 'display (nth 2 (car result)))
                :to-be-truthy)
        (expect (get-text-property 0 'display (nth 2 (cadr result)))
                :to-be-truthy)
        ;; Suffix text has face applied
        (expect (get-text-property 1 'face (nth 2 (car result)))
                :to-equal 'remoto-annotation)))))

;;; ---- PR ordering in issue completion ----

(describe "PR ordering in issue completion"
  (it "sorts PRs before issues"
    (spy-on 'remoto--fetch-issues
            :and-return-value '(((number . 10) (title . "Bug") (state . "open"))
                                ((number . 20) (title . "Feature PR") (state . "open")
                                 (pull_request (url . "http://...")))
                                ((number . 5) (title . "Another issue") (state . "open"))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((result (remoto--handle-file-name-all-completions "" "/github:foo/bar#")))
        ;; First should be the PR (number 20)
        (expect (car result) :to-equal "20")))))

;;; ---- remoto--fetch-user-orgs uses authenticated endpoint ----

(describe "fetch-user-orgs"
  (it "calls user/orgs endpoint (authenticated)"
    (spy-on 'remoto--api :and-return-value '(((login . "org1")) ((login . "org2"))))
    (remoto--fetch-user-orgs "anyone")
    (expect 'remoto--api :to-have-been-called-with "user/orgs?per_page=100&page=1")))

;;; ---- remoto--paginated-api ----

(describe "remoto--paginated-api"
  (it "accumulates results across pages until a short page"
    (let ((calls nil))
      (spy-on 'remoto--api :and-call-fake
              (lambda (endpoint)
                (push endpoint calls)
                (pcase (length calls)
                  (1 (make-list 100 '((n . 1))))
                  (2 (make-list 100 '((n . 2))))
                  (_ '(((n . 3)))))))
      (let ((result (remoto--paginated-api "repos/o/r/branches" 100)))
        (expect (length result) :to-equal 201)
        (expect (length calls) :to-equal 3)
        (expect (car calls) :to-equal "repos/o/r/branches?per_page=100&page=3"))))

  (it "stops after a single short page"
    (spy-on 'remoto--api :and-return-value '(((n . 1)) ((n . 2))))
    (remoto--paginated-api "user/orgs" 100)
    (expect 'remoto--api :to-have-been-called-times 1)
    (expect 'remoto--api :to-have-been-called-with "user/orgs?per_page=100&page=1"))

  (it "caps total requests at MAX-PAGES on huge result sets"
    (spy-on 'remoto--api :and-return-value (make-list 100 '((n . 1))))
    (remoto--paginated-api "repos/o/r/tags" 100 3)
    (expect 'remoto--api :to-have-been-called-times 3))

  (it "uses & as separator when the endpoint already has a query"
    (spy-on 'remoto--api :and-return-value nil)
    (remoto--paginated-api "search/things?q=x" 100)
    (expect 'remoto--api :to-have-been-called-with "search/things?q=x&per_page=100&page=1")))

;;; ---- File commit annotations ----

(describe "file commit annotations"
  (it "propertizes file candidates with commit messages"
    (spy-on 'remoto--api :and-call-fake
            (lambda (endpoint)
              (cond
               ((string-match-p "git/trees" endpoint)
                '((sha . "abc") (tree . (((path . "README.md") (type . "blob")
                                          (size . 100) (sha . "aaa") (mode . "100644"))
                                         ((path . "src") (type . "tree")
                                          (size . 0) (sha . "bbb") (mode . "040000"))))))
               ((string-match-p "commits.*path=README" endpoint)
                '(((commit (message . "Initial commit\n\nBody text")))))
               ((string-match-p "commits.*path=src" endpoint)
                '(((commit (message . "Add source directory")))))
               (t nil))))
    (let ((remoto--file-commits-cache (make-hash-table :test 'equal))
          (remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "testowner/testrepo" "main" remoto--default-branch-cache)
      (remoto-test--install-mock-tree)
      (let ((result (remoto--fetch-file-commits "testowner" "testrepo" "main" ""
                                                '("README.md" "src/"))))
        (expect (alist-get "README.md" result nil nil #'equal)
                :to-equal "Initial commit")
        (expect (alist-get "src/" result nil nil #'equal)
                :to-equal "Add source directory"))))

  (it "provides file commit metadata for canonical paths"
    (let* ((meta (remoto--completion-metadata "/github:foo/bar@main:/"))
           (affix-fn (alist-get 'affixation-function meta))
           (candidate (propertize "file.el" 'remoto-file-commit "Fix typo")))
      (expect affix-fn :not :to-be nil)
      (let ((result (funcall affix-fn (list candidate))))
        (expect (string-match-p "Fix typo" (nth 2 (car result))) :to-be-truthy))))

  (it "provides file commit metadata for files-default paths"
    (let* ((meta (remoto--completion-metadata "/github:foo/bar/"))
           (affix-fn (alist-get 'affixation-function meta))
           (candidate (propertize "src/" 'remoto-file-commit "Refactor modules")))
      (expect affix-fn :not :to-be nil)
      (let ((result (funcall affix-fn (list candidate))))
        (expect (string-match-p "Refactor modules" (nth 2 (car result))) :to-be-truthy))))

  (it "caches results across calls"
    (let ((remoto--file-commits-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint)
                (cl-incf call-count)
                '(((commit (message . "cached msg"))))))
      (remoto--fetch-file-commits "o" "r" "main" "" '("f.el"))
      (remoto--fetch-file-commits "o" "r" "main" "" '("f.el"))
      (expect call-count :to-equal 1)))

  (it "catches generic errors from API (not just user-error)"
    (let ((remoto--file-commits-cache (make-hash-table :test 'equal)))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_endpoint) (error "Connection refused")))
      (expect (remoto--fetch-file-commits "o" "r" "main" "" '("f.el"))
              :to-be nil))))

;;; Async completion infrastructure

(describe "remoto--debounce"
  (it "calls run-with-idle-timer with configured delay"
    (spy-on 'run-with-idle-timer)
    (spy-on 'cancel-timer)
    (let ((remoto-debounce-delay 0.5)
          (remoto--debounce-timer nil)
          (remoto--debounce-key nil)
          (remoto--async-generation 0))
      (remoto--debounce "key1" #'ignore)
      (expect 'run-with-idle-timer :to-have-been-called)
      (let ((args (spy-calls-args-for 'run-with-idle-timer 0)))
        (expect (nth 0 args) :to-equal 0.5))))

  (it "cancels previous timer when key changes"
    (let* ((fake-timer (list 'timer))
           (remoto--debounce-timer fake-timer)
           (remoto--debounce-key "old-key")
           (remoto--async-generation 0)
           (remoto-debounce-delay 0.3))
      (spy-on 'cancel-timer)
      (spy-on 'run-with-idle-timer :and-return-value (list 'new-timer))
      (remoto--debounce "new-key" #'ignore)
      (expect 'cancel-timer :to-have-been-called-with fake-timer)))

  (it "keeps existing timer when same key is re-submitted"
    (let* ((fake-timer (list 'timer))
           (remoto--debounce-timer fake-timer)
           (remoto--debounce-key "same-key")
           (remoto--async-generation 5)
           (remoto-debounce-delay 0.3))
      (spy-on 'cancel-timer)
      (spy-on 'run-with-idle-timer)
      (remoto--debounce "same-key" #'ignore)
      ;; Should not cancel or reschedule
      (expect 'cancel-timer :not :to-have-been-called)
      (expect 'run-with-idle-timer :not :to-have-been-called)
      ;; Generation should not change
      (expect remoto--async-generation :to-equal 5)))

  (it "increments async generation on each new key"
    (let ((remoto--debounce-timer nil)
          (remoto--debounce-key nil)
          (remoto--async-generation 5)
          (remoto-debounce-delay 0.3))
      (spy-on 'run-with-idle-timer :and-return-value 'fake-timer)
      (spy-on 'cancel-timer)
      (remoto--debounce "key1" #'ignore)
      (expect remoto--async-generation :to-equal 6)
      ;; Same key - no increment (timer still pending)
      (remoto--debounce "key1" #'ignore)
      (expect remoto--async-generation :to-equal 6)
      ;; Different key - cancels old, increments
      (remoto--debounce "key2" #'ignore)
      (expect remoto--async-generation :to-equal 7))))

(describe "remoto--api-async"
  (it "delegates to ghub-get with :callback"
    (spy-on 'ghub-get)
    (let ((remoto--auth-failed nil)
          (remoto-github-auth nil)
          (remoto--authenticated-user "testuser"))
      (remoto--api-async "search/users?q=foo" #'ignore)
      (expect 'ghub-get :to-have-been-called)))

  (it "uses auth=none when auth has failed"
    (spy-on 'ghub-get)
    (let ((remoto--auth-failed t))
      (remoto--api-async "user" #'ignore)
      (let ((args (spy-calls-args-for 'ghub-get 0)))
        (expect (plist-get (cddr args) :auth) :to-equal 'none))))

  (it "passes nil auth for default ghub token when no token found"
    (spy-on 'ghub-get)
    (spy-on 'remoto--find-github-token :and-return-value nil)
    (let ((remoto--auth-failed nil)
          (remoto-github-auth nil)
          (remoto--authenticated-user "testuser")
          (remoto--effective-auth nil))
      (remoto--api-async "user/orgs" #'ignore)
      (let ((args (spy-calls-args-for 'ghub-get 0)))
        ;; nil auth lets ghub use its default token mechanism
        (expect (plist-get (cddr args) :auth) :to-be nil)))))

(describe "remoto--search-cache-get with custom TTL"
  (it "respects custom TTL parameter"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-search-cache-ttl 300))
      ;; Entry 10 seconds old
      (puthash "key" (cons (- (float-time) 10) '("val"))
               remoto--search-cache)
      ;; Default TTL (300s) - should be fresh
      (expect (car (remoto--search-cache-get "key")) :to-be-truthy)
      ;; Custom short TTL (5s) - should be expired
      (expect (car (remoto--search-cache-get "key" 5)) :to-be nil))))

(describe "remoto--recent-owner-repos"
  (it "returns nil on cache miss and schedules async"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-repo-cache-ttl 1800))
      (expect (remoto--recent-owner-repos "torvalds") :to-be nil)
      (expect 'remoto--debounce :to-have-been-called)))

  (it "returns cached repos immediately"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-repo-cache-ttl 1800)
          (remoto-search-cache-ttl 300))
      (puthash "\0repos-recent:torvalds"
               (cons (float-time) '("linux" "uemacs"))
               remoto--search-cache)
      (expect (remoto--recent-owner-repos "torvalds")
              :to-equal '("linux" "uemacs"))
      ;; Should not schedule async since cache is fresh
      (expect 'remoto--debounce :not :to-have-been-called)))

  (it "schedules background refresh for stale-but-usable cache"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-repo-cache-ttl 1800)
          (remoto-search-cache-ttl 300))
      ;; Cache entry older than short TTL but within repo TTL
      (puthash "\0repos-recent:torvalds"
               (cons (- (float-time) 600) '("linux" "uemacs"))
               remoto--search-cache)
      (let ((result (remoto--recent-owner-repos "torvalds")))
        ;; Returns stale results immediately
        (expect result :to-equal '("linux" "uemacs"))
        ;; But also schedules background refresh
        (expect 'remoto--debounce :to-have-been-called)))))

;;; Full pipeline: every segment must yield data

;; Mock API responses for a realistic repo.  remoto--api is the single
;; network boundary - everything above it is pure data transformation.
;; These tests verify that data flows through every segment without
;; being silently swallowed.

(defconst remoto-test--pipe-prefix "/github:acme/widgets@main:"
  "Canonical path prefix for pipeline tests.")

(defconst remoto-test--pipe-repo-meta
  '((full_name . "acme/widgets")
    (default_branch . "main")
    (private . t))
  "Mock repos/:owner/:repo response.")

(defconst remoto-test--pipe-tree-response
  `((sha . "abc123")
    (truncated . :false)
    (tree . (((path . "README.md")
              (type . "blob") (size . 800) (sha . "aaa") (mode . "100644"))
             ((path . "src")
              (type . "tree") (size . 0) (sha . "bbb") (mode . "040000"))
             ((path . "src/app.py")
              (type . "blob") (size . 2400) (sha . "ccc") (mode . "100644"))
             ((path . "src/utils.py")
              (type . "blob") (size . 650) (sha . "ddd") (mode . "100644"))
             ((path . "docs")
              (type . "tree") (size . 0) (sha . "eee") (mode . "040000"))
             ((path . "docs/guide.md")
              (type . "blob") (size . 3100) (sha . "fff") (mode . "100644")))))
  "Mock git/trees/:ref?recursive=1 response.")

(defun remoto-test--pipe-api-fake (endpoint)
  "Mock API dispatcher for pipeline tests."
  (cond
   ((string-match-p "repos/acme/widgets$" endpoint)
    remoto-test--pipe-repo-meta)
   ((string-match-p "git/trees/" endpoint)
    remoto-test--pipe-tree-response)
   (t (user-error "Remoto: not found: %s" endpoint))))

(defmacro remoto-test-with-pipeline (&rest body)
  "Run BODY with mock API wired through the full pipeline."
  (declare (indent 0))
  `(let ((remoto--tree-cache (make-hash-table :test 'equal))
         (remoto--default-branch-cache (make-hash-table :test 'equal))
         (remoto--content-cache (make-hash-table :test 'equal))
         (remoto--dir-contents-cache (make-hash-table :test 'equal))
         (remoto--file-commits-cache (make-hash-table :test 'equal))
         (remoto--auth-failed nil)
         (remoto--effective-auth "ghp_mock_token")
         (remoto--authenticated-user "mockuser"))
     (spy-on 'remoto--api :and-call-fake #'remoto-test--pipe-api-fake)
     ,@body))

(describe "pipeline: every segment yields data"
  ;; Segment 1: API returns repo metadata
  (it "remoto--api returns repo metadata"
    (remoto-test-with-pipeline
      (let ((data (remoto--api "repos/acme/widgets")))
        (expect data :to-be-truthy)
        (expect (alist-get 'full_name data) :to-equal "acme/widgets")
        (expect (alist-get 'default_branch data) :to-equal "main"))))

  ;; Segment 2: default branch extraction
  (it "remoto--default-branch returns a non-empty string"
    (remoto-test-with-pipeline
      (let ((branch (remoto--default-branch "acme" "widgets")))
        (expect branch :to-be-truthy)
        (expect (stringp branch) :to-be-truthy)
        (expect (string-empty-p branch) :not :to-be-truthy))))

  ;; Segment 3: tree fetch builds a populated hash table
  (it "remoto--fetch-tree returns a hash table with entries"
    (remoto-test-with-pipeline
      (let ((tree (remoto--fetch-tree "acme" "widgets" "main")))
        (expect tree :to-be-truthy)
        (expect (hash-table-p tree) :to-be-truthy)
        ;; Must have more than just root entries
        (expect (hash-table-count tree) :to-be-greater-than 2)
        ;; Root entry must exist
        (expect (gethash "" tree) :to-be-truthy))))

  ;; Segment 4: ensure-tree caches and returns the tree
  (it "remoto--ensure-tree caches and returns populated tree"
    (remoto-test-with-pipeline
      (let* ((parsed (remoto--parse-path
                      (concat remoto-test--pipe-prefix "/")))
             (tree (remoto--ensure-tree parsed)))
        (expect tree :to-be-truthy)
        (expect (hash-table-p tree) :to-be-truthy)
        (expect (hash-table-count tree) :to-be-greater-than 2)
        ;; Second call should return cached (spy not called again)
        (let ((call-count (spy-calls-count 'remoto--api)))
          (remoto--ensure-tree parsed)
          (expect (spy-calls-count 'remoto--api) :to-equal call-count)))))

  ;; Segment 5: tree-entry finds root, directories, and files
  (it "remoto--tree-entry finds root directory"
    (remoto-test-with-pipeline
      (let ((entry (remoto--tree-entry
                    (remoto--parse-path
                     (concat remoto-test--pipe-prefix "/")))))
        (expect entry :to-be-truthy)
        (expect (alist-get 'type entry) :to-equal "tree"))))

  (it "remoto--tree-entry finds a subdirectory"
    (remoto-test-with-pipeline
      (let ((entry (remoto--tree-entry
                    (remoto--parse-path
                     (concat remoto-test--pipe-prefix "/src")))))
        (expect entry :to-be-truthy)
        (expect (alist-get 'type entry) :to-equal "tree"))))

  (it "remoto--tree-entry finds a file"
    (remoto-test-with-pipeline
      (let ((entry (remoto--tree-entry
                    (remoto--parse-path
                     (concat remoto-test--pipe-prefix "/README.md")))))
        (expect entry :to-be-truthy)
        (expect (alist-get 'type entry) :to-equal "blob")
        (expect (alist-get 'size entry) :to-be-greater-than 0))))

  (it "remoto--tree-entry finds a nested file"
    (remoto-test-with-pipeline
      (let ((entry (remoto--tree-entry
                    (remoto--parse-path
                     (concat remoto-test--pipe-prefix "/src/app.py")))))
        (expect entry :to-be-truthy)
        (expect (alist-get 'type entry) :to-equal "blob")
        (expect (alist-get 'sha entry) :to-be-truthy))))

  (it "remoto--tree-entry returns nil for nonexistent path"
    (remoto-test-with-pipeline
      (expect (remoto--tree-entry
               (remoto--parse-path
                (concat remoto-test--pipe-prefix "/no/such/file.txt")))
              :to-be nil)))

  ;; Segment 6: tree-children returns non-empty lists
  (it "remoto--tree-children lists root children"
    (remoto-test-with-pipeline
      (let* ((children (remoto--tree-children
                        (remoto--parse-path
                         (concat remoto-test--pipe-prefix "/")))))
        (expect children :to-be-truthy)
        (expect (length children) :to-be-greater-than 0)
        (let ((names (mapcar #'car children)))
          (expect (member "README.md" names) :to-be-truthy)
          (expect (member "src" names) :to-be-truthy)
          (expect (member "docs" names) :to-be-truthy)))))

  (it "remoto--tree-children lists subdirectory children"
    (remoto-test-with-pipeline
      (let* ((children (remoto--tree-children
                        (remoto--parse-path
                         (concat remoto-test--pipe-prefix "/src/")))))
        (expect children :to-be-truthy)
        (expect (length children) :to-equal 2)
        (let ((names (mapcar #'car children)))
          (expect (member "app.py" names) :to-be-truthy)
          (expect (member "utils.py" names) :to-be-truthy)))))

  ;; Segment 7: file-exists-p
  (it "file-exists-p returns t for known file"
    (remoto-test-with-pipeline
      (expect (file-exists-p (concat remoto-test--pipe-prefix "/README.md"))
              :to-be-truthy)))

  (it "file-exists-p returns t for directory"
    (remoto-test-with-pipeline
      (expect (file-exists-p (concat remoto-test--pipe-prefix "/src"))
              :to-be-truthy)))

  (it "file-exists-p returns nil for missing path"
    (remoto-test-with-pipeline
      (expect (file-exists-p (concat remoto-test--pipe-prefix "/nope.txt"))
              :not :to-be-truthy)))

  ;; Segment 8: file-directory-p / file-regular-p
  (it "file-directory-p returns t for directories"
    (remoto-test-with-pipeline
      (expect (file-directory-p (concat remoto-test--pipe-prefix "/src"))
              :to-be-truthy)
      (expect (file-directory-p (concat remoto-test--pipe-prefix "/"))
              :to-be-truthy)))

  (it "file-directory-p returns nil for files"
    (remoto-test-with-pipeline
      (expect (file-directory-p (concat remoto-test--pipe-prefix "/README.md"))
              :not :to-be-truthy)))

  (it "file-regular-p returns t for files"
    (remoto-test-with-pipeline
      (expect (file-regular-p (concat remoto-test--pipe-prefix "/README.md"))
              :to-be-truthy)
      (expect (file-regular-p (concat remoto-test--pipe-prefix "/src/app.py"))
              :to-be-truthy)))

  (it "file-regular-p returns nil for directories"
    (remoto-test-with-pipeline
      (expect (file-regular-p (concat remoto-test--pipe-prefix "/src"))
              :not :to-be-truthy)))

  ;; Segment 9: directory-files
  (it "directory-files lists root with . and .."
    (remoto-test-with-pipeline
      (let ((files (directory-files (concat remoto-test--pipe-prefix "/"))))
        (expect files :to-be-truthy)
        (expect (member "." files) :to-be-truthy)
        (expect (member ".." files) :to-be-truthy)
        (expect (member "README.md" files) :to-be-truthy)
        (expect (member "src" files) :to-be-truthy))))

  (it "directory-files lists subdirectory contents"
    (remoto-test-with-pipeline
      (let ((files (directory-files (concat remoto-test--pipe-prefix "/src/"))))
        (expect files :to-be-truthy)
        (expect (length files) :to-be-greater-than 2) ;; . and .. plus entries
        (expect (member "app.py" files) :to-be-truthy))))

  ;; Segment 10: file-attributes
  (it "file-attributes returns non-nil for file with plausible size"
    (remoto-test-with-pipeline
      (let ((attrs (file-attributes
                    (concat remoto-test--pipe-prefix "/README.md"))))
        (expect attrs :to-be-truthy)
        (expect (file-attribute-size attrs) :to-be-greater-than 0))))

  (it "file-attributes returns non-nil for directory"
    (remoto-test-with-pipeline
      (let ((attrs (file-attributes
                    (concat remoto-test--pipe-prefix "/src"))))
        (expect attrs :to-be-truthy)
        ;; directory attribute: t for dirs
        (expect (file-attribute-type attrs) :to-equal t))))

  ;; Segment 11: insert-directory produces output
  (it "insert-directory generates dired-style listing"
    (remoto-test-with-pipeline
      (with-temp-buffer
        (insert-directory (concat remoto-test--pipe-prefix "/") "-la")
        (let ((content (buffer-string)))
          (expect (length content) :to-be-greater-than 0)
          (expect content :to-match "README\\.md")
          (expect content :to-match "src"))))))

;;; Pipeline: auth forwarding

(describe "pipeline: auth is forwarded to API calls"
  (it "passes effective-auth token to remoto--ghub-get"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--auth-failed nil)
          (remoto--effective-auth "ghp_private_token")
          (remoto--authenticated-user "testuser")
          (captured-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (setq captured-auth (plist-get args :auth))
                '((default_branch . "main"))))
      (remoto--default-branch "acme" "widgets")
      (expect captured-auth :to-equal "ghp_private_token")))

  (it "uses auth=none when auth-failed is t"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--auth-failed t)
          (remoto--effective-auth nil)
          (remoto--authenticated-user nil)
          (captured-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (setq captured-auth (plist-get args :auth))
                '((default_branch . "main"))))
      (remoto--default-branch "acme" "widgets")
      (expect captured-auth :to-equal 'none)))

  (it "signals user-error for private repo with auth=none (404)"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--auth-failed t)
          (remoto--effective-auth nil)
          (remoto--authenticated-user nil))
      (spy-on 'remoto--ghub-get :and-call-fake
              (lambda (_resource _auth endpoint)
                (user-error "Remoto: not found: %s" endpoint)))
      (expect (remoto--api "repos/acme/private-repo")
              :to-throw 'user-error))))

;;; Fresh session: try every auth avenue, fail loudly when none work

(describe "pipeline: fresh session auth resolution"
  ;; Simulate fresh Emacs: warm-auth hasn't run, all auth state is nil.
  ;; ghub's own auth-source lookup fails (different host/user patterns).
  ;; remoto--api should try remoto--find-github-token as a last resort.

  (it "falls back to remoto--find-github-token when ghub auth fails"
    (let ((remoto--auth-failed nil)
          (remoto--effective-auth nil)
          (remoto--authenticated-user nil)
          (remoto-github-auth nil)
          (call-count 0))
      ;; ghub fails with nil auth, succeeds with a real token
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (cl-incf call-count)
                (let ((auth (plist-get args :auth)))
                  (if (stringp auth)
                      '((default_branch . "main"))
                    (error "Required Github token does not exist")))))
      (spy-on 'remoto--find-github-token :and-return-value "ghp_fallback_token")
      (let ((data (remoto--api "repos/acme/widgets")))
        (expect data :to-be-truthy)
        (expect (alist-get 'default_branch data) :to-equal "main")
        ;; Should have cached the token for subsequent calls
        (expect remoto--effective-auth :to-equal "ghp_fallback_token"))))

  (it "does not set auth-failed when fallback token works"
    (let ((remoto--auth-failed nil)
          (remoto--effective-auth nil)
          (remoto--authenticated-user nil)
          (remoto-github-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (let ((auth (plist-get args :auth)))
                  (if (stringp auth)
                      '((full_name . "acme/widgets"))
                    (error "Required Github token does not exist")))))
      (spy-on 'remoto--find-github-token :and-return-value "ghp_found")
      (remoto--api "repos/acme/widgets")
      (expect remoto--auth-failed :to-be nil))))

(describe "pipeline: no auth token anywhere - fail loudly"
  ;; No token exists: ghub fails, remoto--find-github-token returns
  ;; nil.  Every avenue exhausted.  The user must see a clear error,
  ;; not silent empty results.

  (it "remoto--api signals user-error when all auth avenues fail"
    (let ((remoto--auth-failed nil)
          (remoto--effective-auth nil)
          (remoto--authenticated-user nil)
          (remoto-github-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (error "Required Github token does not exist")))
      (spy-on 'remoto--find-github-token :and-return-value nil)
      (expect (remoto--api "repos/acme/private-repo")
              :to-throw 'user-error)))

  (it "directory-files signals rather than returning silent empty list"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--auth-failed nil)
          (remoto--effective-auth nil)
          (remoto--authenticated-user nil)
          (remoto-github-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (error "Required Github token does not exist")))
      (spy-on 'remoto--find-github-token :and-return-value nil)
      (expect (directory-files "/github:acme/private@main:/")
              :to-throw 'user-error)))

  (it "file-exists-p signals rather than returning nil for auth failure"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--auth-failed nil)
          (remoto--effective-auth nil)
          (remoto--authenticated-user nil)
          (remoto-github-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (error "Required Github token does not exist")))
      (spy-on 'remoto--find-github-token :and-return-value nil)
      (expect (file-exists-p "/github:acme/private@main:/README.md")
              :to-throw 'user-error)))

  (it "insert-directory signals rather than inserting nothing"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--auth-failed nil)
          (remoto--effective-auth nil)
          (remoto--authenticated-user nil)
          (remoto-github-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (error "Required Github token does not exist")))
      (spy-on 'remoto--find-github-token :and-return-value nil)
      (expect (with-temp-buffer
                (insert-directory "/github:acme/private@main:/" "-la"))
              :to-throw 'user-error))))

;;; Fetch indicator and async completion refresh

(defvar vertico--input)

(describe "remoto--api-async in-flight counter"
  (before-each
    (spy-on 'remoto--show-status))

  (it "increments while a request is pending"
    (let ((remoto--inflight-count 0)
          (remoto--auth-failed nil)
          (remoto--effective-auth 'token))
      (spy-on 'ghub-get)
      (remoto--api-async "search/x" #'ignore)
      (expect remoto--inflight-count :to-equal 1)))

  (it "decrements once and forwards the value on success"
    (let ((remoto--inflight-count 0)
          (remoto--auth-failed nil)
          (remoto--effective-auth 'token)
          (got 'none))
      ;; ghub calls the callback as (value headers status req); the wrapper
      ;; must absorb the extra args and forward only the value, once.
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (funcall (plist-get args :callback) 'VALUE 'h 's 'r)))
      (remoto--api-async "search/x" (lambda (d) (setq got d)))
      (expect remoto--inflight-count :to-equal 0)
      (expect got :to-be 'VALUE)))

  (it "decrements once on error"
    (let ((remoto--inflight-count 0)
          (remoto--auth-failed nil)
          (remoto--effective-auth 'token))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (funcall (plist-get args :errorback) 'err 'h 's 'r)))
      (remoto--api-async "search/y" #'ignore)
      (expect remoto--inflight-count :to-equal 0)))

  (it "does not leak when ghub-get throws synchronously"
    (let ((remoto--inflight-count 0)
          (remoto--auth-failed nil)
          (remoto--effective-auth 'token))
      (spy-on 'ghub-get :and-call-fake (lambda (&rest _) (error "boom")))
      (remoto--api-async "search/z" #'ignore)
      (expect remoto--inflight-count :to-equal 0)))

  (it "stays positive when one of two overlapping fetches finishes"
    (let ((remoto--inflight-count 0)
          (remoto--auth-failed nil)
          (remoto--effective-auth 'token)
          (callbacks '()))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (push (plist-get args :callback) callbacks)))
      (remoto--api-async "a" #'ignore)
      (remoto--api-async "b" #'ignore)
      (expect remoto--inflight-count :to-equal 2)
      (funcall (car callbacks) 'V 'h 's 'r)
      (expect remoto--inflight-count :to-equal 1))))

(describe "remoto fetch indicator overlay"
  (it "renders the indicator at the end of the buffer"
    (let ((remoto--status-overlay nil))
      (with-temp-buffer
        (insert "/github:torvalds/")
        (remoto--render-status (current-buffer))
        (expect (overlayp remoto--status-overlay) :to-be-truthy)
        (expect (substring-no-properties
                 (overlay-get remoto--status-overlay 'after-string))
                :to-equal "  [fetching...]")
        (remoto--clear-status)
        (expect remoto--status-overlay :to-be nil))))

  (it "pins the cursor before the indicator so point does not jump"
    (let ((remoto--status-overlay nil))
      (with-temp-buffer
        (insert "/github:torvalds/")
        (remoto--render-status (current-buffer))
        (expect (get-text-property
                 0 'cursor
                 (overlay-get remoto--status-overlay 'after-string))
                :to-be-truthy)
        (remoto--clear-status))))

  (it "reuses one overlay across repeated renders"
    (let ((remoto--status-overlay nil))
      (with-temp-buffer
        (insert "/github:foo/")
        (remoto--render-status (current-buffer))
        (let ((first remoto--status-overlay))
          (remoto--render-status (current-buffer))
          (expect remoto--status-overlay :to-be first))
        (remoto--clear-status))))

  (it "clears the overlay when the counter reaches zero"
    (let ((remoto--inflight-count 1)
          (remoto--status-overlay nil))
      (with-temp-buffer
        (setq remoto--status-overlay (make-overlay (point-min) (point-min)))
        (remoto--inflight-dec)
        (expect remoto--inflight-count :to-equal 0)
        (expect remoto--status-overlay :to-be nil))))

  (it "keeps the overlay while requests remain"
    (let ((remoto--inflight-count 2)
          (remoto--status-overlay nil))
      (with-temp-buffer
        (setq remoto--status-overlay (make-overlay (point-min) (point-min)))
        (remoto--inflight-dec)
        (expect remoto--inflight-count :to-equal 1)
        (expect (overlayp remoto--status-overlay) :to-be-truthy)
        (remoto--clear-status))))

  (it "is a no-op without an active minibuffer"
    (let ((remoto--status-overlay nil)
          (remoto-show-fetch-indicator t))
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil)))
        (remoto--show-status))
      (expect remoto--status-overlay :to-be nil)))

  (it "respects remoto-show-fetch-indicator set to nil"
    (let ((remoto-show-fetch-indicator nil))
      (spy-on 'remoto--render-status)
      (remoto--show-status)
      (expect 'remoto--render-status :not :to-have-been-called)))

  (it "shows for the remoto-browse completion, not just /github: paths"
    (let ((remoto-show-fetch-indicator t))
      (spy-on 'remoto--render-status)
      (with-temp-buffer
        (setq-local minibuffer-completion-table #'remoto--repo-completion-table)
        (let ((buf (current-buffer)))
          (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () 'win))
                    ((symbol-function 'window-buffer) (lambda (_w) buf))
                    ((symbol-function 'minibuffer-contents-no-properties)
                     (lambda () "")))
            (remoto--show-status))))
      (expect 'remoto--render-status :to-have-been-called))))

(describe "remoto--invalidate-completion-ui"
  (it "voids the default sorted-completions cache"
    (let ((completion-all-sorted-completions 'stale)
          (post-command-hook nil))
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil)))
        (remoto--invalidate-completion-ui))
      (expect completion-all-sorted-completions :to-be nil)))

  (it "voids vertico's input cache so it recomputes"
    (let ((completion-all-sorted-completions nil)
          (post-command-hook nil)
          (vertico--input '("torvalds/" . 9)))
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil)))
        (remoto--invalidate-completion-ui))
      (expect vertico--input :to-be t)))

  (it "runs post-command-hook for hook-driven UIs"
    (let* ((ran nil)
           (completion-all-sorted-completions nil)
           (post-command-hook (list (lambda () (setq ran t)))))
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil)))
        (remoto--invalidate-completion-ui))
      (expect ran :to-be-truthy)))

  (it "does not rebuild *Completions* when it is hidden"
    (let ((completion-all-sorted-completions nil)
          (post-command-hook nil))
      (spy-on 'minibuffer-completion-help)
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) nil)))
        (remoto--invalidate-completion-ui))
      (expect 'minibuffer-completion-help :not :to-have-been-called)))

  (it "rebuilds *Completions* when it is displayed"
    (let ((completion-all-sorted-completions nil)
          (post-command-hook nil))
      (spy-on 'minibuffer-completion-help)
      (cl-letf (((symbol-function 'get-buffer-window) (lambda (&rest _) 'win)))
        (remoto--invalidate-completion-ui))
      (expect 'minibuffer-completion-help :to-have-been-called))))

(describe "remoto--with-fetch-indicator"
  (it "runs body and returns its value without UI when disabled"
    (let ((remoto-show-fetch-indicator nil)
          (ran nil))
      (spy-on 'message)
      (spy-on 'redisplay)
      (expect (remoto--with-fetch-indicator (setq ran t) 99) :to-equal 99)
      (expect ran :to-be t)
      (expect 'message :not :to-have-been-called)
      (expect 'redisplay :not :to-have-been-called)))

  (it "shows the label, forces redisplay, then clears, when enabled"
    (let ((remoto-show-fetch-indicator t)
          (ran nil))
      (spy-on 'message)
      (spy-on 'redisplay)
      (expect (remoto--with-fetch-indicator (setq ran t) 7) :to-equal 7)
      (expect ran :to-be t)
      (expect 'redisplay :to-have-been-called)
      (expect 'message :to-have-been-called-with
              "Remoto %s" remoto--fetch-indicator-text)
      (expect 'message :to-have-been-called-with nil))))

(describe "remoto-browse fetch indicator"
  (it "shows the synchronous indicator around the resolve/open fetch"
    (let ((remoto-show-fetch-indicator t))
      (spy-on 'message)
      (spy-on 'redisplay)
      (spy-on 'remoto--parse-input :and-return-value 'parsed)
      (spy-on 'remoto--resolve-ref :and-return-value 'resolved)
      (spy-on 'remoto--canonical-path :and-return-value "/github:o/r:main:/")
      (spy-on 'remoto--tree-entry :and-return-value '((type . "tree")))
      (spy-on 'dired)
      (spy-on 'find-file)
      (remoto-browse "owner/repo")
      (expect 'redisplay :to-have-been-called)
      (expect 'message :to-have-been-called-with
              "Remoto %s" remoto--fetch-indicator-text)
      (expect 'remoto--resolve-ref :to-have-been-called)
      (expect 'dired :to-have-been-called))))

;;; remoto-embark integration

(describe "remoto-embark module"
  (it "loads without embark and defines the target keymaps"
    (expect (featurep 'remoto-embark) :to-be-truthy)
    (expect (keymapp remoto-embark-repo-map) :to-be-truthy)
    (expect (keymapp remoto-embark-dir-map) :to-be-truthy)
    (expect (keymapp remoto-embark-file-map) :to-be-truthy)))

(describe "remoto--embark-target-at-point"
  (it "classifies a Dired directory entry"
    (remoto-test-with-cache
      (with-temp-buffer
        (dired-mode)
        (setq-local dired-directory "/github:testowner/testrepo@main:/")
        (spy-on 'dired-get-filename :and-return-value
                "/github:testowner/testrepo@main:/src")
        (expect (remoto--embark-target-at-point)
                :to-equal '(remoto-dir . "/github:testowner/testrepo@main:/src")))))

  (it "classifies a file buffer"
    (remoto-test-with-cache
      (with-temp-buffer
        (setq-local buffer-file-name "/github:testowner/testrepo@main:/src/main.el")
        (expect (remoto--embark-target-at-point)
                :to-equal
                '(remoto-file . "/github:testowner/testrepo@main:/src/main.el")))))

  (it "returns nil outside remoto buffers"
    (with-temp-buffer
      (setq-local buffer-file-name "/home/me/x.el")
      (expect (remoto--embark-target-at-point) :to-be nil))))

(describe "remoto-embark actions"
  (it "copies the repo web URL from a repo target (no network)"
    (remoto-test-with-cache
      (remoto-embark-copy-repo-url "/github:o/r:/")
      (expect (car kill-ring) :to-equal "https://github.com/o/r")))

  (it "copies the SSH clone URL"
    (remoto-test-with-cache
      (remoto-embark-copy-ssh-url "/github:o/r:/")
      (expect (car kill-ring) :to-equal "git@github.com:o/r.git")))

  (it "copies the HTTPS clone URL"
    (remoto-test-with-cache
      (remoto-embark-copy-https-url "/github:o/r:/")
      (expect (car kill-ring) :to-equal "https://github.com/o/r.git")))

  (it "copies the web URL for a file target"
    (remoto-test-with-cache
      (remoto-embark-copy-url "/github:testowner/testrepo@main:/src/main.el")
      (expect (car kill-ring)
              :to-equal "https://github.com/testowner/testrepo/blob/main/src/main.el")))

  (it "copies the blame URL for a file target"
    (remoto-test-with-cache
      (remoto-embark-copy-blame-url "/github:testowner/testrepo@main:/src/main.el")
      (expect (car kill-ring)
              :to-equal "https://github.com/testowner/testrepo/blame/main/src/main.el")))

  (it "browses the web URL for a directory target"
    (remoto-test-with-cache
      (spy-on 'browse-url)
      (remoto-embark-browse-url "/github:testowner/testrepo@main:/src")
      (expect 'browse-url :to-have-been-called-with
              "https://github.com/testowner/testrepo/tree/main/src"))))

(provide 'remoto-tests)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-tests.el ends here
