;;; remoto-integration-tests.el --- Integration tests for remoto.el -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;
;; Integration tests that hit the real GitHub API via ghub.
;; Require network access.  No auth token needed - all test repos
;; are public (unauthenticated rate limit: 60 req/hr, plenty for CI).
;;
;; All assertions are pinned to emacs-mirror/emacs at tag emacs-29.1
;; so tree structure, file content, and SHAs are deterministic.
;;
;; Run with: make test-integration
;;
;;; Code:

(require 'buttercup)
(require 'remoto)

(defconst remoto-itest-owner "emacs-mirror"
  "Test repo owner.")

(defconst remoto-itest-repo "emacs"
  "Test repo name.")

(defconst remoto-itest-ref "emacs-29.1"
  "Pinned tag for deterministic assertions.")

(defconst remoto-itest-prefix
  (format "/github:%s/%s@%s:" remoto-itest-owner remoto-itest-repo remoto-itest-ref)
  "Canonical path prefix for the test repo.")

(defmacro remoto-itest-with-clean-cache (&rest body)
  "Run BODY with fresh caches so each test group starts clean."
  (declare (indent 0))
  `(let ((remoto--tree-cache (make-hash-table :test 'equal))
         (remoto--default-branch-cache (make-hash-table :test 'equal))
         (remoto--content-cache (make-hash-table :test 'equal)))
     ,@body))

;;; Low-level API

(describe "integration: remoto--api"
  (it "fetches repo metadata"
    (let ((data (remoto--api
                 (format "repos/%s/%s" remoto-itest-owner remoto-itest-repo))))
      (expect (alist-get 'full_name data)
              :to-equal "emacs-mirror/emacs")))

  (it "returns alists for objects and lists for arrays"
    (let* ((data (remoto--api
                  (format "repos/%s/%s/git/trees/%s?recursive=1"
                          remoto-itest-owner remoto-itest-repo remoto-itest-ref)))
           (entries (alist-get 'tree data)))
      ;; tree should be a list, not a vector
      (expect (listp entries) :to-be-truthy)
      ;; each entry should be an alist
      (expect (listp (car entries)) :to-be-truthy)
      (expect (alist-get 'path (car entries)) :to-be-truthy)))

  (it "signals user-error on 404"
    (expect (remoto--api "repos/nonexistent-owner-xyz/nonexistent-repo-xyz")
            :to-throw 'user-error)))

;;; Default branch resolution

(describe "integration: default branch"
  (it "resolves the default branch for emacs-mirror/emacs"
    (remoto-itest-with-clean-cache
      (expect (remoto--default-branch remoto-itest-owner remoto-itest-repo)
              :to-equal "master"))))

;;; Tree fetching

(describe "integration: tree fetching"
  (it "fetches the full tree without truncation"
    (remoto-itest-with-clean-cache
      (let ((tree (remoto--fetch-tree
                   remoto-itest-owner remoto-itest-repo remoto-itest-ref)))
        ;; emacs-29.1 has ~5200 entries
        (expect (hash-table-count tree) :to-be-greater-than 5000)
        ;; not truncated
        (expect (gethash "\0truncated" tree) :to-be nil))))

  (it "includes root entry"
    (remoto-itest-with-clean-cache
      (let ((tree (remoto--fetch-tree
                   remoto-itest-owner remoto-itest-repo remoto-itest-ref)))
        (expect (gethash "" tree) :to-be-truthy)
        (expect (plist-get (gethash "" tree) :type) :to-equal "tree"))))

  (it "includes known files at expected paths"
    (remoto-itest-with-clean-cache
      (let ((tree (remoto--fetch-tree
                   remoto-itest-owner remoto-itest-repo remoto-itest-ref)))
        ;; top-level files
        (expect (gethash "README" tree) :to-be-truthy)
        (expect (plist-get (gethash "README" tree) :type) :to-equal "blob")
        ;; nested file
        (expect (gethash "lisp/emacs-lisp/cl-lib.el" tree) :to-be-truthy)
        (expect (plist-get (gethash "lisp/emacs-lisp/cl-lib.el" tree) :type)
                :to-equal "blob"))))

  (it "synthesizes intermediate directories"
    (remoto-itest-with-clean-cache
      (let ((tree (remoto--fetch-tree
                   remoto-itest-owner remoto-itest-repo remoto-itest-ref)))
        (expect (gethash "lisp" tree) :to-be-truthy)
        (expect (plist-get (gethash "lisp" tree) :type) :to-equal "tree")
        (expect (gethash "lisp/emacs-lisp" tree) :to-be-truthy)
        (expect (plist-get (gethash "lisp/emacs-lisp" tree) :type) :to-equal "tree")))))

;;; Tree entry lookup via parsed paths

(describe "integration: tree entry lookup"
  (before-all
    (setq remoto-itest--cache (make-hash-table :test 'equal))
    (setq remoto-itest--branch-cache (make-hash-table :test 'equal))
    (setq remoto-itest--content-cache (make-hash-table :test 'equal))
    (let ((remoto--tree-cache remoto-itest--cache)
          (remoto--default-branch-cache remoto-itest--branch-cache)
          (remoto--content-cache remoto-itest--content-cache))
      ;; Prime the tree cache once for all specs in this group
      (remoto--ensure-tree
       (remoto--parse-path (concat remoto-itest-prefix "/")))))

  (after-all
    (makunbound 'remoto-itest--cache)
    (makunbound 'remoto-itest--branch-cache)
    (makunbound 'remoto-itest--content-cache))

  (it "finds root directory"
    (let ((remoto--tree-cache remoto-itest--cache)
          (remoto--default-branch-cache remoto-itest--branch-cache))
      (let ((entry (remoto--tree-entry
                    (remoto--parse-path (concat remoto-itest-prefix "/")))))
        (expect entry :to-be-truthy)
        (expect (plist-get entry :type) :to-equal "tree"))))

  (it "finds a deeply nested file"
    (let ((remoto--tree-cache remoto-itest--cache)
          (remoto--default-branch-cache remoto-itest--branch-cache))
      (let ((entry (remoto--tree-entry
                    (remoto--parse-path
                     (concat remoto-itest-prefix "/lisp/emacs-lisp/cl-lib.el")))))
        (expect entry :to-be-truthy)
        (expect (plist-get entry :type) :to-equal "blob")
        (expect (plist-get entry :size) :to-be-greater-than 0))))

  (it "returns nil for nonexistent paths"
    (let ((remoto--tree-cache remoto-itest--cache)
          (remoto--default-branch-cache remoto-itest--branch-cache))
      (expect (remoto--tree-entry
               (remoto--parse-path
                (concat remoto-itest-prefix "/this/path/does/not/exist.txt")))
              :to-be nil))))

;;; Directory listing

(describe "integration: tree-children"
  (before-all
    (setq remoto-itest--cache2 (make-hash-table :test 'equal))
    (setq remoto-itest--branch-cache2 (make-hash-table :test 'equal))
    (setq remoto-itest--content-cache2 (make-hash-table :test 'equal))
    (let ((remoto--tree-cache remoto-itest--cache2)
          (remoto--default-branch-cache remoto-itest--branch-cache2)
          (remoto--content-cache remoto-itest--content-cache2))
      (remoto--ensure-tree
       (remoto--parse-path (concat remoto-itest-prefix "/")))))

  (after-all
    (makunbound 'remoto-itest--cache2)
    (makunbound 'remoto-itest--branch-cache2)
    (makunbound 'remoto-itest--content-cache2))

  (it "lists root children including known directories"
    (let ((remoto--tree-cache remoto-itest--cache2)
          (remoto--default-branch-cache remoto-itest--branch-cache2))
      (let* ((children (remoto--tree-children
                        (remoto--parse-path (concat remoto-itest-prefix "/"))))
             (names (mapcar #'car children)))
        (expect (member "README" names) :to-be-truthy)
        (expect (member "lisp" names) :to-be-truthy)
        (expect (member "src" names) :to-be-truthy)
        (expect (member "etc" names) :to-be-truthy))))

  (it "lists subdirectory children"
    (let ((remoto--tree-cache remoto-itest--cache2)
          (remoto--default-branch-cache remoto-itest--branch-cache2))
      (let* ((children (remoto--tree-children
                        (remoto--parse-path
                         (concat remoto-itest-prefix "/lisp/emacs-lisp/"))))
             (names (mapcar #'car children)))
        ;; Known files in lisp/emacs-lisp/
        (expect (member "cl-lib.el" names) :to-be-truthy)
        (expect (member "bytecomp.el" names) :to-be-truthy)
        ;; Should have many entries
        (expect (length children) :to-be-greater-than 50)))))

;;; File content

(describe "integration: file content"
  (it "fetches file content with correct first line"
    (remoto-itest-with-clean-cache
      (let ((content (remoto--fetch-file-content
                      remoto-itest-owner remoto-itest-repo
                      "README" remoto-itest-ref)))
        (expect (length content) :to-be-greater-than 100)
        (expect content :to-match "\\`Copyright"))))

  (it "caches content by SHA"
    (remoto-itest-with-clean-cache
      ;; Fetch once
      (remoto--fetch-file-content
       remoto-itest-owner remoto-itest-repo "README" remoto-itest-ref)
      (expect (hash-table-count remoto--content-cache) :to-be-greater-than 0)
      ;; Second fetch should use cache (we can't easily count API calls,
      ;; but we can verify the cache has the entry)
      (let ((cached-content
             (car (hash-table-values remoto--content-cache))))
        (expect cached-content :to-match "\\`Copyright")))))

;;; Full file-name-handler path

(describe "integration: file-name-handler"
  (before-all
    (setq remoto-itest--cache3 (make-hash-table :test 'equal))
    (setq remoto-itest--branch-cache3 (make-hash-table :test 'equal))
    (setq remoto-itest--content-cache3 (make-hash-table :test 'equal))
    (let ((remoto--tree-cache remoto-itest--cache3)
          (remoto--default-branch-cache remoto-itest--branch-cache3)
          (remoto--content-cache remoto-itest--content-cache3))
      (remoto--ensure-tree
       (remoto--parse-path (concat remoto-itest-prefix "/")))))

  (after-all
    (makunbound 'remoto-itest--cache3)
    (makunbound 'remoto-itest--branch-cache3)
    (makunbound 'remoto-itest--content-cache3))

  (it "file-exists-p returns t for known files"
    (let ((remoto--tree-cache remoto-itest--cache3)
          (remoto--default-branch-cache remoto-itest--branch-cache3))
      (expect (file-exists-p (concat remoto-itest-prefix "/README"))
              :to-be-truthy)))

  (it "file-exists-p returns nil for missing files"
    (let ((remoto--tree-cache remoto-itest--cache3)
          (remoto--default-branch-cache remoto-itest--branch-cache3))
      (expect (file-exists-p (concat remoto-itest-prefix "/NOPE.txt"))
              :not :to-be-truthy)))

  (it "file-directory-p works for directories"
    (let ((remoto--tree-cache remoto-itest--cache3)
          (remoto--default-branch-cache remoto-itest--branch-cache3))
      (expect (file-directory-p (concat remoto-itest-prefix "/lisp"))
              :to-be-truthy)
      (expect (file-directory-p (concat remoto-itest-prefix "/README"))
              :not :to-be-truthy)))

  (it "file-regular-p works for files"
    (let ((remoto--tree-cache remoto-itest--cache3)
          (remoto--default-branch-cache remoto-itest--branch-cache3))
      (expect (file-regular-p (concat remoto-itest-prefix "/README"))
              :to-be-truthy)
      (expect (file-regular-p (concat remoto-itest-prefix "/lisp"))
              :not :to-be-truthy)))

  (it "directory-files lists entries with . and .."
    (let ((remoto--tree-cache remoto-itest--cache3)
          (remoto--default-branch-cache remoto-itest--branch-cache3))
      (let ((files (directory-files (concat remoto-itest-prefix "/"))))
        (expect (member "." files) :to-be-truthy)
        (expect (member ".." files) :to-be-truthy)
        (expect (member "README" files) :to-be-truthy)
        (expect (member "lisp" files) :to-be-truthy))))

  (it "file-attributes returns plausible size"
    (let ((remoto--tree-cache remoto-itest--cache3)
          (remoto--default-branch-cache remoto-itest--branch-cache3))
      (let ((attrs (file-attributes (concat remoto-itest-prefix "/README"))))
        (expect attrs :to-be-truthy)
        (expect (file-attribute-size attrs) :to-be-greater-than 100)))))

(provide 'remoto-integration-tests)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-integration-tests.el ends here
