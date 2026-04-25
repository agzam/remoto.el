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
  '(("README.md" (:type "blob" :size 500 :sha "aaa" :mode "100644"))
    ("src" (:type "tree" :size 0 :sha "bbb" :mode "040000"))
    ("src/main.el" (:type "blob" :size 1234 :sha "ccc" :mode "100644"))
    ("src/utils.el" (:type "blob" :size 567 :sha "ddd" :mode "100644"))
    ("bin/run" (:type "blob" :size 42 :sha "eee" :mode "100755"))
    ("bin" (:type "tree" :size 0 :sha "fff" :mode "040000"))
    ("" (:type "tree" :size 0 :sha "" :mode "040000"))
    ("/" (:type "tree" :size 0 :sha "" :mode "040000")))
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
         (remoto--content-cache (make-hash-table :test 'equal)))
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
             (entry-type (plist-get entry :type))
             (entry-size (plist-get entry :size)))
        (expect entry :to-be-truthy)
        (expect entry-type :to-equal "blob")
        (expect entry-size :to-equal 500))))

  (it "finds a directory entry"
    (remoto-test-with-cache
      (let* ((entry (remoto--tree-entry
                     (remoto--parse-path "/github:testowner/testrepo@main:/src")))
             (entry-type (plist-get entry :type)))
        (expect entry :to-be-truthy)
        (expect entry-type :to-equal "tree"))))

  (it "finds root entry"
    (remoto-test-with-cache
      (let* ((entry (remoto--tree-entry
                     (remoto--parse-path "/github:testowner/testrepo@main:/")))
             (entry-type (plist-get entry :type)))
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
        (expect (plist-get entry :sha) :to-equal "ccc")))))

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
        (puthash "" '(:type "tree" :size 0 :sha "" :mode "040000") table)
        (puthash "/" '(:type "tree" :size 0 :sha "" :mode "040000") table)
        (puthash "src" '(:type "tree" :size 0 :sha "bbb" :mode "040000") table)
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
             (entry-type (plist-get entry :type)))
        (expect entry :to-be-truthy)
        (expect entry-type :to-equal "blob")
        (expect (plist-get entry :sha) :to-equal "ccc"))))

  (it "fetches directory children on demand"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--content-cache (make-hash-table :test 'equal)))
      (puthash "testowner/testrepo" "main" remoto--default-branch-cache)
      (let ((table (make-hash-table :test 'equal)))
        (puthash "" '(:type "tree" :size 0 :sha "" :mode "040000") table)
        (puthash "/" '(:type "tree" :size 0 :sha "" :mode "040000") table)
        (puthash "src" '(:type "tree" :size 0 :sha "bbb" :mode "040000") table)
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

  (it "does not re-fetch already fetched directories"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--content-cache (make-hash-table :test 'equal))
          (api-call-count 0))
      (puthash "testowner/testrepo" "main" remoto--default-branch-cache)
      (let ((table (make-hash-table :test 'equal)))
        (puthash "" '(:type "tree" :size 0 :sha "" :mode "040000") table)
        (puthash "/" '(:type "tree" :size 0 :sha "" :mode "040000") table)
        (puthash "src" '(:type "tree" :size 0 :sha "bbb" :mode "040000") table)
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
                :to-equal "/tmp/foo")))))

;;; Dired listing format

(describe "remoto--format-dired-entry"
  (it "formats a file entry"
    (let ((line (remoto--format-dired-entry
                 "file.el" '(:type "blob" :size 1234 :mode "100644"))))
      (expect line :to-match "^-rw-r--r--")
      (expect line :to-match "1234")
      (expect line :to-match "file\\.el")))

  (it "formats a directory entry"
    (let ((line (remoto--format-dired-entry
                 "src" '(:type "tree" :size 0 :mode "040000"))))
      (expect line :to-match "^drwxr-xr-x")))

  (it "formats an executable entry"
    (let ((line (remoto--format-dired-entry
                 "run" '(:type "blob" :size 42 :mode "100755"))))
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

;;; Repository search

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
      (expect captured :to-equal '("torvalds/linux")))))

(describe "remoto--read-repo"
  (it "passes URLs straight through without consult"
    (spy-on 'featurep :and-call-fake
            (lambda (feature &rest _)
              (not (eq feature 'consult))))
    (spy-on 'read-string :and-return-value "https://github.com/torvalds/linux")
    (expect (remoto--read-repo) :to-equal "https://github.com/torvalds/linux"))

  (it "passes owner/repo straight through without consult"
    (spy-on 'featurep :and-call-fake
            (lambda (feature &rest _)
              (not (eq feature 'consult))))
    (spy-on 'read-string :and-return-value "torvalds/linux")
    (expect (remoto--read-repo) :to-equal "torvalds/linux"))

  (it "searches and prompts for bare owner without consult"
    (spy-on 'featurep :and-call-fake
            (lambda (feature &rest _)
              (not (eq feature 'consult))))
    (spy-on 'read-string :and-return-value "torvalds")
    (spy-on 'remoto--search-repos :and-return-value
            '("torvalds/linux" "torvalds/subsurface"))
    (spy-on 'completing-read :and-return-value "torvalds/linux")
    (expect (remoto--read-repo) :to-equal "torvalds/linux")
    (expect 'completing-read :to-have-been-called))

  (it "uses consult--read when consult is loaded"
    (spy-on 'featurep :and-call-fake
            (lambda (feature &rest _)
              (or (eq feature 'consult) t)))
    ;; Simulate consult functions being available
    (cl-letf (((symbol-function 'consult--read)
               (lambda (_collection &rest _args) "magit/magit"))
              ((symbol-function 'consult--dynamic-collection)
               (lambda (fun) fun)))
      (expect (remoto--read-repo) :to-equal "magit/magit"))))

(provide 'remoto-tests)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-tests.el ends here
