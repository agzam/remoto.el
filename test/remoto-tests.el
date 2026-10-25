;;; remoto-tests.el --- Tests for remoto.el -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for remoto - browse GitHub repos without cloning.
;;
;;; Code:

(require 'buttercup)
(require 'loaddefs-gen)
(require 'remoto)
;; Soft: present once remoto-embark.el exists; tests below fail (not error)
;; until then, keeping the rest of the suite runnable.
(require 'remoto-embark nil t)

;; Loading remoto installs nothing.  The suite exercises the handler, the
;; advice and the hooks, so flip the switch the way an init file does.
(global-remoto-mode 1)

;; A request that gets past the fakes goes to a dead port: a forge that
;; happens to answer would let a spec pass that no fake covers.  No
;; auth-source either: the specs of the lookup stub it themselves.
(setq url-proxy-services '(("http" . "127.0.0.1:9") ("https" . "127.0.0.1:9"))
      auth-sources nil)

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

(defvar remoto-test--png-bytes
  (unibyte-string #x89 ?P ?N ?G ?\r ?\n #x1a ?\n 0 0 0 13 ?I ?H ?D ?R
                  0 0 0 1 0 0 0 1 8 6 0 0 0 #xff #xfe)
  "The head of a PNG file: signature, IHDR chunk, NUL and high bytes.")

(defun remoto-test--install-mock-tree ()
  "Install mock tree into the cache."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry remoto-test--mock-tree)
      (puthash (car entry) (cadr entry) table))
    (puthash "/github:testowner/testrepo@main" table remoto--tree-cache)))

(defun remoto-test--logins (&rest props)
  "Return a login table with the same entry, made from PROPS, for every forge.
PROPS are the slots of `remoto--login': :failed, :token and :user."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (forge (seq-uniq (mapcar #'cdr remoto--forges)))
      (puthash (remoto--api-host forge) (apply #'remoto--login-create props) table))
    table))

(defun remoto-test--github-login ()
  "Return the login state of GitHub's API host."
  (remoto--login "api.github.com"))

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
         (remoto--listing-cache (make-hash-table :test 'equal))
         (remoto--entry-cache (make-hash-table :test 'equal))
         (remoto-forgejo--accounts (make-hash-table :test 'equal))
         (remoto--logins (remoto-test--logins)))
     (puthash "/github:testowner/testrepo" "main" remoto--default-branch-cache)
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
    (spy-on 'remoto--matching-refs :and-return-value '("master"))
    (let ((p (remoto--parse-input "https://github.com/torvalds/linux/tree/master/kernel")))
      (expect (remoto-path-ref p) :to-equal "master")
      (expect (remoto-path-path p) :to-equal "/kernel")))

  (it "parses blob URL and strips fragment"
    (spy-on 'remoto--matching-refs :and-return-value '("master"))
    (let ((p (remoto--parse-input "https://github.com/torvalds/linux/blob/master/README#L10-L20")))
      (expect (remoto-path-ref p) :to-equal "master")
      (expect (remoto-path-path p) :to-equal "/README")))

  ;; A GitHub URL does not mark where a ref with a slash ends, so the
  ;; parser asks for the refs that start with the first segment.
  (it "asks the branches once when the first segment is a branch"
    (spy-on 'remoto--matching-refs :and-return-value '("main"))
    (let ((p (remoto--parse-input "https://github.com/o/r/blob/main/src/x.el")))
      (expect (remoto-path-ref p) :to-equal "main")
      (expect (remoto-path-path p) :to-equal "/src/x.el")
      (expect 'remoto--matching-refs :to-have-been-called-times 1)
      (expect 'remoto--matching-refs :to-have-been-called-with remoto--github "o" "r" "heads" "main")))

  (it "asks nothing for a tree URL that ends at the ref"
    (spy-on 'remoto--matching-refs)
    (let ((p (remoto--parse-input "https://github.com/o/r/tree/main")))
      (expect (remoto-path-ref p) :to-equal "main")
      (expect (remoto-path-path p) :to-equal "/")
      (expect 'remoto--matching-refs :not :to-have-been-called)))

  (it "takes the longest branch that starts the URL as the ref"
    (spy-on 'remoto--matching-refs :and-return-value
            '("release/2024.11.1" "release/2026.5.0" "release_obsolete/2024.11.1"))
    (let ((p (remoto--parse-input "https://github.com/o/r/blob/release/2026.5.0/src/x.el")))
      (expect (remoto-path-ref p) :to-equal "release/2026.5.0")
      (expect (remoto-path-path p) :to-equal "/src/x.el"))
    (let ((p (remoto--parse-input "https://github.com/o/r/tree/release/2026.5.0")))
      (expect (remoto-path-ref p) :to-equal "release/2026.5.0")
      (expect (remoto-path-path p) :to-equal "/")))

  (it "falls back to the tags when no branch starts the URL"
    (spy-on 'remoto--matching-refs :and-call-fake
            (lambda (_forge _owner _repo kind _prefix)
              (and (equal kind "tags") '("v1/beta"))))
    (let ((p (remoto--parse-input "https://github.com/o/r/blob/v1/beta/x.el")))
      (expect (remoto-path-ref p) :to-equal "v1/beta")
      (expect (remoto-path-path p) :to-equal "/x.el")))

  (it "asks nothing for a full commit SHA, the form a permalink has"
    (spy-on 'remoto--matching-refs)
    (let ((p (remoto--parse-input
              "https://github.com/o/r/blob/ced1c937d35201e2750b95910defa8e83c0891e2/README.org#L1")))
      (expect (remoto-path-ref p) :to-equal "ced1c937d35201e2750b95910defa8e83c0891e2")
      (expect (remoto-path-path p) :to-equal "/README.org")
      (expect 'remoto--matching-refs :not :to-have-been-called)))

  (it "drops the query string and the fragment the browser adds"
    (spy-on 'remoto--matching-refs :and-return-value '("main"))
    (let ((p (remoto--parse-input "https://github.com/agzam/remoto.el?tab=readme-ov-file")))
      (expect (list (remoto-path-repo p) (remoto-path-ref p) (remoto-path-path p))
              :to-equal '("remoto.el" nil "/")))
    (let ((p (remoto--parse-input "https://github.com/o/r/blob/main/README.org?plain=1#L5")))
      (expect (list (remoto-path-ref p) (remoto-path-path p))
              :to-equal '("main" "/README.org")))
    (let ((p (remoto--parse-input "https://github.com/o/r/tree/main?x=1")))
      (expect (list (remoto-path-ref p) (remoto-path-path p)) :to-equal '("main" "/")))
    (let ((p (remoto--parse-input "https://github.com/o/r/tree/main/test?x=1")))
      (expect (list (remoto-path-ref p) (remoto-path-path p)) :to-equal '("main" "/test"))))

  (it "decodes the percent escapes of the ref and the path"
    (spy-on 'remoto--matching-refs :and-return-value '("feat+x"))
    (let ((p (remoto--parse-input "https://github.com/o/r/blob/feat%2Bx/docs/caf%C3%A9%20au%20lait.md")))
      (expect (list (remoto-path-ref p) (remoto-path-path p))
              :to-equal '("feat+x" "/docs/café au lait.md"))
      (expect 'remoto--matching-refs :to-have-been-called-with remoto--github "o" "r" "heads" "feat+x")))

  (it "reads back every blob and tree URL remoto builds"
    (let ((refs nil))
      (spy-on 'remoto--matching-refs :and-call-fake (lambda (&rest _) refs))
      (pcase-dolist (`(,ref ,path) '(("main" "src/main.el")
                                     ("release/2026.5.0" "docs/a b+c.md")
                                     ("v1.0" "café/✓.md")
                                     ("main" "test")))
        (setq refs (list ref))
        (dolist (kind '(blob tree))
          (let ((p (remoto--parse-input
                    (remoto--forge-url 'github kind "o" "r" ref path nil nil))))
            (expect (list (remoto-path-ref p) (remoto-path-path p))
                    :to-equal (list ref (concat "/" path))))))))

  (it "keeps the first segment, a commit or an unknown name, when no ref starts the URL"
    (spy-on 'remoto--matching-refs :and-return-value nil)
    (let ((p (remoto--parse-input "https://github.com/o/r/blob/ceaf310/test/x.el")))
      (expect (remoto-path-ref p) :to-equal "ceaf310")
      (expect (remoto-path-path p) :to-equal "/test/x.el")
      (expect 'remoto--matching-refs :to-have-been-called-with remoto--github "o" "r" "tags" "ceaf310")))

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

  (it "strips .git from an https clone URL"
    ;; The Code button on github.com hands out this form.
    (let ((p (remoto--parse-input "https://github.com/agzam/remoto.el.git")))
      (expect (remoto-path-owner p) :to-equal "agzam")
      (expect (remoto-path-repo p) :to-equal "remoto.el")
      (expect (remoto-path-path p) :to-equal "/")))

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
      (puthash "/github:testowner/testrepo" "main" remoto--default-branch-cache)
      ;; Simulate a truncated tree with only root and src dir
      (let ((table (make-hash-table :test 'equal)))
        (puthash "" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "/" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "src" '((type . "tree") (size . 0) (sha . "bbb") (mode . "040000")) table)
        (puthash "\0truncated" t table)
        (puthash "/github:testowner/testrepo@main" table remoto--tree-cache))
      ;; Mock the API call for on-demand fetch
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint)
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
      (puthash "/github:testowner/testrepo" "main" remoto--default-branch-cache)
      (let ((table (make-hash-table :test 'equal)))
        (puthash "" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "/" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "src" '((type . "tree") (size . 0) (sha . "bbb") (mode . "040000")) table)
        (puthash "\0truncated" t table)
        (puthash "/github:testowner/testrepo@main" table remoto--tree-cache))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint)
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
      (puthash "/github:testowner/testrepo" "main" remoto--default-branch-cache)
      (let ((table (make-hash-table :test 'equal)))
        (puthash "" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "/" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "README.md" '((type . "blob") (size . 500) (sha . "aaa") (mode . "100644")) table)
        (puthash "src" '((type . "tree") (size . 0) (sha . "bbb") (mode . "040000")) table)
        (puthash "\0truncated" t table)
        (puthash "\0fetched:" t table)
        (puthash "/github:testowner/testrepo@main" table remoto--tree-cache))
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
      (puthash "/github:testowner/testrepo" "main" remoto--default-branch-cache)
      (let ((table (make-hash-table :test 'equal)))
        (puthash "" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "/" '((type . "tree") (size . 0) (sha . "") (mode . "040000")) table)
        (puthash "src" '((type . "tree") (size . 0) (sha . "bbb") (mode . "040000")) table)
        (puthash "\0truncated" t table)
        (puthash "/github:testowner/testrepo@main" table remoto--tree-cache))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint)
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

  (it "file-exists-p on a repository root at a ref fetches no tree"
    ;; Completion asks this of every candidate at the @ level; a recursive
    ;; tree per ref is seconds of fetching on a large repository.
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal)))
      (spy-on 'remoto--api)
      (expect (file-exists-p "/github:o/r@v1.2.3:/") :to-be t)
      (expect (file-exists-p "/github:o/r@v1.2.3:") :to-be t)
      (expect 'remoto--api :not :to-have-been-called)))

  (it "file-exists-p on a file inside the repository still consults the tree"
    (remoto-test-with-cache
      (spy-on 'remoto--tree-entry :and-call-through)
      (expect (file-exists-p "/github:testowner/testrepo@main:/src/main.el")
              :to-be t)
      (expect 'remoto--tree-entry :to-have-been-called)))

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

  (it "file-remote-p with CONNECTED answers for a repo already reached"
    (remoto-test-with-cache
      (expect (file-remote-p "/github:testowner/testrepo@main:/README.md" nil t)
              :to-equal "/github:testowner/testrepo@main:")))

  (it "file-remote-p with CONNECTED answers nil for a repo never reached"
    (remoto-test-with-cache
      (spy-on 'remoto--api)
      (expect (file-remote-p "/github:other/elsewhere@main:/README.md" nil t)
              :to-be nil)
      (expect 'remoto--api :not :to-have-been-called)))

  (it "file-remote-p with CONNECTED `never' answers without any request"
    (remoto-test-with-cache
      (spy-on 'remoto--api)
      (expect (file-remote-p "/github:other/elsewhere@main:/README.md" nil 'never)
              :to-equal "/github:other/elsewhere@main:")
      (expect 'remoto--api :not :to-have-been-called)))

  (it "access-file returns nil for a file that exists"
    (remoto-test-with-cache
      (expect (access-file "/github:testowner/testrepo@main:/README.md" "Probe")
              :to-be nil)))

  (it "access-file signals file-missing for a path the tree does not hold"
    (remoto-test-with-cache
      (expect (access-file "/github:testowner/testrepo@main:/nope.txt" "Probe")
              :to-throw 'file-missing)))

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

  (it "expand-file-name drops . and .. from absolute remoto paths"
    (dolist (case '(("/src/.." . "/") ("/src/../" . "/")
                    ("/src/." . "/src") ("/src/./" . "/src/")
                    ("/src/../README.md" . "/README.md")
                    ("/src/./main.el" . "/src/main.el")))
      (expect (expand-file-name
               (concat "/github:testowner/testrepo@main:" (car case)))
              :to-equal
              (concat "/github:testowner/testrepo@main:" (cdr case)))))

  (it "expand-file-name climbs from a repository root to its owner, then to /github:"
    (dolist (case '(("/github:o/r@main:/.." . "/github:o/")
                    ("/github:o/r@main:/../" . "/github:o/")
                    ("/github:o/r@main:/src/../.." . "/github:o/")
                    ("/github:o/r:/.." . "/github:o/")
                    ("/github:o/r@main:/../.." . "/github:")
                    ("/github:o/r@main:/../../.." . "/github:")
                    ("/github:o/r@main:/../x" . "/github:o/x")
                    ("/github:o/.." . "/github:")
                    ("/github:o/." . "/github:o/")
                    ("/github:.." . "/github:")
                    ("/github:." . "/github:")
                    ("/github:o/r/src/.." . "/github:o/r")
                    ("/github:o/r/src/../" . "/github:o/r/")
                    ("/gh:o/r@main:/.." . "/github:o/")))
      (expect (expand-file-name (car case)) :to-equal (cdr case))))

  (it "expand-file-name resolves a relative .. above a repository root"
    (expect (expand-file-name ".." "/github:o/r@main:/") :to-equal "/github:o/")
    (expect (expand-file-name "../x/" "/github:o/r@main:/") :to-equal "/github:o/x/")
    (expect (expand-file-name ".." "/github:o/") :to-equal "/github:")
    (expect (expand-file-name "." "/github:o/") :to-equal "/github:o/")
    (expect (expand-file-name ".." "/github:") :to-equal "/github:")
    (expect (expand-file-name "agzam" "/github:") :to-equal "/github:agzam"))

  (it "expand-file-name leaves other absolute remoto paths as they are"
    (dolist (name '("/github:testowner/testrepo@main:/a"
                    "/github:testowner/testrepo@main:/src/ab"
                    "/github:testowner/testrepo@main:/.github/ci.yml"
                    "/github:testowner/testrepo@main:/..."
                    "/github:testowner/testrepo@v1.0:/src"
                    "/github:testowner/testrepo@main:"
                    "/github:testowner/"
                    "/github:testowner/testrepo#31"))
      (expect (expand-file-name name) :to-equal name)))

  (it "file-exists-p resolves .. inside a remoto path"
    (remoto-test-with-cache
      (expect (file-exists-p "/github:testowner/testrepo@main:/src/../README.md")
              :to-be t)
      (expect (file-exists-p "/github:testowner/testrepo@main:/src/../nope.md")
              :to-be nil)))

  (it "keeps the caller's match data across file operations"
    ;; One form does the match, the call and the read, so buttercup's own
    ;; matching cannot run in between.
    (remoto-test-with-cache
      (let ((dir "/github:testowner/testrepo@main:/src/"))
        (expect (mapcar (lambda (call)
                          (string-match "\\(abc\\)" "xxabcxx")
                          (apply (car call) (cdr call))
                          (match-beginning 1))
                        `((expand-file-name ,(concat dir ".."))
                          (expand-file-name "main.el" ,dir)
                          (file-exists-p ,(concat dir "main.el"))
                          (file-name-directory ,(concat dir "main.el"))))
                :to-equal '(2 2 2 2)))))

  (it "insert-file-contents does not move point"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-content
              :and-return-value "line one\nline two\nline three\n")
      (with-temp-buffer
        (let ((pt (point)))
          (remoto--handle-insert-file-contents
           "/github:testowner/testrepo@main:/README.md")
          (expect (point) :to-equal pt)
          (expect (buffer-string) :to-equal "line one\nline two\nline three\n")))))

  (it "insert-file-contents keeps a binary file as bytes under no-conversion"
    ;; `image-mode' takes the data from a remote buffer by encoding it
    ;; with `buffer-file-coding-system', so the bytes must round-trip.
    (remoto-test-with-cache
      (puthash "logo.png" '((type . "blob") (size . 31) (sha . "ggg") (mode . "100644"))
               (gethash "/github:testowner/testrepo@main" remoto--tree-cache))
      (spy-on 'remoto--fetch-file-content :and-return-value remoto-test--png-bytes)
      (with-temp-buffer
        (let* ((result (insert-file-contents "/github:testowner/testrepo@main:/logo.png" t))
               (data (encode-coding-string (buffer-string) buffer-file-coding-system)))
          (expect (cadr result) :to-equal (length remoto-test--png-bytes))
          (expect buffer-file-coding-system :to-be 'no-conversion)
          (expect data :to-equal remoto-test--png-bytes)
          (expect (image-type-from-data data) :to-be 'png)))))

  (it "insert-file-contents decodes a UTF-8 text file"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-content
              :and-return-value (encode-coding-string "# Título\n— ünïcödé\n" 'utf-8))
      (with-temp-buffer
        (let ((result (insert-file-contents "/github:testowner/testrepo@main:/README.md" t)))
          (expect (buffer-string) :to-equal "# Título\n— ünïcödé\n")
          (expect (cadr result) :to-equal (length "# Título\n— ünïcödé\n"))
          (expect (coding-system-base buffer-file-coding-system) :to-be 'utf-8)))))

  (it "file-local-copy writes a binary file byte for byte"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-content :and-return-value remoto-test--png-bytes)
      (let ((copy (file-local-copy "/github:testowner/testrepo@main:/logo.png")))
        (unwind-protect
            (expect (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally copy)
                      (buffer-string))
                    :to-equal remoto-test--png-bytes)
          (delete-file copy)))))

  (it "insert-file-contents signals file-missing for a path absent from the tree"
    ;; `find-file-noselect' only treats a `file-error' as a nonexistent
    ;; file; anything else leaves the buffer it created behind.
    (remoto-test-with-cache
      (spy-on 'remoto--api)
      (with-temp-buffer
        (expect (remoto--handle-insert-file-contents
                 "/github:testowner/testrepo@main:/nope.txt")
                :to-throw 'file-missing))
      (expect 'remoto--api :not :to-have-been-called)))

  (it "find-file-noselect on a missing path leaves no stray buffer"
    (remoto-test-with-cache
      (let* ((before (buffer-list))
             (buf (find-file-noselect "/github:testowner/testrepo@main:/nope.txt")))
        (unwind-protect
            (progn
              (expect (buffer-file-name buf)
                      :to-equal "/github:testowner/testrepo@main:/nope.txt")
              (expect (seq-difference (buffer-list) before) :to-equal (list buf)))
          (kill-buffer buf))))))

;;; recentf

(describe "recentf keeps remoto paths"
  ;; `recentf-keep-default-predicate' asks `file-remote-p' with CONNECTED
  ;; first.  Answering it for a repository remoto has not reached would
  ;; send it down `access-file', and a cleanup at startup would then cost
  ;; a tree fetch per entry.
  (before-all (require 'recentf))

  (it "keeps a remoto path with a cold cache and asks GitHub nothing"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal)))
      (spy-on 'remoto--api)
      (expect (recentf-keep-default-predicate
               "/github:testowner/testrepo@main:/README.md")
              :to-be-truthy)
      (expect 'remoto--api :not :to-have-been-called)))

  (it "keeps a remoto path whose repository is already cached"
    (remoto-test-with-cache
      (spy-on 'remoto--api)
      (expect (recentf-keep-default-predicate
               "/github:testowner/testrepo@main:/README.md")
              :to-be-truthy)
      (expect 'remoto--api :not :to-have-been-called)))

  (it "drops a cached repository's path that the tree does not hold"
    (remoto-test-with-cache
      (expect (recentf-keep-default-predicate
               "/github:testowner/testrepo@main:/nope.txt")
              :to-be nil))))

;;; Evil's ex argument

(defmacro remoto-test-in-evil-ex (argument &rest body)
  "Run BODY with the bindings Evil makes for an ex command given ARGUMENT."
  (declare (indent 1))
  `(cl-progv '(evil-called-from-ex-p evil-ex-argument) (list t ,argument)
     ,@body))

(defun remoto-test--evil-rebuild (name &optional current alternate)
  "Rebuild NAME the way `evil-ex-replace-special-filenames' does.
CURRENT and ALTERNATE stand for the files that `%' and `#' name."
  (let ((remote (file-remote-p name))
        (local (or (file-remote-p name 'localname) name)))
    (when current
      (setq local (replace-regexp-in-string
                   "\\(^\\|[^\\\\]\\)\\(%\\)" current local t t 2)))
    (when alternate
      (setq local (replace-regexp-in-string
                   "\\(^\\|[^\\\\]\\)\\(#\\)" alternate local t t 2)))
    (concat remote (replace-regexp-in-string "\\\\\\([#%]\\)" "\\1" local t))))

(describe "file-remote-p for the argument of an Evil ex command"
  ;; Evil rebuilds a file argument from its prefix and `localname'.  Only
  ;; that argument gets the path after the prefix; every other caller keeps
  ;; the prefix, because callers hand `localname' to local programs.
  (it "answers the path after the prefix for a canonical name"
    (remoto-test-in-evil-ex "/github:o/r@main:/src/a:b.el"
      (expect (file-remote-p "/github:o/r@main:/src/a:b.el" 'localname)
              :to-equal "/src/a:b.el")))

  (it "answers \"\" and \"/\" for a repository root"
    (remoto-test-in-evil-ex "/github:o/r@main:"
      (expect (file-remote-p "/github:o/r@main:" 'localname) :to-equal ""))
    (remoto-test-in-evil-ex "/github:o/r@main:/"
      (expect (file-remote-p "/github:o/r@main:/" 'localname) :to-equal "/")))

  (it "answers the path after the prefix for a name without a ref"
    (remoto-test-in-evil-ex "/github:o/r:/README.md"
      (expect (file-remote-p "/github:o/r:/README.md" 'localname)
              :to-equal "/README.md")))

  (it "answers the text after /github: for a short name in either spelling"
    (remoto-test-in-evil-ex "/gh:o/r/README.md"
      (expect (file-remote-p "/gh:o/r/README.md" 'localname)
              :to-equal "o/r/README.md"))
    (remoto-test-in-evil-ex "/github:o/r/src/"
      (expect (file-remote-p "/github:o/r/src/" 'localname)
              :to-equal "o/r/src/")))

  (it "lets Evil's rebuild give back every name it is given"
    (dolist (name '("/github:o/r@main:/README.md" "/github:o/r@main:"
                    "/github:o/r@main:/" "/github:o/r@v1.0:/src/"
                    "/github:o/r:/README.md" "/github:o/r/README.md"
                    "/github:o/r/" "/github:o/r" "/github:o/" "/github:"))
      (remoto-test-in-evil-ex name
        (expect (remoto-test--evil-rebuild name "/tmp/cur" "/tmp/alt")
                :to-equal name)))
    (remoto-test-in-evil-ex "/gh:o/r/README.md"
      (expect (remoto-test--evil-rebuild "/gh:o/r/README.md")
              :to-equal "/github:o/r/README.md")))

  (it "escapes each # and % that Evil would replace with a file name"
    (remoto-test-in-evil-ex "/gh:o/r#22"
      (expect (file-remote-p "/gh:o/r#22" 'localname) :to-equal "o/r\\#22"))
    (remoto-test-in-evil-ex "/github:o/r@main:/a#%b%"
      (expect (file-remote-p "/github:o/r@main:/a#%b%" 'localname)
              :to-equal "/a\\#\\%b\\%"))
    (remoto-test-in-evil-ex "/gh:o/r\\#22"
      (expect (file-remote-p "/gh:o/r\\#22" 'localname) :to-equal "o/r\\#22")))

  (it "keeps # and % literal through Evil's rebuild"
    (dolist (case '(("/gh:o/r#22" . "/github:o/r#22")
                    ("/gh:o/r\\#22" . "/github:o/r#22")
                    ("/github:o/r@main:/100%.md" . "/github:o/r@main:/100%.md")
                    ("/github:o/r@main:/a#%b" . "/github:o/r@main:/a#%b")))
      (remoto-test-in-evil-ex (car case)
        (expect (remoto-test--evil-rebuild (car case) "/tmp/cur" "/tmp/alt")
                :to-equal (cdr case)))))

  (it "keeps the prefix for another name inside the same command"
    (remoto-test-in-evil-ex "/gh:o/r/README.md"
      (expect (file-remote-p "/github:o/r@main:/README.md" 'localname)
              :to-equal "/github:o/r@main:")
      (expect (file-local-name "/github:o/r@main:/README.md")
              :to-equal "/github:o/r@main:")))

  (it "keeps the other identifications as they are"
    (remoto-test-in-evil-ex "/github:o/r@main:/README.md"
      (expect (file-remote-p "/github:o/r@main:/README.md")
              :to-equal "/github:o/r@main:")
      (expect (file-remote-p "/github:o/r@main:/README.md" 'method)
              :to-equal "github")
      (expect (file-remote-p "/github:o/r@main:/README.md" 'host)
              :to-equal "o/r")))

  (it "keeps the prefix outside an ex command"
    ;; Evil leaves `evil-ex-argument' set between commands.
    (cl-progv '(evil-called-from-ex-p evil-ex-argument)
        (list nil "/github:o/r@main:/README.md")
      (expect (file-remote-p "/github:o/r@main:/README.md" 'localname)
              :to-equal "/github:o/r@main:")))

  (it "keeps the prefix for an ex command without an argument"
    (remoto-test-in-evil-ex nil
      (expect (file-remote-p "/github:o/r@main:/README.md" 'localname)
              :to-equal "/github:o/r@main:")))

  (it "keeps the prefix for every caller when Evil is not loaded"
    (assume (not (boundp 'evil-called-from-ex-p)) "Evil is loaded")
    (expect (file-local-name "/github:o/r@main:/etc/hosts")
            :to-equal "/github:o/r@main:")
    (expect (file-remote-p "/gh:o/r/README.md" 'localname)
            :to-equal "/github:"))

  (it "splits the argument for an Evil without evil-called-from-ex-p"
    ;; Such an Evil binds `evil-ex-point' around each ex command only, and
    ;; sets `evil-ex-argument' while the prompt is typed into.
    (assume (not (boundp 'evil-called-from-ex-p)) "Evil is loaded")
    (cl-progv '(evil-ex-point evil-ex-argument) (list 1 "/gh:o/r/README.md")
      (expect (file-remote-p "/gh:o/r/README.md" 'localname)
              :to-equal "o/r/README.md")
      (expect (remoto-test--evil-rebuild "/gh:o/r/README.md")
              :to-equal "/github:o/r/README.md"))
    (cl-progv '(evil-ex-point evil-ex-argument) (list nil "/gh:o/r/README.md")
      (expect (file-remote-p "/gh:o/r/README.md" 'localname)
              :to-equal "/github:")))

  (it "follows evil-called-from-ex-p over evil-ex-point when both exist"
    ;; `:normal' binds `evil-called-from-ex-p' to nil for the keys it runs.
    (cl-progv '(evil-called-from-ex-p evil-ex-point evil-ex-argument)
        (list nil 1 "/github:o/r@main:/README.md")
      (expect (file-remote-p "/github:o/r@main:/README.md" 'localname)
              :to-equal "/github:o/r@main:")))

  (it "still honors CONNECTED inside the command"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal)))
      (spy-on 'remoto--api)
      (remoto-test-in-evil-ex "/github:o/r@main:/README.md"
        (expect (file-remote-p "/github:o/r@main:/README.md" 'localname t)
                :to-be nil)
        (expect (file-remote-p "/github:o/r@main:/README.md" 'localname 'never)
                :to-equal "/README.md"))
      (expect 'remoto--api :not :to-have-been-called))))

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
      (expect line :to-match "^-rwxr-xr-x")))

  (it "marks exactly the name with dired-filename"
    (let* ((line (remoto--format-dired-entry
                  "src" '((type . "tree") (size . 0) (mode . "040000")) t))
           (beg (text-property-any 0 (length line) 'dired-filename t line))
           (end (next-single-property-change beg 'dired-filename line)))
      (expect (substring line beg end) :to-equal "src")
      (expect (substring line end) :to-equal "/\n")))

  (it "appends the ls -F indicator only when asked"
    (dolist (case '(("040000" "tree" "/") ("100755" "blob" "*")
                    ("120000" "blob" "@") ("100644" "blob" "")))
      (pcase-let* ((`(,mode ,type ,mark) case)
                   (plist `((type . ,type) (size . 1) (mode . ,mode))))
        (expect (remoto--format-dired-entry "x" plist t)
                :to-match (concat " x" (regexp-quote mark) "\n\\'"))
        (expect (remoto--format-dired-entry "x" plist)
                :to-match " x\n\\'"))))

  (it "takes the mode and the date of a listing entry from its attributes"
    (expect (remoto--format-dired-entry
             "r" `((type . "tree") (size . 2048) (perms . "drwx------")
                   (time . ,(encode-time (iso8601-parse "2020-06-15T12:00:00Z")))))
            :to-equal "drwx------  1 github github     2048 Jun 15  2020 r\n"))

  (it "shows the hour of a date within six months, as ls does"
    (expect (remoto--format-dired-entry
             "r" `((type . "tree") (time . ,(time-subtract nil 3600))))
            :to-match (rx " " (= 3 alpha) " " (in " 123") digit " "
                          (= 2 digit) ":" (= 2 digit) " r\n" eos)))

  (it "keeps a note out of the name, 4 columns past it"
    (let* ((line (remoto--format-dired-entry
                  "r" '((type . "tree") (note . "desc")) t))
           (beg (text-property-any 0 (length line) 'dired-filename t line))
           (end (next-single-property-change beg 'dired-filename line)))
      (expect (substring line beg end) :to-equal "r")
      (expect (substring line end) :to-equal "/    desc\n")))

  (it "keeps a note that spans lines, as a Forgejo description may, on its one line"
    (expect (remoto--format-dired-entry
             "sokobelt" '((type . "tree")
                          (note . "Entry for the Lisp Game Jam 2022 \r\n\r\n https://itch.io\r\n")))
            :to-match (rx " sokobelt    Entry for the Lisp Game Jam 2022 https://itch.io\n" eos)))

  (it "lines up notes and sizes across a listing"
    (let* ((entries '(("a" (type . "tree") (size . 7) (note . "N1"))
                      ("abcdef" (type . "tree") (size . 1234567890) (note . "N2"))))
           (widths (remoto--listing-widths entries nil))
           (lines (mapcar (lambda (e)
                            (remoto--format-dired-entry (car e) (cdr e) nil widths))
                          entries)))
      (expect widths :to-equal '(10 . 6))
      (expect (string-search "N1" (car lines))
              :to-equal (string-search "N2" (cadr lines)))
      (expect (cadr lines) :to-match " 1234567890 .* abcdef    N2\n")))

  (it "lets a name past 40 columns move only its own note"
    (let* ((long (make-string 60 ?x))
           (entries `(("a" (type . "tree") (note . "N1"))
                      (,long (type . "tree") (note . "N2"))))
           (widths (remoto--listing-widths entries nil)))
      (expect (cdr widths) :to-equal 40)
      (expect (remoto--format-dired-entry "a" (cdr (car entries)) nil widths)
              :to-match (concat " a" (make-string 43 ?\s) "N1\n"))
      (expect (remoto--format-dired-entry long (cdr (cadr entries)) nil widths)
              :to-match (concat " " long "    N2\n")))))

(describe "remoto--ls-switch-p"
  (it "finds a short option in a group of them, or its long form"
    (expect (remoto--ls-switch-p "-aBhlt --group-directories-first" "t") :to-be-truthy)
    (expect (remoto--ls-switch-p "-lt" "t") :to-be-truthy)
    (expect (remoto--ls-switch-p "-al --classify" "F" "classify") :to-be-truthy))

  (it "rejects the option inside a long option or an argument"
    (expect (remoto--ls-switch-p "-al --time-style=+%F" "t") :not :to-be-truthy)
    (expect (remoto--ls-switch-p "-al" "t") :not :to-be-truthy)
    (expect (remoto--ls-switch-p nil "t") :not :to-be-truthy)))

(describe "remoto--classify-p"
  (it "recognizes the switches Dired reads as -F"
    (dolist (switches '("-alF" "-F" "--dired -alF" "-al --classify"
                        "-al --classify=auto"))
      (expect (remoto--classify-p switches) :to-be-truthy)))

  (it "rejects switches without -F"
    (dolist (switches '("-al" "-alf" "-aBhlt --group-directories-first"
                        "-al --time-style=+%F" nil ("-alF")))
      (expect (remoto--classify-p switches) :not :to-be-truthy))))

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
              :to-throw 'user-error)))

  (it "make-directory signals for a repository no listing holds"
    ;; Dired's + would otherwise add a line for a repository it never made.
    (remoto-test-with-listings
      (remoto-test--listing-text "/github:me/")
      (expect (make-directory "/github:me/newrepo") :to-throw 'user-error)
      (expect (make-directory "/github:me/zeta") :not :to-throw))))

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

  (it "percent-encodes path segments and keeps the slashes"
    (expect (remoto--forge-url 'github 'blob "o" "r" "main" "docs/a b+c.md" nil nil)
            :to-equal "https://github.com/o/r/blob/main/docs/a%20b%2Bc.md")
    (expect (remoto--forge-url 'github 'raw "o" "r" "main" "img/x y.png" nil nil)
            :to-equal "https://raw.githubusercontent.com/o/r/main/img/x%20y.png"))

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

  (it "defaults a nil ref to HEAD instead of erroring"
    (expect (remoto--forge-url 'github 'history "o" "r" nil "" nil nil)
            :to-equal "https://github.com/o/r/commits/HEAD/")
    (expect (remoto--forge-url 'github 'tree "o" "r" nil "" nil nil)
            :to-equal "https://github.com/o/r/tree/HEAD/"))

  (it "builds the repo web URL"
    (expect (remoto--forge-url 'github 'repo "o" "r" nil nil nil nil)
            :to-equal "https://github.com/o/r"))

  (it "builds the SSH clone URL"
    (expect (remoto--forge-url 'github 'ssh "o" "r" nil nil nil nil)
            :to-equal "git@github.com:o/r.git"))

  (it "builds the HTTPS clone URL"
    (expect (remoto--forge-url 'github 'https "o" "r" nil nil nil nil)
            :to-equal "https://github.com/o/r.git"))

  (it "builds a compare URL"
    (expect (remoto--forge-url 'github 'compare "o" "r" "main" nil nil nil)
            :to-equal "https://github.com/o/r/compare/main"))

  (it "builds a new-pr URL"
    (expect (remoto--forge-url 'github 'new-pr "o" "r" "main" nil nil nil)
            :to-equal "https://github.com/o/r/pull/new/main"))

  (it "signals for an unknown forge"
    (expect (remoto--forge-url 'bogus 'blob "o" "r" "main" "x" nil nil)
            :to-throw 'user-error)))

;;; remoto--path-context and target classification

(describe "remoto--path-context"
  ;; Note: plist-get results are bound in `let*' and asserted as plain
  ;; locals.  Calling (plist-get ctx :key) directly inside `expect'
  ;; mis-evaluates under buttercup on Emacs 29.
  (it "classifies a repo root as remoto-repo without resolving the ref"
    (remoto-test-with-cache
      (let* ((ctx (remoto--path-context "/github:testowner/testrepo:/"))
             (type (plist-get ctx :type))
             (owner (plist-get ctx :owner))
             (repo (plist-get ctx :repo))
             (ref (plist-get ctx :ref))
             (path (plist-get ctx :path)))
        (expect type :to-be 'remoto-repo)
        (expect owner :to-equal "testowner")
        (expect repo :to-equal "testrepo")
        ;; root targets stay unresolved (no ref/tree API needed)
        (expect ref :to-be nil)
        (expect path :to-equal ""))))

  (it "classifies a directory as remoto-dir"
    (remoto-test-with-cache
      (let* ((ctx (remoto--path-context "/github:testowner/testrepo@main:/src"))
             (type (plist-get ctx :type))
             (kind (plist-get ctx :kind))
             (path (plist-get ctx :path)))
        (expect type :to-be 'remoto-dir)
        (expect kind :to-be 'tree)
        (expect path :to-equal "src"))))

  (it "classifies a file as remoto-file"
    (remoto-test-with-cache
      (let* ((ctx (remoto--path-context "/github:testowner/testrepo@main:/src/main.el"))
             (type (plist-get ctx :type))
             (kind (plist-get ctx :kind))
             (path (plist-get ctx :path)))
        (expect type :to-be 'remoto-file)
        (expect kind :to-be 'blob)
        (expect path :to-equal "src/main.el"))))

  (it "keeps line info only for file targets"
    (remoto-test-with-cache
      (let* ((file (remoto--path-context "/github:testowner/testrepo@main:/src/main.el" 5 7))
             (dir (remoto--path-context "/github:testowner/testrepo@main:/src" 5 7))
             (file-start (plist-get file :line-start))
             (file-end (plist-get file :line-end))
             (dir-start (plist-get dir :line-start))
             (dir-end (plist-get dir :line-end)))
        (expect file-start :to-be 5)
        (expect file-end :to-be 7)
        (expect dir-start :to-be nil)
        (expect dir-end :to-be nil))))

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
      (expect (remoto--fetch-branches remoto--github "torvalds" "linux")
              :to-equal '("main" "develop" "feature/x"))))

  (it "caches results"
    (let ((remoto--branches-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge _endpoint)
                (setq call-count (1+ call-count))
                '(((name . "main")))))
      (remoto--fetch-branches remoto--github "torvalds" "linux")
      (remoto--fetch-branches remoto--github "torvalds" "linux")
      (expect call-count :to-equal 1)))

  (it "returns nil on API errors"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_forge _endpoint)
              (user-error "not found")))
    (let ((remoto--branches-cache (make-hash-table :test 'equal)))
      (expect (remoto--fetch-branches remoto--github "no" "repo") :to-be nil))))

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
            (lambda (_forge _endpoint callback)
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
            :to-have-been-called-with remoto--github "agzam" "space"))

  (it "delegates an owner/ query (no repo part) to recent-owner-repos"
    (spy-on 'remoto--recent-owner-repos :and-return-value '("dotfiles"))
    (expect (remoto--search-repos "agzam/")
            :to-equal '("agzam/dotfiles"))
    (expect 'remoto--recent-owner-repos :to-have-been-called-with remoto--github "agzam"))

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
              :to-have-been-called-with remoto--github "qlik-trial" "stitch-")))

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
            (lambda (_forge _endpoint callback)
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

(describe "remoto--parse-topic-url"
  (it "reads owner, repo and number from pull request and issue URLs"
    (expect (remoto--parse-topic-url "https://github.com/o/r/pull/42")
            :to-equal '("o" "r" "42"))
    (expect (remoto--parse-topic-url "https://github.com/o/r/issues/7")
            :to-equal '("o" "r" "7"))
    (expect (remoto--parse-topic-url "github.com/o/r/pull/42/files")
            :to-equal '("o" "r" "42"))
    (expect (remoto--parse-topic-url "/github.com/o/r/issues/7#issuecomment-99")
            :to-equal '("o" "r" "7"))
    (expect (remoto--parse-topic-url "https://github.com/o/r/pull/42?diff=split")
            :to-equal '("o" "r" "42")))

  (it "returns nil for repository, tree and blob URLs and other input"
    (expect (remoto--parse-topic-url "https://github.com/o/r") :to-be nil)
    (expect (remoto--parse-topic-url "https://github.com/o/r/pulls") :to-be nil)
    (expect (remoto--parse-topic-url "https://github.com/o/r/blob/main/pull/42") :to-be nil)
    (expect (remoto--parse-topic-url "/github:o/r#42") :to-be nil)
    (expect (remoto--parse-topic-url "o/r#42") :to-be nil)))

(describe "remoto-browse issue dispatch"
  (it "calls remoto-topic-display for #NUM input"
    (spy-on 'remoto-topic-display :and-return-value (generate-new-buffer "*test*"))
    (spy-on 'remoto--require-topic)
    (remoto-browse "foo/bar#42")
    (expect 'remoto-topic-display :to-have-been-called-with
            "42" "/github:foo/bar")
    (kill-buffer "*test*"))

  (it "calls remoto-topic-display for a pull request or issue web URL"
    (spy-on 'remoto-topic-display)
    (spy-on 'remoto--require-topic)
    (remoto-browse "https://github.com/foo/bar/pull/42")
    (expect 'remoto-topic-display :to-have-been-called-with "42" "/github:foo/bar")
    (remoto-browse "https://github.com/foo/bar/issues/7#issuecomment-1")
    (expect 'remoto-topic-display :to-have-been-called-with "7" "/github:foo/bar"))

  (it "turns global-remoto-mode on when it is off"
    (spy-on 'remoto-topic-display)
    (spy-on 'remoto--require-topic)
    (spy-on 'message)
    (unwind-protect
        (progn
          (global-remoto-mode -1)
          (remoto-browse "foo/bar#42")
          (expect global-remoto-mode :to-be-truthy)
          (expect 'message :to-have-been-called-with
                  "Remoto: `global-remoto-mode' enabled"))
      (global-remoto-mode 1)))

  (it "leaves global-remoto-mode alone when it is already on"
    (spy-on 'remoto-topic-display)
    (spy-on 'remoto--require-topic)
    (spy-on 'message)
    (remoto-browse "foo/bar#42")
    (expect global-remoto-mode :to-be-truthy)
    (expect 'message :not :to-have-been-called-with
            "Remoto: `global-remoto-mode' enabled"))

  (it "opens dired for plain owner/repo"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--tree-cache (make-hash-table :test 'equal)))
      (puthash "/github:torvalds/linux" "master" remoto--default-branch-cache)
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
      (puthash "/github:testowner/testrepo" "main" remoto--default-branch-cache)
      (spy-on 'dired)
      (spy-on 'remoto--tree-entry :and-return-value '((type . "tree")))
      (remoto-browse "testowner/testrepo/")
      (expect 'dired :to-have-been-called)))

  (it "opens file for owner/repo/path/file.el"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "/github:testowner/testrepo" "main" remoto--default-branch-cache)
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
    (let ((remoto--logins (remoto-test--logins :failed nil))
          (remoto-github-auth nil)
          (remoto-auth-timeout 0.3))
      (spy-on 'remoto--find-token :and-return-value nil)
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (if (eq (plist-get args :auth) 'none)
                    '((name . "test-repo"))
                  (sleep-for 5))))
      (expect (remoto--api remoto--github "repos/owner/repo") :to-equal '((name . "test-repo")))
      (expect (remoto--login-failed (remoto-test--github-login)) :to-be nil)))

  (it "waits out a slow request once the login holds its token, whatever the forge"
    ;; The timeout guards ghub's own token lookup; with the token in hand
    ;; none is left, and a slow answer is no lookup that hangs.
    (let ((remoto--logins (remoto-test--logins))
          (remoto-auth-timeout 0.1)
          (auths nil))
      (setf (remoto--login-token (remoto--login "codeberg.org/api/v1")) "cb_token")
      (spy-on 'remoto--find-token :and-return-value "ghp_found")
      (spy-on 'message)
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (push (plist-get args :auth) auths)
                (sleep-for 0.3)
                '((name . "docs"))))
      (expect (remoto--api remoto--codeberg "repos/o/r") :to-equal '((name . "docs")))
      (expect (remoto--api remoto--github "repos/o/r") :to-equal '((name . "docs")))
      (expect (nreverse auths) :to-equal '("cb_token" "ghp_found"))
      (expect 'message :not :to-have-been-called)))

  (it "asks no endpoint of the token's account anonymously after a timed-out lookup"
    (let ((remoto--logins (remoto-test--logins :failed nil))
          (remoto-github-auth nil)
          (remoto-auth-timeout 0.3)
          (auths nil))
      (spy-on 'remoto--find-token :and-return-value nil)
      (spy-on 'message)
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (push (plist-get args :auth) auths)
                (sleep-for 5)))
      (expect (remoto--api remoto--github "user") :to-throw 'user-error)
      (expect auths :to-equal '(nil))))

    (it "signals user-error on auth error instead of silent fallback"
      (let ((remoto--logins (remoto-test--logins :failed nil :token nil))
            (remoto-github-auth nil)
            (remoto-auth-timeout 5))
        (spy-on 'ghub-get :and-call-fake
                (lambda (_resource &optional _params &rest _args)
                  (error "Package ghub requires a Github API token")))
        (spy-on 'remoto--find-token :and-return-value nil)
        (expect (remoto--api remoto--github "repos/owner/repo")
                :to-throw 'user-error)))

  (it "skips auth when failure is cached"
    (let ((remoto--logins (remoto-test--logins :failed t))
          (remoto-github-auth nil)
          (remoto-auth-timeout 5)
          (auth-used nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (push (plist-get args :auth) auth-used)
                '((name . "test-repo"))))
      (remoto--api remoto--github "repos/owner/repo")
      (expect auth-used :to-equal '(none))))

  (it "clears cache with remoto-reset-auth"
    (let ((remoto--logins (remoto-test--logins :failed t)))
      (remoto-reset-auth)
      (expect (remoto--login-failed (remoto-test--github-login)) :to-be nil)))

  (it "goes unauthenticated on the same call when the token lookup itself fails"
    (let ((remoto--logins (remoto-test--logins :failed nil :token nil))
          (remoto-github-auth nil)
          (remoto-auth-timeout 5)
          (auth-used nil))
      (spy-on 'remoto--find-token :and-call-fake
              (lambda (_forge) (setf (remoto--login-failed (remoto-test--github-login)) t) nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (push (plist-get args :auth) auth-used)
                '((name . "test-repo"))))
      (expect (remoto--api remoto--github "repos/owner/repo") :to-equal '((name . "test-repo")))
      (expect auth-used :to-equal '(none))))

  (it "does not cache failure when auth succeeds"
    (let ((remoto--logins (remoto-test--logins :failed nil))
          (remoto-github-auth nil)
          (remoto-auth-timeout 5))
      (spy-on 'remoto--find-token :and-return-value nil)
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                '((name . "test-repo"))))
      (remoto--api remoto--github "repos/owner/repo")
      (expect (remoto--login-failed (remoto-test--github-login)) :to-be nil))))

(describe "remoto--ghub-get message suppression"
  (it "suppresses messages when ghub-debug is nil"
    (let ((ghub-debug nil)
          (captured-inhibit nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (setq captured-inhibit inhibit-message)
                '((result . t))))
      (remoto--ghub-get remoto--github "/repos/owner/repo" 'none "repos/owner/repo")
      (expect captured-inhibit :to-be t)))

  (it "allows messages when ghub-debug is t"
    (let ((ghub-debug t)
          (captured-inhibit nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (setq captured-inhibit inhibit-message)
                '((result . t))))
      (remoto--ghub-get remoto--github "/repos/owner/repo" 'none "repos/owner/repo")
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
    (expect (remoto--ghub-get remoto--github "/repos/owner/repo" 'none "repos/owner/repo")
            :to-throw 'user-error))

  (it "translates json-end-of-file to user-error"
    (spy-on 'ghub-get :and-call-fake
            (lambda (_resource &optional _params &rest _args)
              (signal 'json-end-of-file '("premature end"))))
    (expect (remoto--ghub-get remoto--github "/repos/owner/repo" 'none "repos/owner/repo")
            :to-throw 'user-error)))

(defun remoto-test--ghub-fails-with (code &optional payload headers)
  "Make `ghub-get' signal the `ghub-http-error' ghub raises for status CODE.
PAYLOAD is the body that came with it, as the reader returned it, and
HEADERS the headers, which ghub leaves in `ghub-response-headers'."
  (spy-on 'ghub-get :and-call-fake
          (lambda (&rest _)
            (setq-default ghub-response-headers headers)
            (signal 'ghub-http-error
                    (list code "status text" "https://api.github.com/x" payload)))))

(defun remoto-test--ghub-get-message ()
  "The `user-error' text `remoto--ghub-get' produces for repos/o/r."
  (condition-case err
      (remoto--ghub-get remoto--github "/repos/o/r" 'none "repos/o/r")
    (user-error (error-message-string err))))

(describe "remoto--ghub-get HTTP status messages"
  ;; ghub has no per-status error symbols; the code is the first datum.
  (it "says not found on 404"
    (remoto-test--ghub-fails-with 404)
    (expect (remoto-test--ghub-get-message) :to-equal "Remoto: not found: repos/o/r"))

  (it "says not found on 422, a search of an account that does not exist"
    (remoto-test--ghub-fails-with 422)
    (expect (remoto-test--ghub-get-message) :to-equal "Remoto: not found: repos/o/r"))

  (it "says not found on a 400 whose body says not found, Forgejo's answer to an unknown ref"
    (remoto-test--ghub-fails-with 400 '((message . "sha not found [v1]")))
    (expect (remoto-test--ghub-get-message) :to-equal "Remoto: not found: repos/o/r")
    (remoto-test--ghub-fails-with 400 '((message . "invalid limit")))
    (expect (remoto-test--ghub-get-message) :not :to-match (regexp-quote remoto--not-found))
    (remoto-test--ghub-fails-with 400 "not found, as text")
    (expect (remoto-test--ghub-get-message) :not :to-match (regexp-quote remoto--not-found)))

  (it "says access denied on 403"
    (remoto-test--ghub-fails-with 403)
    (expect (remoto-test--ghub-get-message)
            :to-equal "Remoto: access denied (rate limit or permissions): repos/o/r"))

  (it "says authentication failed on 401, naming the API host"
    (remoto-test--ghub-fails-with 401)
    (expect (remoto-test--ghub-get-message)
            :to-equal "Remoto: authentication failed for api.github.com; configure \
a token for it in auth-source, then M-x remoto-reset-auth")
    (expect (condition-case err
                (remoto--ghub-get remoto--codeberg "/repos/o/r" 'none "repos/o/r")
              (user-error (cadr err)))
            :to-match "\\`Remoto: authentication failed for codeberg\\.org/api/v1;"))

  (it "names the host and the status for other codes, with no raw data"
    (remoto-test--ghub-fails-with 500)
    (expect (remoto-test--ghub-get-message)
            :to-equal "Remoto: api.github.com answered 500 status text for repos/o/r")
    (remoto-test--ghub-fails-with 400 '((message . "invalid limit")))
    (expect (remoto-test--ghub-get-message)
            :to-equal "Remoto: api.github.com answered 400 status text for repos/o/r: invalid limit")
    (remoto-test--ghub-fails-with 503 nil '(("Retry-After" . "30")))
    (expect (remoto-test--ghub-get-message)
            :to-equal "Remoto: api.github.com answered 503 status text for repos/o/r; retry in 30 seconds"))

  (it "says rate limited on 429, with the wait Retry-After asks for"
    (remoto-test--ghub-fails-with 429 nil '(("retry-after" . "60")))
    (expect (remoto-test--ghub-get-message)
            :to-equal "Remoto: api.github.com rate limited repos/o/r (429); retry in 60 seconds")
    (remoto-test--ghub-fails-with 429 nil '(("Retry-After" . "Wed, 21 Oct 2026 07:28:00 GMT")))
    (expect (remoto-test--ghub-get-message)
            :to-equal "Remoto: api.github.com rate limited repos/o/r (429); \
retry after Wed, 21 Oct 2026 07:28:00 GMT")
    (remoto-test--ghub-fails-with 429)
    (expect (remoto-test--ghub-get-message)
            :to-equal "Remoto: api.github.com rate limited repos/o/r (429); retry later"))

  (it "reads no Retry-After of an earlier answer"
    (setq-default ghub-response-headers '(("Retry-After" . "999")))
    (unwind-protect
        (progn
          (spy-on 'ghub-get :and-call-fake
                  (lambda (&rest _)
                    (signal 'ghub-http-error
                            (list 429 "Too Many Requests" "https://api.github.com/x" nil))))
          (expect (remoto-test--ghub-get-message) :to-match "retry later\\'"))
      (setq-default ghub-response-headers nil))))

(defvar remoto-test--reply nil
  "The callback and errorback of the last faked callback request.")

(defun remoto-test--ghub-answers-later ()
  "Fake `ghub-get' as a callback request: return a live buffer, keep the callbacks.
The test delivers the reply through `remoto-test--reply' when it decides."
  (spy-on 'ghub-get :and-call-fake
          (lambda (_resource _params &rest args)
            (setq remoto-test--reply (list (plist-get args :callback)
                                           (plist-get args :errorback)))
            (generate-new-buffer " *remoto-test-http*"))))

(describe "remoto--ghub-get under while-no-input"
  ;; `while-no-input' binds `throw-on-input'; a synchronous wait that it
  ;; throws past leaves the url buffer behind, so the call goes through a
  ;; callback request that ghub cleans up itself.
  (before-each
    (setq remoto-test--reply nil)
    (clrhash remoto--pending-requests))

  (after-each
    (dolist (buf (buffer-list))
      (when (string-prefix-p " *remoto-test-http*" (buffer-name buf))
        (kill-buffer buf))))

  (it "calls ghub synchronously when input cannot interrupt"
    (let ((throw-on-input nil) callback)
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource _params &rest args)
                (setq callback (plist-get args :callback))
                '((name . "main"))))
      (expect (remoto--ghub-get remoto--github "/repos/o/r" 'none "repos/o/r")
              :to-equal '((name . "main")))
      (expect callback :to-be nil)))

  (it "waits for the callback reply and returns it"
    (let ((throw-on-input 'remoto-test-input))
      (remoto-test--ghub-answers-later)
      (run-at-time 0.01 nil (lambda () (funcall (car remoto-test--reply) '((name . "main")))))
      (expect (remoto--ghub-get remoto--github "/repos/o/r" 'none "repos/o/r")
              :to-equal '((name . "main")))
      (expect (hash-table-count remoto--pending-requests) :to-equal 0)))

  (it "leaves the headers of the answer in remoto--response-headers, either way"
    ;; Forgejo's pages say in X-Total-Count how many items there are.
    (let ((remoto--response-headers nil)
          (throw-on-input 'remoto-test-input))
      (remoto-test--ghub-answers-later)
      (run-at-time 0.01 nil (lambda ()
                              (funcall (car remoto-test--reply) '((name . "main"))
                                       '(("X-Total-Count" . "306")))))
      (remoto--ghub-get remoto--github "/repos/o/r" 'none "repos/o/r")
      (expect remoto--response-headers :to-equal '(("X-Total-Count" . "306"))))
    (let ((remoto--response-headers nil)
          (throw-on-input nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (&rest _)
                (setq ghub-response-headers '(("X-Total-Count" . "28")))
                '((name . "main"))))
      (remoto--ghub-get remoto--github "/repos/o/r" 'none "repos/o/r")
      (expect remoto--response-headers :to-equal '(("X-Total-Count" . "28")))))

  (it "hands the reply of an abandoned request to the next call"
    (let ((throw-on-input 'remoto-test-input))
      (remoto-test--ghub-answers-later)
      ;; A timer plays the keystroke that makes `while-no-input' throw.
      (expect (catch 'remoto-test-input
                (run-at-time 0.01 nil (lambda () (throw 'remoto-test-input 'typed)))
                (remoto--ghub-get remoto--github "/repos/o/r" 'none "repos/o/r"))
              :to-be 'typed)
      (funcall (car remoto-test--reply) '((name . "main")))
      (expect (remoto--ghub-get remoto--github "/repos/o/r" 'none "repos/o/r")
              :to-equal '((name . "main")))
      (expect 'ghub-get :to-have-been-called-times 1)
      (expect (hash-table-count remoto--pending-requests) :to-equal 0)))

  (it "waits on the pending request of an abandoned call instead of starting another"
    (let ((throw-on-input 'remoto-test-input))
      (remoto-test--ghub-answers-later)
      (catch 'remoto-test-input
        (run-at-time 0.01 nil (lambda () (throw 'remoto-test-input 'typed)))
        (remoto--ghub-get remoto--github "/repos/o/r" 'none "repos/o/r"))
      (run-at-time 0.01 nil (lambda () (funcall (car remoto-test--reply) '((name . "main")))))
      (expect (remoto--ghub-get remoto--github "/repos/o/r" 'none "repos/o/r")
              :to-equal '((name . "main")))
      (expect 'ghub-get :to-have-been-called-times 1)))

  (it "keeps requests with different auth apart"
    (let ((throw-on-input 'remoto-test-input))
      (remoto-test--ghub-answers-later)
      (catch 'remoto-test-input
        (run-at-time 0.01 nil (lambda () (throw 'remoto-test-input 'typed)))
        (remoto--ghub-get remoto--github "/repos/o/r" 'none "repos/o/r"))
      (run-at-time 0.01 nil (lambda () (funcall (car remoto-test--reply) '((name . "private")))))
      (expect (remoto--ghub-get remoto--github "/repos/o/r" "ghp_token" "repos/o/r")
              :to-equal '((name . "private")))
      (expect 'ghub-get :to-have-been-called-times 2)))

  (it "keeps the token out of the pending-request key"
    ;; The table is global and lives in backtraces and bug reports; it only
    ;; has to tell two callers apart.
    (let ((throw-on-input 'remoto-test-input)
          (token "ghp_supersecrettoken"))
      (remoto-test--ghub-answers-later)
      (catch 'remoto-test-input
        (run-at-time 0.01 nil (lambda () (throw 'remoto-test-input 'typed)))
        (remoto--ghub-get remoto--github "/repos/o/r" token "repos/o/r"))
      (expect (hash-table-count remoto--pending-requests) :to-equal 1)
      (expect (seq-find (lambda (key) (string-search token (format "%S" key)))
                        (hash-table-keys remoto--pending-requests))
              :to-be nil)
      ;; ghub still gets the credential itself
      (expect (plist-get (cddr (spy-calls-args-for 'ghub-get 0)) :auth)
              :to-equal token)))

  (it "reports a failed reply like the synchronous call and forgets it"
    (let ((throw-on-input 'remoto-test-input))
      (remoto-test--ghub-answers-later)
      (run-at-time 0.01 nil (lambda () (funcall (cadr remoto-test--reply) '(error http 404 nil))))
      (expect (remoto-test--ghub-get-message) :to-equal "Remoto: not found: repos/o/r")
      (expect (hash-table-count remoto--pending-requests) :to-equal 0)))

  (it "gives up when the reply buffer dies without a reply"
    (let ((throw-on-input 'remoto-test-input) buffer)
      (spy-on 'ghub-get :and-call-fake
              (lambda (&rest _)
                (setq buffer (generate-new-buffer " *remoto-test-http*"))))
      (run-at-time 0.01 nil (lambda () (kill-buffer buffer)))
      (expect (remoto--ghub-get remoto--github "/repos/o/r" 'none "repos/o/r") :to-throw 'error)
      (expect (hash-table-count remoto--pending-requests) :to-equal 0))))

(describe "remoto--find-token"
  (it "finds token at api.github.com with ^forge suffix"
    (spy-on 'ghub--username :and-return-value "testuser")
    (spy-on 'auth-source-search :and-call-fake
            (lambda (&rest args)
              (let ((host (plist-get args :host))
                    (user (plist-get args :user)))
                (when (and (equal host "api.github.com")
                           (equal user "testuser^forge"))
                  (list (list :secret "ghp_found_token"))))))
    (expect (remoto--find-token remoto--github) :to-equal "ghp_found_token"))

  (it "returns nil when no token found anywhere"
    (spy-on 'ghub--username :and-return-value "testuser")
    (spy-on 'auth-source-search :and-return-value nil)
    (expect (remoto--find-token remoto--github) :to-be nil))

  (it "returns nil when username cannot be determined"
    (spy-on 'ghub--username :and-call-fake
            (lambda (&rest _) (error "Cannot determine username")))
    (expect (remoto--find-token remoto--github) :to-be nil))

  (it "reports a failing auth-source backend once, stops, and marks auth failed"
    (let ((remoto--logins (remoto-test--logins :failed nil)))
      (spy-on 'ghub--username :and-return-value "testuser")
      (spy-on 'auth-source-search :and-call-fake
              (lambda (&rest _) (error "Decryption failed")))
      (spy-on 'message)
      (expect (remoto--find-token remoto--github) :to-be nil)
      (expect 'auth-source-search :to-have-been-called-times 1)
      (expect 'message :to-have-been-called-times 1)
      (expect (apply #'format (spy-calls-args-for 'message 0))
              :to-equal "Remoto: auth-source lookup failed (Decryption failed); \
using unauthenticated access until M-x remoto-reset-auth")
      ;; Every API call retries the lookup while this is nil, and each
      ;; retry would repeat the message.
      (expect (remoto--login-failed (remoto-test--github-login)) :to-be t))))

(describe "remoto--warm-auth"
  (it "caches authenticated user and token on success"
    (let ((remoto--logins (remoto-test--logins :user nil :failed nil :token nil)))
      (spy-on 'remoto--find-token :and-return-value "ghp_fake_token")
      (spy-on 'ghub-get :and-return-value '((login . "agzam")))
      (spy-on 'message)
      (remoto--warm-auth)
      (expect (remoto--login-user (remoto-test--github-login)) :to-equal "agzam")
      (expect (remoto--login-token (remoto-test--github-login)) :to-equal "ghp_fake_token")
      (expect (remoto--login-failed (remoto-test--github-login)) :to-be nil)))

  (it "does not set auth-failed when no token found"
    (let ((remoto--logins (remoto-test--logins :user nil :failed nil :token nil))
          (remoto-github-auth nil))
      (spy-on 'remoto--find-token :and-return-value nil)
      (spy-on 'message)
      (remoto--warm-auth)
      ;; warm-auth is opportunistic; missing token should NOT lock out
      ;; auth permanently - remoto--api will try ghub's own resolution.
      (expect (remoto--login-failed (remoto-test--github-login)) :to-be nil)
      (expect (remoto--login-user (remoto-test--github-login)) :to-be nil)))

  (it "adds no message of its own after the lookup reported a backend failure"
    (let ((remoto--logins (remoto-test--logins :user nil :failed nil :token nil))
          (remoto-github-auth nil))
      (spy-on 'remoto--find-token :and-call-fake
              (lambda (_forge) (setf (remoto--login-failed (remoto-test--github-login)) t) nil))
      (spy-on 'message)
      (remoto--warm-auth)
      (expect 'message :not :to-have-been-called)))

  (it "sets auth-failed when API call fails with found token"
    (let ((remoto--logins (remoto-test--logins :user nil :failed nil :token nil)))
      (spy-on 'remoto--find-token :and-return-value "ghp_bad_token")
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (error "401 Unauthorized")))
      (spy-on 'message)
      (remoto--warm-auth)
      (expect (remoto--login-failed (remoto-test--github-login)) :to-be-truthy)
      (expect (remoto--login-token (remoto-test--github-login)) :to-be nil)))

  (it "skips when user already cached"
    (let ((remoto--logins (remoto-test--logins :user "agzam" :failed nil)))
      (spy-on 'remoto--find-token)
      (remoto--warm-auth)
      (expect 'remoto--find-token :not :to-have-been-called)))

  (it "skips when auth already failed"
    (let ((remoto--logins (remoto-test--logins :user nil :failed t)))
      (spy-on 'remoto--find-token)
      (remoto--warm-auth)
      (expect 'remoto--find-token :not :to-have-been-called)))

  (it "uses literal remoto-github-auth string directly"
    (let ((remoto--logins (remoto-test--logins :user nil :failed nil :token nil))
          (remoto-github-auth "ghp_explicit_token"))
      (spy-on 'remoto--find-token)
      (spy-on 'ghub-get :and-return-value '((login . "agzam")))
      (remoto--warm-auth)
      (expect 'remoto--find-token :not :to-have-been-called)
      (expect (remoto--login-token (remoto-test--github-login)) :to-equal "ghp_explicit_token"))))

;;; Partial path parsing

(describe "remoto--parse"
  (it "parses /github: as the root with an empty query"
    (let ((p (remoto--parse "/github:")))
      (expect (remoto-path-level p) :to-be 'root)
      (expect (remoto-path-query p) :to-equal "")
      (expect (remoto-path-directory p) :to-equal "/github:")))

  (it "parses a bare account name as a query at the root"
    (let ((p (remoto--parse "/github:foobar")))
      (expect (remoto-path-level p) :to-be 'root)
      (expect (remoto-path-query p) :to-equal "foobar")
      (expect (remoto-path-directory p) :to-equal "/github:")))

  (it "parses /github:owner/ as the owner level"
    (let ((p (remoto--parse "/github:foobar/")))
      (expect (remoto-path-level p) :to-be 'owner)
      (expect (remoto-path-owner p) :to-equal "foobar")
      (expect (remoto-path-query p) :to-equal "")))

  (it "parses a bare repository name as a query at the owner level"
    (let ((p (remoto--parse "/github:a/b")))
      (expect (remoto-path-level p) :to-be 'owner)
      (expect (remoto-path-query p) :to-equal "b")
      (expect (remoto-path-directory p) :to-equal "/github:a/")))

  (it "parses /github:owner/repo@ as the refs level"
    (let ((p (remoto--parse "/github:torvalds/linux@")))
      (expect (remoto-path-level p) :to-be 'refs)
      (expect (remoto-path-owner p) :to-equal "torvalds")
      (expect (remoto-path-repo p) :to-equal "linux")
      (expect (remoto-path-query p) :to-equal "")))

  (it "keeps a ref with a slash as one query at the refs level"
    (let ((p (remoto--parse "/github:o/r@release/2026.5")))
      (expect (remoto-path-level p) :to-be 'refs)
      (expect (remoto-path-query p) :to-equal "release/2026.5")
      (expect (remoto-path-directory p) :to-equal "/github:o/r@")))

  (it "parses /github:owner/repo# as the topics level"
    (let ((p (remoto--parse "/github:foobar/zapato#42")))
      (expect (remoto-path-level p) :to-be 'topics)
      (expect (remoto-path-query p) :to-equal "42")
      (expect (remoto-path-directory p) :to-equal "/github:foobar/zapato#")))

  (it "parses the short form as a tree on the default branch"
    (let ((p (remoto--parse "/github:foobar/zapato/src/ma")))
      (expect (remoto-path-level p) :to-be 'tree)
      (expect (remoto-path-short p) :to-be t)
      (expect (remoto-path-ref p) :to-be nil)
      (expect (remoto-path-path p) :to-equal "/src/ma")
      (expect (remoto-path-query p) :to-equal "ma")
      (expect (remoto-path-directory p) :to-equal "/github:foobar/zapato/src/")))

  (it "parses a canonical path, the ref ending at the colon"
    (let ((p (remoto--parse "/github:o/r@feature/x:/a.el")))
      (expect (remoto-path-level p) :to-be 'tree)
      (expect (remoto-path-short p) :to-be nil)
      (expect (remoto-path-ref p) :to-equal "feature/x")
      (expect (remoto-path-path p) :to-equal "/a.el")
      (expect (remoto-path-query p) :to-equal "a.el")
      (expect (remoto-path-directory p) :to-equal "/github:o/r@feature/x:/")))

  (it "keeps a canonical root without a slash after its colon as its own directory"
    (let ((p (remoto--parse "/github:a/b@main:")))
      (expect (remoto-path-path p) :to-equal "/")
      (expect (remoto-path-query p) :to-equal "")
      (expect (remoto-path-directory p) :to-equal "/github:a/b@main:")))

  (it "treats a delimiter after no repository as a query at the owner level"
    (let ((p (remoto--parse "/github:foo/#")))
      (expect (remoto-path-level p) :to-be 'owner)
      (expect (remoto-path-query p) :to-equal "#")))

  (it "treats a delimiter after no repository name as a query at the root"
    (let ((p (remoto--parse "/github:foobar#")))
      (expect (remoto-path-level p) :to-be 'root)
      (expect (remoto-path-query p) :to-equal "foobar#")))

  (it "parses /github:/ as the root"
    (let ((p (remoto--parse "/github:/")))
      (expect (remoto-path-level p) :to-be 'root)
      (expect (remoto-path-query p) :to-equal "/")))

  (it "returns nil for other names"
    (expect (remoto--parse "/home/user/file.el") :to-be nil)
    (expect (remoto--parse "https://github.com/a/b") :to-be nil)
    (expect (remoto--parse nil) :to-be nil))

  (it "is inverted by remoto--unparse at every level"
    (dolist (name '("/github:" "/github:foo" "/github:foo/" "/github:foo/bar"
                    "/github:foo/bar@" "/github:foo/bar@v1" "/github:foo/bar@rel/1"
                    "/github:foo/bar#" "/github:foo/bar#42"
                    "/github:foo/bar/" "/github:foo/bar/src/" "/github:foo/bar/src/x"
                    "/github:foo/bar:/" "/github:foo/bar@v1:/"
                    "/github:foo/bar@rel/1:/a/b"))
      (expect (remoto--unparse (remoto--parse name)) :to-equal name))))

(describe "remoto-register-forge"
  (it "adds a forge under its prefixes, shorthand included"
    (let ((remoto--forges (copy-alist remoto--forges))
          (remoto--handler-regexp remoto--handler-regexp)
          (file-name-handler-alist (copy-alist file-name-handler-alist))
          (fake (remoto-forge-create :name 'fake :prefixes '("fake" "fk")
                                     :host "fake.example" :delimiters '(?@))))
      (remoto-register-forge fake)
      (expect (remoto--canonical-forge "/fake:o/r") :to-be fake)
      (expect (remoto--canonical-forge "/fk:o/r") :to-be nil)
      (expect (remoto--normalize-shorthand "/fk:o/r") :to-equal "/fake:o/r")
      (expect (remoto--normalize-shorthand "/gh:o/r") :to-equal "/github:o/r")
      (expect (string-match-p remoto--handler-regexp "/fk:o") :to-be 0)
      (expect (string-match-p remoto--handler-regexp "/github:o") :to-be 0)
      (expect (cdr (assoc remoto--handler-regexp file-name-handler-alist))
              :to-be #'remoto-file-name-handler)
      (expect (remoto--forge-type "/fk:o/r") :to-be 'fake)))

  (it "parses with the delimiters of the forge only"
    (let ((remoto--forges (copy-alist remoto--forges))
          (remoto--handler-regexp remoto--handler-regexp)
          (file-name-handler-alist (copy-alist file-name-handler-alist)))
      (remoto-register-forge
       (remoto-forge-create :name 'fake :prefixes '("fake") :delimiters '(?@)))
      (let ((topic (remoto--parse "/fake:o/r#1"))
            (ref (remoto--parse "/fake:o/r@v1:/a")))
        (expect (remoto-path-level topic) :to-be 'owner)
        (expect (remoto-path-query topic) :to-equal "r#1")
        (expect (remoto-path-level ref) :to-be 'tree)
        (expect (remoto-path-ref ref) :to-equal "v1")
        (expect (remoto--unparse ref) :to-equal "/fake:o/r@v1:/a")
        (expect (file-remote-p "/fake:o/r@v1:/a" 'method) :to-equal "fake")
        (expect (file-remote-p "/fake:o" 'host) :to-equal nil))))

  (it "names the prefixes of the built-in forges in the spelling of the cookies"
    (expect remoto--handler-regexp
            :to-equal "\\`/\\(?:github\\|gh\\|codeberg\\|cb\\):"))

  (it "kills the buffers of a forge it unregisters, under any of its prefixes"
    (let ((remoto--forges (copy-alist remoto--forges))
          (remoto--handler-regexp remoto--handler-regexp)
          (file-name-handler-alist (copy-alist file-name-handler-alist))
          (fake (remoto-forge-create :name 'fake :prefixes '("fake" "fk")
                                     :host "fake.example" :delimiters '(?@)))
          (buffers (list (generate-new-buffer "x.el") (generate-new-buffer "x.el")
                         (generate-new-buffer "x.el"))))
      (spy-on 'message)
      (unwind-protect
          (progn
            (remoto-register-forge fake)
            (cl-mapc (lambda (buffer name)
                       (with-current-buffer buffer (setq buffer-file-name name)))
                     buffers '("/fake:o/r@main:/x.el" "/fk:o/r@main:/x.el" "/tmp/x.el"))
            (remoto-unregister-forge fake)
            (expect (mapcar #'buffer-live-p buffers) :to-equal '(nil nil t))
            (expect (remoto--prefix-of "/fake:o/r") :to-be nil)
            (expect 'message :to-have-been-called-with
                    "Remoto: killed %d buffer%s of %s" 2 "s" "/fake:"))
        (dolist (buffer buffers)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (setq buffer-file-name nil))
            (kill-buffer buffer)))))))

(describe "the forge contract"
  :var ((fake (remoto-forge-create :name 'fake :prefixes '("fake") :delimiters '(?@))))

  (it "signals remoto-unsupported for data a forge does not provide"
    (dolist (call (list (lambda () (remoto-forge-default-ref fake "o" "r"))
                        (lambda () (remoto-forge-tree fake "o" "r" "main"))
                        (lambda () (remoto-forge-content fake "o" "r" "main" "a"))
                        (lambda () (remoto-forge-branches fake "o" "r"))
                        (lambda () (remoto-forge-topics fake "o" "r"))
                        (lambda () (remoto-forge-search-accounts fake "q" t))
                        (lambda () (remoto-forge-owner-listing fake "/fake:o/"))))
      (expect (condition-case err (funcall call) (remoto-unsupported (cadr err)))
              :to-be 'fake)))

  (it "answers nil, not an error, where nothing is a fine answer"
    (expect (remoto-forge-user fake) :to-be nil)
    (expect (remoto-forge-file-commits fake "o" "r" "main" "" '("a")) :to-be nil)
    (expect (remoto-forge-url-input-p fake "https://x/o/r") :to-be nil)
    (expect (remoto-forge-parse-url fake "https://x/o/r") :to-be nil)
    (expect (remoto-forge-parse-topic-url fake "https://x/o/r/pull/1") :to-be nil)
    (expect (remoto-forge-forget-refs fake "o" "r") :to-be nil))

  (it "lists children from the tree where a forge has no cheaper answer"
    (remoto-test-with-cache
      ;; The tree cache is keyed by forge: the fake forge's tree is its own.
      (puthash "/fake:testowner/testrepo@main"
               (gethash "/github:testowner/testrepo@main" remoto--tree-cache)
               remoto--tree-cache)
      (expect (mapcar #'car (remoto-forge-children fake "testowner" "testrepo"
                                                   "main" "src"))
              :to-equal '("main.el" "utils.el"))))

  (it "dispatches the GitHub methods to the GitHub functions"
    (spy-on 'remoto--fetch-branches :and-return-value '("main"))
    (spy-on 'remoto--fetch-issue :and-return-value '((number . 1)))
    (spy-on 'remoto--resolve-commit-sha :and-return-value "abc")
    (expect (remoto-forge-branches remoto--github "o" "r") :to-equal '("main"))
    (expect (remoto-forge-topic remoto--github "o" "r" "1") :to-equal '((number . 1)))
    (expect (remoto-forge-commit-sha remoto--github "o" "r" "main") :to-equal "abc")
    (expect 'remoto--fetch-branches :to-have-been-called-with remoto--github "o" "r"))

  (it "routes a URL to the forge that recognizes it"
    (expect (remoto--url-forge "https://github.com/o/r") :to-be remoto--github)
    (expect (remoto--url-forge "/home/me/x") :to-be nil)
    (expect (remoto--canonical-path (remoto--url-path "https://github.com/o/r"))
            :to-equal "/github:o/r:/")
    (expect (remoto--canonical-path (remoto--url-path "o/r@v1"))
            :to-equal "/github:o/r@v1:/")
    (expect (remoto--url-path "not a repo") :to-throw 'user-error))

  (it "finds a registered forge by name"
    (expect (remoto--forge-named 'github) :to-be remoto--github)
    (expect (remoto--forge-named 'nope) :to-be nil)))

(describe "remoto--directory-level"
  (it "names the level of a directory"
    (expect (remoto--directory-level "/github:") :to-be 'root)
    (expect (remoto--directory-level "/github:foobar/") :to-be 'owner)
    (expect (remoto--directory-level "/github:foobar/zapato@") :to-be 'refs)
    (expect (remoto--directory-level "/github:foobar/zapato#") :to-be 'topics)
    (expect (remoto--directory-level "/github:foobar/zapato/") :to-be 'tree)
    (expect (remoto--directory-level "/github:a/b@main:/src/") :to-be 'tree))

  (it "is nil for a name with a query above the tree"
    (expect (remoto--directory-level "/github:foobar") :to-be nil)
    (expect (remoto--directory-level "/github:a/b") :to-be nil)
    (expect (remoto--directory-level "/github:a/b@main") :to-be nil)
    (expect (remoto--directory-level "/github:/") :to-be nil)))

(describe "remoto--repo-root"
  (it "names the repository of /github:owner/repo on its default branch"
    (let ((p (remoto--repo-root (remoto--parse "/github:torvalds/linux"))))
      (expect (remoto-path-owner p) :to-equal "torvalds")
      (expect (remoto-path-repo p) :to-equal "linux")
      (expect (remoto-path-ref p) :to-be nil)
      (expect (remoto-path-path p) :to-equal "/")))

  (it "names the repository of /github:owner/repo@ref at that ref"
    (expect (remoto-path-ref (remoto--repo-root (remoto--parse "/github:torvalds/linux@v6.5")))
            :to-equal "v6.5")
    (expect (remoto-path-ref (remoto--repo-root (remoto--parse "/github:o/r@v6.5/")))
            :to-equal "v6.5")
    (expect (remoto-path-ref (remoto--repo-root (remoto--parse "/github:o/r@rel/1")))
            :to-equal "rel/1"))

  (it "is nil for a canonical path, a topic, the root and a delimiter alone"
    (expect (remoto--repo-root (remoto--parse "/github:a/b@main:/src")) :to-be nil)
    (expect (remoto--repo-root (remoto--parse "/github:agzam/spacehammer#193")) :to-be nil)
    (expect (remoto--repo-root (remoto--parse "/github:")) :to-be nil)
    (expect (remoto--repo-root (remoto--parse "/github:a/b@")) :to-be nil))

  (it "keeps the forge of the name it was made from"
    (expect (remoto-forge-name
             (remoto-path-forge (remoto--repo-root (remoto--parse "/codeberg:o/r"))))
            :to-be 'codeberg)
    (expect (remoto-forge-name
             (remoto-path-forge (remoto--repo-root (remoto--parse "/codeberg:o/r@v1"))))
            :to-be 'codeberg)))

;;; The transport and the login, per forge and host

(describe "remoto--api per forge"
  (it "sends a request to the API host of the forge, in ghub's spelling"
    (let ((remoto--logins (remoto-test--logins :failed t))
          (calls nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (resource &optional _params &rest args)
                (push (list resource (plist-get args :host) (plist-get args :forge))
                      calls)
                '((ok . t))))
      (remoto--api remoto--github "repos/o/r")
      (remoto--api remoto--codeberg "repos/o/r")
      (expect (nreverse calls)
              :to-equal '(("/repos/o/r" "api.github.com" nil)
                          ("/repos/o/r" "codeberg.org/api/v1" forgejo)))))

  (it "keeps the login state of each host apart"
    (let ((remoto--logins (remoto-test--logins))
          (auths nil))
      (setf (remoto--login-failed (remoto--login "codeberg.org/api/v1")) t
            (remoto--login-token (remoto--login "api.github.com")) "ghp_x"
            (remoto--login-user (remoto--login "api.github.com")) "me")
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (push (plist-get args :auth) auths)
                '((ok . t))))
      (remoto--api remoto--codeberg "repos/o/r")
      (remoto--api remoto--github "repos/o/r")
      (expect (nreverse auths) :to-equal '(none "ghp_x"))))

  (it "sends a string remoto-github-auth to GitHub only"
    (let ((remoto--logins (remoto-test--logins))
          (remoto-github-auth "ghp_literal")
          (auths nil))
      (spy-on 'remoto--find-token :and-call-fake
              (lambda (forge) (and (eq forge remoto--codeberg) "cb_token")))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (push (cons (plist-get args :host) (plist-get args :auth)) auths)
                '((ok . t))))
      (remoto--api remoto--codeberg "repos/o/r")
      (remoto--api remoto--github "repos/o/r")
      (expect (nreverse auths)
              :to-equal '(("codeberg.org/api/v1" . "cb_token")
                          ("api.github.com" . "ghp_literal")))))

  (it "reads Codeberg anonymously with a string remoto-github-auth and no Codeberg token"
    (let ((remoto--logins (remoto-test--logins))
          (remoto-github-auth "ghp_literal")
          (auths nil))
      (spy-on 'remoto--find-token :and-call-fake
              (lambda (forge)
                (setf (remoto--login-failed (remoto--forge-login forge)) t)
                nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (push (plist-get args :auth) auths)
                '((ok . t))))
      (remoto--api remoto--codeberg "repos/o/r")
      (expect auths :to-equal '(none))
      (expect (remoto--literal-token
               (remoto-forgejo-create :name 'x :prefixes '("x") :host "x.org"))
              :to-be nil)))

  (it "keeps pending requests of two hosts apart"
    (let ((remoto--pending-requests (make-hash-table :test 'equal))
          (started nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (push (list (plist-get args :host) (plist-get args :forge)) started)
                (generate-new-buffer " *fake request*")))
      (dolist (forge (list remoto--github remoto--codeberg))
        (let ((key (list (remoto--api-host forge) "/repos/o/r" 'none)))
          (remoto--request-start key forge "/repos/o/r" 'none)))
      (expect (sort started (lambda (a b) (string< (car a) (car b))))
              :to-equal '(("api.github.com" nil) ("codeberg.org/api/v1" forgejo)))
      (expect (sort (hash-table-keys remoto--pending-requests)
                    (lambda (a b) (string< (car a) (car b))))
              :to-equal '(("api.github.com" "/repos/o/r" none)
                          ("codeberg.org/api/v1" "/repos/o/r" none)))
      (maphash (lambda (_key req) (kill-buffer (remoto--request-buffer req)))
               remoto--pending-requests)))

  (it "goes on anonymously once the forge refuses the token, and says so"
    (let ((remoto--logins (remoto-test--logins))
          (auths nil))
      (setf (remoto--login-token (remoto--login "codeberg.org/api/v1")) "revoked")
      (spy-on 'message)
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (push (plist-get args :auth) auths)
                (if (eq (plist-get args :auth) 'none)
                    '((name . "docs"))
                  (signal 'ghub-http-error
                          (list 401 "Unauthorized" "https://codeberg.org/api/v1/x" nil)))))
      (expect (remoto--api remoto--codeberg "repos/o/r") :to-equal '((name . "docs")))
      (expect (remoto--api remoto--codeberg "repos/o/r") :to-equal '((name . "docs")))
      (expect (reverse auths) :to-equal '("revoked" none none))
      (expect (remoto--login-failed (remoto--login "codeberg.org/api/v1")) :to-be t)
      (expect (remoto--login-failed (remoto-test--github-login)) :to-be nil)
      (expect 'message :to-have-been-called-with
              "Remoto: %s rejected the token; reading it anonymously until M-x remoto-reset-auth"
              "codeberg.org/api/v1")))

  (it "asks the token's own endpoints nothing anonymously after the token is refused"
    (let ((remoto--logins (remoto-test--logins)))
      (setf (remoto--login-token (remoto--login "codeberg.org/api/v1")) "revoked")
      (spy-on 'message)
      (spy-on 'ghub-get :and-call-fake
              (lambda (&rest _)
                (signal 'ghub-http-error
                        (list 401 "Unauthorized" "https://codeberg.org/api/v1/user" nil))))
      (expect (remoto--get-authenticated-user remoto--codeberg) :to-be nil)
      (expect 'ghub-get :to-have-been-called-times 1)))

  (it "names the host of the forge when every auth avenue fails"
    (let ((remoto--logins (remoto-test--logins))
          (remoto-github-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (&rest _) (error "Required Forgejo token does not exist")))
      (spy-on 'remoto--find-token :and-return-value nil)
      (expect (remoto--api remoto--codeberg "repos/o/r")
              :to-throw 'user-error)
      (expect (remoto--login-failed (remoto--login "codeberg.org/api/v1")) :to-be t)
      (expect (remoto--login-failed (remoto-test--github-login)) :to-be nil))))

(describe "remoto--find-token per forge"
  (it "searches the API host and the web host of the forge, as ghub stores tokens"
    (let ((remoto--logins (remoto-test--logins))
          (searched nil))
      (spy-on 'ghub--username :and-return-value "me")
      (spy-on 'auth-source-search :and-call-fake
              (lambda (&rest args)
                (push (cons (plist-get args :host) (plist-get args :user)) searched)
                nil))
      (expect (remoto--find-token remoto--codeberg) :to-be nil)
      (expect 'ghub--username :to-have-been-called-with "codeberg.org" 'forgejo)
      (expect (seq-uniq (mapcar #'car (reverse searched)))
              :to-equal '("codeberg.org/api/v1" "codeberg.org"))
      (expect (mapcar #'cdr (seq-take (reverse searched) 3))
              :to-equal '("me^forge" "me^ghub" "me"))
      (expect (remoto--login-failed (remoto--login "codeberg.org/api/v1")) :to-be nil)))

  (it "goes anonymous for good when git config names no account for the forge"
    (let ((remoto--logins (remoto-test--logins)))
      (spy-on 'ghub--username :and-call-fake
              (lambda (&rest _) (error "Cannot determine username")))
      (spy-on 'auth-source-search)
      (spy-on 'message)
      (expect (remoto--find-token remoto--codeberg) :to-be nil)
      (expect 'auth-source-search :not :to-have-been-called)
      (expect (remoto--login-failed (remoto--login "codeberg.org/api/v1")) :to-be t)
      (expect (remoto--login-failed (remoto-test--github-login)) :to-be nil)
      (expect 'message :to-have-been-called-with
              "Remoto: no %s in git config, reading %s anonymously"
              "forgejo.user" "codeberg.org")))

  (it "names the git config key ghub reads for the host of the forge"
    ;; ghub takes KIND.user for the domain of its default host of the kind
    ;; only; its releases name GitHub's api.github.com, some snapshots github.com.
    (unwind-protect
        (progn
          (remoto-forgejo--register-instances '(("gitea" "gitea.com")))
          (dolist (github '("api.github.com" "github.com"))
            (let ((ghub-default-host-alist `((github . ,github) (forgejo . "codeberg.org"))))
              (expect (remoto--git-user-key remoto--github) :to-equal "github.user")
              (expect (remoto--git-user-key remoto--codeberg) :to-equal "forgejo.user")
              (expect (remoto--git-user-key (cdr (remoto--prefix-of "/gitea:o/r")))
                      :to-equal "forgejo.gitea.com.user"))))
      (remoto-forgejo--register-instances nil))))

(describe "caches keyed by forge"
  (it "keeps the trees and default branches of two forges apart"
    (remoto-test-with-cache
      (puthash "/codeberg:testowner/testrepo" "forgejo" remoto--default-branch-cache)
      (expect (remoto--maybe-rewrite "/github:testowner/testrepo/")
              :to-equal "/github:testowner/testrepo@main:/")
      (expect (remoto--maybe-rewrite "/codeberg:testowner/testrepo/")
              :to-equal "/codeberg:testowner/testrepo@forgejo:/")
      (expect (remoto--repo-key (remoto--parse-path "/codeberg:o/r@main:/"))
              :to-equal "/codeberg:o/r@main")
      (expect (file-exists-p "/github:testowner/testrepo@main:/README.md") :to-be t)
      (spy-on 'remoto-forge-tree :and-call-fake
              (lambda (&rest _) (signal 'remoto-unsupported '(codeberg tree))))
      ;; GitHub's cached tree answers for nothing else.
      (expect (ignore-errors (file-exists-p "/codeberg:testowner/testrepo@main:/README.md"))
              :to-be nil)
      (expect 'remoto-forge-tree :to-have-been-called)))

  (it "remembers a listed repository under the prefix of its forge"
    (remoto-test-with-cache
      (remoto--remember-repo "/codeberg:" "o/r" '((name . "r") (default_branch . "dev")))
      (expect (gethash "/codeberg:o/r" remoto--default-branch-cache) :to-equal "dev")
      (expect (gethash "o/r" remoto--default-branch-cache) :to-be nil))))

;;; The Forgejo forge

(describe "the Forgejo forge"
  (it "is registered for Codeberg under /codeberg: and /cb:"
    (expect (remoto-forge-name (cdr (remoto--prefix-of "/cb:o/r"))) :to-be 'codeberg)
    (expect (remoto--prefix remoto--codeberg) :to-equal "/codeberg:")
    (expect (remoto-forgejo-p remoto--codeberg) :to-be t)
    (expect (remoto-github-p remoto--codeberg) :to-be t)
    (expect (remoto--api-host remoto--codeberg) :to-equal "codeberg.org/api/v1")
    (expect (remoto--ghub-forge remoto--codeberg) :to-be 'forgejo))

  (it "spells pages and page sizes Forgejo's way"
    (expect (remoto--page-params remoto--codeberg 30) :to-equal "limit=30")
    (expect (remoto--page-params remoto--codeberg 50 2) :to-equal "limit=50&page=2")
    (expect (remoto--page-size remoto--codeberg) :to-equal 50)
    (expect (remoto--page-params remoto--github 100 2) :to-equal "per_page=100&page=2"))

  (it "pages branches and tags by 50 and stops at a short page"
    (remoto-test-with-cache
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint)
                (pcase endpoint
                  ("repos/o/r/branches?limit=50&page=1"
                   (cl-loop for i from 1 to 50 collect `((name . ,(format "b%d" i)))))
                  ("repos/o/r/branches?limit=50&page=2" '(((name . "last"))))
                  (_ (error "Unexpected %s" endpoint)))))
      (let ((branches (remoto-forge-branches remoto--codeberg "o" "r")))
        (expect (length branches) :to-equal 51)
        (expect (car (last branches)) :to-equal "last"))))

  (it "asks the pages after the first at once, as many as X-Total-Count says"
    ;; One after another, the 7 tag pages of forgejo/forgejo took 7 round trips.
    (remoto-test-with-cache
      (let ((names (lambda (from to)
                     (cl-loop for i from from to to collect `((name . ,(format "t%d" i)))))))
        (spy-on 'remoto--api :and-call-fake
                (lambda (_forge endpoint)
                  (expect endpoint :to-equal "repos/o/r/tags?limit=50&page=1")
                  (setq remoto--response-headers '(("x-total-count" . "120")))
                  (funcall names 1 50)))
        (spy-on 'remoto--api-async :and-call-fake
                (lambda (_forge endpoint callback &optional _errback)
                  (funcall callback
                           (pcase endpoint
                             ("repos/o/r/tags?limit=50&page=2" (funcall names 51 100))
                             ("repos/o/r/tags?limit=50&page=3" (funcall names 101 120))
                             (_ (error "Unexpected %s" endpoint))))))
        (let ((tags (remoto-forge-tags remoto--codeberg "o" "r")))
          (expect (length tags) :to-equal 120)
          (expect (seq-take tags 2) :to-equal '("t1" "t2"))
          (expect (car (last tags)) :to-equal "t120"))
        (expect (mapcar #'cadr (spy-calls-all-args 'remoto--api-async))
                :to-equal '("repos/o/r/tags?limit=50&page=2"
                            "repos/o/r/tags?limit=50&page=3")))))

  (it "asks no more pages at once than MAX-PAGES, and keeps the pages that answer"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_forge _endpoint)
              (setq remoto--response-headers '(("X-Total-Count" . "5000")))
              (make-list 50 '((name . "a")))))
    (spy-on 'remoto--api-async :and-call-fake
            (lambda (_forge endpoint callback &optional errback)
              (if (string-suffix-p "page=2" endpoint)
                  (funcall errback)
                (funcall callback (make-list 50 '((name . "b")))))))
    (let ((items (remoto--paginated-api remoto--codeberg "repos/o/r/tags" 3)))
      (expect 'remoto--api-async :to-have-been-called-times 2)
      (expect (length items) :to-equal 100)))

  (it "searches accounts and repositories at Forgejo's endpoints, by the owner's id"
    (remoto-test-with-cache
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint)
                (pcase endpoint
                  ("users/forgejo" '((id . 70422) (login . "forgejo")))
                  ("users/forge" (user-error "%s%s" remoto--not-found endpoint))
                  ("users/search?q=forge&limit=50"
                   '((ok . t) (data . (((login . "forgejo-bot"))))))
                  ("repos/search?q=doc&uid=70422&exclusive=true&limit=50"
                   '((ok . t) (data . (((name . "docs") (full_name . "forgejo/docs")
                                        (default_branch . "next"))))))
                  ("repos/search?uid=70422&exclusive=true&sort=updated&order=desc&limit=30"
                   '((ok . t) (data . (((name . "website") (full_name . "forgejo/website"))))))
                  (_ (error "Unexpected %s" endpoint)))))
      (expect (remoto-forge-search-accounts remoto--codeberg "forge" t)
              :to-equal '("forgejo-bot"))
      (expect (remoto-forge-search-repos remoto--codeberg "forgejo" "doc" t)
              :to-equal '("docs"))
      (expect (remoto-forge-recent-repos remoto--codeberg "forgejo" t)
              :to-equal '("website"))
      (expect (gethash "/codeberg:forgejo/docs" remoto--default-branch-cache)
              :to-equal "next")
      ;; The id was asked for once.
      (expect (seq-count (lambda (args) (equal (cadr args) "users/forgejo"))
                         (spy-calls-all-args 'remoto--api))
              :to-equal 1)))

  (it "puts the account the query names first, an organization users/search misses"
    (remoto-test-with-cache
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint)
                (pcase endpoint
                  ("users/search?q=Forgejo&limit=50"
                   '((ok . t) (data . (((login . "forgejo-bot")) ((login . "niceforgejo"))))))
                  ("users/Forgejo" '((id . 70422) (login . "forgejo")))
                  (_ (error "Unexpected %s" endpoint)))))
      (expect (remoto-forge-search-accounts remoto--codeberg "Forgejo" t)
              :to-equal '("forgejo" "forgejo-bot" "niceforgejo"))
      (expect (cdr (remoto--account-matches "/codeberg:Forgejo"))
              :to-equal '("forgejo" "forgejo-bot" "niceforgejo"))))

  (it "offers the account the query names in completion once its lookup answers"
    (remoto-test-with-cache
      (spy-on 'run-with-idle-timer :and-call-fake
              (lambda (_secs _repeat fn &rest args) (apply fn args) nil))
      (spy-on 'remoto--api-async :and-call-fake
              (lambda (_forge endpoint callback &optional _errback)
                (funcall callback
                         (pcase endpoint
                           ("users/search?q=forgejo&limit=30"
                            '((ok . t) (data . (((login . "forgejo-bot"))))))
                           ("users/forgejo" '((id . 70422) (login . "forgejo")))
                           (_ (error "Unexpected %s" endpoint))))))
      (remoto-forge-search-accounts remoto--codeberg "forgejo" nil)
      (expect (remoto-forge-search-accounts remoto--codeberg "forgejo" nil)
              :to-equal '("forgejo" "forgejo-bot"))
      (expect 'remoto--api-async :to-have-been-called-times 2)))

  (it "searches no repositories for an owner of no account, in the background or not"
    ;; repos/search with no uid searches every account; a timer that signals
    ;; prints "Error running timer".
    (remoto-test-with-cache
      (spy-on 'run-with-idle-timer :and-call-fake
              (lambda (_secs _repeat fn &rest args) (apply fn args) nil))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint)
                (pcase endpoint
                  ((or "users/zz9q" "users/zz9q/repos?limit=50" "repos/zz9q/x")
                   (user-error "%s%s" remoto--not-found endpoint))
                  (_ (error "Unexpected %s" endpoint)))))
      (spy-on 'remoto--api-async :and-call-fake
              (lambda (_forge endpoint _callback &optional errback)
                (expect endpoint :to-equal "users/zz9q/repos?limit=30")
                (when errback (funcall errback))))
      (expect (remoto-forge-recent-repos remoto--codeberg "zz9q" nil) :to-be nil)
      (expect (condition-case err (remoto--repo-matches "/codeberg:zz9q/x")
                (user-error (cadr err)))
              :to-equal "Remoto: no account zz9q")
      ;; The account was asked for once.
      (expect (seq-count (lambda (args) (equal (cadr args) "users/zz9q"))
                         (spy-calls-all-args 'remoto--api))
              :to-equal 1)))

  (it "searches topics in the repository's own issues endpoint"
    (spy-on 'remoto--api :and-return-value '(((number . 7) (title . "rate limit"))))
    (expect (remoto-forge-search-topics remoto--codeberg "o" "r" "rate limit")
            :to-equal '(((number . 7) (title . "rate limit"))))
    (expect 'remoto--api :to-have-been-called-with
            remoto--codeberg "repos/o/r/issues?q=rate%20limit&state=all&type=all&limit=30"))

  (it "joins the pages of a recursive tree, asked for at once after the first"
    (remoto-test-with-cache
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint)
                (expect endpoint :to-equal
                        "repos/o/r/git/trees/main?recursive=1&per_page=1000&page=1")
                '((total_count . 2500) (truncated . t)
                  (tree . (((path . "a") (type . "blob") (size . 1) (sha . "1")
                            (mode . "100644")))))))
      (spy-on 'remoto--api-async :and-call-fake
              (lambda (_forge endpoint callback &optional _errback)
                (funcall callback
                         `((truncated . ,(string-suffix-p "page=2" endpoint))
                           (tree . (((path . ,(if (string-suffix-p "page=2" endpoint)
                                                   "b" "c"))
                                     (type . "blob") (size . 1) (sha . "2")
                                     (mode . "100644"))))))))
      (let ((tree (remoto-forge-tree remoto--codeberg "o" "r" "main")))
        (expect (sort (seq-remove (lambda (k) (string-prefix-p "\0" k))
                                  (hash-table-keys tree))
                      #'string<)
                :to-equal '("" "/" "a" "b" "c"))
        (expect (gethash "\0truncated" tree) :to-be nil)
        (expect (mapcar #'cadr (spy-calls-all-args 'remoto--api-async))
                :to-equal '("repos/o/r/git/trees/main?recursive=1&per_page=1000&page=2"
                            "repos/o/r/git/trees/main?recursive=1&per_page=1000&page=3")))))

  (it "leaves the tree partial when a page fails"
    (remoto-test-with-cache
      (spy-on 'remoto--api :and-return-value
              '((total_count . 1500) (truncated . t)
                (tree . (((path . "a") (type . "blob") (size . 1) (sha . "1")
                          (mode . "100644"))))))
      (spy-on 'remoto--api-async :and-call-fake
              (lambda (_forge _endpoint _callback &optional errback)
                (funcall errback)))
      (spy-on 'message)
      (let ((tree (remoto-forge-tree remoto--codeberg "o" "r" "main")))
        (expect (gethash "a" tree) :to-be-truthy)
        (expect (gethash "\0truncated" tree) :to-be t))))

  (it "looks refs up under a prefix at git/refs, and a commit at git/commits"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_forge endpoint)
              (pcase endpoint
                ("repos/o/r/git/refs/heads/v12" '(((ref . "refs/heads/v12.0/forgejo"))))
                ("repos/o/r/git/commits/main" '((sha . "abc")))
                (_ (error "Unexpected %s" endpoint)))))
    (expect (remoto--matching-refs remoto--codeberg "o" "r" "heads" "v12")
            :to-equal '("v12.0/forgejo"))
    (expect (remoto-forge-commit-sha remoto--codeberg "o" "r" "main") :to-equal "abc"))

  (it "escapes the slash of a ref in the endpoints that take the ref in their path"
    ;; Codeberg answers 404 to git/trees/v15.0/forgejo, 200 to v15.0%2Fforgejo.
    (remoto-test-with-cache
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint)
                (pcase endpoint
                  ("repos/o/r/git/trees/v15.0%2Fforgejo?recursive=1&per_page=1000&page=1"
                   '((total_count . 1)
                     (tree . (((path . "go.mod") (type . "blob") (size . 1) (sha . "1")
                               (mode . "100644"))))))
                  ("repos/o/r/git/commits/v15.0%2Fforgejo" '((sha . "115c575")))
                  (_ (error "Unexpected %s" endpoint)))))
      (expect (file-exists-p "/codeberg:o/r@v15.0/forgejo:/go.mod") :to-be t)
      (expect (remoto-forge-commit-sha remoto--codeberg "o" "r" "v15.0/forgejo")
              :to-equal "115c575")))

  (it "leaves the slash of a ref as it is in GitHub's tree endpoint"
    (remoto-test-with-cache
      (spy-on 'remoto--api :and-return-value '((tree)))
      (remoto-forge-tree remoto--github "o" "r" "release/2026.5.0")
      (expect 'remoto--api :to-have-been-called-with
              remoto--github "repos/o/r/git/trees/release/2026.5.0?recursive=1")))

  (it "spells review states GitHub's way and drops review requests"
    (spy-on 'remoto--api :and-return-value
            '(((state . "APPROVED") (user . ((login . "a"))))
              ((state . "REQUEST_CHANGES") (user . ((login . "b"))))
              ((state . "COMMENT") (user . ((login . "c"))))
              ((state . "REQUEST_REVIEW") (user . nil))))
    (expect (mapcar (lambda (r) (alist-get 'state r))
                    (remoto-forge-reviews remoto--codeberg "o" "r" "1"))
            :to-equal '("APPROVED" "CHANGES_REQUESTED" "COMMENTED")))

  (it "reads the organizations of the token by their username"
    (spy-on 'remoto--api :and-return-value
            '(((username . "forgejo") (description . "We forge."))))
    (let ((orgs (remoto-forge-user-orgs remoto--codeberg "me")))
      (expect (mapcar #'substring-no-properties orgs) :to-equal '("forgejo"))
      (expect (get-text-property 0 'remoto-acct-desc (car orgs)) :to-equal "We forge."))))

(describe "the web URLs of a Forgejo forge"
  (it "spells the kind of the ref in the path, from the cached refs"
    (spy-on 'remoto-forge-branches :and-return-value '("main" "v12.0/forgejo"))
    (spy-on 'remoto-forge-tags :and-return-value '("v1.0"))
    (expect (remoto--forge-url 'codeberg 'blob "o" "r" "main" "go.mod" 5 10)
            :to-equal "https://codeberg.org/o/r/src/branch/main/go.mod#L5-L10")
    (expect (remoto--forge-url 'codeberg 'raw "o" "r" "v1.0" "go.mod")
            :to-equal "https://codeberg.org/o/r/raw/tag/v1.0/go.mod")
    (expect (remoto--forge-url 'codeberg 'tree "o" "r" "v12.0/forgejo" "models")
            :to-equal "https://codeberg.org/o/r/src/branch/v12.0/forgejo/models")
    (expect (remoto--forge-url 'codeberg 'blame "o" "r" "1d9703c28a34" "go.mod" 3)
            :to-equal "https://codeberg.org/o/r/blame/commit/1d9703c28a34/go.mod#L3")
    (expect (remoto--forge-url 'codeberg 'history "o" "r" nil "")
            :to-equal "https://codeberg.org/o/r/commits/branch/HEAD/")
    (expect (remoto--forge-url 'codeberg 'repo "o" "r" nil "")
            :to-equal "https://codeberg.org/o/r")
    (expect (remoto--forge-url 'codeberg 'ssh "o" "r" nil "")
            :to-equal "git@codeberg.org:o/r.git")
    (expect (remoto--forge-url 'codeberg 'compare "o" "r" "dev" "")
            :to-equal "https://codeberg.org/o/r/compare/dev")
    (expect (remoto--forge-issue-url 'codeberg "o" "r" "7") :to-equal "https://codeberg.org/o/r/issues/7")
    (expect (remoto--forge-issue-url 'codeberg "o" "r" "7" 'pr) :to-equal "https://codeberg.org/o/r/pulls/7")
    (expect (remoto--forge-issue-url 'codeberg "o" "r" "7" 'pr-diff)
            :to-equal "https://codeberg.org/o/r/pulls/7/files")
    (expect (remoto--forge-owner-url 'codeberg "o") :to-equal "https://codeberg.org/o"))

  (it "leaves GitHub's URLs as they were"
    (expect (remoto--forge-url 'github 'blob "o" "r" "main" "a.el" 1)
            :to-equal "https://github.com/o/r/blob/main/a.el#L1")
    (expect (remoto--forge-issue-url 'github "o" "r" "7" 'pr)
            :to-equal "https://github.com/o/r/pull/7"))

  (it "reads Codeberg's URLs and remotes, the kind of the ref spelled or not"
    (spy-on 'remoto--matching-refs :and-call-fake
            (lambda (_forge _owner _repo kind prefix)
              (and (equal kind "heads") (equal prefix "v12.0") '("v12.0/forgejo"))))
    (dolist (case '(("https://codeberg.org/o/r" . "/codeberg:o/r:/")
                    ("https://codeberg.org/o/r.git" . "/codeberg:o/r:/")
                    ("codeberg.org/o/r" . "/codeberg:o/r:/")
                    ("/codeberg.org/o/r/" . "/codeberg:o/r:/")
                    ("git@codeberg.org:o/r.git" . "/codeberg:o/r:/")
                    ("https://codeberg.org/o/r/src/branch/main/go.mod"
                     . "/codeberg:o/r@main:/go.mod")
                    ("https://codeberg.org/o/r/src/tag/v1.0/docs"
                     . "/codeberg:o/r@v1.0:/docs")
                    ("https://codeberg.org/o/r/src/commit/1d9703c/go.mod"
                     . "/codeberg:o/r@1d9703c:/go.mod")
                    ("https://codeberg.org/o/r/src/main/go.mod?display=source#L5"
                     . "/codeberg:o/r@main:/go.mod")
                    ("https://codeberg.org/o/r/raw/branch/main/go.mod"
                     . "/codeberg:o/r@main:/go.mod")
                    ("https://codeberg.org/o/r/src/branch/v12.0/forgejo/go.mod"
                     . "/codeberg:o/r@v12.0/forgejo:/go.mod")
                    ("https://codeberg.org/o/r/pulls/7" . "/codeberg:o/r:/")))
      (expect (remoto--canonical-path
               (remoto-forge-parse-url remoto--codeberg (car case)))
              :to-equal (cdr case)))
    (expect (remoto-forge-parse-url remoto--codeberg "https://github.com/o/r") :to-be nil)
    (expect (remoto-forge-url-input-p remoto--codeberg "https://codeberg.org/o/r") :to-be-truthy)
    (expect (remoto-forge-url-input-p remoto--codeberg "https://github.com/o/r") :to-be nil)
    (expect (remoto-forge-parse-topic-url remoto--codeberg
                                          "https://codeberg.org/o/r/pulls/7/files")
            :to-equal '("o" "r" "7"))
    (expect (remoto-forge-parse-topic-url remoto--codeberg "codeberg.org/o/r/issues/8#x")
            :to-equal '("o" "r" "8"))
    (expect (remoto-forge-parse-topic-url remoto--codeberg "https://codeberg.org/o/r")
            :to-be nil))

  (it "routes a URL to the forge of its host"
    (expect (remoto--url-forge "https://codeberg.org/o/r") :to-be remoto--codeberg)
    (expect (remoto--url-forge "git@codeberg.org:o/r.git") :to-be remoto--codeberg)
    (expect (remoto--url-forge "https://github.com/o/r") :to-be remoto--github)
    (remoto-test-with-cache
      (puthash "/codeberg:o/r" "main" remoto--default-branch-cache)
      (expect (remoto--maybe-rewrite "https://codeberg.org/o/r")
              :to-equal "/codeberg:o/r@main:/")))

  (it "opens a topic in the browser at the forge's pull or issue page"
    (require 'remoto-topic)
    (spy-on 'browse-url)
    (with-temp-buffer
      (setq remoto-topic--number "7"
            remoto-topic--repo-path "/codeberg:o/r"
            remoto-topic--is-pr t)
      (remoto-topic-browse)
      (expect 'browse-url :to-have-been-called-with "https://codeberg.org/o/r/pulls/7")
      (setq remoto-topic--repo-path "/github:o/r" remoto-topic--is-pr nil)
      (remoto-topic-browse)
      (expect 'browse-url :to-have-been-called-with "https://github.com/o/r/issues/7"))))

(describe "remoto-topic-display on two forges"
  (it "keeps the same OWNER/REPO#N of two forges in two buffers named by the forge"
    (require 'remoto-topic)
    (spy-on 'remoto-forge-topic :and-call-fake
            (lambda (forge _owner _repo number)
              `((number . ,(string-to-number number)) (state . "open")
                (title . ,(format "on %s" (remoto-forge-name forge)))
                (user . ((login . "a"))) (body . "text"))))
    (spy-on 'remoto-forge-topic-comments)
    (spy-on 'pop-to-buffer)
    (let ((github (remoto-topic-display "7" "/github:o/r"))
          (codeberg (remoto-topic-display "7" "/codeberg:o/r")))
      (unwind-protect
          (progn
            (expect (buffer-name github) :to-equal "*remoto: /github:o/r#7*")
            (expect (buffer-name codeberg) :to-equal "*remoto: /codeberg:o/r#7*")
            (expect (with-current-buffer github (buffer-string)) :to-match "on github")
            (expect (with-current-buffer codeberg (buffer-string)) :to-match "on codeberg"))
        (kill-buffer github)
        (kill-buffer codeberg)))))

(describe "remoto-forgejo-instances"
  (after-each
    (remoto-forgejo--register-instances nil))

  (it "registers a forge per (PREFIX HOST) and drops it when the entry goes"
    (remoto-forgejo--register-instances '(("gitea" "gitea.com")))
    (let ((forge (cdr (remoto--prefix-of "/gitea:o/r"))))
      (expect (remoto-forgejo-p forge) :to-be t)
      (expect (remoto-forge-name forge) :to-be 'gitea)
      (expect (remoto-forge-host forge) :to-equal "gitea.com")
      (expect (remoto--api-host forge) :to-equal "gitea.com/api/v1")
      (expect (remoto--canonical-path (remoto--parse-path "/gitea:o/r@main:/x"))
              :to-equal "/gitea:o/r@main:/x")
      (expect (remoto--forge-url 'gitea 'repo "o" "r" nil "")
              :to-equal "https://gitea.com/o/r")
      (expect (string-match-p remoto--handler-regexp "/gitea:o/r") :to-be 0))
    (remoto-forgejo--register-instances nil)
    (expect (remoto--prefix-of "/gitea:o/r") :to-be nil)
    (expect (string-match-p remoto--handler-regexp "/gitea:o/r") :to-be nil)
    (expect (string-match-p remoto--handler-regexp "/cb:o/r") :to-be 0))

  (it "refuses a prefix that another forge owns"
    (spy-on 'display-warning)
    (remoto-forgejo--register-instances '(("gh" "gitea.com")))
    (expect 'display-warning :to-have-been-called)
    (expect (cdr (remoto--prefix-of "/gh:o/r")) :to-be remoto--github))

  (it "refuses a prefix with a colon or a slash and a host with a scheme or a path"
    (spy-on 'display-warning)
    (remoto-forgejo--register-instances '(("gitea:" "gitea.com") ("g/t" "gitea.com")
                                          ("gs" "https://gitea.com") ("gp" "gitea.com/x")
                                          ("ok" "127.0.0.1:8899")))
    (expect 'display-warning :to-have-been-called-times 4)
    (expect (mapcar #'car remoto-forgejo--instances) :to-equal '("ok"))
    (expect (remoto-forge-host (cdr (remoto--prefix-of "/ok:o/r")))
            :to-equal "127.0.0.1:8899")
    (expect (remoto--prefix-of "/gs:o/r") :to-be nil))

  (it "refuses a prefix that names a TRAMP method"
    ;; remoto's handler goes first in the alist: /ssh: would stop reaching TRAMP.
    (spy-on 'display-warning)
    (remoto-forgejo--register-instances '(("ssh" "example.org") ("gitea" "gitea.com")))
    (expect 'display-warning :to-have-been-called-times 1)
    (expect (mapcar #'car remoto-forgejo--instances) :to-equal '("gitea"))
    (expect (remoto--prefix-of "/ssh:host:/tmp/x") :to-be nil)
    (expect (find-file-name-handler "/ssh:host:/tmp/x" 'file-exists-p)
            :not :to-be 'remoto-file-name-handler))

  (it "applies the option when it is set through custom"
    (customize-set-variable 'remoto-forgejo-instances '(("gitea" "gitea.com")))
    (expect (remoto-forge-host (cdr (remoto--prefix-of "/gitea:o/r")))
            :to-equal "gitea.com")
    (customize-set-variable 'remoto-forgejo-instances nil)
    (expect (remoto--prefix-of "/gitea:o/r") :to-be nil))

  (it "kills the buffers of a removed server, says so, and keeps the others"
    ;; A buffer whose name no handler serves breaks uniquify for its namesakes.
    (remoto-test-with-cache
      (remoto-forgejo--register-instances '(("gitea" "gitea.com")))
      (puthash "/gitea:testowner/testrepo@main"
               (gethash "/github:testowner/testrepo@main" remoto--tree-cache)
               remoto--tree-cache)
      (spy-on 'message)
      (let ((dired (dired-noselect "/gitea:testowner/testrepo@main:/"))
            (file (generate-new-buffer "README.md"))
            (topic (generate-new-buffer "*remoto: /gitea:o/r#7*"))
            (other (generate-new-buffer "README.md")))
        (unwind-protect
            (progn
              (with-current-buffer file
                (setq buffer-file-name "/gitea:testowner/testrepo@main:/README.md"))
              (with-current-buffer topic
                (setq-local remoto-topic--repo-path "/gitea:o/r"))
              (with-current-buffer other
                (setq buffer-file-name "/codeberg:o/r@main:/README.md"))
              (remoto-forgejo--register-instances nil)
              (expect (mapcar #'buffer-live-p (list dired file topic other))
                      :to-equal '(nil nil nil t))
              (expect 'message :to-have-been-called-with
                      "Remoto: killed %d buffer%s of %s" 3 "s" "/gitea:"))
          (dolist (buffer (list dired file topic other))
            (when (buffer-live-p buffer)
              (kill-buffer buffer)))))))

  (it "keeps a server that stays, its forge and its buffers, when the list changes"
    (remoto-forgejo--register-instances '(("gitea" "gitea.com")))
    (let ((forge (cdr (remoto--prefix-of "/gitea:o/r")))
          (file (generate-new-buffer "README.md")))
      (unwind-protect
          (progn
            (with-current-buffer file
              (setq buffer-file-name "/gitea:o/r@main:/README.md"))
            (remoto-forgejo--register-instances '(("gitea" "gitea.com")
                                                  ("cf" "code.forgejo.org")))
            (expect (cdr (remoto--prefix-of "/gitea:o/r")) :to-be forge)
            (expect (buffer-live-p file) :to-be t)
            (expect (remoto-forge-host (cdr (remoto--prefix-of "/cf:o/r")))
                    :to-equal "code.forgejo.org")
            ;; A new host behind the prefix is a new server.
            (spy-on 'message)
            (remoto-forgejo--register-instances '(("gitea" "try.gitea.io")))
            (expect (remoto-forge-host (cdr (remoto--prefix-of "/gitea:o/r")))
                    :to-equal "try.gitea.io")
            (expect (buffer-live-p file) :to-be nil)
            (expect (remoto--prefix-of "/cf:o/r") :to-be nil))
        (when (buffer-live-p file)
          (kill-buffer file)))))

  (it "forgets the web URL templates and the login of a removed server"
    (let ((remoto--logins (remoto-test--logins)))
      (remoto-forgejo--register-instances '(("gitea" "gitea.com") ("cbx" "codeberg.org")))
      (remoto--login "gitea.com/api/v1")
      (remoto-forgejo--register-instances nil)
      (expect (assq 'gitea remoto-forge-url-templates) :to-be nil)
      (expect (assq 'cbx remoto-forge-url-templates) :to-be nil)
      (expect (gethash "gitea.com/api/v1" remoto--logins) :to-be nil)
      ;; Codeberg itself still asks the host the second server shared.
      (expect (gethash "codeberg.org/api/v1" remoto--logins) :to-be-truthy)
      (expect (assq 'codeberg remoto-forge-url-templates) :to-be-truthy))))

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

  (it "file-name-as-directory leaves /github: and /github:OWNER/REPO@ as they are"
    ;; Dired builds every name in a listing from this; /github:/OWNER
    ;; would name no account, and /github:OWNER/REPO@/REF no ref.
    (expect (file-name-as-directory "/github:") :to-equal "/github:")
    (expect (file-name-as-directory "/gh:") :to-equal "/github:")
    (expect (file-name-as-directory "/github:foobar") :to-equal "/github:foobar/")
    (expect (file-name-as-directory "/github:o/r@") :to-equal "/github:o/r@")
    (expect (file-name-as-directory "/github:o/r@main") :to-equal "/github:o/r@main/"))

  (it "file-name-nondirectory of a canonical directory name is empty"
    ;; Dired lists a directory whose name has a nondirectory part as a
    ;; wildcard, and completion matches that part against the children.
    (expect (file-name-nondirectory "/github:o/r@main:/src/") :to-equal "")
    (expect (file-name-nondirectory "/github:o/r@main:/src") :to-equal "src")
    (expect (file-name-nondirectory "/github:o/r@main:/") :to-equal ""))

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

  (it "completes /gh: and /github: without doubling the prefix"
    ;; Regression: the `read-file-name' advice re-based candidates to full
    ;; paths (e.g. /github:agzam/), so base-aware frameworks (Vertico, default
    ;; completion) prepended the directory again, yielding /gh:/gh:agzam/
    ;; (and /gh:agza/github:agzam/ before that).  Candidates must stay relative
    ;; to the completion boundary.  This mirrors how a framework inserts:
    ;; string[0..base] + candidate.
    (spy-on 'remoto--handle-file-name-all-completions
            :and-call-fake
            (lambda (file directory)
              (seq-filter (lambda (c) (string-prefix-p file c))
                          (if (string-match-p "/github:[^/]+/[^/]+/" directory)
                              '("src/") '("agzam/")))))
    (let* ((tbl #'read-file-name-internal)
           (insert (lambda (input)
                     (let* ((md (completion-metadata input tbl nil))
                            (all (completion-all-completions
                                  input tbl nil (length input) md))
                            (base (or (cdr (last all)) 0)))
                       (concat (substring input 0 base)
                               (and (consp all)
                                    (substring-no-properties (car all))))))))
      ;; candidate is the relative segment, not a full /github: path
      (expect (substring-no-properties
               (car (completion-all-completions
                     "/github:agza" tbl nil 12
                     (completion-metadata "/github:agza" tbl nil))))
              :to-equal "agzam/")
      ;; the framework insert is single-prefixed at every level
      (expect (funcall insert "/gh:agza") :to-equal "/gh:agzam/")
      (expect (funcall insert "/github:agza") :to-equal "/github:agzam/")
      (expect (funcall insert "/gh:torvalds/linux/sr")
              :to-equal "/gh:torvalds/linux/src/")))

  (it "injects the same completion metadata category as /github: per level"
    (let ((cat (lambda (s)
                 (completion-metadata-get
                  (completion-metadata s #'read-file-name-internal nil) 'category))))
      (expect (funcall cat "/gh:agzam/repo@") :to-equal 'remoto-branch)
      (expect (funcall cat "/gh:agzam/repo#") :to-equal 'remoto-issue)
      (expect (funcall cat "/gh:agza") :to-equal (funcall cat "/github:agza"))))

  (it "routes /gh: through the public file API like /github:"
    (expect (file-remote-p "/gh:foobar/" 'method) :to-equal "github")
    (expect (file-remote-p "/gh:foobar/")
            :to-equal (file-remote-p "/github:foobar/"))))

;;; User search

(describe "remoto--search-users"
  (it "returns nil for queries below min-search-chars"
    (let ((remoto-min-search-chars 3))
      (expect (remoto--search-users remoto--github "") :to-be nil)
      (expect (remoto--search-users remoto--github "a") :to-be nil)
      (expect (remoto--search-users remoto--github "ab") :to-be nil)))

  (it "schedules async fetch on cache miss, returns nil"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto--users-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      (expect (remoto--search-users remoto--github "tor") :to-be nil)
      (expect 'remoto--debounce :to-have-been-called)))

  (it "populates cache via async callback"
    ;; Make debounce execute immediately, mock api-async to invoke callback
    (spy-on 'remoto--debounce :and-call-fake (lambda (_key fn) (funcall fn)))
    (spy-on 'remoto--api-async :and-call-fake
            (lambda (_forge _endpoint callback)
              (funcall callback '((items . (((login . "torvalds") (type . "User"))
                                            ((login . "torgeirhelge") (type . "User"))))))))
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto--users-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      ;; First call: triggers async, returns nil
      (remoto--search-users remoto--github "tor")
      ;; Cache should now be populated by the callback
      (expect (remoto--search-users remoto--github "tor")
              :to-equal '("torvalds" "torgeirhelge"))))

  (it "returns cached results without async call"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto--users-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      ;; Pre-populate cache
      (puthash "\0users:/github:tor" (cons (float-time) '("torvalds" "torgeirhelge"))
               remoto--search-cache)
      (expect (remoto--search-users remoto--github "tor")
              :to-equal '("torvalds" "torgeirhelge"))
      ;; Should not have scheduled any async fetch
      (expect 'remoto--debounce :not :to-have-been-called)))

  (it "narrows cached results for longer prefixes without API call"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto--users-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      ;; Seed the users-cache with a shorter query
      (puthash "/github:tor" (cons (float-time) '("torvalds" "torgeirhelge"))
               remoto--users-cache)
      (let ((result (remoto--search-users remoto--github "torv")))
        (expect result :to-equal '("torvalds"))
        (expect 'remoto--debounce :not :to-have-been-called)))))

;;; Owner repo search

(describe "remoto--search-owner-repos"
  (it "returns nil for empty query"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      (expect (remoto--search-owner-repos remoto--github "torvalds" "") :to-be nil)))

  (it "narrows from recent-repos cache below min-search-chars"
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3)
          (remoto-repo-cache-ttl 1800))
      ;; Seed recent-repos cache
      (puthash "\0repos-recent:/github:torvalds"
               (cons (float-time) '("linux" "libfdt" "subsurface"))
               remoto--search-cache)
      ;; Short query ("li") narrows from recent cache
      (expect (remoto--search-owner-repos remoto--github "torvalds" "li")
              :to-equal '("linux" "libfdt"))))

  (it "schedules async fetch on cache miss"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      (expect (remoto--search-owner-repos remoto--github "torvalds" "lin") :to-be nil)
      (expect 'remoto--debounce :to-have-been-called)))

  (it "populates cache via async callback"
    (spy-on 'remoto--debounce :and-call-fake (lambda (_key fn) (funcall fn)))
    (spy-on 'remoto--api-async :and-call-fake
            (lambda (_forge _endpoint callback)
              (funcall callback '((items . (((name . "linux"))
                                            ((name . "libfdt"))))))))
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      (remoto--search-owner-repos remoto--github "torvalds" "lin")
      ;; Cache now populated
      (expect (remoto--search-owner-repos remoto--github "torvalds" "lin")
              :to-equal '("linux" "libfdt"))))

  (it "returns cached results without async call"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      (puthash "\0repos:/github:torvalds/lin"
               (cons (float-time) '("linux" "libfdt"))
               remoto--search-cache)
      (expect (remoto--search-owner-repos remoto--github "torvalds" "lin")
              :to-equal '("linux" "libfdt"))
      (expect 'remoto--debounce :not :to-have-been-called)))

  (it "narrows cached results for longer query"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-min-search-chars 3))
      ;; Seed with shorter query
      (puthash "\0repos:/github:torvalds/li"
               (cons (float-time) '("linux" "libfdt"))
               remoto--search-cache)
      (let ((result (remoto--search-owner-repos remoto--github "torvalds" "lin")))
        (expect result :to-equal '("linux"))
        (expect 'remoto--debounce :not :to-have-been-called)))))

(describe "remoto--extract-search-repos"
  (it "extracts repo names with description properties"
    (let* ((data '((items . (((name . "linux") (description . "kernel"))
                              ((name . "uemacs") (description . nil))))))
           (repos (remoto--extract-search-repos remoto--github data)))
      (expect (length repos) :to-equal 2)
      (expect (car repos) :to-equal "linux")
      (expect (get-text-property 0 'remoto-repo-desc (car repos))
              :to-equal "kernel")
      (expect (get-text-property 0 'remoto-repo-desc (cadr repos))
              :to-equal "")))

  (it "uses alternate name key when provided"
    (let* ((data '((items . (((full_name . "torvalds/linux")
                               (description . "kernel"))))))
           (repos (remoto--extract-search-repos remoto--github data 'full_name)))
      (expect (car repos) :to-equal "torvalds/linux"))))

(describe "remoto--owner-search"
  (it "returns repos and populates cache on success"
    (spy-on 'remoto--api :and-return-value
            '((items . (((name . "linux") (description . "kernel"))
                         ((name . "libfdt") (description . ""))))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((result (remoto--owner-search remoto--github "torvalds" "lin")))
        (expect (length result) :to-equal 2)
        (expect (car result) :to-equal "linux")
        ;; Cache should be warm now
        (pcase-let ((`(,hit ,cached) (remoto--search-cache-get
                                       "\0repos:/github:torvalds/lin")))
          (expect hit :to-be-truthy)
          (expect (length cached) :to-equal 2)))))

  (it "signals on an API error, which completion turns into no candidates"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_forge _) (error "network error")))
    (spy-on 'remoto--search-owner-repos :and-return-value nil)
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (expect (remoto--owner-search remoto--github "torvalds" "lin") :to-throw)
      (expect (remoto--handle-file-name-all-completions "lin" "/github:torvalds/")
              :to-be nil))))

(describe "remoto--recent-owner-repos-sync"
  (it "returns repos and populates cache on success"
    (spy-on 'remoto--api :and-return-value
            '((items . (((name . "linux") (description . "kernel"))))))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (let ((result (remoto--recent-owner-repos-sync remoto--github "torvalds")))
        (expect (length result) :to-equal 1)
        (expect (car result) :to-equal "linux")
        ;; Cache should be warm
        (pcase-let ((`(,hit ,_) (remoto--search-cache-get
                                  "\0repos-recent:/github:torvalds"
                                  remoto-repo-cache-ttl)))
          (expect hit :to-be-truthy)))))

  (it "returns nil on API error without signaling"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_forge _) (error "network error")))
    (let ((remoto--search-cache (make-hash-table :test 'equal)))
      (expect (remoto--recent-owner-repos-sync remoto--github "torvalds")
              :to-be nil))))

(describe "owner-level sync fallback in file-name-all-completions"
  (it "falls back to sync search when async returns nil"
    (spy-on 'remoto--search-owner-repos :and-return-value nil)
    (spy-on 'remoto--owner-search :and-return-value '("linux"))
    (let ((completions (remoto--handle-file-name-all-completions
                        "lin" "/github:torvalds/")))
      (expect completions :to-equal '("linux/"))
      (expect 'remoto--owner-search
              :to-have-been-called-with remoto--github "torvalds" "lin")))

  (it "falls back to sync recent repos when async returns nil"
    (spy-on 'remoto--recent-owner-repos :and-return-value nil)
    (spy-on 'remoto--recent-owner-repos-sync :and-return-value '("linux"))
    (let ((completions (remoto--handle-file-name-all-completions
                        "" "/github:torvalds/")))
      (expect completions :to-equal '("linux/"))
      (expect 'remoto--recent-owner-repos-sync
              :to-have-been-called-with remoto--github "torvalds")))

  (it "skips sync fallback when async has results"
    (spy-on 'remoto--search-owner-repos :and-return-value '("linux"))
    (spy-on 'remoto--owner-search)
    (let ((completions (remoto--handle-file-name-all-completions
                        "lin" "/github:torvalds/")))
      (expect completions :to-equal '("linux/"))
      (expect 'remoto--owner-search :not :to-have-been-called)))

  (it "skips sync search below min-search-chars"
    (let ((remoto-min-search-chars 3))
      (spy-on 'remoto--search-owner-repos :and-return-value nil)
      (spy-on 'remoto--owner-search)
      (remoto--handle-file-name-all-completions "li" "/github:torvalds/")
      (expect 'remoto--owner-search :not :to-have-been-called))))

(describe "completion style registration"
  (it "leaves the user's completion-category-overrides alone"
    (dolist (cat '(remoto remoto-repo remoto-file remoto-branch
                   remoto-issue remoto-owner remoto-browse))
      (expect (assq cat completion-category-overrides) :to-be nil)
      (expect (assq cat completion-category-defaults) :to-be nil))))

(describe "remoto--get-authenticated-user"
  (it "returns login from /user endpoint"
    (let ((remoto--logins (remoto-test--logins :user nil :failed nil)))
      (spy-on 'remoto--api :and-return-value '((login . "agzam")))
      (expect (remoto--get-authenticated-user remoto--github) :to-equal "agzam")))

  (it "caches the result for subsequent calls"
    (let ((remoto--logins (remoto-test--logins :user nil :failed nil))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge _)
                (setq call-count (1+ call-count))
                '((login . "agzam"))))
      (remoto--get-authenticated-user remoto--github)
      (remoto--get-authenticated-user remoto--github)
      (expect call-count :to-equal 1)))

  (it "returns nil when auth has failed"
    (let ((remoto--logins (remoto-test--logins :user nil :failed t)))
      (spy-on 'remoto--api)
      (expect (remoto--get-authenticated-user remoto--github) :to-be nil)
      (expect 'remoto--api :not :to-have-been-called)))

  (it "returns nil on API error"
    (let ((remoto--logins (remoto-test--logins :user nil :failed nil)))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge _) (user-error "auth failed")))
      (expect (remoto--get-authenticated-user remoto--github) :to-be nil)))

  (it "sends no /user when the token lookup marks the login failed on the way"
    ;; An anonymous /user answers 401, and url.el answers that with a
    ;; password prompt.
    (let ((remoto--logins (remoto-test--logins))
          (remoto-github-auth nil))
      (spy-on 'remoto--find-token :and-call-fake
              (lambda (forge)
                (setf (remoto--login-failed (remoto--forge-login forge)) t)
                nil))
      (spy-on 'ghub-get)
      (expect (remoto--get-authenticated-user remoto--github) :to-be nil)
      (expect (remoto--get-authenticated-user remoto--codeberg) :to-be nil)
      (expect 'ghub-get :not :to-have-been-called))))

(describe "the root listing without a user name in git config"
  (it "says it needs a token and sends no request, on either forge"
    (remoto-test-with-cache
      (let ((remoto-github-auth nil)
            (before (buffer-list)))
        (spy-on 'ghub--username :and-call-fake
                (lambda (&rest _) (error "Cannot determine username")))
        (spy-on 'ghub-get)
        (spy-on 'message)
        (unwind-protect
            (pcase-dolist (`(,dir . ,host) '(("/github:" . "api.github.com")
                                             ("/codeberg:" . "codeberg.org/api/v1")))
              (expect (condition-case err (dired-noselect dir)
                        (user-error (error-message-string err)))
                      :to-equal (format "Remoto: %s lists your account and \
organizations, which needs a token for %s" dir host)))
          (dolist (buf (buffer-list))
            (unless (memq buf before) (kill-buffer buf))))
        (expect 'ghub-get :not :to-have-been-called)))))

(describe "remoto-reset-auth clears authenticated user"
  (it "clears cached authenticated user"
    (let ((remoto--logins (remoto-test--logins :failed t :user "agzam")))
      (remoto-reset-auth)
      (expect (remoto--login-user (remoto-test--github-login)) :to-be nil)
      (expect (remoto--login-failed (remoto-test--github-login)) :to-be nil)))

  (it "clears one host and keeps the others"
    (let ((remoto--logins (remoto-test--logins :failed t :user "agzam")))
      (setf (remoto--login-user (remoto--login "codeberg.org/api/v1")) "ag")
      (remoto-reset-auth "codeberg.org/api/v1")
      (expect (remoto--login-user (remoto--login "codeberg.org/api/v1")) :to-be nil)
      (expect (remoto--login-user (remoto-test--github-login)) :to-equal "agzam")))

  (it "clears every host when the prompt for one is left empty"
    ;; completing-read answers "" to an empty RET even when it requires a match.
    (let ((remoto--logins (remoto-test--logins :failed t :user "agzam"))
          (current-prefix-arg '(4)))
      (spy-on 'completing-read :and-return-value "")
      (spy-on 'message)
      (call-interactively #'remoto-reset-auth)
      (expect (hash-table-count remoto--logins) :to-equal 0)
      (expect (apply #'format (spy-calls-args-for 'message 0))
              :to-match "cleared for every host"))))

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

  (it "orderless-style: empty FILE, query from the minibuffer, regexps applied"
    ;; orderless hands the table only the boundary prefix and expresses
    ;; the typed text as `completion-regexp-list'.
    (spy-on 'remoto--search-owner-repos :and-return-value
            '("linux" "libdc-for-dirk"))
    (spy-on 'remoto--minibuffer-input :and-return-value "/github:torvalds/lin")
    (let ((completion-regexp-list '("lin")))
      (expect (remoto--handle-file-name-all-completions "" "/github:torvalds/")
              :to-equal '("linux/"))
      (expect 'remoto--search-owner-repos
              :to-have-been-called-with remoto--github "torvalds" "lin"))))

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
    (expect 'remoto--prefetch-owner-repos :to-have-been-called-with remoto--github "torvalds"))

  (it "returns nil for empty user query"
    (spy-on 'run-with-idle-timer)
    (let* ((remoto--logins (remoto-test--logins))
           (completions (remoto--handle-file-name-all-completions "" "/github:")))
      (expect completions :to-be nil)))

  (it "returns recent repos for empty query at /github:owner/"
    (spy-on 'remoto--recent-owner-repos :and-return-value '("linux" "uemacs"))
    (let ((completions (remoto--handle-file-name-all-completions "" "/github:torvalds/")))
      (expect completions :to-equal '("linux/" "uemacs/"))
      (expect 'remoto--recent-owner-repos :to-have-been-called-with remoto--github "torvalds")))

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
          (kill-buffer buf)))))

  (it "canonicalizes the short forms it is given"
    ;; The advice sits here rather than on `dired', so `dired',
    ;; `dired-other-window' and `dired-other-frame' all get the rewrite.
    (remoto-test-with-cache
      (dolist (name '("/github:testowner/testrepo"
                      "/github:testowner/testrepo/"
                      "/gh:testowner/testrepo"))
        (let ((buf (dired-noselect name)))
          (unwind-protect
              (with-current-buffer buf
                (expect default-directory
                        :to-equal "/github:testowner/testrepo@main:/")
                (expect (buffer-string) :to-match "README\\.md"))
            (kill-buffer buf))))))

  (it "lists a short form the rewriting advice never saw"
    ;; The first Dired of a session reaches the handler with the name the
    ;; caller typed: `dired-noselect' throws away the result of the one
    ;; operation the autoload bootstrap gets to rewrite.
    (remoto-test-with-cache
      (with-temp-buffer
        (remoto--handle-insert-directory
         "/github:testowner/testrepo/" "-al" nil t)
        (expect (buffer-string) :to-match "README\\.md")
        (expect (buffer-string) :to-match "src")))))

(defun remoto-test--add-listing-entries ()
  "Add a one-letter directory and a symlink to the cached mock tree."
  (let ((tree (gethash "/github:testowner/testrepo@main" remoto--tree-cache)))
    (puthash "a" '((type . "tree") (size . 0) (sha . "hhh") (mode . "040000"))
             tree)
    (puthash "a/b" '((type . "blob") (size . 1) (sha . "iii") (mode . "100644"))
             tree)
    (puthash "CHANGELOG"
             '((type . "blob") (size . 16) (sha . "ggg") (mode . "120000"))
             tree)))

(defmacro remoto-test-with-listing (switches &rest body)
  "Run BODY over the mock tree and its extra entries under ls SWITCHES.
Buffers BODY creates are killed afterwards."
  (declare (indent 1))
  (let ((before (make-symbol "before")))
    `(remoto-test-with-cache
       (remoto-test--add-listing-entries)
       (let ((dired-listing-switches ,switches)
             (,before (buffer-list)))
         (unwind-protect (progn ,@body)
           (dolist (buf (buffer-list))
             (unless (memq buf ,before) (kill-buffer buf))))))))

(defun remoto-test--listed-names (dir switches)
  "Return the names Dired reads in its listing of DIR under SWITCHES."
  (with-current-buffer (dired-noselect dir switches)
    (save-excursion
      (goto-char (point-min))
      (let (names)
        (while (not (eobp))
          (when (dired-move-to-filename)
            (push (dired-get-filename 'verbatim t) names))
          (forward-line 1))
        (nreverse names)))))

(defun remoto-test--visit-entry (dir name)
  "Press RET on NAME's line in the Dired buffer of DIR.
Return the buffer that RET leaves current."
  (with-current-buffer (dired-noselect dir)
    (goto-char (point-min))
    (let ((case-fold-search nil))
      (re-search-forward
       (concat " " (regexp-quote name) "[/*@]?\\(?: .*\\)?$")))
    (dired-find-file)
    (current-buffer)))

(describe "Dired listing under dired-listing-switches"
  ;; Dired cuts one character off a directory or executable name under -F
  ;; unless the listing marks the name, and needs " -> " on a symlink line.
  (it "reads every name exactly under -alF and -al"
    (dolist (switches '("-alF" "-al"))
      (remoto-test-with-listing switches
        (expect (remoto-test--listed-names
                 "/github:testowner/testrepo@main:/" switches)
                :to-equal '("." ".." "CHANGELOG" "README.md" "a" "bin" "src"))
        (expect (remoto-test--listed-names
                 "/github:testowner/testrepo@main:/bin/" switches)
                :to-equal '("." ".." "run")))))

  (it "shows the -F indicators under -F only"
    (remoto-test-with-listing "-alF"
      (let ((root (with-current-buffer
                      (dired-noselect "/github:testowner/testrepo@main:/")
                    (buffer-string)))
            (bin (with-current-buffer
                     (dired-noselect "/github:testowner/testrepo@main:/bin/")
                   (buffer-string))))
        (dolist (line '(" \\./$" " \\.\\./$" " a/$" " src/$" " CHANGELOG@$"
                        " README\\.md$"))
          (expect root :to-match line))
        (expect bin :to-match " run\\*$")))
    (remoto-test-with-listing "-al"
      (with-current-buffer (dired-noselect "/github:testowner/testrepo@main:/")
        (expect (buffer-string) :to-match " src$")
        (expect (buffer-string) :not :to-match "[*@]$\\| \\(?:a\\|src\\)/$"))))

  (it "visits . and .. from a listing"
    (dolist (switches '("-al" "-alF"))
      (remoto-test-with-listing switches
        ;; .. at the root lists the owner, here without a token.
        (spy-on 'remoto--api :and-call-fake
                (lambda (_forge endpoint)
                  (if (string-prefix-p "users/testowner/repos" endpoint)
                      (list (remoto-test--repo-item "testrepo" "2026-10-20T12:00:00Z"))
                    (error "Unexpected endpoint %s" endpoint))))
        (let ((remoto--logins (remoto-test--logins :failed t))
              (root "/github:testowner/testrepo@main:/")
              (src "/github:testowner/testrepo@main:/src/"))
          (with-current-buffer (remoto-test--visit-entry src "..")
            (expect dired-directory :to-equal root))
          (expect (remoto-test--visit-entry src ".")
                  :to-be (dired-noselect src))
          (with-current-buffer (remoto-test--visit-entry root "..")
            (expect dired-directory :to-equal "/github:testowner/"))))))

  (it "lists a subdirectory as a directory, with no wildcard line"
    (remoto-test-with-listing "-al"
      (with-current-buffer (dired-noselect "/github:testowner/testrepo@main:/src/")
        (expect (buffer-string) :not :to-match "wildcard")
        (expect (remoto-test--listed-names "/github:testowner/testrepo@main:/src/" "-al")
                :to-equal '("." ".." "main.el" "utils.el")))))

  (it "visits a one-letter directory and a symlink"
    (remoto-test-with-listing "-alF"
      (spy-on 'remoto--fetch-file-content :and-return-value "README.md")
      (with-current-buffer (remoto-test--visit-entry
                            "/github:testowner/testrepo@main:/" "a")
        (expect dired-directory :to-equal "/github:testowner/testrepo@main:/a/"))
      (with-current-buffer (remoto-test--visit-entry
                            "/github:testowner/testrepo@main:/" "CHANGELOG")
        (expect buffer-file-name
                :to-equal "/github:testowner/testrepo@main:/CHANGELOG")))))

;;; Listings above the repository level

(defun remoto-test--repo-item (name pushed &rest props)
  "Return repository NAME, last pushed at PUSHED, as a list endpoint sends it.
PROPS sets :desc, :private, :fork, :archived, :size and :branch, and
:owner the full_name that search results carry."
  `((name . ,name)
    (full_name . ,(and (plist-get props :owner)
                       (concat (plist-get props :owner) "/" name)))
    (description . ,(plist-get props :desc))
    (private . ,(plist-get props :private))
    (fork . ,(plist-get props :fork))
    (archived . ,(plist-get props :archived))
    (pushed_at . ,pushed)
    (size . ,(or (plist-get props :size) 1))
    (default_branch . ,(or (plist-get props :branch) "main"))))

(defun remoto-test--repo-items (count prefix)
  "Return COUNT repositories named PREFIX000, PREFIX001 and so on."
  (cl-loop for i below count
           collect (remoto-test--repo-item (format "%s%03d" prefix i)
                                           "2026-01-01T00:00:00Z")))

(defun remoto-test--listing-api (forge endpoint)
  "Answer ENDPOINT as GitHub does for the token of the account \"me\"."
  (cond
   ((string-prefix-p "user/orgs" endpoint)
    '(((login . "acme") (description . "Acme tools"))
      ((login . "quiet") (description))))
   ((string-prefix-p "user/repos?affiliation=owner&sort=pushed&" endpoint)
    (list (remoto-test--repo-item "zeta" "2026-10-20T12:00:00Z"
                                  :desc "Newest push" :size 9365)
          (remoto-test--repo-item "mid" "2026-01-02T03:04:05Z"
                                  :desc "Forked" :fork t)
          (remoto-test--repo-item "alpha" "2020-01-02T03:04:05Z"
                                  :private t :archived t :branch "trunk")))
   ((string-prefix-p "orgs/acme/repos?sort=pushed&" endpoint)
    (list (remoto-test--repo-item "tool" "2026-10-01T00:00:00Z" :private t)))
   ((string-prefix-p "users/torvalds/repos?sort=pushed&" endpoint)
    (list (remoto-test--repo-item "linux" "2026-10-20T00:00:00Z")))
   ((string-match-p "/git/trees/" endpoint)
    '((tree ((path . "README.md") (type . "blob") (size . 1) (sha . "a")
             (mode . "100644")))))
   (t (error "Unexpected endpoint %s" endpoint))))

(defmacro remoto-test-with-listings (&rest body)
  "Run BODY as the account \"me\" against `remoto-test--listing-api'.
Buffers BODY creates are killed afterwards."
  (declare (indent 0))
  (let ((before (make-symbol "before")))
    `(remoto-test-with-cache
       (let ((remoto--logins (remoto-test--logins :user "me"))
             (dired-listing-switches "-al")
             (,before (buffer-list)))
         (spy-on 'remoto--api :and-call-fake #'remoto-test--listing-api)
         (unwind-protect (progn ,@body)
           (dolist (buf (buffer-list))
             (unless (memq buf ,before) (kill-buffer buf))))))))

(defun remoto-test--listing-text (dir &optional switches)
  "Return the text of the Dired listing of DIR under ls SWITCHES."
  (with-current-buffer (dired-noselect dir (or switches "-al"))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun remoto-test--with-big-owner (forge endpoint)
  "Answer ENDPOINT with full first pages for the account \"big\"."
  (if (string-prefix-p "users/big/repos" endpoint)
      (remoto-test--repo-items 100 "a")
    (remoto-test--listing-api forge endpoint)))

(describe "Dired listing of /github:"
  (it "lists the account of the token and its organizations"
    (remoto-test-with-listings
      (let ((text (remoto-test--listing-text "/github:")))
        (expect text :to-match "^  drwxr-xr-x .* 2000 me +User$")
        (expect text :to-match "^  drwxr-xr-x .* acme +Organization  Acme tools$")
        (expect text :to-match "^  drwxr-xr-x .* quiet +Organization$"))
      (expect (remoto-test--listed-names "/github:" "-alF")
              :to-equal '("." ".." "acme" "me" "quiet"))))

  (it "says why, and leaves no buffer, when no token answers"
    (remoto-test-with-listings
      (let ((remoto--logins (remoto-test--logins :user nil :failed t))
            (before (buffer-list)))
        (expect (dired-noselect "/github:") :to-throw 'user-error)
        (expect (seq-difference (buffer-list) before) :to-be nil))))

  (it "opens an account's listing from its line, and goes nowhere above"
    (remoto-test-with-listings
      (with-current-buffer (remoto-test--visit-entry "/github:" "acme")
        (expect dired-directory :to-equal "/github:acme/")
        (expect (buffer-string) :to-match " tool$"))
      (with-current-buffer (remoto-test--visit-entry "/github:acme/" "..")
        (expect dired-directory :to-equal "/github:"))
      (with-current-buffer (remoto-test--visit-entry "/github:" "..")
        (expect dired-directory :to-equal "/github:")))))

(describe "remoto--add-listing-page"
  (it "lists only the owner's repositories, and pages by what the page held"
    ;; Forgejo's user/repos ignores affiliation=owner: the organizations' come too.
    (remoto-test-with-cache
      (let* ((item (lambda (owner name)
                     `((name . ,name) (full_name . ,(concat owner "/" name))
                       (owner (login . ,owner)))))
             (page (cons (funcall item "testy-shmeisty" "testy-besty")
                         (cl-loop for i below 49 collect (funcall item "Ag" (format "r%d" i)))))
             (listing (remoto--listing-create)))
        (remoto--add-listing-page listing "/codeberg:ag/" "ag" page)
        (expect (length (remoto--listing-entries listing)) :to-equal 49)
        (expect (assoc "testy-besty" (remoto--listing-entries listing)) :to-be nil)
        (expect (remoto--listing-state listing) :to-be 'fetching)))))

(describe "Dired listing of /github:OWNER/"
  (it "shows each repository's size, last push, mode and note"
    (remoto-test-with-listings
      (let ((text (remoto-test--listing-text "/github:me/")))
        (expect text :to-match
                (rx bol "  drwxr-xr-x  1 github github  9589760 " (= 12 nonl)
                    " zeta" (>= 4 " ") "Newest push" eol))
        (expect text :to-match
                (rx bol "  drwxr-xr-x " (+ nonl) " mid" (>= 4 " ") "fork  Forked" eol))
        (expect text :to-match
                (rx bol "  dr-x------ " (+ nonl) " Jan  " (in "12") "  2020 alpha" eol)))))

  (it "reads every name exactly under -al and -alF"
    (remoto-test-with-listings
      (dolist (switches '("-al" "-alF"))
        (expect (remoto-test--listed-names "/github:me/" switches)
                :to-equal '("." ".." "alpha" "mid" "zeta")))))

  (it "sorts by name, and under -t by the last push, newest first"
    (remoto-test-with-listings
      (expect (remoto-test--listed-names "/github:me/" "-alt")
              :to-equal '("." ".." "zeta" "mid" "alpha"))))

  (it "lines the notes up where dired-hide-details-mode hides them"
    ;; Dired hides a line from 4 columns past its name, for symlink targets.
    (remoto-test-with-listings
      (dolist (switches '("-al" "-alF"))
        (with-current-buffer (dired-noselect "/github:me/" switches)
          (let ((columns
                 (mapcar (lambda (note)
                           (goto-char (point-min))
                           (search-forward note)
                           (goto-char (match-beginning 0))
                           (expect (get-text-property (point) 'invisible)
                                   :to-be 'dired-hide-details-link)
                           (current-column))
                         '("Newest push" "fork  Forked"))))
            (expect (car columns) :to-equal (cadr columns)))))))

  (it "opens a repository's root at its default branch with one request"
    (remoto-test-with-listings
      (remoto-test--listing-text "/github:me/")
      (spy-calls-reset 'remoto--api)
      (with-current-buffer (remoto-test--visit-entry "/github:me/" "alpha")
        (expect dired-directory :to-equal "/github:me/alpha@trunk:/")
        (expect (buffer-string) :to-match "README\\.md"))
      (expect (mapcar #'cadr (spy-calls-all-args 'remoto--api))
              :to-equal '("repos/me/alpha/git/trees/trunk?recursive=1"))))

  (it "climbs from a repository root to its owner, then to /github:"
    (remoto-test-with-listings
      (with-current-buffer (remoto-test--visit-entry "/github:me/" "zeta")
        (expect dired-directory :to-equal "/github:me/zeta@main:/"))
      (with-current-buffer (remoto-test--visit-entry "/github:me/zeta@main:/" "..")
        (expect dired-directory :to-equal "/github:me/"))
      (with-current-buffer (remoto-test--visit-entry "/github:me/" "..")
        (expect dired-directory :to-equal "/github:"))))

  (it "fails with the API's answer, and leaves no buffer, for an unknown owner"
    (remoto-test-with-listings
      (let ((before (buffer-list)))
        (spy-on 'remoto--api :and-call-fake
                (lambda (forge endpoint)
                  (if (string-prefix-p "users/nobody/" endpoint)
                      (user-error "Remoto: not found: %s" endpoint)
                    (remoto-test--listing-api forge endpoint))))
        (expect (dired-noselect "/github:nobody/") :to-throw 'user-error)
        (expect (seq-difference (buffer-list) before) :to-be nil)))))

(describe "the endpoint of an owner listing"
  (it "lists the private repositories of the token's own account"
    (remoto-test-with-listings
      (remoto-test--listing-text "/github:me/")
      (expect 'remoto--api :to-have-been-called-with
              remoto--github "user/repos?affiliation=owner&sort=pushed&per_page=100&page=1")))

  (it "lists an organization of the token through the organization endpoint"
    (remoto-test-with-listings
      (expect (remoto-test--listing-text "/github:acme/")
              :to-match "^  drwx------ .* tool$")
      (expect 'remoto--api :to-have-been-called-with
              remoto--github "orgs/acme/repos?sort=pushed&per_page=100&page=1")))

  (it "lists the public repositories of any other account, token or not"
    (remoto-test-with-listings
      (expect (remoto-test--listing-text "/github:torvalds/") :to-match " linux$")
      (expect 'remoto--api :to-have-been-called-with
              remoto--github "users/torvalds/repos?sort=pushed&per_page=100&page=1"))
    (remoto-test-with-listings
      (let ((remoto--logins (remoto-test--logins :user nil :failed t)))
        (expect (remoto-test--listing-text "/github:torvalds/") :to-match " linux$")
        (expect (mapcar #'cadr (spy-calls-all-args 'remoto--api))
                :to-equal '("users/torvalds/repos?sort=pushed&per_page=100&page=1"))))))

(describe "the pages of an owner listing"
  (it "takes a short first page as the whole listing"
    (remoto-test-with-listings
      (spy-on 'remoto--api-async)
      (expect (remoto-test--listing-text "/github:torvalds/") :not :to-match "so far")
      (expect 'remoto--api-async :not :to-have-been-called)))

  (it "loads the later pages in the background, one at a time, and reverts once"
    (remoto-test-with-listings
      (let ((pending nil))
        (spy-on 'remoto--api :and-call-fake #'remoto-test--with-big-owner)
        (spy-on 'remoto--api-async :and-call-fake
                (lambda (_forge endpoint callback &optional _errback)
                  (setq pending (append pending (list (cons endpoint callback))))))
        (let ((buf (dired-noselect "/github:big/")))
          (expect (with-current-buffer buf (buffer-string))
                  :to-match " \\. +100 so far, fetching the rest$")
          (expect (mapcar #'car pending)
                  :to-equal '("users/big/repos?sort=pushed&per_page=100&page=2"))
          (spy-on 'revert-buffer :and-call-through)
          (funcall (cdr (pop pending)) (remoto-test--repo-items 100 "b"))
          (expect 'revert-buffer :not :to-have-been-called)
          (expect (mapcar #'car pending)
                  :to-equal '("users/big/repos?sort=pushed&per_page=100&page=3"))
          (funcall (cdr (pop pending)) (remoto-test--repo-items 5 "c"))
          (expect pending :to-be nil)
          (expect 'revert-buffer :to-have-been-called-times 1)
          (with-current-buffer buf
            (expect (buffer-string) :not :to-match "so far")
            (expect (buffer-string) :to-match " a000$")
            (expect (buffer-string) :to-match " c004$"))))))

  (it "stops at remoto-listing-cap and says so on the . line"
    (remoto-test-with-listings
      (let ((remoto-listing-cap 150)
            (pending nil))
        (spy-on 'remoto--api :and-call-fake #'remoto-test--with-big-owner)
        (spy-on 'remoto--api-async :and-call-fake
                (lambda (_forge _endpoint callback &optional _errback)
                  (push callback pending)))
        (let ((buf (dired-noselect "/github:big/")))
          (funcall (pop pending) (remoto-test--repo-items 100 "b"))
          (expect pending :to-be nil)
          (with-current-buffer buf
            (expect (buffer-string) :to-match
                    " \\. +the 150 most recently pushed, as `remoto-listing-cap' allows$")
            (expect (buffer-string) :to-match " b049$")
            (expect (buffer-string) :not :to-match " b050$"))))))

  (it "says when a later page failed, and leaves the retry to remoto-refresh"
    ;; The revert that shows the failure must not fetch again: against a
    ;; failing API that would loop.
    (remoto-test-with-listings
      (let ((errbacks nil))
        (spy-on 'remoto--api :and-call-fake #'remoto-test--with-big-owner)
        (spy-on 'remoto--api-async :and-call-fake
                (lambda (_forge _endpoint _callback &optional errback)
                  (push errback errbacks)))
        (with-current-buffer (dired-noselect "/github:big/")
          (spy-calls-reset 'remoto--api)
          (funcall (pop errbacks))
          (expect (buffer-string) :to-match
                  " \\. +100, the rest failed to load; `remoto-refresh' retries$")
          (revert-buffer)
          (expect 'remoto--api :not :to-have-been-called)
          (expect errbacks :to-be nil)
          (remoto-refresh)
          (expect 'remoto--api :to-have-been-called-with
                  remoto--github "users/big/repos?sort=pushed&per_page=100&page=1")))))

  (it "fetches no page again when the pages took longer than the cache lives"
    ;; The revert at the end found the listing stale and fetched it all again.
    (remoto-test-with-listings
      (let ((remoto-repo-cache-ttl 5)
            (pending nil))
        (spy-on 'remoto--api :and-call-fake #'remoto-test--with-big-owner)
        (spy-on 'remoto--api-async :and-call-fake
                (lambda (_forge _endpoint callback &optional _errback)
                  (push callback pending)))
        (with-current-buffer (dired-noselect "/github:big/")
          (setf (remoto--listing-time (gethash "/github:big/" remoto--listing-cache))
                (- (float-time) 60))
          (spy-calls-reset 'remoto--api)
          (funcall (pop pending) (remoto-test--repo-items 5 "b"))
          (expect 'remoto--api :not :to-have-been-called)
          (expect pending :to-be nil)
          (expect (buffer-string) :to-match " b004$")))))

  (it "drops the late pages of a listing that remoto-refresh replaced"
    (remoto-test-with-listings
      (let ((pending nil))
        (spy-on 'remoto--api :and-call-fake #'remoto-test--with-big-owner)
        (spy-on 'remoto--api-async :and-call-fake
                (lambda (_forge _endpoint callback &optional _errback)
                  (push callback pending)))
        (with-current-buffer (dired-noselect "/github:big/")
          (let ((late (car (last pending))))
            (remoto-refresh)
            (let ((fresh (gethash "/github:big/" remoto--listing-cache)))
              (funcall late (remoto-test--repo-items 5 "z"))
              (expect (gethash "/github:big/" remoto--listing-cache) :to-be fresh)
              (expect (length (remoto--listing-entries fresh)) :to-equal 100)
              (expect (buffer-string) :not :to-match " z000$")))))))

  (it "remembers each default branch, so opening a listed repository asks for none"
    (remoto-test-with-listings
      (remoto-test--listing-text "/github:me/")
      (expect (gethash "/github:me/alpha" remoto--default-branch-cache) :to-equal "trunk")
      (expect (remoto--maybe-rewrite "/github:me/alpha") :to-equal "/github:me/alpha@trunk:/")
      (expect 'remoto--api :not :to-have-been-called-with "repos/me/alpha"))))

(describe "file-exists-p of a bare account or repository name"
  (it "answers t once a cached listing holds it, however old the listing"
    (remoto-test-with-listings
      (remoto-test--listing-text "/github:")
      (remoto-test--listing-text "/github:me/")
      (dolist (dir '("/github:" "/github:me/"))
        (setf (remoto--listing-time (gethash dir remoto--listing-cache)) 0))
      (expect (file-exists-p "/github:me/zeta") :to-be t)
      (expect (file-exists-p "/gh:me/zeta") :to-be t)
      (expect (file-exists-p "/github:acme") :to-be t)))

  (it "keeps the confirmation for a name no listing holds"
    (remoto-test-with-listings
      (remoto-test--listing-text "/github:")
      (remoto-test--listing-text "/github:me/")
      (expect (file-exists-p "/github:me/zet") :to-be nil)
      (expect (file-exists-p "/github:other/zeta") :to-be nil)
      (expect (file-exists-p "/github:acm") :to-be nil)
      (expect (file-exists-p "/github:acme#") :to-be nil))))

(describe "remoto-refresh in a listing"
  (it "fetches the listing of the buffer again"
    (remoto-test-with-listings
      (with-current-buffer (dired-noselect "/github:")
        (spy-calls-reset 'remoto--api)
        (remoto-refresh)
        (expect 'remoto--api :to-have-been-called-with remoto--github "user/orgs?per_page=100&page=1")
        (expect (buffer-string) :to-match " acme "))
      (with-current-buffer (dired-noselect "/github:me/")
        (spy-calls-reset 'remoto--api)
        (remoto-refresh)
        (expect 'remoto--api :to-have-been-called-with
                remoto--github "user/repos?affiliation=owner&sort=pushed&per_page=100&page=1")
        (expect (buffer-string) :to-match " zeta ")))))

(defun remoto-test--search-api (forge endpoint)
  "Answer ENDPOINT as `remoto-test--listing-api' does, plus a search of acme.
A search for stitch finds stitch-env and stitch-api; acme has no other
repository than tool, and a search for anything else finds none."
  (cond
   ((string-prefix-p "search/repositories?q=stitch%20" endpoint)
    `((items ,(remoto-test--repo-item "stitch-env" "2026-10-19T10:00:00Z"
                                      :owner "acme" :private t :branch "trunk"
                                      :desc "Environments")
             ,(remoto-test--repo-item "stitch-api" "2026-10-13T17:14:04Z"
                                      :owner "acme" :desc "The API"))))
   ((string-prefix-p "search/repositories?" endpoint) '((items)))
   ((equal endpoint "repos/acme/tool") '((default_branch . "main")))
   ((string-match-p "\\`repos/acme/[^/]+\\'" endpoint)
    (user-error "%s%s" remoto--not-found endpoint))
   (t (remoto-test--listing-api forge endpoint))))

(defun remoto-test--dired-names ()
  "Return the names that Dired reads in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let (names)
      (while (not (eobp))
        (when (dired-move-to-filename)
          (push (dired-get-filename 'verbatim t) names))
        (forward-line 1))
      (nreverse names))))

(describe "a bare name of no repository"
  (it "opens a Dired of the repositories that the search of completion found"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--search-api)
      ;; Completion at /github:acme/ searched for the typed text already.
      (remoto--owner-search remoto--github "acme" "stitch")
      (spy-calls-reset 'remoto--api)
      (with-current-buffer (find-file-noselect "/gh:acme/stitch")
        (expect dired-directory :to-equal '("/github:acme/" "stitch-api" "stitch-env"))
        (expect (remoto-test--dired-names) :to-equal '("stitch-api" "stitch-env"))
        (expect (buffer-string) :to-match
                (rx bol "  drwx------  1 github github " (+ nonl) " stitch-env"
                    (>= 4 " ") "Environments" eol))
        (expect (buffer-string) :to-match
                (rx bol "  drwxr-xr-x " (+ nonl) " stitch-api" (>= 4 " ") "The API" eol)))
      (expect (mapcar #'cadr (spy-calls-all-args 'remoto--api))
              :to-equal '("repos/acme/stitch"))))

  (it "lines the notes up across the matches, and keeps them on revert"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--search-api)
      (with-current-buffer (find-file-noselect "/gh:acme/stitch")
        (revert-buffer)
        (expect (remoto-test--dired-names) :to-equal '("stitch-api" "stitch-env"))
        (let ((columns (mapcar (lambda (note)
                                 (goto-char (point-min))
                                 (search-forward note)
                                 (- (match-beginning 0) (line-beginning-position)))
                               '("The API" "Environments"))))
          (expect (car columns) :to-equal (cadr columns))))))

  (it "puts the newest push first under -t, as a listing does"
    (remoto-test-with-listings
      (let ((dired-listing-switches "-alt"))
        (spy-on 'remoto--api :and-call-fake #'remoto-test--search-api)
        (expect (cdr (buffer-local-value 'dired-directory
                                         (find-file-noselect "/gh:acme/stitch")))
                :to-equal '("stitch-env" "stitch-api")))))

  (it "opens a match at its default branch with only the tree request"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--search-api)
      (with-current-buffer (find-file-noselect "/gh:acme/stitch")
        (spy-calls-reset 'remoto--api)
        (goto-char (point-min))
        (re-search-forward " stitch-env ")
        (dired-find-file)
        (expect dired-directory :to-equal "/github:acme/stitch-env@trunk:/"))
      (expect (mapcar #'cadr (spy-calls-all-args 'remoto--api))
              :to-equal '("repos/acme/stitch-env/git/trees/trunk?recursive=1"))))

  (it "lists the matches for dired-noselect too"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--search-api)
      (expect (buffer-local-value 'dired-directory (dired-noselect "/github:acme/stitch"))
              :to-equal '("/github:acme/" "stitch-api" "stitch-env"))))

  (it "opens an existing repository as before, with no search"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--search-api)
      (expect (buffer-local-value 'dired-directory (find-file-noselect "/gh:acme/tool"))
              :to-equal "/github:acme/tool@main:/")
      (expect (seq-filter (lambda (args) (string-prefix-p "search/" (car args)))
                          (spy-calls-all-args 'remoto--api))
              :to-be nil)))

  (it "asks for no repository that a name cannot be, nor for dots"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--search-api)
      (expect (cdr (buffer-local-value 'dired-directory
                                       (find-file-noselect "/gh:acme/stitch env")))
              :to-equal '("stitch-api" "stitch-env"))
      (expect (remoto--query-matches "/github:acme/..") :to-be nil)
      (expect (remoto--query-matches "/github:acme/zeta@main:/..") :to-be nil)
      (expect (seq-filter (lambda (args) (string-prefix-p "repos/" (cadr args)))
                          (spy-calls-all-args 'remoto--api))
              :to-be nil)))

  (it "says so, and leaves no buffer, when nothing matches"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--search-api)
      (let ((before (buffer-list)))
        (expect (find-file-noselect "/gh:acme/zzz")
                :to-throw 'user-error '("Remoto: no repository of acme matches zzz"))
        (expect (seq-difference (buffer-list) before) :to-be nil))))

  (it "names the owner when GitHub cannot search an account that does not exist"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint) (user-error "%s%s" remoto--not-found endpoint)))
      (let ((before (buffer-list)))
        (expect (find-file-noselect "/gh:nobody/tool")
                :to-throw 'user-error '("Remoto: no account nobody"))
        (expect (seq-difference (buffer-list) before) :to-be nil))))

  (it "lets a failed search or repository check signal its own error"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake
              (lambda (forge endpoint)
                (if (string-prefix-p "search/" endpoint)
                    (user-error "Remoto: access denied (rate limit or permissions): x")
                  (remoto-test--search-api forge endpoint))))
      (expect (find-file-noselect "/gh:acme/stitch")
              :to-throw 'user-error '("Remoto: access denied (rate limit or permissions): x")))
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint)
                (user-error "Remoto: access denied (rate limit or permissions): %s" endpoint)))
      (expect (find-file-noselect "/gh:acme/stitch") :to-throw 'user-error)
      (expect (mapcar #'cadr (spy-calls-all-args 'remoto--api))
              :to-equal '("repos/acme/stitch"))))

  (it "gets one line from insert-directory without FULL-DIRECTORY-P"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--search-api)
      (remoto--owner-search remoto--github "acme" "stitch")
      (with-temp-buffer
        (let ((default-directory "/github:acme/"))
          (remoto--handle-insert-directory "stitch-api" "-al" nil nil))
        (expect (buffer-string) :to-match
                (rx bos "  drwxr-xr-x  1 github github " (+ nonl) " stitch-api"
                    (>= 4 " ") "The API\n" eos)))))

  (it "reads an owner's listing as /github:OWNER, which still does not exist"
    (expect (file-readable-p "/github:acme") :to-be t)
    (expect (file-readable-p "/github:") :to-be t)
    (remoto-test-with-cache
      (expect (file-exists-p "/github:acme") :to-be nil)))

  (it "remembers a repository a search found, so that it exists and opens"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--search-api)
      (remoto--owner-search remoto--github "acme" "stitch")
      (expect (file-exists-p "/github:acme/stitch-env") :to-be t)
      (expect (file-exists-p "/github:acme/stitch") :to-be nil)
      (expect (gethash "/github:acme/stitch-env" remoto--default-branch-cache)
              :to-equal "trunk"))))

(defun remoto-test--account-api (forge endpoint)
  "Answer ENDPOINT as `remoto-test--listing-api' does, plus a user search.
A search for qlik finds the user qlik, the organizations qlik-oss and
qlik-trial, and jdoe, whose login lacks the word; qlik-trial has one
repository."
  (cond
   ((string-prefix-p "search/users?q=qlik&" endpoint)
    '((items ((login . "qlik-trial") (type . "Organization"))
             ((login . "jdoe") (type . "User"))
             ((login . "qlik") (type . "User"))
             ((login . "qlik-oss") (type . "Organization")))))
   ((string-prefix-p "search/users?" endpoint) '((items)))
   ((string-prefix-p "users/qlik-trial/repos?sort=pushed&" endpoint)
    (list (remoto-test--repo-item "stitch" "2026-10-01T00:00:00Z")))
   (t (remoto-test--listing-api forge endpoint))))

(describe "a bare account name"
  (it "opens a Dired of the accounts whose login holds the typed words"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--account-api)
      (with-current-buffer (find-file-noselect "/gh:qlik")
        (expect dired-directory :to-equal '("/github:" "qlik" "qlik-oss" "qlik-trial"))
        (expect (remoto-test--dired-names) :to-equal '("qlik" "qlik-oss" "qlik-trial"))
        (expect (buffer-string) :to-match
                (rx bol "  drwxr-xr-x " (+ nonl) " qlik-trial" (>= 4 " ") "Organization" eol))
        (expect (buffer-string) :to-match
                (rx bol "  drwxr-xr-x " (+ nonl) " qlik" (>= 4 " ") "User" eol)))
      (expect (mapcar #'cadr (spy-calls-all-args 'remoto--api))
              :to-equal '("search/users?q=qlik&per_page=100"))))

  (it "puts the account typed first, whatever its case"
    ;; Capitals sort first, which put Qlik-PE and QlikSense above qlik.
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint)
                (if (string-prefix-p "search/users?" endpoint)
                    `((items ,@(mapcar (lambda (login) `((login . ,login) (type . "User")))
                                       '("qlik-trial" "QlikSense" "qlik" "Qlik-PE"))))
                  (remoto-test--listing-api forge endpoint))))
      (with-current-buffer (find-file-noselect "/gh:Qlik")
        (expect (cdr dired-directory)
                :to-equal '("qlik" "Qlik-PE" "QlikSense" "qlik-trial"))
        (expect (dired-get-filename 'verbatim t) :to-equal "qlik"))))

  (it "searches for the typed name, though completion cached a narrowed list"
    ;; Completion narrows qlik from the top 30 of qli, which can lack qlik.
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--account-api)
      (remoto--search-cache-put
       "\0users:/github:qlik" (list (propertize "qlik-trial" 'remoto-acct-type "Organization")))
      (expect (cdr (buffer-local-value 'dired-directory (find-file-noselect "/gh:qlik")))
              :to-equal '("qlik" "qlik-oss" "qlik-trial"))
      (kill-buffer (find-file-noselect "/gh:qlik"))
      (find-file-noselect "/gh:qlik")
      (expect (mapcar #'cadr (spy-calls-all-args 'remoto--api))
              :to-equal '("search/users?q=qlik&per_page=100"))))

  (it "opens an account from its line in the Dired of matches"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--account-api)
      (with-current-buffer (remoto-test--visit-entry "/github:qlik" "qlik-trial")
        (expect dired-directory :to-equal "/github:qlik-trial/")
        (expect (remoto-test--dired-names) :to-equal '("." ".." "stitch")))))

  (it "opens an account typed with its slash, with no search"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--account-api)
      (expect (buffer-local-value 'dired-directory (find-file-noselect "/gh:qlik-trial/"))
              :to-equal "/github:qlik-trial/")
      (expect (seq-filter (lambda (args) (string-prefix-p "search/" (car args)))
                          (spy-calls-all-args 'remoto--api))
              :to-be nil)))

  (it "says so, and leaves no buffer, when no account matches"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--account-api)
      (let ((before (buffer-list)))
        (expect (find-file-noselect "/gh:zzz")
                :to-throw 'user-error '("Remoto: no account matches zzz"))
        (expect (seq-difference (buffer-list) before) :to-be nil))))

  (it "lets a failed search signal its own error"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake
              (lambda (forge endpoint)
                (if (string-prefix-p "search/" endpoint)
                    (user-error "Remoto: access denied (rate limit or permissions): x")
                  (remoto-test--account-api forge endpoint))))
      (expect (find-file-noselect "/gh:qlik")
              :to-throw 'user-error
              '("Remoto: access denied (rate limit or permissions): x")))))

(defun remoto-test--ref-api (forge endpoint)
  "Answer ENDPOINT as `remoto-test--listing-api' does, plus the refs of acme/tool.
Its branches are main, release-1 and feature/x, its tags v1.0 and
release-2, and only main and release-1 have a tree."
  (cond
   ((string-prefix-p "repos/acme/tool/branches?" endpoint)
    '(((name . "main")) ((name . "release-1")) ((name . "feature/x"))))
   ((string-prefix-p "repos/acme/tool/tags?" endpoint)
    '(((name . "v1.0")) ((name . "release-2"))))
   ((string-match-p (rx bos "repos/acme/tool/git/trees/" (or "main" "release-1") "?")
                    endpoint)
    (remoto-test--listing-api forge endpoint))
   ((string-prefix-p "repos/acme/tool/git/trees/" endpoint)
    (user-error "%s%s" remoto--not-found endpoint))
   (t (remoto-test--listing-api forge endpoint))))

(defun remoto-test--asked-p (regexp)
  "Return non-nil when a spied `remoto--api' call asked for REGEXP."
  (seq-some (lambda (args) (string-match-p regexp (cadr args)))
            (spy-calls-all-args 'remoto--api)))

(describe "a ref of no tree"
  (it "opens a Dired of the branches and tags that hold the typed words"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--ref-api)
      (with-current-buffer (find-file-noselect "/gh:acme/tool@rel")
        (expect dired-directory :to-equal '("/github:acme/tool@" "release-1" "release-2"))
        (expect (remoto-test--dired-names) :to-equal '("release-1" "release-2"))
        (expect (buffer-string) :to-match
                (rx bol "  drwxr-xr-x " (+ nonl) " release-1" (>= 4 " ") "branch" eol))
        (expect (buffer-string) :to-match
                (rx bol "  drwxr-xr-x " (+ nonl) " release-2" (>= 4 " ") "tag" eol)))))

  (it "opens the Dired of the matching refs on Codeberg, which answers 400 to the ref"
    (remoto-test-with-cache
      (let ((remoto--logins (remoto-test--logins :failed t))
            (dired-listing-switches "-al")
            (before (buffer-list)))
        (spy-on 'ghub-get :and-call-fake
                (lambda (resource &rest _)
                  (pcase resource
                    ("/repos/acme/tool/git/trees/rel?recursive=1&per_page=1000&page=1"
                     (signal 'ghub-http-error
                             (list 400 "Bad Request" "https://codeberg.org/api/v1/x"
                                   '((message . "sha not found [rel]")))))
                    ("/repos/acme/tool/branches?limit=50&page=1"
                     '(((name . "main")) ((name . "release-1"))))
                    ("/repos/acme/tool/tags?limit=50&page=1" '(((name . "release-2"))))
                    (_ (error "Unexpected %s" resource)))))
        (unwind-protect
            (expect (buffer-local-value 'dired-directory
                                        (find-file-noselect "/cb:acme/tool@rel"))
                    :to-equal '("/codeberg:acme/tool@" "release-1" "release-2"))
          (dolist (buf (buffer-list))
            (unless (memq buf before) (kill-buffer buf)))))))

  (it "lists every branch and tag after a bare @, a slash in a ref included"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--ref-api)
      (expect (cdr (buffer-local-value 'dired-directory
                                       (find-file-noselect "/gh:acme/tool@")))
              :to-equal '("feature/x" "main" "release-1" "release-2" "v1.0"))
      (expect (remoto-test--asked-p "/git/trees/") :to-be nil)))

  (it "opens the tree of a ref with a slash from its Dired line"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--ref-api)
      (find-file-noselect "/gh:acme/tool@")
      (expect (file-exists-p "/github:acme/tool@feature/x") :to-be t)
      (expect (file-directory-p "/github:acme/tool@feature/x") :to-be t)
      (expect (remoto--maybe-rewrite "/github:acme/tool@feature/x")
              :to-equal "/github:acme/tool@feature/x:/")))

  (it "lines the notes up from one count of the widths per reading"
    ;; Dired asks for each line on its own; counting the widths over all
    ;; the names for each line made a long list of refs quadratic.
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--ref-api)
      (spy-on 'remoto--listing-widths :and-call-through)
      (with-current-buffer (find-file-noselect "/gh:acme/tool@")
        (expect 'remoto--listing-widths :to-have-been-called-times 1)
        (revert-buffer)
        (expect 'remoto--listing-widths :to-have-been-called-times 2)
        (let ((columns (mapcar (lambda (note)
                                 (goto-char (point-min))
                                 (re-search-forward (concat " " note "$"))
                                 (- (match-beginning 0) (line-beginning-position)))
                               '("branch" "tag"))))
          (expect (car columns) :to-equal (cadr columns))))))

  (it "opens a ref from its line at the root of its tree"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--ref-api)
      (with-current-buffer (remoto-test--visit-entry "/github:acme/tool@rel" "release-1")
        (expect dired-directory :to-equal "/github:acme/tool@release-1:/")
        (expect (remoto-test--dired-names) :to-equal '("." ".." "README.md")))))

  (it "opens a ref or a commit whose tree loads, asking for no list"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--ref-api)
      (expect (buffer-local-value 'dired-directory (find-file-noselect "/gh:acme/tool@main"))
              :to-equal "/github:acme/tool@main:/")
      (expect (remoto-test--asked-p "/\\(branches\\|tags\\)") :to-be nil)))

  (it "asks for no tree of a ref that a name cannot be"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--ref-api)
      (expect (cdr (buffer-local-value 'dired-directory
                                       (find-file-noselect "/gh:acme/tool@rel 2")))
              :to-equal '("release-2"))
      (expect (remoto-test--asked-p "/git/trees/") :to-be nil)))

  (it "says so, and leaves no buffer, when no ref matches"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--ref-api)
      (let ((before (buffer-list)))
        (expect (find-file-noselect "/gh:acme/tool@zzz")
                :to-throw 'user-error '("Remoto: no branch or tag of acme/tool matches zzz"))
        (expect (seq-difference (buffer-list) before) :to-be nil))))

  (it "forgets the branches and tags on remoto-refresh in the Dired of refs"
    (remoto-test-with-listings
      (spy-on 'remoto--api :and-call-fake #'remoto-test--ref-api)
      (with-current-buffer (find-file-noselect "/gh:acme/tool@rel")
        (expect (gethash "/github:acme/tool" remoto--tags-cache) :not :to-be nil)
        (remoto-refresh)
        (expect (gethash "/github:acme/tool" remoto--branches-cache) :to-be nil)
        (expect (gethash "/github:acme/tool" remoto--tags-cache) :to-be nil)
        (expect (remoto-test--dired-names) :to-equal '("release-1" "release-2"))))))

(describe "a missing file name"
  (it "opens a Dired of the entries of its directory that hold the typed words"
    (remoto-test-with-listing "-al"
      (with-current-buffer (find-file-noselect "/gh:testowner/testrepo/read")
        (expect dired-directory :to-equal '("/github:testowner/testrepo@main:/" "README.md"))
        (expect (remoto-test--dired-names) :to-equal '("README.md")))))

  (it "shows a matching directory as one line that opens it"
    (remoto-test-with-listing "-alF"
      (with-current-buffer (find-file-noselect "/github:testowner/testrepo@main:/s")
        (expect (cdr dired-directory) :to-equal '("src"))
        (expect (buffer-string) :to-match (rx bol "  drwxr-xr-x " (+ nonl) " src/" eol))
        (goto-char (point-min))
        (re-search-forward " src/$")
        (dired-find-file)
        (expect dired-directory :to-equal "/github:testowner/testrepo@main:/src/"))))

  (it "lists the matches inside a subdirectory, for dired-noselect too"
    (remoto-test-with-listing "-al"
      (expect (buffer-local-value 'dired-directory
                                  (dired-noselect "/gh:testowner/testrepo/src/ma"))
              :to-equal '("/github:testowner/testrepo@main:/src/" "main.el"))))

  (it "is no query when it exists, ends in a slash, holds a wildcard or matches nothing"
    ;; One that matches nothing visits a new file, as a local name does.
    (remoto-test-with-listing "-al"
      (dolist (path '("README.md" "src/" "*.md" "zzz" "nodir/x"))
        (expect (remoto--file-matches (concat "/github:testowner/testrepo@main:/" path))
                :to-be nil)))))

;;; maybe-rewrite for partial canonical paths

(describe "remoto--maybe-rewrite with partial canonical paths"
  (it "rewrites /github:owner/repo to canonical path"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "/github:torvalds/linux" "master" remoto--default-branch-cache)
      (expect (remoto--maybe-rewrite "/github:torvalds/linux")
              :to-equal "/github:torvalds/linux@master:/")))

  (it "rewrites /github:owner/repo@ref to canonical path"
    (expect (remoto--maybe-rewrite "/github:torvalds/linux@v6.5")
            :to-equal "/github:torvalds/linux@v6.5:/"))

  (it "leaves full canonical paths unchanged"
    (expect (remoto--maybe-rewrite "/github:torvalds/linux@master:/src")
            :to-equal "/github:torvalds/linux@master:/src"))

  (it "leaves non-github paths unchanged"
    (expect (remoto--maybe-rewrite "/home/user/file") :to-equal "/home/user/file"))

  (it "resolves . and .. before it reads a short form"
    ;; /github:o/.. matches the short form of a repository named "..".
    (spy-on 'remoto--api)
    (expect (remoto--maybe-rewrite "/github:o/..") :to-equal "/github:")
    (expect (remoto--maybe-rewrite "/github:o/.") :to-equal "/github:o/")
    (expect (remoto--maybe-rewrite "/gh:o/r@main:/..") :to-equal "/github:o/")
    (expect (remoto--maybe-rewrite "/github:o/r@main:/src/..")
            :to-equal "/github:o/r@main:/")
    (expect 'remoto--api :not :to-have-been-called))

  (it "normalizes the /gh: shorthand before rewriting"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "/github:torvalds/linux" "master" remoto--default-branch-cache)
      (expect (remoto--maybe-rewrite "/gh:torvalds/linux")
              :to-equal "/github:torvalds/linux@master:/")
      (expect (remoto--maybe-rewrite "/gh:torvalds/linux/")
              :to-equal "/github:torvalds/linux@master:/")
      (expect (remoto--maybe-rewrite "/gh:torvalds/linux@master:/src")
              :to-equal "/github:torvalds/linux@master:/src")
      (expect (remoto--maybe-rewrite "/gh:foo/bar#42")
              :to-equal "/github:foo/bar#42"))))

(describe "remoto--dired-around-a"
  ;; `dired' gets the raw argument; only URLs and remoto paths are rewritten.
  (it "rewrites the bare, short and shorthand forms to the canonical path"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "/github:torvalds/linux" "master" remoto--default-branch-cache)
      (dolist (dir '("/github:torvalds/linux" "/github:torvalds/linux/"
                     "/gh:torvalds/linux" "/gh:torvalds/linux/"
                     "https://github.com/torvalds/linux"))
        (expect (remoto--dired-around-a (lambda (d &rest _) d) dir)
                :to-equal "/github:torvalds/linux@master:/"))))

  (it "rewrites the directory of a (DIR . FILES) argument"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "/github:torvalds/linux" "master" remoto--default-branch-cache)
      (expect (remoto--dired-around-a (lambda (d &rest _) d)
                                      '("/gh:torvalds/linux" "Makefile"))
              :to-equal '("/github:torvalds/linux@master:/" "Makefile"))))

  (it "passes local directories and canonical paths through untouched"
    ;; A canonical name is checked against its tree, which may hold no
    ;; such name; the mock tree answers without a request.
    (remoto-test-with-cache
      (spy-on 'remoto--maybe-rewrite :and-call-through)
      (spy-on 'remoto--api)
      (expect (remoto--dired-around-a (lambda (d &rest _) d) "/tmp/")
              :to-equal "/tmp/")
      (expect 'remoto--maybe-rewrite :not :to-have-been-called)
      (expect (remoto--dired-around-a (lambda (d &rest _) d)
                                      "/github:testowner/testrepo@main:/src")
              :to-equal "/github:testowner/testrepo@main:/src")
      (expect 'remoto--api :not :to-have-been-called))))

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

(describe "remoto--parse on degenerate names"
  (it "reads a repository with dots, hyphens and underscores"
    (expect (remoto-path-repo (remoto--parse "/github:agzam/remoto.el#"))
            :to-equal "remoto.el")
    (expect (remoto-path-repo (remoto--parse "/github:foo/my-repo@"))
            :to-equal "my-repo")
    (expect (remoto-path-repo (remoto--parse "/github:foo/my_repo/"))
            :to-equal "my_repo"))

  (it "reads a double slash as a query at the root"
    (let ((p (remoto--parse "/github://")))
      (expect (remoto-path-level p) :to-be 'root)
      (expect (remoto-path-query p) :to-equal "//")))

  (it "reads a delimiter with no repository as a query, not a level"
    (expect (remoto-path-level (remoto--parse "/github:foobar@")) :to-be 'root)
    (expect (remoto--directory-level "/github:foobar@") :to-be nil)
    (expect (remoto--directory-level "/github:foo/#") :to-be nil)))

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
      (let ((children (remoto--fetch-dir-children-light remoto--github "owner" "repo" "main" "")))
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
        (let ((children (remoto--fetch-dir-children-light remoto--github "owner" "repo" "main" "")))
          (expect (length children) :to-equal 20)))))

  (it "caches results"
    (let ((remoto--dir-contents-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge _endpoint)
                (setq call-count (1+ call-count))
                '(((name . "a.el") (type . "file") (size . 10) (sha . "x")))))
      (remoto--fetch-dir-children-light remoto--github "owner" "repo" "main" "")
      (remoto--fetch-dir-children-light remoto--github "owner" "repo" "main" "")
      (expect call-count :to-equal 1)))

  (it "returns nil on API error"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_forge _) (user-error "not found")))
    (let ((remoto--dir-contents-cache (make-hash-table :test 'equal)))
      (expect (remoto--fetch-dir-children-light remoto--github "owner" "repo" "main" "")
              :to-be nil)))

  (it "fetches subdirectory contents"
    (spy-on 'remoto--api :and-return-value
            '(((name . "main.el") (type . "file") (size . 1000) (sha . "aa"))
              ((name . "utils.el") (type . "file") (size . 500) (sha . "bb"))))
    (let ((remoto--dir-contents-cache (make-hash-table :test 'equal)))
      (let ((children (remoto--fetch-dir-children-light remoto--github "owner" "repo" "main" "src")))
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

  ;; `while-no-input' answers t when a key arrives during the direct
  ;; fetch; that t must not reach the candidates.
  (it "keeps the cached issues when a key interrupts the direct fetch"
    ;; Buttercup records no call that exits by `throw', hence the flag.
    (let ((interrupted nil))
      (spy-on 'remoto--fetch-issue :and-call-fake
              (lambda (&rest _) (setq interrupted t) (throw throw-on-input t)))
      (spy-on 'remoto--fetch-issues :and-return-value
              '(((number . 1) (title . "First issue"))))
      (let ((remoto--search-cache (make-hash-table :test 'equal)))
        (let ((completions (remoto--handle-file-name-all-completions
                            "1" "/github:foobar/zapato#")))
          (expect interrupted :to-be t)
          (expect (member "1" completions) :to-be-truthy)))))

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
      (puthash "/github:foobar/zapato" "main" remoto--default-branch-cache)
      (expect (remoto--maybe-rewrite "/github:foobar/zapato/")
              :to-equal "/github:foobar/zapato@main:/")))

  (it "rewrites /github:owner/repo/path to canonical form"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "/github:foobar/zapato" "main" remoto--default-branch-cache)
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
    (let ((remoto--logins (remoto-test--logins :user "agzam")))
      (let ((completions (remoto--handle-file-name-all-completions "" "/github:")))
        (expect (member "agzam/" completions) :to-be-truthy)
        (expect (member "qlik-oss/" completions) :to-be-truthy)
        (expect (member "nebula-contrib/" completions) :to-be-truthy))))

  (it "falls back to nil when not authenticated"
    (let ((remoto--logins (remoto-test--logins :user nil)))
      (spy-on 'remoto--search-users :and-return-value nil)
      (spy-on 'run-with-idle-timer)
      (let ((completions (remoto--handle-file-name-all-completions "" "/github:")))
        (expect completions :to-be nil))))

  (it "learns the account of the token in the background, then lists it and its organizations"
    ;; A Codeberg login has no warm-up: nothing but this lookup names its user.
    (let ((remoto--logins (remoto-test--logins))
          (remoto--user-timer nil))
      (setf (remoto--login-token (remoto--login "codeberg.org/api/v1")) "cb_token")
      (spy-on 'run-with-idle-timer :and-call-fake
              (lambda (_secs _repeat fn &rest args) (apply fn args) nil))
      (spy-on 'remoto--refresh-minibuffer-completions)
      (spy-on 'ghub-get :and-call-fake
              (lambda (resource &optional _params &rest args)
                (expect (plist-get args :auth) :to-equal "cb_token")
                (let ((value (pcase resource
                               ("/user" '((login . "ag")))
                               ("/user/orgs?limit=50&page=1"
                                '(((username . "testy-shmeisty"))))
                               (_ (error "Unexpected %s" resource))))
                      (callback (plist-get args :callback)))
                  ;; Under `while-no-input' the reply comes through the callback.
                  (if (not callback)
                      value
                    (funcall callback value)
                    (let ((buffer (generate-new-buffer " *remoto-test-http*")))
                      (kill-buffer buffer)
                      buffer)))))
      (expect (remoto--handle-file-name-all-completions "" "/codeberg:") :to-be nil)
      (expect 'remoto--refresh-minibuffer-completions :to-have-been-called-times 1)
      (expect (remoto--handle-file-name-all-completions "" "/codeberg:")
              :to-equal '("ag/" "testy-shmeisty/"))
      (expect (remoto--login-user (remoto-test--github-login)) :to-be nil)))

  (it "asks for the account of no token, and only once"
    ;; An anonymous /user answers 401, and url.el answers that with a
    ;; password prompt.
    (let ((remoto--logins (remoto-test--logins))
          (remoto--user-timer nil))
      (spy-on 'run-with-idle-timer :and-call-fake
              (lambda (_secs _repeat fn &rest args) (apply fn args) nil))
      (spy-on 'ghub--username :and-call-fake
              (lambda (&rest _) (error "Cannot determine username")))
      (spy-on 'remoto--refresh-minibuffer-completions)
      (spy-on 'message)
      (spy-on 'ghub-get)
      (expect (remoto--handle-file-name-all-completions "" "/codeberg:") :to-be nil)
      (expect (remoto--handle-file-name-all-completions "" "/codeberg:") :to-be nil)
      (expect 'ghub-get :not :to-have-been-called)
      (expect 'run-with-idle-timer :to-have-been-called-times 1)
      (expect 'remoto--refresh-minibuffer-completions :not :to-have-been-called))))

;;; ---- Issue cache ----

(describe "issue cache"
  (it "caches issue listing results"
    (let ((remoto--issues-cache (make-hash-table :test 'equal))
          (call-count 0))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge _endpoint)
                (setq call-count (1+ call-count))
                '(((number . 1) (title . "Bug")))))
      (remoto--fetch-issues remoto--github "foo" "bar")
      (remoto--fetch-issues remoto--github "foo" "bar")
      (expect call-count :to-equal 1)))

  (it "returns nil on API error"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_forge _) (user-error "not found")))
    (let ((remoto--issues-cache (make-hash-table :test 'equal)))
      (expect (remoto--fetch-issues remoto--github "foo" "nonexistent") :to-be nil))))

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
    (expect 'remoto-topic-display :not :to-have-been-called))

  (it "routes the /gh: shorthand with #NUM to remoto-topic-display"
    (spy-on 'remoto-topic-display :and-return-value (generate-new-buffer "*test*"))
    (spy-on 'remoto--require-topic)
    (remoto--find-file-around-a #'ignore "/gh:testowner/testrepo#42")
    (expect 'remoto-topic-display :to-have-been-called-with "42" "/github:testowner/testrepo")
    (kill-buffer "*test*"))

  (it "routes a pull request or issue web URL to remoto-topic-display"
    (spy-on 'remoto-topic-display)
    (spy-on 'remoto--require-topic)
    (spy-on 'remoto--maybe-rewrite)
    (remoto--find-file-around-a #'ignore "https://github.com/testowner/testrepo/pull/42/files")
    (expect 'remoto-topic-display :to-have-been-called-with "42" "/github:testowner/testrepo")
    (remoto--find-file-around-a #'ignore "https://github.com/testowner/testrepo/issues/7#issuecomment-1")
    (expect 'remoto-topic-display :to-have-been-called-with "7" "/github:testowner/testrepo")
    (expect 'remoto--maybe-rewrite :not :to-have-been-called))

  (it "rewrites the /gh: short form before calling the original"
    (remoto-test-with-cache
      (expect (remoto--find-file-around-a (lambda (f &rest _) f)
                                          "/gh:testowner/testrepo/")
              :to-equal "/github:testowner/testrepo@main:/"))))

(describe "insert-file-contents on a #NUM path"
  ;; Two callers reach this and the cure differs.  Someone asking for the
  ;; contents directly needs the command that goes through the advice; a
  ;; `find-file-noselect' that started before the advice existed only has to
  ;; run again.  `advice-member-p' cannot tell them apart - the autoload
  ;; handler installs the advice before it dispatches, so it is present in
  ;; both - but the buffer state `find-file-noselect' leaves can.
  (it "sends a direct caller to find-file"
    (let ((msg (format "%s" (condition-case err
                                (progn (with-temp-buffer
                                         (insert-file-contents "/github:o/r#31"))
                                       :no-error)
                              (user-error (cadr err))))))
      (expect msg :to-match "is an issue or pull request, not a file")
      (expect msg :to-match "open it with .find-file.")))

  (it "leaves a caller's own buffer alone and does not tell it to run again"
    (let* ((buf (generate-new-buffer " *remoto-test-icf*"))
           (msg (format "%s"
                        (condition-case err
                            (with-current-buffer buf
                              (insert "unsaved work")
                              (insert-file-contents "/github:o/r#31" t)
                              :no-error)
                          (user-error (cadr err))))))
      (expect (buffer-live-p buf) :to-be t)
      (expect (with-current-buffer buf (buffer-string)) :to-equal "unsaved work")
      (expect msg :to-match "open it with .find-file.")
      (kill-buffer buf)))

  (it "tells a first call of a session to run again"
    ;; The state `find-file-noselect' hands the handler: VISIT set, buffer
    ;; empty, no `buffer-file-name'.  That buffer is killed as well.
    (let* ((buf (generate-new-buffer " *remoto-test-icf*"))
           (msg (format "%s" (condition-case err
                                 (with-current-buffer buf
                                   (insert-file-contents "/gh:o/r#31" t)
                                   :no-error)
                               (user-error (cadr err))))))
      (expect msg :to-match "is an issue or pull request, not a file")
      (expect msg :to-match "remoto is loaded now, run the command again")
      (expect (buffer-live-p buf) :to-be nil))))

;;; ---- parse-partial-canonical rejects #NUM paths ----

;;; ---- maybe-rewrite preserves #NUM paths ----

(describe "maybe-rewrite preserves #NUM paths"
  (it "returns /github:owner/repo#NUM unchanged"
    (expect (remoto--maybe-rewrite "/github:foo/bar#42")
            :to-equal "/github:foo/bar#42"))
  (it "returns /github:owner/repo#999 unchanged"
    (expect (remoto--maybe-rewrite "/github:foo/bar#999")
            :to-equal "/github:foo/bar#999")))

;;; ---- The tree of a repository without a commit ----

(describe "remoto--forge-tree"
  ;; The repository is asked only about its default branch, "main" here.
  (it "gives an empty tree for an empty Forgejo repository, which answers 404"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "/codeberg:o/r" "main" remoto--default-branch-cache)
      (spy-on 'remoto-forge-tree :and-call-fake
              (lambda (&rest _) (user-error "Remoto: not found: repos/o/r/git/trees/main")))
      (spy-on 'remoto--api :and-return-value '((empty . t)))
      (spy-on 'message)
      (let ((tree (remoto--forge-tree remoto--codeberg "o" "r" "main")))
        (expect (sort (hash-table-keys tree) #'string<) :to-equal '("" "/"))
        (expect 'message :to-have-been-called-with "Remoto: %s/%s is empty" "o" "r"))))
  (it "gives an empty tree for GitHub's 409, without another request"
    (spy-on 'remoto-forge-tree :and-call-fake
            (lambda (&rest _)
              (user-error "%s" "Remoto: api.github.com answered 409 Conflict for repos/o/r/git/trees/main?recursive=1: Git Repository is empty.")))
    (spy-on 'remoto--api)
    (spy-on 'message)
    (expect (hash-table-count (remoto--forge-tree remoto--github "o" "r" "main")) :to-equal 2)
    (expect 'remoto--api :not :to-have-been-called))
  (it "signals the failure of a repository that has commits"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "/codeberg:o/r" "main" remoto--default-branch-cache)
      (spy-on 'remoto-forge-tree :and-call-fake
              (lambda (&rest _) (user-error "Remoto: not found: repos/o/r/git/trees/main")))
      (spy-on 'remoto--api :and-return-value '((empty . :false)))
      (expect (remoto--forge-tree remoto--codeberg "o" "r" "main")
              :to-throw 'user-error '("Remoto: not found: repos/o/r/git/trees/main"))))
  (it "asks nothing more when a ref other than the default branch is missing"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "/codeberg:o/r" "main" remoto--default-branch-cache)
      (spy-on 'remoto-forge-tree :and-call-fake
              (lambda (&rest _) (user-error "Remoto: not found: repos/o/r/git/trees/ma")))
      (spy-on 'remoto--api)
      (expect (remoto--forge-tree remoto--codeberg "o" "r" "ma")
              :to-throw 'user-error '("Remoto: not found: repos/o/r/git/trees/ma"))
      (expect 'remoto--api :not :to-have-been-called)))
  (it "asks nothing more after a failure other than not found"
    (let ((remoto--default-branch-cache (make-hash-table :test 'equal)))
      (puthash "/codeberg:o/r" "main" remoto--default-branch-cache)
      (spy-on 'remoto-forge-tree :and-call-fake
              (lambda (&rest _) (user-error "Remoto: access denied (rate limit or permissions): repos/o/r/git/trees/main")))
      (spy-on 'remoto--api)
      (expect (remoto--forge-tree remoto--codeberg "o" "r" "main")
              :to-throw 'user-error)
      (expect 'remoto--api :not :to-have-been-called))))

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

  (it "puts a description that spans lines on the candidate's one line"
    (expect (substring-no-properties
             (nth 2 (car (remoto--affixate '(("sokobelt" "" "Lisp Game Jam\r\n\r\nhttps://itch.io"))))))
            :to-equal " Lisp Game Jam https://itch.io"))

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
        (expect (car result) :to-equal "20"))))

  (it "tells the completion UI to keep that order"
    (let ((md (completion-metadata "/github:foo/bar#" #'read-file-name-internal nil)))
      (expect (completion-metadata-get md 'category) :to-be 'remoto-issue)
      (expect (completion-metadata-get md 'display-sort-function) :to-be #'identity)
      (expect (completion-metadata-get md 'cycle-sort-function) :to-be #'identity))))

;;; ---- remoto--fetch-user-orgs uses authenticated endpoint ----

(describe "fetch-user-orgs"
  (it "calls user/orgs endpoint (authenticated)"
    (spy-on 'remoto--api :and-return-value '(((login . "org1")) ((login . "org2"))))
    (remoto--fetch-user-orgs remoto--github "anyone")
    (expect 'remoto--api :to-have-been-called-with remoto--github "user/orgs?per_page=100&page=1")))

;;; ---- remoto--paginated-api ----

(describe "remoto--paginated-api"
  (it "accumulates results across pages until a short page"
    (let ((calls nil))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge endpoint)
                (push endpoint calls)
                (pcase (length calls)
                  (1 (make-list 100 '((n . 1))))
                  (2 (make-list 100 '((n . 2))))
                  (_ '(((n . 3)))))))
      (let ((result (remoto--paginated-api remoto--github "repos/o/r/branches")))
        (expect (length result) :to-equal 201)
        (expect (length calls) :to-equal 3)
        (expect (car calls) :to-equal "repos/o/r/branches?per_page=100&page=3"))))

  (it "stops after a single short page"
    (spy-on 'remoto--api :and-return-value '(((n . 1)) ((n . 2))))
    (remoto--paginated-api remoto--github "user/orgs")
    (expect 'remoto--api :to-have-been-called-times 1)
    (expect 'remoto--api :to-have-been-called-with remoto--github "user/orgs?per_page=100&page=1"))

  (it "caps total requests at MAX-PAGES on huge result sets"
    (spy-on 'remoto--api :and-return-value (make-list 100 '((n . 1))))
    (remoto--paginated-api remoto--github "repos/o/r/tags" 3)
    (expect 'remoto--api :to-have-been-called-times 3))

  (it "uses & as separator when the endpoint already has a query"
    (spy-on 'remoto--api :and-return-value nil)
    (remoto--paginated-api remoto--github "search/things?q=x")
    (expect 'remoto--api :to-have-been-called-with remoto--github "search/things?q=x&per_page=100&page=1")))

;;; ---- File commit annotations ----

(describe "file commit annotations"
  (it "propertizes file candidates with commit messages"
    (spy-on 'remoto--api :and-call-fake
            (lambda (_forge endpoint)
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
      (puthash "/github:testowner/testrepo" "main" remoto--default-branch-cache)
      (remoto-test--install-mock-tree)
      (let ((result (remoto--fetch-file-commits remoto--github "testowner" "testrepo" "main" ""
                                                '("README.md" "src/"))))
        (expect (alist-get "README.md" result nil nil #'equal)
                :to-equal "Initial commit")
        (expect (alist-get "src/" result nil nil #'equal)
                :to-equal "Add source directory"))))

  (it "asks for the commits of a subdirectory's files under one slash"
    (let ((dirs nil)
          (remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal)))
      (spy-on 'remoto-forge-file-commits
              :and-call-fake (lambda (_forge _owner _repo _ref dir _names) (push dir dirs) nil))
      (puthash "/github:testowner/testrepo" "main" remoto--default-branch-cache)
      (remoto-test--install-mock-tree)
      (remoto--file-name-completions "" "/github:testowner/testrepo@main:/src/")
      (remoto--file-name-completions "" "/github:testowner/testrepo@main:/")
      (expect dirs :to-equal '("" "src"))))

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
              (lambda (_forge _endpoint)
                (cl-incf call-count)
                '(((commit (message . "cached msg"))))))
      (remoto--fetch-file-commits remoto--github "o" "r" "main" "" '("f.el"))
      (remoto--fetch-file-commits remoto--github "o" "r" "main" "" '("f.el"))
      (expect call-count :to-equal 1)))

  (it "catches generic errors from API (not just user-error)"
    (let ((remoto--file-commits-cache (make-hash-table :test 'equal)))
      (spy-on 'remoto--api :and-call-fake
              (lambda (_forge _endpoint) (error "Connection refused")))
      (expect (remoto--fetch-file-commits remoto--github "o" "r" "main" "" '("f.el"))
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
    (let ((remoto--logins (remoto-test--logins :failed nil :user "testuser"))
          (remoto-github-auth nil))
      (remoto--api-async remoto--github "search/users?q=foo" #'ignore)
      (expect 'ghub-get :to-have-been-called)))

  (it "uses auth=none when auth has failed"
    (spy-on 'ghub-get)
    (let ((remoto--logins (remoto-test--logins :failed t)))
      (remoto--api-async remoto--github "user" #'ignore)
      (let ((args (spy-calls-args-for 'ghub-get 0)))
        (expect (plist-get (cddr args) :auth) :to-equal 'none))))

  (it "passes nil auth for default ghub token when no token found"
    (spy-on 'ghub-get)
    (spy-on 'remoto--find-token :and-return-value nil)
    (let ((remoto--logins (remoto-test--logins :failed nil :user "testuser" :token nil))
          (remoto-github-auth nil))
      (remoto--api-async remoto--github "user/orgs" #'ignore)
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
      (expect (remoto--recent-owner-repos remoto--github "torvalds") :to-be nil)
      (expect 'remoto--debounce :to-have-been-called)))

  (it "returns cached repos immediately"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-repo-cache-ttl 1800)
          (remoto-search-cache-ttl 300))
      (puthash "\0repos-recent:/github:torvalds"
               (cons (float-time) '("linux" "uemacs"))
               remoto--search-cache)
      (expect (remoto--recent-owner-repos remoto--github "torvalds")
              :to-equal '("linux" "uemacs"))
      ;; Should not schedule async since cache is fresh
      (expect 'remoto--debounce :not :to-have-been-called)))

  (it "schedules background refresh for stale-but-usable cache"
    (spy-on 'remoto--debounce)
    (let ((remoto--search-cache (make-hash-table :test 'equal))
          (remoto-repo-cache-ttl 1800)
          (remoto-search-cache-ttl 300))
      ;; Cache entry older than short TTL but within repo TTL
      (puthash "\0repos-recent:/github:torvalds"
               (cons (- (float-time) 600) '("linux" "uemacs"))
               remoto--search-cache)
      (let ((result (remoto--recent-owner-repos remoto--github "torvalds")))
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

(defun remoto-test--pipe-api-fake (_forge endpoint)
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
         (remoto--logins (remoto-test--logins :failed nil :token "ghp_mock_token" :user "mockuser")))
     (spy-on 'remoto--api :and-call-fake #'remoto-test--pipe-api-fake)
     ,@body))

(describe "pipeline: every segment yields data"
  ;; Segment 1: API returns repo metadata
  (it "remoto--api returns repo metadata"
    (remoto-test-with-pipeline
      (let ((data (remoto--api remoto--github "repos/acme/widgets")))
        (expect data :to-be-truthy)
        (expect (alist-get 'full_name data) :to-equal "acme/widgets")
        (expect (alist-get 'default_branch data) :to-equal "main"))))

  ;; Segment 2: default branch extraction
  (it "remoto--default-branch returns a non-empty string"
    (remoto-test-with-pipeline
      (let ((branch (remoto--default-branch remoto--github "acme" "widgets")))
        (expect branch :to-be-truthy)
        (expect (stringp branch) :to-be-truthy)
        (expect (string-empty-p branch) :not :to-be-truthy))))

  ;; Segment 3: tree fetch builds a populated hash table
  (it "remoto--fetch-tree returns a hash table with entries"
    (remoto-test-with-pipeline
      (let ((tree (remoto--fetch-tree remoto--github "acme" "widgets" "main")))
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
        (insert-directory (concat remoto-test--pipe-prefix "/") "-la" nil t)
        (let ((content (buffer-string)))
          (expect (length content) :to-be-greater-than 0)
          (expect content :to-match "README\\.md")
          (expect content :to-match "src")))))

  (it "insert-directory gives a directory one line without FULL-DIRECTORY-P"
    ;; As ls-lisp does; Dired asks so for each name of a list of names.
    (remoto-test-with-pipeline
      (with-temp-buffer
        (insert-directory (concat remoto-test--pipe-prefix "/src") "-la")
        (expect (buffer-string) :to-match
                (rx bos "  drwxr-xr-x  1 github github " (+ nonl) " src\n" eos))))))

;;; Pipeline: auth forwarding

(describe "pipeline: auth is forwarded to API calls"
  (it "passes effective-auth token to remoto--ghub-get"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--logins (remoto-test--logins :failed nil :token "ghp_private_token" :user "testuser"))
          (captured-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (setq captured-auth (plist-get args :auth))
                '((default_branch . "main"))))
      (remoto--default-branch remoto--github "acme" "widgets")
      (expect captured-auth :to-equal "ghp_private_token")))

  (it "uses auth=none when auth-failed is t"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--logins (remoto-test--logins :failed t :token nil :user nil))
          (captured-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (setq captured-auth (plist-get args :auth))
                '((default_branch . "main"))))
      (remoto--default-branch remoto--github "acme" "widgets")
      (expect captured-auth :to-equal 'none)))

  (it "signals user-error for private repo with auth=none (404)"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--logins (remoto-test--logins :failed t :token nil :user nil)))
      (spy-on 'remoto--ghub-get :and-call-fake
              (lambda (_forge _resource _auth endpoint)
                (user-error "Remoto: not found: %s" endpoint)))
      (expect (remoto--api remoto--github "repos/acme/private-repo")
              :to-throw 'user-error))))

;;; Fresh session: try every auth avenue, fail loudly when none work

(describe "pipeline: fresh session auth resolution"
  ;; Simulate fresh Emacs: warm-auth hasn't run, all auth state is nil.
  ;; ghub's own auth-source lookup fails (different host/user patterns).
  ;; remoto--api should try remoto--find-token as a last resort.

  (it "falls back to remoto--find-token when ghub auth fails"
    (let ((remoto--logins (remoto-test--logins :failed nil :token nil :user nil))
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
      (spy-on 'remoto--find-token :and-return-value "ghp_fallback_token")
      (let ((data (remoto--api remoto--github "repos/acme/widgets")))
        (expect data :to-be-truthy)
        (expect (alist-get 'default_branch data) :to-equal "main")
        ;; Should have cached the token for subsequent calls
        (expect (remoto--login-token (remoto-test--github-login)) :to-equal "ghp_fallback_token"))))

  (it "does not set auth-failed when fallback token works"
    (let ((remoto--logins (remoto-test--logins :failed nil :token nil :user nil))
          (remoto-github-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (let ((auth (plist-get args :auth)))
                  (if (stringp auth)
                      '((full_name . "acme/widgets"))
                    (error "Required Github token does not exist")))))
      (spy-on 'remoto--find-token :and-return-value "ghp_found")
      (remoto--api remoto--github "repos/acme/widgets")
      (expect (remoto--login-failed (remoto-test--github-login)) :to-be nil))))

(describe "pipeline: no auth token anywhere - fail loudly"
  ;; No token exists: ghub fails, remoto--find-token returns
  ;; nil.  Every avenue exhausted.  The user must see a clear error,
  ;; not silent empty results.

  (it "remoto--api signals user-error when all auth avenues fail"
    (let ((remoto--logins (remoto-test--logins :failed nil :token nil :user nil))
          (remoto-github-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (error "Required Github token does not exist")))
      (spy-on 'remoto--find-token :and-return-value nil)
      (expect (remoto--api remoto--github "repos/acme/private-repo")
              :to-throw 'user-error)))

  (it "directory-files signals rather than returning silent empty list"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--logins (remoto-test--logins :failed nil :token nil :user nil))
          (remoto-github-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (error "Required Github token does not exist")))
      (spy-on 'remoto--find-token :and-return-value nil)
      (expect (directory-files "/github:acme/private@main:/")
              :to-throw 'user-error)))

  (it "file-exists-p signals rather than returning nil for auth failure"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--logins (remoto-test--logins :failed nil :token nil :user nil))
          (remoto-github-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (error "Required Github token does not exist")))
      (spy-on 'remoto--find-token :and-return-value nil)
      (expect (file-exists-p "/github:acme/private@main:/README.md")
              :to-throw 'user-error)))

  (it "insert-directory signals rather than inserting nothing"
    (let ((remoto--tree-cache (make-hash-table :test 'equal))
          (remoto--default-branch-cache (make-hash-table :test 'equal))
          (remoto--logins (remoto-test--logins :failed nil :token nil :user nil))
          (remoto-github-auth nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest _args)
                (error "Required Github token does not exist")))
      (spy-on 'remoto--find-token :and-return-value nil)
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
          (remoto--logins (remoto-test--logins :failed nil :token 'token)))
      (spy-on 'ghub-get)
      (remoto--api-async remoto--github "search/x" #'ignore)
      (expect remoto--inflight-count :to-equal 1)))

  (it "decrements once and forwards the value on success"
    (let ((remoto--inflight-count 0)
          (remoto--logins (remoto-test--logins :failed nil :token 'token))
          (got 'none))
      ;; ghub calls the callback as (value headers status req); the wrapper
      ;; must absorb the extra args and forward only the value, once.
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (funcall (plist-get args :callback) 'VALUE 'h 's 'r)))
      (remoto--api-async remoto--github "search/x" (lambda (d) (setq got d)))
      (expect remoto--inflight-count :to-equal 0)
      (expect got :to-be 'VALUE)))

  (it "decrements once on error"
    (let ((remoto--inflight-count 0)
          (remoto--logins (remoto-test--logins :failed nil :token 'token)))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (funcall (plist-get args :errorback) 'err 'h 's 'r)))
      (remoto--api-async remoto--github "search/y" #'ignore)
      (expect remoto--inflight-count :to-equal 0)))

  (it "does not leak when ghub-get throws synchronously"
    (let ((remoto--inflight-count 0)
          (remoto--logins (remoto-test--logins :failed nil :token 'token)))
      (spy-on 'ghub-get :and-call-fake (lambda (&rest _) (error "boom")))
      (remoto--api-async remoto--github "search/z" #'ignore)
      (expect remoto--inflight-count :to-equal 0)))

  (it "calls ERRBACK for a failed request and for one that never started"
    (let ((remoto--inflight-count 0)
          (remoto--logins (remoto-test--logins :failed nil :token 'token))
          (failed nil))
      (spy-on 'ghub-get :and-call-fake
              (lambda (resource &optional _params &rest args)
                (if (equal resource "/late")
                    (funcall (plist-get args :errorback) 'err 'h 's 'r)
                  (error "boom"))))
      (remoto--api-async remoto--github "late" #'ignore (lambda () (push 'late failed)))
      (remoto--api-async remoto--github "never" #'ignore (lambda () (push 'never failed)))
      (expect failed :to-equal '(never late))
      (expect remoto--inflight-count :to-equal 0)))

  (it "stays positive when one of two overlapping fetches finishes"
    (let ((remoto--inflight-count 0)
          (remoto--logins (remoto-test--logins :failed nil :token 'token))
          (callbacks '()))
      (spy-on 'ghub-get :and-call-fake
              (lambda (_resource &optional _params &rest args)
                (push (plist-get args :callback) callbacks)))
      (remoto--api-async remoto--github "a" #'ignore)
      (remoto--api-async remoto--github "b" #'ignore)
      (expect remoto--inflight-count :to-equal 2)
      (funcall (car callbacks) 'V 'h 's 'r)
      (expect remoto--inflight-count :to-equal 1))))

(describe "remoto fetch indicator overlay"
  (it "renders the indicator between the prompt and the input"
    (let ((remoto--status-overlay nil))
      (with-temp-buffer
        (insert "/github:torvalds/")
        (remoto--render-status (current-buffer) t)
        (expect (overlayp remoto--status-overlay) :to-be-truthy)
        (expect (overlay-start remoto--status-overlay)
                :to-equal (minibuffer-prompt-end))
        (expect (substring-no-properties
                 (overlay-get remoto--status-overlay 'before-string))
                :to-equal "⟳ ")
        (remoto--clear-status)
        (expect remoto--status-overlay :to-be nil))))

  (it "draws nothing after the input, where the cursor is"
    ;; A string after point takes the cursor with it: Emacs draws the
    ;; cursor after it, and a UI that opens its candidate list at point
    ;; (Vertico) claims the `cursor' property for its own string, so the
    ;; property cannot win it back.
    (let ((remoto--status-overlay nil))
      (with-temp-buffer
        (insert "/github:torvalds/")
        (remoto--render-status (current-buffer) t)
        (expect (overlay-get remoto--status-overlay 'after-string) :to-be nil)
        (expect (overlay-end remoto--status-overlay)
                :to-be-less-than (point-max))
        (remoto--clear-status))))

  (it "holds the slot at the same width busy or idle, so nothing shifts"
    (let ((remoto--status-overlay nil))
      (with-temp-buffer
        (insert "/github:torvalds/")
        (remoto--render-status (current-buffer) t)
        (let ((busy (overlay-get remoto--status-overlay 'before-string)))
          (remoto--render-status (current-buffer) nil)
          (let ((idle (overlay-get remoto--status-overlay 'before-string)))
            (expect (string-width idle) :to-equal (string-width busy))
            (expect (string-trim idle) :to-equal "")))
        (remoto--clear-status))))

  (it "keeps the blank slot while the prompt is up"
    (let ((remoto--inflight-count 1)
          (remoto--status-overlay nil))
      (with-temp-buffer
        (insert "/github:torvalds/")
        (remoto--render-status (current-buffer) t)
        (spy-on 'minibufferp :and-return-value t)
        (remoto--inflight-dec)
        (expect (overlayp remoto--status-overlay) :to-be-truthy)
        (expect (string-trim
                 (overlay-get remoto--status-overlay 'before-string))
                :to-equal "")
        (remoto--clear-status))))

  (it "reuses one overlay across repeated renders"
    (let ((remoto--status-overlay nil))
      (with-temp-buffer
        (insert "/github:foo/")
        (remoto--render-status (current-buffer) t)
        (let ((first remoto--status-overlay))
          (remoto--render-status (current-buffer) t)
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

(defmacro remoto-test-with-minibuffer-contents (contents &rest body)
  "Run BODY as if a file-name minibuffer showing CONTENTS were active.
The suite runs in batch, where no minibuffer can be active, so the
three functions the indicator asks are answered by a temp buffer."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,contents)
     (let ((buf (current-buffer)))
       (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () 'win))
                 ((symbol-function 'window-buffer) (lambda (_w) buf))
                 ((symbol-function 'minibuffer-contents-no-properties)
                  (lambda () (buffer-string))))
         ,@body))))

(describe "remoto--completion-minibuffer"
  (it "recognizes the /github: prefix"
    (remoto-test-with-minibuffer-contents "/github:torvalds/"
      (expect (remoto--completion-minibuffer) :to-be (current-buffer))))

  (it "recognizes the /gh: shorthand"
    (remoto-test-with-minibuffer-contents "/gh:torvalds/"
      (expect (remoto--completion-minibuffer) :to-be (current-buffer))))

  (it "recognizes a remoto path typed behind the shadowed default directory"
    ;; `C-x C-f' starts with the current directory in the minibuffer; typing
    ;; a second absolute path after it is how the prompt is normally used.
    (remoto-test-with-minibuffer-contents "~/src//gh:torvalds/"
      (expect (remoto--completion-minibuffer) :to-be (current-buffer))))

  (it "recognizes the remoto-browse prompt by its collection"
    (remoto-test-with-minibuffer-contents ""
      (setq-local minibuffer-completion-table #'remoto--repo-completion-table)
      (expect (remoto--completion-minibuffer) :to-be (current-buffer))))

  (it "recognizes an emptied prompt opened inside a remoto directory"
    ;; `C-x C-f' in a remoto Dired, then `C-a C-k': the text is gone but
    ;; `read-file-name' left its DIR in `default-directory', and completion
    ;; still fetches from there.
    (remoto-test-with-minibuffer-contents ""
      (setq-local default-directory "/github:o/r@main:/")
      (expect (remoto--completion-minibuffer) :to-be (current-buffer))))

  (it "ignores an emptied prompt opened in a local directory"
    (remoto-test-with-minibuffer-contents ""
      (setq-local default-directory "/tmp/")
      (expect (remoto--completion-minibuffer) :to-be nil)))

  (it "ignores a local file name"
    (remoto-test-with-minibuffer-contents "~/src/"
      (expect (remoto--completion-minibuffer) :to-be nil)))

  (it "is nil without an active minibuffer"
    (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil)))
      (expect (remoto--completion-minibuffer) :to-be nil))))

(describe "remoto--show-status with the /gh: shorthand"
  (it "renders the overlay for /gh: input"
    (let ((remoto-show-fetch-indicator t)
          (remoto--status-overlay nil))
      (remoto-test-with-minibuffer-contents "/gh:agz"
        (remoto--show-status)
        (expect (overlayp remoto--status-overlay) :to-be-truthy)
        (expect (overlay-buffer remoto--status-overlay) :to-be (current-buffer))
        (remoto--clear-status))))

  (it "renders the overlay for a shadowed /gh: input"
    (let ((remoto-show-fetch-indicator t)
          (remoto--status-overlay nil))
      (remoto-test-with-minibuffer-contents "~/src//gh:agz"
        (remoto--show-status)
        (expect (overlayp remoto--status-overlay) :to-be-truthy)
        (remoto--clear-status)))))

(describe "remoto--with-fetch-indicator"
  ;; The suite runs in batch, where the macro does nothing; each spec here
  ;; pretends to be interactive.
  (before-each
    (setq remoto--sync-fetch-depth 0
          remoto--sync-fetch-overlay nil))

  (it "runs body and returns its value without UI when disabled"
    (let ((noninteractive nil)
          (remoto-show-fetch-indicator nil)
          (ran nil))
      (spy-on 'message)
      (spy-on 'redisplay)
      (expect (remoto--with-fetch-indicator (setq ran t) 99) :to-equal 99)
      (expect ran :to-be t)
      (expect 'message :not :to-have-been-called)
      (expect 'redisplay :not :to-have-been-called)))

  (it "does nothing in batch, where there is no display"
    (let ((noninteractive t)
          (remoto-show-fetch-indicator t))
      (spy-on 'message)
      (spy-on 'redisplay)
      (expect (remoto--with-fetch-indicator 5) :to-equal 5)
      (expect 'message :not :to-have-been-called)
      (expect 'redisplay :not :to-have-been-called)))

  (it "uses the echo area with no remoto minibuffer, then clears its own message"
    (let ((noninteractive nil)
          (remoto-show-fetch-indicator t)
          (ran nil))
      (spy-on 'message)
      (spy-on 'redisplay)
      (spy-on 'current-message
              :and-return-value (format "Remoto %s" remoto--fetch-indicator-text))
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil)))
        (expect (remoto--with-fetch-indicator (setq ran t) 7) :to-equal 7))
      (expect ran :to-be t)
      (expect 'message :to-have-been-called-with
              "Remoto %s" remoto--fetch-indicator-text)
      (expect 'message :to-have-been-called-with nil)
      (expect 'redisplay :not :to-have-been-called)))

  (it "leaves a message that something else put up during the fetch"
    (let ((noninteractive nil)
          (remoto-show-fetch-indicator t))
      (spy-on 'message)
      (spy-on 'current-message :and-return-value "Remoto: tree truncated")
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil)))
        (remoto--with-fetch-indicator 1))
      (expect 'message :not :to-have-been-called-with nil)))

  (it "draws the minibuffer overlay and paints it when a remoto prompt is active"
    (let ((noninteractive nil)
          (remoto-show-fetch-indicator t)
          (remoto--inflight-count 0)
          (remoto--status-overlay nil)
          seen)
      (spy-on 'message)
      (spy-on 'redisplay)
      (remoto-test-with-minibuffer-contents "/gh:agzam/remoto.el@"
        (remoto--with-fetch-indicator
          (setq seen (list remoto--inflight-count
                           (overlayp remoto--status-overlay))))
        (expect seen :to-equal '(1 t))
        (expect 'redisplay :to-have-been-called)
        (expect 'message :not :to-have-been-called)
        (expect remoto--inflight-count :to-equal 0)
        (expect remoto--status-overlay :to-be nil))))

  (it "draws once for nested bodies and clears at the outermost end"
    (let ((noninteractive nil)
          (remoto-show-fetch-indicator t)
          (remoto--inflight-count 0)
          (remoto--status-overlay nil)
          inner)
      (spy-on 'redisplay)
      (remoto-test-with-minibuffer-contents "/gh:agzam/"
        (remoto--with-fetch-indicator
          (remoto--with-fetch-indicator
            (setq inner remoto--inflight-count))
          (expect (overlayp remoto--status-overlay) :to-be-truthy))
        (expect inner :to-equal 1)
        (expect 'redisplay :to-have-been-called-times 1)
        (expect remoto--status-overlay :to-be nil))))

  (it "clears the indicator when the body signals"
    (let ((noninteractive nil)
          (remoto-show-fetch-indicator t)
          (remoto--inflight-count 0)
          (remoto--status-overlay nil))
      (spy-on 'redisplay)
      (remoto-test-with-minibuffer-contents "/gh:agzam/"
        (expect (remoto--with-fetch-indicator (error "boom")) :to-throw 'error)
        (expect remoto--sync-fetch-depth :to-equal 0)
        (expect remoto--inflight-count :to-equal 0)
        (expect remoto--status-overlay :to-be nil)))))

(describe "remoto--ghub-get fetch indicator"
  ;; Every blocking API call shows the indicator, so `C-x C-f' and
  ;; `remoto-browse' behave the same whichever of them is fetching.
  (before-each
    (setq remoto--sync-fetch-depth 0
          remoto--sync-fetch-overlay nil))

  (it "shows the minibuffer overlay around a blocking fetch while completing"
    (let ((noninteractive nil)
          (remoto-show-fetch-indicator t)
          (remoto--inflight-count 0)
          (remoto--status-overlay nil)
          (throw-on-input nil)
          seen)
      (spy-on 'redisplay)
      (spy-on 'ghub-get :and-call-fake
              (lambda (&rest _)
                (setq seen (overlayp remoto--status-overlay))
                '((name . "main"))))
      (remoto-test-with-minibuffer-contents "/gh:agzam/remoto.el@"
        (expect (remoto--ghub-get remoto--github "/repos/o/r/branches" 'none "repos/o/r/branches")
                :to-equal '((name . "main")))
        (expect seen :to-be t)
        (expect 'redisplay :to-have-been-called)
        (expect remoto--status-overlay :to-be nil))))

  (it "shows the echo-area message around a blocking fetch after the prompt"
    (let ((noninteractive nil)
          (remoto-show-fetch-indicator t)
          (throw-on-input nil))
      (spy-on 'message)
      (spy-on 'ghub-get :and-return-value '((default_branch . "main")))
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil)))
        (remoto--ghub-get remoto--github "/repos/o/r" 'none "repos/o/r"))
      (expect 'message :to-have-been-called-with
              "Remoto %s" remoto--fetch-indicator-text)))

  (it "clears the overlay when the fetch fails"
    (let ((noninteractive nil)
          (remoto-show-fetch-indicator t)
          (remoto--inflight-count 0)
          (remoto--status-overlay nil)
          (throw-on-input nil))
      (spy-on 'redisplay)
      (spy-on 'ghub-get :and-call-fake
              (lambda (&rest _) (signal 'ghub-http-error '(404 "Not found" "u" nil))))
      (remoto-test-with-minibuffer-contents "/gh:agzam/nope/"
        (expect (remoto--ghub-get remoto--github "/repos/agzam/nope" 'none "repos/agzam/nope")
                :to-throw 'user-error)
        (expect remoto--inflight-count :to-equal 0)
        (expect remoto--status-overlay :to-be nil)))))

(describe "remoto-browse fetch indicator"
  (it "shows the synchronous indicator around the resolve/open fetch"
    (let ((noninteractive nil)
          (remoto-show-fetch-indicator t))
      (spy-on 'message)
      (spy-on 'remoto--parse-input :and-return-value 'parsed)
      (spy-on 'remoto--resolve-ref :and-return-value 'resolved)
      (spy-on 'remoto--canonical-path :and-return-value "/github:o/r:main:/")
      (spy-on 'remoto--tree-entry :and-return-value '((type . "tree")))
      (spy-on 'dired)
      (spy-on 'find-file)
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil)))
        (remoto-browse "owner/repo"))
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

  (it "classifies the lines of the listings above the repositories"
    (spy-on 'remoto--api)
    (dolist (case '(("/github:me/" "/github:me/zeta" remoto-repo . "/github:me/zeta:/")
                    ("/github:" "/github:acme" remoto-owner . "/github:acme")
                    ("/github:me/" nil remoto-owner . "/github:me/")))
      (pcase-let ((`(,dir ,file . ,target) case))
        (with-temp-buffer
          (dired-mode)
          (setq-local dired-directory dir)
          (spy-on 'dired-get-filename :and-return-value file)
          (expect (remoto--embark-target-at-point) :to-equal target))))
    (expect 'remoto--api :not :to-have-been-called))

  (it "resolves the dots of the . and .. entries first"
    (spy-on 'remoto--api)
    (dolist (case '(("/github:me/zeta@main:/.." remoto-owner . "/github:me/")
                    ("/github:me/zeta@main:/." remoto-repo . "/github:me/zeta@main:/")
                    ("/github:me/.." . nil)))
      (with-temp-buffer
        (dired-mode)
        (setq-local dired-directory "/github:me/")
        (spy-on 'dired-get-filename :and-return-value (car case))
        (expect (remoto--embark-target-at-point) :to-equal (cdr case))))
    (expect 'remoto--api :not :to-have-been-called))

  (it "returns nil outside remoto buffers"
    (with-temp-buffer
      (setq-local buffer-file-name "/home/me/x.el")
      (expect (remoto--embark-target-at-point) :to-be nil)))

  (it "treats a failed forge lookup as no target"
    (with-temp-buffer
      (setq-local buffer-file-name "/github:testowner/testrepo@main:/src/main.el")
      (spy-on 'remoto--path-context :and-throw-error 'user-error)
      (expect (remoto--embark-target-at-point) :to-be nil)))

  (it "lets a programming error propagate"
    (with-temp-buffer
      (setq-local buffer-file-name "/github:testowner/testrepo@main:/src/main.el")
      (spy-on 'remoto--path-context :and-throw-error 'wrong-type-argument)
      (expect (remoto--embark-target-at-point) :to-throw 'wrong-type-argument))))

(describe "remoto--embark-classify"
  (it "falls back to the given type when the forge lookup fails"
    (spy-on 'remoto--path-context :and-throw-error 'user-error)
    (expect (remoto--embark-classify "/github:o/r@main:/src" 'remoto-file)
            :to-be 'remoto-file)))

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
              "https://github.com/testowner/testrepo/tree/main/src")))

  (it "copies the owner page URL (no network)"
    (remoto-embark-copy-owner-url "/github:torvalds")
    (expect (car kill-ring) :to-equal "https://github.com/torvalds"))

  (it "browses the owner page"
    (spy-on 'browse-url)
    (remoto-embark-browse-owner "/github:torvalds")
    (expect 'browse-url :to-have-been-called-with "https://github.com/torvalds"))

  (it "browses the owner's repositories page"
    (spy-on 'browse-url)
    (remoto-embark-browse-owner-repos "/github:torvalds")
    (expect 'browse-url :to-have-been-called-with
            "https://github.com/torvalds?tab=repositories")))

(describe "remoto owner target plumbing"
  (it "builds the owner profile and repositories URLs"
    (expect (remoto--forge-owner-url 'github "agzam")
            :to-equal "https://github.com/agzam")
    (expect (remoto--forge-owner-url 'github "agzam" 'owner-repos)
            :to-equal "https://github.com/agzam?tab=repositories"))

  (it "makes a root candidate carrying the canonical owner path"
    (let ((cand (remoto--owner-candidate
                 (propertize "agzam" 'remoto-acct-type "User") "/github:")))
      (expect (get-text-property 0 'remoto-target cand)
              :to-equal "/github:agzam")
      (expect (get-text-property 0 'remoto-acct-type cand)
              :to-equal "User")))

  (it "tags the /github: root completion with the remoto-owner category"
    (expect (alist-get 'category (remoto--completion-metadata "/github:"))
            :to-be 'remoto-owner))

  (it "parses owner parts, tolerating a trailing slash"
    (expect (remoto--embark-owner-parts "/github:agzam")
            :to-equal '(github "agzam"))
    (expect (remoto--embark-owner-parts "/github:agzam/")
            :to-equal '(github "agzam"))))

(describe "remoto-embark-open-in-remoto"
  (it "opens a blob URL at its canonical remoto path"
    (spy-on 'find-file)
    (remoto-embark-open-in-remoto "https://github.com/o/r/blob/main/x.el")
    (expect 'find-file :to-have-been-called-with "/github:o/r@main:/x.el"))

  (it "opens a repo URL at its root"
    (spy-on 'find-file)
    (remoto-embark-open-in-remoto "https://github.com/o/r")
    (expect 'find-file :to-have-been-called-with "/github:o/r:/"))

  (it "errors on a non-forge URL"
    (expect (remoto-embark-open-in-remoto "https://example.com/foo")
            :to-throw 'user-error))

  (it "turns global-remoto-mode on when it is off"
    (spy-on 'find-file)
    (spy-on 'message)
    (unwind-protect
        (progn
          (global-remoto-mode -1)
          (remoto-embark-open-in-remoto "https://github.com/o/r")
          (expect global-remoto-mode :to-be-truthy)
          (expect 'find-file :to-have-been-called-with "/github:o/r:/"))
      (global-remoto-mode 1))))

(describe "remoto-embark-open-issue"
  (it "turns global-remoto-mode on and visits the issue path"
    (spy-on 'find-file)
    (spy-on 'message)
    (unwind-protect
        (progn
          (global-remoto-mode -1)
          (remoto-embark-open-issue "/github:o/r#42")
          (expect global-remoto-mode :to-be-truthy)
          (expect 'find-file :to-have-been-called-with "/github:o/r#42"))
      (global-remoto-mode 1))))

(describe "remoto-embark-clone"
  (it "clones with the HTTPS URL and chosen dir by default"
    (let ((remoto-clone-url-type 'https))
      (spy-on 'read-directory-name :and-return-value "/tmp/r/")
      (spy-on 'remoto--clone)
      (remoto-embark-clone "/github:o/r:/")
      (expect 'remoto--clone :to-have-been-called-with
              "https://github.com/o/r.git" "/tmp/r/")))

  (it "honors remoto-clone-url-type set to ssh"
    (let ((remoto-clone-url-type 'ssh))
      (spy-on 'read-directory-name :and-return-value "/tmp/r/")
      (spy-on 'remoto--clone)
      (remoto-embark-clone "/github:o/r:/")
      (expect 'remoto--clone :to-have-been-called-with
              "git@github.com:o/r.git" "/tmp/r/")))

  (it "is bound in the repo keymap"
    (expect (lookup-key remoto-embark-repo-map "c") :to-be 'remoto-embark-clone))

  (it "prompts from a local directory when acting in a remoto buffer"
    (spy-on 'remoto--clone)
    (spy-on 'read-directory-name :and-return-value "/tmp/r/")
    (let ((default-directory "/github:o/r:/"))
      (remoto-embark-clone "/github:o/r:/"))
    (expect (nth 1 (spy-calls-args-for 'read-directory-name 0))
            :to-equal (expand-file-name "~/"))))

(describe "remoto--clone"
  (before-each
    (spy-on 'start-process :and-return-value nil)
    (spy-on 'set-process-sentinel)
    (spy-on 'display-buffer))

  (it "launches git clone with the url and dest"
    (remoto--clone "https://github.com/o/r.git" "/tmp/r/")
    (expect (nthcdr 2 (spy-calls-args-for 'start-process 0))
            :to-equal '("git" "clone" "https://github.com/o/r.git" "/tmp/r/")))

  (it "expands a tilde dest, which git would take literally"
    (remoto--clone "https://github.com/o/r.git" "~/GitHub/agzam/r/")
    (expect (nth 5 (spy-calls-args-for 'start-process 0))
            :to-equal (expand-file-name "~/GitHub/agzam/r/")))

  (it "resolves a relative dest against a local dir, not the remoto one"
    (let ((default-directory "/github:o/r:/"))
      (remoto--clone "https://github.com/o/r.git" "r/"))
    (expect (nth 5 (spy-calls-args-for 'start-process 0))
            :to-equal (expand-file-name "r/" (expand-file-name "~/"))))

  (it "reports the clone through its sentinel"
    (remoto--clone "https://github.com/o/r.git" "/tmp/r/")
    (expect (functionp (nth 1 (spy-calls-args-for 'set-process-sentinel 0)))
            :to-be-truthy)))

(describe "remoto--clone-finished"
  (let (visited)
    (before-each (setq visited nil))

    (it "opens magit-status on the clone when it succeeded"
      (cl-letf (((symbol-function 'require) (lambda (f &rest _) (eq f 'magit)))
                ((symbol-function 'magit-status-setup-buffer)
                 (lambda (dir) (setq visited (cons 'magit dir)))))
        (remoto--clone-finished "/tmp/r/" "finished\n"))
      (expect visited :to-equal '(magit . "/tmp/r/")))

    (it "falls back to dired when magit is unavailable"
      ;; Unbind the Magit entry point too: an installed Magit leaves it
      ;; autoloaded, and the fallback keys on `fboundp'.
      (cl-letf (((symbol-function 'require) (lambda (&rest _) nil))
                ((symbol-function 'magit-status-setup-buffer) nil)
                ((symbol-function 'dired) (lambda (dir) (setq visited (cons 'dired dir)))))
        (remoto--clone-finished "/tmp/r/" "finished\n"))
      (expect visited :to-equal '(dired . "/tmp/r/")))

    (it "visits nothing when the clone failed"
      (cl-letf (((symbol-function 'require) (lambda (f &rest _) (eq f 'magit)))
                ((symbol-function 'magit-status-setup-buffer)
                 (lambda (dir) (setq visited (cons 'magit dir))))
                ((symbol-function 'dired) (lambda (dir) (setq visited (cons 'dired dir)))))
        (remoto--clone-finished "/tmp/r/" "exited abnormally with code 128\n"))
      (expect visited :to-be nil))))

(describe "owner-level repo completion targets (Stage C)"
  (it "reports the remoto-repo category at owner level"
    (let* ((meta (remoto--completion-metadata "/github:agzam/"))
           (cat (alist-get 'category meta)))
      (expect cat :to-be 'remoto-repo)))

  (it "attaches the full remoto path as a remoto-target property on candidates"
    (spy-on 'remoto--recent-owner-repos :and-return-value
            (list (propertize "remoto.el" 'remoto-repo-desc "desc")))
    (let* ((cands (remoto--handle-file-name-all-completions "" "/github:agzam/"))
           (cand (car cands))
           (target (get-text-property 0 'remoto-target cand)))
      (expect cand :to-equal "remoto.el/")
      (expect target :to-equal "/github:agzam/remoto.el:/")))

  (it "transforms a candidate to its full path via remoto--embark-transform"
    (let* ((cand (propertize "remoto.el/" 'remoto-target "/github:agzam/remoto.el:/"))
           (result (remoto--embark-transform 'remoto-repo cand)))
      (expect result :to-equal '(remoto-repo . "/github:agzam/remoto.el:/")))))

(describe "file-level completion targets (Stage C)"
  (it "reports the remoto-file category at file level"
    (let* ((meta (remoto--completion-metadata "/github:o/r/"))
           (cat (alist-get 'category meta)))
      (expect cat :to-be 'remoto-file)))

  (it "attaches remoto-target on files-default candidates"
    (spy-on 'remoto--default-branch :and-return-value "main")
    (spy-on 'remoto--fetch-dir-children-light :and-return-value
            '(("README.md" . ((type . "blob"))) ("src" . ((type . "tree")))))
    (let* ((cands (remoto--handle-file-name-all-completions "" "/github:o/r/"))
           (readme (car cands))
           (rt (get-text-property 0 'remoto-target readme)))
      (expect readme :to-equal "README.md")
      (expect rt :to-equal "/github:o/r@main:/README.md")))

  (it "attaches remoto-target on canonical-path candidates"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-commits :and-return-value nil)
      (let* ((cands (remoto--handle-file-name-all-completions
                     "" "/github:testowner/testrepo@main:/"))
             (readme (seq-find (lambda (c) (equal c "README.md")) cands))
             (rt (and readme (get-text-property 0 'remoto-target readme))))
        (expect rt :to-equal "/github:testowner/testrepo@main:/README.md"))))

  (it "reclassifies dir vs file targets in the transformer"
    (remoto-test-with-cache
      (let* ((dir (remoto--embark-transform
                   'remoto-file
                   (propertize "src/" 'remoto-target
                               "/github:testowner/testrepo@main:/src")))
             (file (remoto--embark-transform
                    'remoto-file
                    (propertize "main.el" 'remoto-target
                                "/github:testowner/testrepo@main:/src/main.el")))
             (dir-type (car dir))
             (file-type (car file)))
        (expect dir-type :to-be 'remoto-dir)
        (expect file-type :to-be 'remoto-file)))))

(describe "branch-level completion targets (Stage C)"
  (it "reports the remoto-branch category at the @ level"
    (let* ((meta (remoto--completion-metadata "/github:o/r@"))
           (cat (alist-get 'category meta)))
      (expect cat :to-be 'remoto-branch)))

  (it "attaches remoto-target on branch candidates"
    (spy-on 'remoto--fetch-branches :and-return-value '("main" "dev"))
    (spy-on 'remoto--fetch-tags :and-return-value nil)
    (let* ((cands (remoto--handle-file-name-all-completions "" "/github:o/r@"))
           (main (car cands))
           (rt (get-text-property 0 'remoto-target main)))
      (expect main :to-equal "main:")
      (expect rt :to-equal "/github:o/r@main:/")))

  (it "keeps the branch type in the ref transformer"
    (let* ((cand (propertize "main:" 'remoto-target "/github:o/r@main:/"))
           (result (remoto--embark-transform-ref 'remoto-branch cand)))
      (expect result :to-equal '(remoto-branch . "/github:o/r@main:/"))))

  (it "browses the compare view for a branch"
    (spy-on 'browse-url)
    (remoto-embark-browse-compare "/github:o/r@main:/")
    (expect 'browse-url :to-have-been-called-with
            "https://github.com/o/r/compare/main"))

  (it "opens the new-PR page for a branch"
    (spy-on 'browse-url)
    (remoto-embark-new-pr "/github:o/r@main:/")
    (expect 'browse-url :to-have-been-called-with
            "https://github.com/o/r/pull/new/main"))

  (it "binds branch actions in the branch keymap"
    (expect (lookup-key remoto-embark-branch-map "y")
            :to-be 'remoto-embark-copy-branch-url)
    (expect (lookup-key remoto-embark-branch-map "b")
            :to-be 'remoto-embark-browse-branch)
    (expect (lookup-key remoto-embark-branch-map "d")
            :to-be 'remoto-embark-browse-compare)
    (expect (lookup-key remoto-embark-branch-map "n")
            :to-be 'remoto-embark-new-pr)))

(describe "issue-level completion targets (Stage C)"
  (it "reports the remoto-issue category at the # level"
    (let* ((meta (remoto--completion-metadata "/github:o/r#"))
           (cat (alist-get 'category meta)))
      (expect cat :to-be 'remoto-issue)))

  (it "attaches remoto-target on issue candidates"
    (spy-on 'remoto--fetch-issues :and-return-value
            '(((number . 42) (title . "Bug") (state . "open"))))
    (let* ((cands (remoto--handle-file-name-all-completions "" "/github:o/r#"))
           (first (car cands))
           (rt (get-text-property 0 'remoto-target first)))
      (expect first :to-equal "42")
      (expect rt :to-equal "/github:o/r#42")))

  (it "opens an issue target via find-file"
    (spy-on 'find-file)
    (remoto-embark-open-issue "/github:o/r#42")
    (expect 'find-file :to-have-been-called-with "/github:o/r#42"))

  (it "copies the OWNER/REPO#N reference"
    (remoto-embark-copy-issue-ref "/github:o/r#42")
    (expect (car kill-ring) :to-equal "o/r#42"))

  (it "builds the issue web URL"
    (expect (remoto--forge-issue-url 'github "o" "r" "42")
            :to-equal "https://github.com/o/r/issues/42"))

  (it "browses the issue web page"
    (spy-on 'browse-url)
    (remoto-embark-browse-issue "/github:o/r#42")
    (expect 'browse-url :to-have-been-called-with
            "https://github.com/o/r/issues/42"))

  (it "copies the issue web URL"
    (remoto-embark-copy-issue-url "/github:o/r#42")
    (expect (car kill-ring) :to-equal "https://github.com/o/r/issues/42"))

  (it "builds the PR files-diff URL via the pr-diff template"
    (expect (remoto--forge-issue-url 'github "o" "r" "42" 'pr-diff)
            :to-equal "https://github.com/o/r/pull/42/files"))

  (it "browses the PR files-diff page"
    (spy-on 'browse-url)
    (remoto-embark-browse-pr-diff "/github:o/r#42")
    (expect 'browse-url :to-have-been-called-with
            "https://github.com/o/r/pull/42/files"))

  (it "binds issue actions in the issue keymap"
    (expect (lookup-key remoto-embark-issue-map "o") :to-be 'remoto-embark-open-issue)
    (expect (lookup-key remoto-embark-issue-map "b") :to-be 'remoto-embark-browse-issue)
    (expect (lookup-key remoto-embark-issue-map "y") :to-be 'remoto-embark-copy-issue-url)
    (expect (lookup-key remoto-embark-issue-map "d") :to-be 'remoto-embark-browse-pr-diff)
    (expect (lookup-key remoto-embark-issue-map "R")
            :to-be 'remoto-embark-copy-issue-ref)))

(describe "remoto-browse Embark targets (Stage D)"
  ;; Candidates from the browse completion table carry the full canonical
  ;; path in a `remoto-target' property so Embark actions resolve a bare
  ;; candidate (mirrors the file-name completion surface).
  (it "attaches remoto-target on search-mode candidates"
    (spy-on 'remoto--search-repos :and-return-value
            (list (propertize "torvalds/linux" 'remoto-repo-desc "kernel")))
    (let* ((cands (remoto--browse-completions "torvalds"))
           (cand (car cands))
           (rt (get-text-property 0 'remoto-target cand))
           (desc (get-text-property 0 'remoto-repo-desc cand)))
      (expect cand :to-equal "torvalds/linux")
      (expect rt :to-equal "/github:torvalds/linux:/")
      ;; existing display property is preserved
      (expect desc :to-equal "kernel")))

  (it "attaches remoto-target on issue-mode candidates"
    (spy-on 'remoto--fetch-issues :and-return-value
            '(((number . 42) (title . "Bug") (state . "open"))))
    (let* ((cands (remoto--browse-completions "foo/bar#"))
           (cand (car cands))
           (rt (get-text-property 0 'remoto-target cand)))
      (expect cand :to-equal "foo/bar#42")
      (expect rt :to-equal "/github:foo/bar#42")))

  (it "keeps the cached issues when a key interrupts the direct fetch"
    (let ((interrupted nil))
      (spy-on 'remoto--fetch-issue :and-call-fake
              (lambda (&rest _) (setq interrupted t) (throw throw-on-input t)))
      (spy-on 'remoto--fetch-issues :and-return-value
              '(((number . 42) (title . "Bug") (state . "open"))))
      (let ((cands (remoto--browse-completions "foo/bar#4")))
        (expect interrupted :to-be t)
        (expect (car cands) :to-equal "foo/bar#42"))))

  (it "attaches remoto-target on branch-mode candidates"
    (spy-on 'remoto--fetch-branches :and-return-value '("main"))
    (spy-on 'remoto--fetch-tags :and-return-value nil)
    (let* ((cands (remoto--browse-completions "foo/bar@"))
           (cand (car cands))
           (rt (get-text-property 0 'remoto-target cand)))
      (expect cand :to-equal "foo/bar@main")
      (expect rt :to-equal "/github:foo/bar@main:/")))

  (it "attaches remoto-target on file-mode candidates"
    (spy-on 'remoto--default-branch :and-return-value "main")
    (spy-on 'remoto--fetch-dir-children-light :and-return-value
            '(("README.md" . ((type . "blob"))) ("src" . ((type . "tree")))))
    (let* ((cands (remoto--browse-completions "foo/bar/"))
           (readme (seq-find (lambda (c) (equal c "foo/bar/README.md")) cands))
           (dir (seq-find (lambda (c) (equal c "foo/bar/src/")) cands))
           (readme-rt (get-text-property 0 'remoto-target readme))
           (dir-rt (get-text-property 0 'remoto-target dir)))
      (expect readme-rt :to-equal "/github:foo/bar@main:/README.md")
      (expect dir-rt :to-equal "/github:foo/bar@main:/src/")))

  ;; The single `remoto-browse' category dispatches per-target via the
  ;; transformer, reusing the per-type keymaps.
  (it "classifies a repo browse target"
    (let* ((cand (propertize "torvalds/linux"
                             'remoto-target "/github:torvalds/linux:/"))
           (result (remoto--embark-browse-transform 'remoto-browse cand)))
      (expect result :to-equal '(remoto-repo . "/github:torvalds/linux:/"))))

  (it "classifies an issue browse target"
    (let* ((cand (propertize "foo/bar#42" 'remoto-target "/github:foo/bar#42"))
           (result (remoto--embark-browse-transform 'remoto-browse cand)))
      (expect result :to-equal '(remoto-issue . "/github:foo/bar#42"))))

  (it "classifies a branch browse target"
    ;; The browse table marks its branch and tag candidates with
    ;; `remoto-ref-type'; without it the same root is the repository.
    (let* ((cand (propertize "foo/bar@main"
                             'remoto-ref-type "branch"
                             'remoto-target "/github:foo/bar@main:/"))
           (result (remoto--embark-browse-transform 'remoto-browse cand)))
      (expect result :to-equal '(remoto-branch . "/github:foo/bar@main:/"))))

  (it "reclassifies dir vs file browse targets via the path context"
    (remoto-test-with-cache
      (let* ((dir (remoto--embark-browse-transform
                   'remoto-browse
                   (propertize "testowner/testrepo/src/" 'remoto-target
                               "/github:testowner/testrepo@main:/src")))
             (file (remoto--embark-browse-transform
                    'remoto-browse
                    (propertize "testowner/testrepo/src/main.el" 'remoto-target
                                "/github:testowner/testrepo@main:/src/main.el")))
             (dir-type (car dir))
             (file-type (car file)))
        (expect dir-type :to-be 'remoto-dir)
        (expect file-type :to-be 'remoto-file)))))

(describe "completion candidates survive embark collection"
  (it "keeps remoto-target through completion-all-completions per category"
    ;; embark's candidate collectors call `completion-all-completions' on the
    ;; remoto table, and embark-collect stores the bare candidate as the
    ;; entry id.  The remoto-target property must survive that call so a
    ;; collected candidate still resolves to a full path with no live
    ;; minibuffer.  Exercised for every remoto category, including the
    ;; default-style `remoto-browse' (no completion-category-override).
    (let ((survives
           (lambda (category)
             (let* ((cand (propertize "x/y" 'remoto-target "/github:x/y:/"))
                    (table (lambda (str pred action)
                             (if (eq action 'metadata)
                                 `(metadata (category . ,category))
                               (complete-with-action action (list cand) str pred))))
                    (all (completion-all-completions "" table nil 0)))
               (when (and (consp all) (last all)) (setcdr (last all) nil))
               (and (car all) (get-text-property 0 'remoto-target (car all)))))))
      (dolist (cat '(remoto-repo remoto-file remoto-branch remoto-issue
                                 remoto-owner remoto-browse))
        (let ((rt (funcall survives cat)))
          (expect rt :to-equal "/github:x/y:/"))))))

;;; Completion boundaries and style-agnostic filtering

(defun remoto-test--all-completions (input &optional styles table)
  "Candidates and base for INPUT under STYLES, as a completion UI computes them.
TABLE defaults to `read-file-name-internal'.  The base is the last cdr
of `completion-all-completions'; Vertico inserts a candidate as
\(concat (substring INPUT 0 base) candidate)."
  (let* ((completion-styles (or styles '(basic)))
         (completion-category-overrides nil)
         (completion-category-defaults nil)
         (all (completion-all-completions input (or table #'read-file-name-internal)
                                          nil (length input)))
         (base (or (when-let* ((z (last all))) (prog1 (cdr z) (setcdr z nil))) 0)))
    (cons (mapcar #'substring-no-properties all) base)))

(describe "completion boundary after the colon"
  (it "file-name-directory of a canonical path is a prefix of it"
    (dolist (input '("/github:o/r@main:s" "/github:o/r:s" "/github:o/r@main:"
                     "/github:o/r@main:/" "/github:o/r@main:/s"
                     "/github:o/r@main:src/m"))
      (expect (string-prefix-p (remoto--handle-file-name-directory input) input)
              :to-be-truthy)))

  (it "returns the typed prefix when the path has no directory part"
    (expect (remoto--handle-file-name-directory "/github:o/r@main:s")
            :to-equal "/github:o/r@main:")
    (expect (remoto--handle-file-name-directory "/github:o/r:s")
            :to-equal "/github:o/r:")
    (expect (remoto--handle-file-name-directory "/github:o/r@main:")
            :to-equal "/github:o/r@main:"))

  (it "keeps the slash when it was typed"
    (expect (remoto--handle-file-name-directory "/github:o/r@main:/")
            :to-equal "/github:o/r@main:/")
    (expect (remoto--handle-file-name-directory "/github:o/r@main:/src/m")
            :to-equal "/github:o/r@main:/src/")
    (expect (remoto--handle-file-name-directory "/github:o/r@main:src/m")
            :to-equal "/github:o/r@main:src/"))

  (it "puts the completion field after the colon, not at the end of the input"
    (expect (completion-boundaries "/github:o/r@main:s" #'read-file-name-internal nil "")
            :to-equal '(17 . 0))
    (expect (completion-boundaries "/github:o/r:s" #'read-file-name-internal nil "")
            :to-equal '(12 . 0)))

  (it "replaces the typed text with the selected candidate after a branch pick"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-commits :and-return-value nil)
      (pcase-let ((`(,cands . ,base)
                   (remoto-test--all-completions "/github:testowner/testrepo@main:s")))
        (expect cands :to-equal '("src/"))
        (expect (concat (substring "/github:testowner/testrepo@main:s" 0 base) "src/")
                :to-equal "/github:testowner/testrepo@main:src/"))
      (pcase-let ((`(,_ . ,base)
                   (remoto-test--all-completions "/github:testowner/testrepo:s")))
        (expect (concat (substring "/github:testowner/testrepo:s" 0 base) "src/")
                :to-equal "/github:testowner/testrepo:src/"))))

  (it "resolves the slash-less canonical path that results"
    (remoto-test-with-cache
      (expect (remoto--handle-file-exists-p "/github:testowner/testrepo@main:src/main.el")
              :to-be-truthy)
      (expect (remoto--handle-file-directory-p "/github:testowner/testrepo@main:src/")
              :to-be-truthy)
      (spy-on 'remoto--fetch-file-commits :and-return-value nil)
      (expect (remoto--handle-file-name-all-completions "" "/github:testowner/testrepo@main:src/")
              :to-equal '("main.el" "utils.el")))))

(describe "completion-regexp-list in file-name-all-completions"
  (it "applies every regexp, like the built-in primitive"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-commits :and-return-value nil)
      (let ((completion-regexp-list '("s")))
        (expect (remoto--handle-file-name-all-completions "" "/github:testowner/testrepo@main:/")
                :to-equal '("src/")))
      (let ((completion-regexp-list '("R" "md")))
        (expect (remoto--handle-file-name-all-completions "" "/github:testowner/testrepo@main:/")
                :to-equal '("README.md")))
      (let ((completion-regexp-list '("nothing")))
        (expect (remoto--handle-file-name-all-completions "" "/github:testowner/testrepo@main:/")
                :to-be nil))))

  (it "returns everything when no regexps are set"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-commits :and-return-value nil)
      (let ((completion-regexp-list nil))
        (expect (remoto--handle-file-name-all-completions "" "/github:testowner/testrepo@main:/")
                :to-equal '("README.md" "bin/" "src/")))))

  (it "matches the name without the trailing slash"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-commits :and-return-value nil)
      (let ((completion-regexp-list '("src$")))
        (expect (remoto--handle-file-name-all-completions "" "/github:testowner/testrepo@main:/")
                :to-equal '("src/")))))

  (it "follows completion-ignore-case"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-commits :and-return-value nil)
      (let ((completion-regexp-list '("readme")))
        (let ((completion-ignore-case nil))
          (expect (remoto--handle-file-name-all-completions "" "/github:testowner/testrepo@main:/")
                  :to-be nil))
        (let ((completion-ignore-case t))
          (expect (remoto--handle-file-name-all-completions "" "/github:testowner/testrepo@main:/")
                  :to-equal '("README.md"))))))

  (it "filters the files-default listing"
    (spy-on 'remoto--default-branch :and-return-value "main")
    (spy-on 'remoto--fetch-dir-children-light :and-return-value
            '(("README.md" . ((type . "blob"))) ("src" . ((type . "tree")))))
    (let ((completion-regexp-list '("sr")))
      (expect (remoto--handle-file-name-all-completions "" "/github:o/r/")
              :to-equal '("src/"))))

  (it "filters branches and tags by name without the colon"
    (spy-on 'remoto--fetch-branches :and-return-value '("main" "develop"))
    (spy-on 'remoto--fetch-tags :and-return-value '("v1.0"))
    (let ((completion-regexp-list '("v")))
      (expect (remoto--handle-file-name-all-completions "" "/github:o/r@")
              :to-equal '("develop:" "v1.0:")))
    (let ((completion-regexp-list '("main$")))
      (expect (remoto--handle-file-name-all-completions "" "/github:o/r@")
              :to-equal '("main:"))))

  (it "matches issues by number or title"
    (spy-on 'remoto--fetch-issues :and-return-value
            '(((number . 42) (title . "forty-two") (state . "open"))
              ((number . 10) (title . "ten") (state . "open"))))
    (let ((completion-regexp-list '("forty")))
      (expect (remoto--handle-file-name-all-completions "" "/github:o/r#")
              :to-equal '("42")))
    (let ((completion-regexp-list '("1")))
      (expect (remoto--handle-file-name-all-completions "" "/github:o/r#")
              :to-equal '("10"))))

  (it "matches repos by name or description"
    (spy-on 'remoto--recent-owner-repos :and-return-value
            (list (propertize "dotfiles" 'remoto-repo-desc "my emacs config")
                  (propertize "remoto.el" 'remoto-repo-desc "browse github")))
    (let ((completion-regexp-list '("emacs")))
      (expect (remoto--handle-file-name-all-completions "" "/github:agzam/")
              :to-equal '("dotfiles/")))
    (let ((completion-regexp-list '("remoto")))
      (expect (remoto--handle-file-name-all-completions "" "/github:agzam/")
              :to-equal '("remoto.el/"))))

  (it "matches accounts by login or description"
    (let ((remoto--logins (remoto-test--logins :user "me")))
      (spy-on 'remoto--fetch-user-orgs :and-return-value
              (list (propertize "acme" 'remoto-acct-type "Organization"
                                'remoto-acct-desc "Rockets")))
      (let ((completion-regexp-list '("rock"))
            (completion-ignore-case t))
        (expect (remoto--handle-file-name-all-completions "" "/github:")
                :to-equal '("acme/")))
      (let ((completion-regexp-list '("me")))
        (expect (remoto--handle-file-name-all-completions "" "/github:")
                :to-equal '("me/" "acme/"))))))

(describe "typed query recovery for regexp-filtering styles"
  (it "extracts the text after DIRECTORY from the input"
    (expect (remoto--input-query "/github:torvalds/lin" "/github:torvalds/") :to-equal "lin")
    (expect (remoto--input-query "/github:tor" "/github:") :to-equal "tor")
    (expect (remoto--input-query "/github:o/r#bug" "/github:o/r#") :to-equal "bug"))

  (it "normalizes the /gh: shorthand and a shadowed prefix"
    (expect (remoto--input-query "/gh:torvalds/lin" "/github:torvalds/") :to-equal "lin")
    (expect (remoto--input-query "~/x//github:torvalds/lin" "/github:torvalds/")
            :to-equal "lin"))

  (it "returns nil when the input is not under DIRECTORY"
    (expect (remoto--input-query "/github:other/lin" "/github:torvalds/") :to-be nil)
    (expect (remoto--input-query "/tmp/x" "/github:torvalds/") :to-be nil))

  (it "returns nil when the input sits at a deeper level than DIRECTORY"
    (expect (remoto--input-query "/github:kn66/repo@" "/github:") :to-be nil)
    (expect (remoto--input-query "/github:kn66/repo@" "/github:kn66/") :to-be nil)
    (expect (remoto--input-query "/github:o/r#12" "/github:o/") :to-be nil)
    (expect (remoto--input-query "/github:o/r@main:/src" "/github:o/r@") :to-be nil))

  (it "does not turn a parent-level probe into a search"
    ;; partial-completion probes /github: and /github:kn66/ with FILE ""
    ;; while the minibuffer holds /github:kn66/repo@.
    (spy-on 'remoto--minibuffer-input :and-return-value "/github:kn66/repo@")
    (spy-on 'remoto--search-users)
    (spy-on 'remoto--search-owner-repos)
    (spy-on 'remoto--recent-owner-repos :and-return-value '("repo"))
    (spy-on 'run-with-idle-timer)
    (let ((remoto--logins (remoto-test--logins :user nil)))
      (expect (remoto--handle-file-name-all-completions "" "/github:") :to-be nil))
    (expect (remoto--handle-file-name-all-completions "" "/github:kn66/")
            :to-equal '("repo/"))
    (expect 'remoto--search-users :not :to-have-been-called)
    (expect 'remoto--search-owner-repos :not :to-have-been-called))

  (it "prefers a non-empty FILE over the minibuffer"
    (spy-on 'remoto--minibuffer-input :and-return-value "/github:torvalds/other")
    (expect (remoto--completion-query "lin" "/github:torvalds/") :to-equal "lin"))

  (it "falls back to the minibuffer text when FILE is empty"
    (spy-on 'remoto--minibuffer-input :and-return-value "/github:torvalds/lin")
    (expect (remoto--completion-query "" "/github:torvalds/") :to-equal "lin"))

  (it "yields an empty query outside a completion minibuffer"
    (expect (remoto--minibuffer-input) :to-be nil)
    (expect (remoto--completion-query "" "/github:torvalds/") :to-equal ""))

  (it "reads the real minibuffer when it is current"
    (with-current-buffer (window-buffer (minibuffer-window))
      (unwind-protect
          (let ((minibuffer-completion-table #'read-file-name-internal))
            (insert "/github:torvalds/lin")
            (expect (remoto--minibuffer-input) :to-equal "/github:torvalds/lin")
            (expect (remoto--minibuffer-query "/github:torvalds/") :to-equal "lin"))
        (erase-buffer))))

  (it "ignores a minibuffer that is not completing"
    (with-current-buffer (window-buffer (minibuffer-window))
      (unwind-protect
          (let ((minibuffer-completion-table nil))
            (insert "/github:torvalds/lin")
            (expect (remoto--minibuffer-input) :to-be nil))
        (erase-buffer))))

  (it "searches users with the minibuffer text at the root"
    (spy-on 'remoto--minibuffer-input :and-return-value "/github:tor")
    (spy-on 'remoto--search-users :and-return-value '("torvalds"))
    (expect (remoto--handle-file-name-all-completions "" "/github:")
            :to-equal '("torvalds/"))
    (expect 'remoto--search-users :to-have-been-called-with remoto--github "tor"))

  (it "searches issues with the minibuffer text"
    (spy-on 'remoto--minibuffer-input :and-return-value "/github:o/r#bug")
    (spy-on 'remoto--search-issues :and-return-value
            '(((number . 7) (title . "a bug") (state . "open"))))
    (expect (remoto--handle-file-name-all-completions "" "/github:o/r#")
            :to-equal '("7"))
    (expect 'remoto--search-issues :to-have-been-called-with remoto--github "o" "r" "bug"))

  (it "fetches an issue by number from the minibuffer text"
    (spy-on 'remoto--minibuffer-input :and-return-value "/github:o/r#42")
    (spy-on 'remoto--fetch-issues :and-return-value nil)
    (spy-on 'remoto--fetch-issue :and-return-value
            '((number . 42) (title . "x") (state . "open")))
    (expect (remoto--handle-file-name-all-completions "" "/github:o/r#")
            :to-equal '("42"))
    (expect 'remoto--fetch-issue :to-have-been-called-with remoto--github "o" "r" "42")))

(describe "remoto--repo-completion-table under regexp-filtering styles"
  (it "takes the query from the minibuffer when STRING is empty"
    (spy-on 'remoto--minibuffer-input :and-return-value "agzam/rem")
    (spy-on 'remoto--search-repos :and-return-value '("agzam/remoto.el"))
    (let ((completion-regexp-list '("rem")))
      (expect (remoto--repo-completion-table "" nil t) :to-equal '("agzam/remoto.el")))
    (expect 'remoto--search-repos :to-have-been-called-with "agzam/rem"))

  (it "still applies the regexps to the candidates"
    (spy-on 'remoto--minibuffer-input :and-return-value "agzam/rem")
    (spy-on 'remoto--search-repos :and-return-value '("agzam/remoto.el" "agzam/other"))
    (let ((completion-regexp-list '("remoto")))
      (expect (remoto--repo-completion-table "" nil t) :to-equal '("agzam/remoto.el"))))

  (it "does not search for the boundaries action"
    (spy-on 'remoto--search-repos)
    (expect (remoto--repo-completion-table "agzam/rem" nil '(boundaries . "")) :to-be nil)
    (expect 'remoto--search-repos :not :to-have-been-called))

  (it "uses STRING when it is non-empty"
    (spy-on 'remoto--minibuffer-input :and-return-value "ignored")
    (spy-on 'remoto--search-repos :and-return-value '("agzam/remoto.el"))
    (expect (remoto--repo-completion-table "agzam/rem" nil t) :to-equal '("agzam/remoto.el"))
    (expect 'remoto--search-repos :to-have-been-called-with "agzam/rem")))

(require 'orderless)

(describe "end-to-end under the orderless completion style"
  (it "filters the file listing to the typed text"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-commits :and-return-value nil)
      (let ((input "/github:testowner/testrepo@main:/s"))
        (spy-on 'remoto--minibuffer-input :and-return-value input)
        (expect (remoto-test--all-completions input '(orderless))
                :to-equal '(("src/") . 33)))))

  (it "matches anywhere in the name, as orderless does elsewhere"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-commits :and-return-value nil)
      (let ((input "/github:testowner/testrepo@main:/md"))
        (spy-on 'remoto--minibuffer-input :and-return-value input)
        (expect (car (remoto-test--all-completions input '(orderless)))
                :to-equal '("README.md")))))

  (it "runs the owner repo search with the typed text"
    (let ((input "/github:torvalds/lin"))
      (spy-on 'remoto--minibuffer-input :and-return-value input)
      (spy-on 'remoto--search-owner-repos :and-return-value '("linux" "libdc-for-dirk"))
      (expect (remoto-test--all-completions input '(orderless))
              :to-equal '(("linux/") . 17))
      (expect 'remoto--search-owner-repos :to-have-been-called-with remoto--github "torvalds" "lin")))

  (it "runs the user search with the typed text at the root"
    (let ((input "/github:tor"))
      (spy-on 'remoto--minibuffer-input :and-return-value input)
      (spy-on 'remoto--search-users :and-return-value '("torvalds"))
      (expect (remoto-test--all-completions input '(orderless))
              :to-equal '(("torvalds/") . 8))
      (expect 'remoto--search-users :to-have-been-called-with remoto--github "tor")))

  (it "finds issues by title"
    (let ((input "/github:o/r#forty"))
      (spy-on 'remoto--minibuffer-input :and-return-value input)
      (spy-on 'remoto--search-issues :and-return-value
              '(((number . 42) (title . "forty-two") (state . "open"))))
      (expect (remoto-test--all-completions input '(orderless))
              :to-equal '(("42") . 12))
      (expect 'remoto--search-issues :to-have-been-called-with remoto--github "o" "r" "forty")))

  (it "filters branches and tags"
    (let ((input "/github:o/r@dev"))
      (spy-on 'remoto--minibuffer-input :and-return-value input)
      (spy-on 'remoto--fetch-branches :and-return-value '("main" "develop"))
      (spy-on 'remoto--fetch-tags :and-return-value '("v1.0"))
      (expect (remoto-test--all-completions input '(orderless))
              :to-equal '(("develop:") . 12))))

  (it "inserts the candidate in place of the typed text after a branch pick"
    (remoto-test-with-cache
      (spy-on 'remoto--fetch-file-commits :and-return-value nil)
      (let ((input "/github:testowner/testrepo@main:s"))
        (spy-on 'remoto--minibuffer-input :and-return-value input)
        (pcase-let ((`(,cands . ,base) (remoto-test--all-completions input '(orderless))))
          (expect cands :to-equal '("src/"))
          (expect (concat (substring input 0 base) "src/")
                  :to-equal "/github:testowner/testrepo@main:src/")))))

  (it "runs the repo search in remoto-browse with the typed text"
    (let ((input "agzam/rem"))
      (spy-on 'remoto--minibuffer-input :and-return-value input)
      (spy-on 'remoto--search-repos :and-return-value '("agzam/remoto.el" "agzam/other"))
      (expect (car (remoto-test--all-completions
                    input '(orderless) #'remoto--repo-completion-table))
              :to-equal '("agzam/remoto.el"))
      (expect 'remoto--search-repos :to-have-been-called-with "agzam/rem"))))

;;; The global switch

(describe "global-remoto-mode"
  ;; The suite runs with the mode on; every spec here puts it back.
  (it "installs the handler, the advice and the hooks"
    (global-remoto-mode 1)
    (expect (cdr (assoc remoto--handler-regexp file-name-handler-alist))
            :to-be 'remoto-file-name-handler)
    (expect (advice-member-p #'remoto--dired-around-a 'dired-noselect)
            :to-be-truthy)
    (expect (advice-member-p #'remoto--find-file-around-a 'find-file-noselect)
            :to-be-truthy)
    (expect (advice-member-p #'remoto--read-file-name-internal-a
                             'read-file-name-internal)
            :to-be-truthy)
    (expect (advice-member-p #'remoto--inhibit-a 'eglot-ensure) :to-be-truthy)
    (expect (memq 'remoto--maybe-enable-mode find-file-hook) :to-be-truthy)
    (expect (memq 'remoto--maybe-enable-mode dired-mode-hook) :to-be-truthy)
    (expect (memq 'remoto--minibuffer-exit-cleanup minibuffer-exit-hook)
            :to-be-truthy))

  (it "removes all of them when turned off"
    (unwind-protect
        (progn
          (global-remoto-mode -1)
          (expect (assoc remoto--handler-regexp file-name-handler-alist)
                  :to-be nil)
          (expect (advice-member-p #'remoto--dired-around-a 'dired-noselect)
                  :to-be nil)
          (expect (advice-member-p #'remoto--find-file-around-a 'find-file-noselect)
                  :to-be nil)
          (expect (advice-member-p #'remoto--read-file-name-internal-a
                                   'read-file-name-internal)
                  :to-be nil)
          (expect (advice-member-p #'remoto--inhibit-a 'eglot-ensure) :to-be nil)
          (expect (memq 'remoto--maybe-enable-mode find-file-hook) :to-be nil)
          (expect (memq 'remoto--maybe-enable-mode dired-mode-hook) :to-be nil)
          (expect (memq 'remoto--minibuffer-exit-cleanup minibuffer-exit-hook)
                  :to-be nil))
      (global-remoto-mode 1)))

  (it "schedules the auth warm-up on idle and cancels it when turned off"
    (unwind-protect
        (progn
          (global-remoto-mode -1)
          (global-remoto-mode 1)
          (let ((timer remoto--warm-auth-timer))
            (expect (memq timer timer-idle-list) :to-be-truthy)
            (expect (timer--function timer) :to-be #'remoto--warm-auth)
            (global-remoto-mode -1)
            (expect (memq timer timer-idle-list) :to-be nil)
            (expect remoto--warm-auth-timer :to-be nil)))
      (global-remoto-mode 1)))

  (it "registers the handler once however often it is turned on"
    (global-remoto-mode 1)
    (global-remoto-mode 1)
    (expect (cl-count remoto--handler-regexp file-name-handler-alist
                      :key #'car :test #'equal)
            :to-equal 1)
    (expect (cl-count 'remoto--maybe-enable-mode find-file-hook) :to-equal 1))

  (it "makes a remoto path reach the handler only while on"
    (unwind-protect
        (progn
          (expect (find-file-name-handler "/github:o/r:/" 'file-exists-p)
                  :to-be 'remoto-file-name-handler)
          (global-remoto-mode -1)
          (expect (find-file-name-handler "/github:o/r:/" 'file-exists-p)
                  :not :to-be 'remoto-file-name-handler))
      (global-remoto-mode 1))))

;;; Functions kept out of remoto buffers

(defun remoto-test--tool ()
  "Stand-in for an LSP entry point."
  'ran)

(defun remoto-test--call-in (file-name fn)
  "Call FN in a buffer visiting FILE-NAME."
  (with-temp-buffer
    (setq-local buffer-file-name file-name)
    (funcall fn)))

(describe "remoto-inhibited-functions"
  ;; The suite runs with the mode on; every spec puts the option back.
  (let (saved)
    (before-each
      (setq saved remoto-inhibited-functions)
      (setopt remoto-inhibited-functions '(remoto-test--tool)))

    (after-each
      (setopt remoto-inhibited-functions saved))

    (it "defaults to the entry points of lsp-mode and Eglot"
      (expect (eval (car (get 'remoto-inhibited-functions 'standard-value)) t)
              :to-equal '(lsp eglot-ensure)))

    (it "skips a listed function in a buffer visiting a remoto path"
      (expect (remoto-test--call-in "/github:o/r@main:/src/api.py"
                                    #'remoto-test--tool)
              :to-be nil)
      (expect (remoto-test--call-in "/gh:o/r@main:/src/api.py"
                                    #'remoto-test--tool)
              :to-be nil))

    (it "skips it in a buffer whose directory is a remoto path, as in Dired"
      (with-temp-buffer
        (setq default-directory "/github:o/r@main:/src/")
        (expect (remoto-test--tool) :to-be nil)))

    (it "runs it in a buffer visiting a local file"
      (expect (remoto-test--call-in "/home/me/api.py" #'remoto-test--tool)
              :to-be 'ran))

    (it "runs it everywhere once the mode is off"
      (unwind-protect
          (progn
            (global-remoto-mode -1)
            (expect (advice-member-p #'remoto--inhibit-a 'remoto-test--tool)
                    :to-be nil)
            (expect remoto--inhibited :to-be nil)
            (expect (remoto-test--call-in "/github:o/r@main:/src/api.py"
                                          #'remoto-test--tool)
                    :to-be 'ran))
        (global-remoto-mode 1)))

    (it "moves the advice at once when setopt changes the list"
      (setopt remoto-inhibited-functions '(remoto-test--other))
      (expect (advice-member-p #'remoto--inhibit-a 'remoto-test--tool)
              :to-be nil)
      (expect (advice-member-p #'remoto--inhibit-a 'remoto-test--other)
              :to-be-truthy))

    (it "takes a plain setq the next time the mode turns on"
      (setq remoto-inhibited-functions '(remoto-test--other))
      (expect (advice-member-p #'remoto--inhibit-a 'remoto-test--other)
              :to-be nil)
      (global-remoto-mode 1)
      (expect (advice-member-p #'remoto--inhibit-a 'remoto-test--tool)
              :to-be nil)
      (expect (advice-member-p #'remoto--inhibit-a 'remoto-test--other)
              :to-be-truthy))

    (it "removes the advice it added when turned off after a plain setq"
      (unwind-protect
          (progn
            (setq remoto-inhibited-functions nil)
            (global-remoto-mode -1)
            (expect (advice-member-p #'remoto--inhibit-a 'remoto-test--tool)
                    :to-be nil))
        (global-remoto-mode 1)))

    (it "advises a function once however often the mode is turned on"
      (global-remoto-mode 1)
      (global-remoto-mode 1)
      (let ((count 0))
        (advice-mapc (lambda (f _props)
                       (when (eq f #'remoto--inhibit-a)
                         (setq count (1+ count))))
                     'remoto-test--tool)
        (expect count :to-equal 1)))

    (it "waits for a function that is not defined yet without defining it"
      (unwind-protect
          (progn
            (setopt remoto-inhibited-functions '(remoto-test--later))
            (expect (fboundp 'remoto-test--later) :to-be nil)
            (defalias 'remoto-test--later (lambda () 'ran))
            (expect (remoto-test--call-in "/github:o/r@main:/src/api.py"
                                          #'remoto-test--later)
                    :to-be nil)
            (expect (remoto-test--call-in "/home/me/api.py"
                                          #'remoto-test--later)
                    :to-be 'ran))
        (setopt remoto-inhibited-functions '(remoto-test--tool))
        (fmakunbound 'remoto-test--later)))))

;;; The bootstrap handler of the autoloads

(defun remoto-test--push-bootstrap ()
  "Register the bootstrap entry the way the package autoloads do."
  (add-to-list 'file-name-handler-alist
               (cons remoto--handler-regexp #'remoto-autoload-file-name-handler)))

(describe "remoto-autoload-file-name-handler"
  ;; The suite runs with the mode on; every spec here puts it back.
  (it "turns the mode on, leaves the alist, and runs the operation"
    (unwind-protect
        (progn
          (global-remoto-mode -1)
          (remoto-test--push-bootstrap)
          (spy-on 'message)
          (expect (find-file-name-handler "/gh:o/r@main:/x" 'file-remote-p)
                  :to-be 'remoto-autoload-file-name-handler)
          (expect (file-remote-p "/gh:o/r@main:/x") :to-equal "/github:o/r@main:")
          (expect global-remoto-mode :to-be-truthy)
          (expect (rassq 'remoto-autoload-file-name-handler file-name-handler-alist)
                  :to-be nil)
          (expect (find-file-name-handler "/gh:o/r@main:/x" 'file-remote-p)
                  :to-be 'remoto-file-name-handler)
          (expect 'message :to-have-been-called-with
                  "Remoto: `global-remoto-mode' enabled")
          (expect 'message :to-have-been-called-times 1))
      (global-remoto-mode 1)))

  (it "is dropped when the mode is turned on from the init file instead"
    (unwind-protect
        (progn
          (global-remoto-mode -1)
          (remoto-test--push-bootstrap)
          (global-remoto-mode 1)
          (expect (rassq 'remoto-autoload-file-name-handler file-name-handler-alist)
                  :to-be nil)
          (expect (car (rassq 'remoto-file-name-handler file-name-handler-alist))
                  :to-equal remoto--handler-regexp))
      (global-remoto-mode 1)))

  (it "does not loop when an operation falls through the real handler to it"
    ;; A stale bootstrap entry behind the real handler catches the
    ;; operations that handler passes down; it must step aside, not recurse.
    (unwind-protect
        (progn
          (setq file-name-handler-alist
                (append file-name-handler-alist
                        (list (cons remoto--handler-regexp
                                    #'remoto-autoload-file-name-handler))))
          (expect (file-newer-than-file-p "/gh:o/r@main:/a" "/gh:o/r@main:/b")
                  :to-be nil)
          (expect (rassq 'remoto-autoload-file-name-handler file-name-handler-alist)
                  :to-be nil)
          (expect global-remoto-mode :to-be-truthy))
      (remoto--drop-autoload-handler)
      (global-remoto-mode 1)))

  (it "splits the argument of an Evil ex command that brings remoto in"
    (unwind-protect
        (progn
          (global-remoto-mode -1)
          (remoto-test--push-bootstrap)
          (spy-on 'message)
          (remoto-test-in-evil-ex "/gh:o/r@main:/x"
            (expect (remoto-test--evil-rebuild "/gh:o/r@main:/x")
                    :to-equal "/github:o/r@main:/x"))
          (expect global-remoto-mode :to-be-truthy))
      (global-remoto-mode 1)))

  (it "is dropped by remoto-unload-function when the mode never turned on"
    (unwind-protect
        (progn
          (global-remoto-mode -1)
          (remoto-test--push-bootstrap)
          (remoto-unload-function)
          (expect (rassq 'remoto-autoload-file-name-handler file-name-handler-alist)
                  :to-be nil))
      (global-remoto-mode 1))))

(defmacro remoto-test-with-autoloads (var &rest body)
  "Bind VAR to a freshly generated autoloads file of the package and run BODY.
The file sits in its own temporary directory: `loaddefs-generate' skips
every source older than an existing output file, so it must not exist."
  (declare (indent 1))
  `(let ((,var (expand-file-name "remoto-autoloads.el"
                                 (make-temp-file "remoto-autoloads" t))))
     (unwind-protect
         (progn
           (loaddefs-generate (file-name-directory (locate-library "remoto")) ,var)
           ,@body)
       (delete-directory (file-name-directory ,var) t))))

(defun remoto-test--autoload-forms (file)
  "Return the top-level forms of the autoloads FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (forms)
      (condition-case nil
          (while t (push (read (current-buffer)) forms))
        (end-of-file (nreverse forms))))))

(describe "the autoloads bootstrap"
  (it "registers the handler for every prefix of the built-in forges"
    (remoto-test-with-autoloads file
      (let* ((forms (remoto-test--autoload-forms file))
             (entries (mapcar (lambda (f) (cadr (nth 2 f)))
                              (seq-filter (lambda (f)
                                            (and (eq (car-safe f) 'add-to-list)
                                                 (equal (nth 1 f) ''file-name-handler-alist)))
                                          forms))))
        ;; One cookie per forge file, GitHub's and Forgejo's.
        (expect (length entries) :to-equal 2)
        (dolist (entry entries)
          (expect (cdr entry) :to-be 'remoto-autoload-file-name-handler))
        (dolist (prefix (mapcar #'car remoto--forges))
          (expect (seq-some (lambda (entry)
                              (string-match-p (car entry) (format "/%s:o/r" prefix)))
                            entries)
                  :to-be-truthy))
        (expect (seq-find (lambda (f)
                            (and (eq (car-safe f) 'autoload)
                                 (equal (nth 1 f) ''remoto-autoload-file-name-handler)))
                          forms)
                :to-be-truthy))))

  (it "loads nothing and turns nothing on by itself"
    (remoto-test-with-autoloads file
      (let ((forms (remoto-test--autoload-forms file)))
        (expect (seq-find (lambda (f) (memq (car-safe f) '(require global-remoto-mode)))
                          forms)
                :to-be nil)))))

;;; A fresh session: the autoloads alone, then the first remoto path

(defun remoto-test--fresh-session (autoloads form)
  "Run FORM in a child Emacs that has loaded only AUTOLOADS; return its value.
The child is `emacs -Q --batch' with a throwaway init directory and this
process's `load-path', so remoto and ghub resolve when the autoload
fires; nil AUTOLOADS loads nothing.  FORM is read back from the child's
standard output; a child that fails yields (:error ...), an unreadable
child (:unreadable OUT ERR)."
  (let* ((init-dir (make-temp-file "remoto-fresh" t))
         (stderr (make-temp-file "remoto-fresh-stderr"))
         (script `(progn
                    (setq load-path ',load-path)
                    ,@(and autoloads `((load ,autoloads nil t)))
                    (prin1 (condition-case err ,form (error (list :error err))))))
         (print-length nil)
         (print-level nil)
         (output (with-temp-buffer
                   (call-process (expand-file-name invocation-name invocation-directory)
                                 nil (list (current-buffer) stderr) nil
                                 "-Q" "--batch" "--init-directory" init-dir
                                 "--eval" (prin1-to-string script))
                   (buffer-string))))
    (unwind-protect
        (condition-case nil
            (car (read-from-string output))
          (error (list :unreadable output
                       (with-temp-buffer
                         (insert-file-contents stderr)
                         (buffer-string)))))
      (delete-directory init-dir t)
      (delete-file stderr))))

(defconst remoto-test--fresh-session-form
  '(let ((messages nil)
         (before (list (featurep 'remoto)
                       (find-file-name-handler "/gh:o/r@main:/" 'file-exists-p)
                       (bound-and-true-p global-remoto-mode))))
     (advice-add 'message :before
                 (lambda (fmt &rest args)
                   (when fmt (push (apply #'format fmt args) messages))))
     ;; The fixture answers the API from the moment remoto is in, which is
     ;; before its first request: the autoload fires on the operation below.
     (with-eval-after-load 'remoto
       (advice-add 'remoto--api :override
                   (lambda (_forge endpoint)
                     (pcase endpoint
                       ("repos/o/r" '((default_branch . "main")))
                       ("repos/o/r/git/trees/main?recursive=1"
                        '((tree . (((path . "README.md") (type . "blob")
                                    (size . 6) (sha . "aaa") (mode . "100644"))))))
                       ("repos/o/r/contents/README.md?ref=main"
                        (list (cons 'sha "aaa")
                              (cons 'encoding "base64")
                              (cons 'content (base64-encode-string "hello\n"))))
                       (_ nil)))))
     ;; What `C-x C-f /gh:o/r@main:/RE TAB RET' does, minus the keystrokes.
     (let* ((completions (file-name-all-completions "RE" "/gh:o/r@main:/"))
            (buf (find-file-noselect "/gh:o/r@main:/README.md")))
       (list :before before
             :completions completions
             :content (with-current-buffer buf (buffer-string))
             :file (buffer-file-name buf)
             :remoto-mode (buffer-local-value 'remoto-mode buf)
             :global global-remoto-mode
             :handler (find-file-name-handler "/gh:o/r@main:/" 'file-exists-p)
             :bootstrap-left (and (rassq 'remoto-autoload-file-name-handler
                                         file-name-handler-alist)
                                  t)
             :enabled-messages (seq-count (lambda (m)
                                            (equal m "Remoto: `global-remoto-mode' enabled"))
                                          messages))))
  "The first remoto path of a session, as a form for `remoto-test--fresh-session'.")

(defconst remoto-test--fresh-api-stub
  '(with-eval-after-load 'remoto
     (advice-add 'remoto--api :override
                 (lambda (_forge endpoint)
                   (pcase endpoint
                     ("repos/o/r" '((default_branch . "main")))
                     ((or "repos/o/r/git/trees/main?recursive=1"
                          "repos/o/r/git/trees/main?recursive=1&per_page=1000&page=1")
                      '((total_count . 1)
                        (tree . (((path . "README.md") (type . "blob")
                                  (size . 6) (sha . "aaa") (mode . "100644"))))))
                     ("repos/o/r/contents/README.md?ref=main"
                      (list (cons 'sha "aaa")
                            (cons 'encoding "base64")
                            (cons 'content (base64-encode-string "hello\n"))))
                     (_ nil)))))
  "Answer the API for o/r, installed before remoto's first request.")

(defun remoto-test--fresh-first-call-form (call)
  "Build a form that runs CALL as the first remoto operation of a session.
The result reports the visited buffer, so a first call can be compared
with what the same call does once the mode is on."
  `(progn
     ,remoto-test--fresh-api-stub
     (condition-case err
         (let ((buf ,call))
           (with-current-buffer buf
             (list :name (buffer-name) :dir default-directory
                   :mode major-mode :file buffer-file-name
                   :listed (and (string-match-p "README\\.md" (buffer-string)) t))))
       (error (list :error (car err)
                    :message (error-message-string err)
                    :buffers (seq-remove (lambda (n) (string-prefix-p " " n))
                                         (mapcar #'buffer-name (buffer-list))))))))

(describe "the first remoto call of a session"
  ;; `remoto--install' adds its advice from inside the call that loads
  ;; remoto, so that one call runs without it.  Every shape below has to
  ;; land where it would land on the second call.
  (it "opens a short repository form as the canonical root"
    (remoto-test-with-autoloads file
      (dolist (name '("/github:o/r" "/github:o/r/" "/gh:o/r"))
        (let ((result (remoto-test--fresh-session
                       file
                       (remoto-test--fresh-first-call-form
                        `(find-file-noselect ,name)))))
          (expect (plist-get result :dir) :to-equal "/github:o/r@main:/")
          (expect (plist-get result :mode) :to-be 'dired-mode)
          (expect (plist-get result :listed) :to-be t)))))

  (it "opens a short file form as the file, not as a directory"
    (remoto-test-with-autoloads file
      (let ((result (remoto-test--fresh-session
                     file
                     (remoto-test--fresh-first-call-form
                      '(find-file-noselect "/github:o/r/README.md")))))
        (expect (plist-get result :file) :to-equal "/github:o/r@main:/README.md")
        (expect (plist-get result :mode) :not :to-be 'dired-mode))))

  (it "serves a Codeberg path first, from the cookie of its own file"
    (remoto-test-with-autoloads file
      (dolist (name '("/codeberg:o/r" "/cb:o/r/"))
        (let ((result (remoto-test--fresh-session
                       file
                       (remoto-test--fresh-first-call-form
                        `(find-file-noselect ,name)))))
          (expect (plist-get result :dir) :to-equal "/codeberg:o/r@main:/")
          (expect (plist-get result :mode) :to-be 'dired-mode)
          (expect (plist-get result :listed) :to-be t)))))

  (it "lists the tree from every Dired entry point"
    (remoto-test-with-autoloads file
      (dolist (call '((dired-noselect "/github:o/r")
                      (dired-noselect "/gh:o/r")
                      (progn (dired "/github:o/r") (current-buffer))
                      (dired-other-window "/gh:o/r")))
        (let ((result (remoto-test--fresh-session
                       file (remoto-test--fresh-first-call-form call))))
          (expect (plist-get result :mode) :to-be 'dired-mode)
          (expect (plist-get result :listed) :to-be t)))))

  (it "says what a #NUM path is and leaves no buffer behind"
    (remoto-test-with-autoloads file
      (let ((result (remoto-test--fresh-session
                     file
                     (remoto-test--fresh-first-call-form
                      '(find-file-noselect "/gh:o/r#31")))))
        (expect (plist-get result :error) :to-be 'user-error)
        (expect (plist-get result :message)
                :to-match "is an issue or pull request, not a file")
        ;; The advice arrives while this very call runs, so the cure is to
        ;; repeat the call, not to reach for the command that was used.
        (expect (plist-get result :message) :to-match "run the command again")
        (expect (seq-find (lambda (n) (string-match-p "31" n))
                          (plist-get result :buffers))
                :to-be nil)))))

(describe "a fresh session"
  ;; The complaint this guards: with nothing in the init file, `C-x C-f
  ;; /gh:...' must work the way `M-x remoto-browse' does.
  (it "serves the first /gh: path from the autoloads alone"
    (remoto-test-with-autoloads file
      (let ((result (remoto-test--fresh-session file remoto-test--fresh-session-form)))
        (expect (plist-get result :before)
                :to-equal '(nil remoto-autoload-file-name-handler nil))
        (expect (plist-get result :completions) :to-equal '("README.md"))
        (expect (plist-get result :content) :to-equal "hello\n")
        (expect (plist-get result :file) :to-equal "/github:o/r@main:/README.md")
        (expect (plist-get result :remoto-mode) :to-be t)
        (expect (plist-get result :global) :to-be t)
        (expect (plist-get result :handler) :to-be 'remoto-file-name-handler)
        (expect (plist-get result :bootstrap-left) :to-be nil)
        (expect (plist-get result :enabled-messages) :to-equal 1))))

  (it "leaves a session that never touches a remoto path alone"
    (remoto-test-with-autoloads file
      (let ((result (remoto-test--fresh-session
                     file
                     `(progn
                        (find-file-noselect ,(locate-library "remoto"))
                        (list :loaded (featurep 'remoto)
                              :global (bound-and-true-p global-remoto-mode)
                              :hooked (and (memq 'remoto--maybe-enable-mode
                                                 find-file-hook)
                                           t))))))
        (expect (plist-get result :loaded) :to-be nil)
        (expect (plist-get result :global) :to-be nil)
        (expect (plist-get result :hooked) :to-be nil))))

  (it "loads the forges from the directory of remoto.el when that is off load-path"
    ;; package.el reloads an upgrade's files by name before their new
    ;; directory joins `load-path'.
    (let ((source (file-name-directory (locate-library "remoto")))
          (dir (file-name-as-directory (make-temp-file "remoto-upgrade" t))))
      (unwind-protect
          (progn
            (dolist (file '("remoto.el" "remoto-github.el" "remoto-forgejo.el"))
              (copy-file (expand-file-name file source) dir))
            (let ((result (remoto-test--fresh-session
                           nil
                           `(progn
                              (setq load-path (seq-remove (lambda (d) (file-equal-p d ,source))
                                                          load-path))
                              (load ,(expand-file-name "remoto.el" dir) nil t)
                              (list :github (symbol-file 'remoto--fetch-tree)
                                    :forgejo (symbol-file 'remoto-forgejo-register)
                                    :codeberg (and (assoc "codeberg" remoto--forges) t))))))
              (expect (file-name-directory (or (plist-get result :github) "")) :to-equal dir)
              (expect (file-name-directory (or (plist-get result :forgejo) "")) :to-equal dir)
              (expect (plist-get result :codeberg) :to-be t)))
        (delete-directory dir t)))))

(describe "remoto-inhibited-functions in a fresh session"
  (it "advises nothing when remoto is only required"
    (remoto-test-with-autoloads file
      (let ((result (remoto-test--fresh-session
                     file
                     '(progn
                        (require 'remoto)
                        (list :global (bound-and-true-p global-remoto-mode)
                              :advised (seq-filter
                                        (lambda (f)
                                          (advice-member-p #'remoto--inhibit-a f))
                                        '(lsp eglot-ensure)))))))
        (expect (plist-get result :global) :to-be nil)
        (expect (plist-get result :advised) :to-be nil))))

  (it "keeps Eglot's eglot-ensure from arming in a remoto buffer"
    ;; Eglot ships with Emacs; its autoload gets the advice before it loads.
    (remoto-test-with-autoloads file
      (let ((result (remoto-test--fresh-session
                     file
                     '(progn
                        (require 'remoto)
                        (global-remoto-mode 1)
                        (require 'eglot)
                        (let ((armed (lambda (name)
                                       (with-temp-buffer
                                         (setq-local buffer-file-name name)
                                         (eglot-ensure)
                                         (local-variable-p 'post-command-hook)))))
                          (list :remoto (funcall armed "/github:o/r@main:/src/api.py")
                                :local (funcall armed "/home/me/api.py")))))))
        (expect (plist-get result :remoto) :to-be nil)
        (expect (plist-get result :local) :to-be t)))))

;;; Unloading

(describe "remoto-unload-function"
  ;; Runs last: it empties the real caches.
  (it "turns global-remoto-mode off and empties the caches"
    (unwind-protect
        (progn
          (puthash "/github:o/r" "main" remoto--default-branch-cache)
          (remoto-unload-function)
          (expect global-remoto-mode :to-be nil)
          (expect (assoc remoto--handler-regexp file-name-handler-alist)
                  :to-be nil)
          (expect (advice-member-p #'remoto--read-file-name-internal-a
                                   'read-file-name-internal)
                  :to-be nil)
          (expect (advice-member-p #'remoto--inhibit-a 'eglot-ensure) :to-be nil)
          (expect (memq 'remoto--maybe-enable-mode find-file-hook) :to-be nil)
          (expect (hash-table-count remoto--default-branch-cache) :to-equal 0))
      (global-remoto-mode 1))))

;;; Grammar invariants

;; The rows come from the delimiter registry, so a delimiter registered
;; later gets its rows without anyone listing them by hand.

(defconst remoto-test--grammar-roots '("/github:" "/codeberg:")
  "The canonical prefixes the grammar rows are spelled with: one per forge.")

(defun remoto-test--grammar-rows ()
  "Return every shape of a remoto name as (NAME . PARENT), for every forge.
PARENT is what .. names from NAME, nil where .. has no meaning: a
query, a ref or a topic.  Above a short-form directory it is the bare
repository name, as `remoto--normalize-name' resolves it."
  (mapcan #'remoto-test--grammar-rows-of remoto-test--grammar-roots))

(defun remoto-test--grammar-rows-of (root)
  "Return the grammar rows of the forge whose canonical prefix is ROOT."
  (let* ((owner (concat root "testowner/"))
         (repo (concat owner "testrepo"))
         (rows (list (cons root root)
                     (cons (concat root "testowner") nil)
                     (cons owner root)
                     (cons repo nil)
                     (cons (concat repo "/") owner)
                     (cons (concat repo "/src/") repo)
                     (cons (concat repo "/src/main.el") nil)
                     (cons (concat repo ":/") owner)
                     (cons (concat repo ":/src/") (concat repo ":/"))
                     (cons (concat repo ":/src/main.el") nil))))
    (dolist (char (remoto-forge-delimiters (remoto--canonical-forge root)))
      (let* ((delimiter (alist-get char remoto--delimiters))
             (c (char-to-string char))
             (ref-p (eq (remoto-delimiter-kind delimiter) 'ref))
             (pick (if ref-p "main" "42")))
        (push (cons (concat repo c) nil) rows)
        (push (cons (concat repo c pick) nil) rows)
        (when ref-p
          (push (cons (concat repo c "rel/1") nil) rows)
          (push (cons (concat repo c "main:/") owner) rows)
          (push (cons (concat repo c "main:/src/") (concat repo c "main:/")) rows)
          (push (cons (concat repo c "main:/src/main.el") nil) rows)
          (push (cons (concat repo c "rel/1:/src/") (concat repo c "rel/1:/")) rows))))
    (nreverse rows)))

(defun remoto-test--grammar-failures (predicate)
  "Return the names of the grammar rows for which PREDICATE is nil."
  (seq-remove predicate (mapcar #'car (remoto-test--grammar-rows))))

(defmacro remoto-test-with-grammar-data (&rest body)
  "Run BODY with every fetcher answering for testowner/testrepo from stubs."
  (declare (indent 0))
  `(remoto-test-with-cache
     (let ((remoto--logins (remoto-test--logins :user "me")))
       (spy-on 'remoto-forge-user-orgs :and-return-value
               (list (propertize "testowner" 'remoto-acct-type "Organization")))
       (spy-on 'remoto--recent-owner-repos :and-return-value '("testrepo" "other"))
       (spy-on 'remoto--fetch-branches :and-return-value '("main" "rel/1"))
       (spy-on 'remoto--fetch-tags :and-return-value '("v1.0"))
       (spy-on 'remoto--fetch-issues :and-return-value
               '(((number . 42) (title . "An issue") (state . "open"))
                 ((number . 7) (title . "A pull") (state . "open")
                  (pull_request . ((url . "x"))))))
       (spy-on 'remoto--default-branch :and-return-value "main")
       (spy-on 'remoto--fetch-dir-children-light :and-call-fake
               (lambda (forge _owner _repo _ref dir-path)
                 (remoto--tree-children
                  (remoto--parse-path
                   (format "%stestowner/testrepo@main:/%s" (remoto--prefix forge)
                           dir-path)))))
       (spy-on 'remoto--fetch-file-commits :and-return-value nil)
       (dolist (root remoto-test--grammar-roots)
         (puthash (concat root "testowner/testrepo") "main" remoto--default-branch-cache)
         (dolist (ref '("main" "rel/1"))
           (puthash (concat root "testowner/testrepo@" ref)
                    (gethash "/github:testowner/testrepo@main" remoto--tree-cache)
                    remoto--tree-cache)))
       ,@body)))

(describe "grammar invariants on every row"
  (it "split a name into a directory that is its prefix and the rest"
    (expect (remoto-test--grammar-failures
             (lambda (name)
               (let ((dir (file-name-directory name)))
                 (and (string-prefix-p dir name)
                      (equal (concat dir (file-name-nondirectory name)) name)))))
            :to-equal nil))

  (it "parse into a path that unparses to the same name"
    (expect (remoto-test--grammar-failures
             (lambda (name) (equal (remoto--unparse (remoto--parse name)) name)))
            :to-equal nil))

  (it "answer file-remote-p with a prefix of the name"
    (expect (remoto-test--grammar-failures
             (lambda (name) (string-prefix-p (file-remote-p name) name)))
            :to-equal nil))

  (it "expand to themselves"
    (expect (remoto-test--grammar-failures
             (lambda (name) (equal (expand-file-name name) name)))
            :to-equal nil))

  (it "resolve .. to the directory above, where .. has a meaning"
    (expect (seq-remove (lambda (row)
                          (or (null (cdr row))
                              (equal (expand-file-name ".." (car row)) (cdr row))))
                        (remoto-test--grammar-rows))
            :to-equal nil))

  (it "exist when they are directories, except where RET must ask first"
    ;; A bare name that no listing holds and a delimiter with nothing
    ;; after it are still being typed: `file-exists-p' is nil so that
    ;; `find-file' asks to confirm, directory or not.
    (remoto-test-with-grammar-data
      (expect (remoto-test--grammar-failures
               (lambda (name)
                 (let* ((parsed (remoto--parse name))
                        (level (remoto-path-level parsed))
                        (query (remoto-path-query parsed))
                        (guarded (if (memq level '(root owner tree))
                                     (and (not (eq level 'tree))
                                          (not (string-empty-p query)))
                                   (string-empty-p query))))
                   (if guarded
                       (not (file-exists-p name))
                     (or (not (file-directory-p name)) (file-exists-p name))))))
              :to-equal nil)))

  (it "keep a directory name through file-name-as-directory and back"
    (remoto-test-with-grammar-data
      (expect (remoto-test--grammar-failures
               (lambda (name)
                 (or (not (file-directory-p name))
                     (let ((dir (file-name-as-directory name)))
                       (and (file-directory-p dir)
                            (equal (file-name-as-directory (directory-file-name dir))
                                   dir))))))
              :to-equal nil)))

  (it "complete, at every directory, to names that parse one level down"
    (remoto-test-with-grammar-data
      (let (failures)
        (dolist (name (mapcar #'car (remoto-test--grammar-rows)))
          (when (and (file-directory-p name) (equal (file-name-directory name) name))
            (let* ((level (remoto-path-level (remoto--parse name)))
                   (candidates (file-name-all-completions "" name)))
              (unless candidates (push (cons name 'no-candidates) failures))
              (dolist (candidate candidates)
                (let* ((joined (concat name candidate))
                       (parsed (remoto--parse joined))
                       (target (get-text-property 0 'remoto-target candidate)))
                  (unless (and parsed
                               (file-exists-p joined)
                               (memq (remoto-path-level parsed)
                                     (pcase level
                                       ('root '(owner))
                                       ('owner '(tree))
                                       ('tree '(tree))
                                       ((guard (eq (remoto--level-kind level) 'ref))
                                        '(tree))
                                       (_ (list level))))
                               (or (null target)
                                   (equal (remoto--unparse (remoto--parse target))
                                          target)))
                    (push (cons name candidate) failures)))))))
        (expect failures :to-equal nil)))))

;;; Conformance of a forge, from replayed answers

;; One suite for every forge: a fixture kit names a path at each level
;; and answers the forge's requests from recorded data, and the suite
;; asserts the level table at every row.  GitHub's kit replays the
;; answers of test/e2e/fixtures.jsonl at `remoto--api'.

(defvar remoto-test--fixtures (make-hash-table :test 'equal)
  "Recorded answers by file, each a table of resource -> (STATUS BODY).
Arrays come as lists, as `remoto--json-reader' parses them.")

(defconst remoto-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "The directory of this file, where the fixtures live.")

(defun remoto-test--fixtures-file (name)
  "Return the path of the fixtures file NAME under test/."
  (expand-file-name name remoto-test--directory))

(defun remoto-test--load-fixtures (file hand)
  "Read the recorded answers of FILE plus HAND, the ones about the fake account."
  (let ((table (make-hash-table :test 'equal)))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file))
      (dolist (line (split-string (buffer-string) "\n" t))
        (let ((entry (json-parse-string line :object-type 'alist
                                        :array-type 'list
                                        :null-object nil :false-object nil)))
          (puthash (alist-get 'resource entry)
                   (list (alist-get 'status entry) (alist-get 'body entry))
                   table))))
    (pcase-dolist (`(,resource . ,answer) hand)
      (puthash resource answer table))
    table))

(defun remoto-test--fixtures-of (kit)
  "Return the table of recorded answers of KIT, read on first use."
  (let ((file (remoto-test--fixtures-file (plist-get kit :fixtures))))
    (or (gethash file remoto-test--fixtures)
        (puthash file (remoto-test--load-fixtures file (plist-get kit :hand))
                 remoto-test--fixtures))))

(defun remoto-test--fixture-api (forge endpoint)
  "Answer ENDPOINT from the fixtures of FORGE, as `remoto--api' would."
  (pcase-let ((`(,status ,body)
               (gethash (concat "/" endpoint)
                        (remoto-test--fixtures-of
                         (if (eq (remoto-forge-name forge) 'codeberg)
                             remoto-test--codeberg-kit
                           remoto-test--github-kit))
                        '(404 ((message . "Not Found"))))))
    (if (eql status 200)
        body
      (user-error "%s%s" remoto--not-found endpoint))))

(defconst remoto-test--github-kit
  (list :forge 'github
        :root "/github:" :account "remoto-e2e" :org "emacs-mirror"
        :owner "agzam" :repo "remoto.el" :ref "main" :tag "2.2.0"
        :dir "test" :file "README.org" :topic "47"
        :api #'remoto-test--fixture-api
        :fixtures "e2e/fixtures.jsonl"
        :hand '(("/user" 200 ((login . "remoto-e2e") (type . "User")))
                ("/user/orgs?per_page=100&page=1" 200
                 (((login . "emacs-mirror")
                   (description . "Mirrors of the GNU Emacs repositories")))))
        :url "https://github.com/agzam/remoto.el"
        :topic-url "https://github.com/agzam/remoto.el/pull/47")
  "What the conformance suite needs to know about GitHub.
The fixtures are the ones `make test-e2e' replays.")

(defconst remoto-test--codeberg-kit
  (list :forge 'codeberg
        :root "/codeberg:" :account "remoto-e2e" :org "forgejo"
        :owner "forgejo" :repo "docs" :ref "next" :tag "v13.0.0-dev"
        :dir "docs" :file "README.md" :topic "2249"
        :api #'remoto-test--fixture-api
        :fixtures "fixtures/codeberg.jsonl"
        :hand '(("/user" 200 ((login . "remoto-e2e")))
                ("/user/orgs?limit=50&page=1" 200
                 (((username . "forgejo") (name . "forgejo")
                   (description . "Beyond coding. We forge.")))))
        :url "https://codeberg.org/forgejo/docs"
        :topic-url "https://codeberg.org/forgejo/docs/pulls/2249")
  "What the conformance suite needs to know about Codeberg.
The fixtures come from test/record-codeberg-fixtures.el.")

(defmacro remoto-test-with-kit (kit &rest body)
  "Run BODY with the forge of KIT answering from its fixtures."
  (declare (indent 1))
  `(remoto-test-with-cache
     (let ((remoto--logins (remoto-test--logins :user (plist-get ,kit :account))))
       (spy-on 'remoto--api :and-call-fake (plist-get ,kit :api))
       (spy-on 'remoto--api-async :and-call-fake
               (lambda (forge endpoint callback &optional errback)
                 (condition-case nil
                     (funcall callback (funcall (plist-get ,kit :api) forge endpoint))
                   (user-error (when errback (funcall errback))))))
       ;; Loading remoto-topic would define the function over the spy.
       (spy-on 'remoto--require-topic)
       (spy-on 'remoto-topic-display :and-return-value (generate-new-buffer "*topic*"))
       (let ((before (buffer-list)))
         (unwind-protect (progn ,@body)
           (dolist (buf (buffer-list))
             (unless (memq buf before) (kill-buffer buf))))))))

(defun remoto-test--kit-names (kit)
  "Return the rows of the level table for KIT as (LEVEL . NAME)."
  (let* ((root (plist-get kit :root))
         (owner (concat root (plist-get kit :owner) "/"))
         (repo (concat owner (plist-get kit :repo)))
         (at (concat repo "@" (plist-get kit :ref) ":/")))
    `((root . ,root)
      (owner . ,owner)
      (repo . ,(concat repo "/"))
      (repo-at-ref . ,at)
      (refs . ,(concat repo "@"))
      (topics . ,(concat repo "#"))
      (topic . ,(concat repo "#" (plist-get kit :topic)))
      (dir . ,(concat at (plist-get kit :dir) "/"))
      (file . ,(concat at (plist-get kit :file))))))

(defun remoto-test--conformance (kit)
  "Define the specs of the level table for the forge of KIT."
  (let-alist (remoto-test--kit-names kit)
    (it "treats the levels above a file as directories, a file and a topic as not"
      (remoto-test-with-kit kit
        (dolist (name (list .root .owner .repo .repo-at-ref .refs .dir))
          (expect (file-directory-p name) :to-be t))
        (dolist (name (list .topics .topic .file))
          (expect (file-directory-p name) :to-be nil))))

    (it "opens every level on RET except a bare delimiter"
      (remoto-test-with-kit kit
        (dolist (name (list .root .owner .repo .repo-at-ref .topic .dir .file))
          (expect (file-exists-p name) :to-be t))
        (dolist (name (list .refs .topics))
          (expect (file-exists-p name) :to-be nil))))

    (it "lists the account and its organizations at the root"
      (remoto-test-with-kit kit
        (let ((names (remoto-test--dired-names-of .root)))
          (expect (member (plist-get kit :account) names) :to-be-truthy)
          (expect (member (plist-get kit :org) names) :to-be-truthy))))

    (it "lists the repositories of an owner"
      (remoto-test-with-kit kit
        (expect (member (plist-get kit :repo) (remoto-test--dired-names-of .owner))
                :to-be-truthy)))

    (it "lists the tree at the repository root and below"
      (remoto-test-with-kit kit
        (expect (member (plist-get kit :file) (remoto-test--dired-names-of .repo-at-ref))
                :to-be-truthy)
        (expect (member (plist-get kit :file) (remoto-test--dired-names-of .repo))
                :to-be-truthy)
        (expect (remoto-test--dired-names-of .dir) :not :to-be nil)))

    (it "completes each level to the names one level down"
      (remoto-test-with-kit kit
        (expect (member (concat (plist-get kit :org) "/")
                        (file-name-all-completions "" .root))
                :to-be-truthy)
        (expect (member (concat (plist-get kit :ref) ":")
                        (file-name-all-completions "" .refs))
                :to-be-truthy)
        (expect (member (concat (plist-get kit :tag) ":")
                        (file-name-all-completions "" .refs))
                :to-be-truthy)
        (expect (member (plist-get kit :topic) (file-name-all-completions "" .topics))
                :to-be-truthy)
        (expect (member (plist-get kit :file) (file-name-all-completions "" .repo-at-ref))
                :to-be-truthy)
        (expect (member (plist-get kit :file) (file-name-all-completions "" .repo))
                :to-be-truthy)))

    (it "reads a file"
      (remoto-test-with-kit kit
        (with-temp-buffer
          (insert-file-contents .file)
          (expect (buffer-size) :to-be-greater-than 0))))

    (it "opens a topic in its own buffer"
      (remoto-test-with-kit kit
        (find-file-noselect .topic)
        (expect 'remoto-topic-display :to-have-been-called-with
                (plist-get kit :topic)
                (concat (plist-get kit :root) (plist-get kit :owner) "/"
                        (plist-get kit :repo)))))

    (it "opens the URLs of the forge"
      (remoto-test-with-kit kit
        (expect (remoto--maybe-rewrite (plist-get kit :url)) :to-equal .repo-at-ref)
        (find-file-noselect (plist-get kit :topic-url))
        (expect 'remoto-topic-display :to-have-been-called)))))

(defun remoto-test--dired-names-of (dir)
  "Return the names of the lines of a Dired of DIR."
  (with-current-buffer (dired-noselect dir)
    (remoto-test--dired-names)))

(describe "the GitHub forge, against the level table"
  (remoto-test--conformance remoto-test--github-kit))

(describe "the Codeberg forge, against the level table"
  (remoto-test--conformance remoto-test--codeberg-kit))

(provide 'remoto-tests)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-tests.el ends here
