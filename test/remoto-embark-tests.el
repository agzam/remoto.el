;;; remoto-embark-tests.el --- Embark integration tests -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Tests for remoto-embark.el against a real Embark.  Run via `make test-embark'
;;  (embark is a test-only dependency, not a runtime one).  Kept separate from
;;  remoto-tests.el so the latter can keep verifying the no-embark path: once
;;  Embark is loaded in a process, `featurep' stays t for its lifetime.
;;
;;  These tests use repo-root targets, which classify without any GitHub API
;;  call, so no mock cache is needed.  Directory/file classification and the
;;  file actions are covered (embark-free) in remoto-tests.el; here we verify the
;;  Embark wiring itself: registration, the target finder's shape, and that
;;  actions dispatch with Embark loaded.
;;
;;; Code:

(require 'buttercup)
(require 'embark)
(require 'remoto)
(require 'remoto-embark)

;;; Registration

(describe "remoto-embark registration"
  (it "registers the per-type keymaps in embark-keymap-alist"
    (expect (assoc 'remoto-repo embark-keymap-alist)
            :to-equal '(remoto-repo remoto-embark-repo-map))
    (expect (assoc 'remoto-dir embark-keymap-alist)
            :to-equal '(remoto-dir remoto-embark-dir-map))
    (expect (assoc 'remoto-file embark-keymap-alist)
            :to-equal '(remoto-file remoto-embark-file-map)))

  (it "registers the target finder"
    (expect (and (memq 'remoto--embark-target-finder embark-target-finders) t)
            :to-be t))

  (it "binds open-in-remoto in embark-url-map"
    (expect (lookup-key embark-url-map "R") :to-be 'remoto-embark-open-in-remoto))

  (it "registers the candidate transformer for remoto-repo"
    (let ((fn (alist-get 'remoto-repo embark-transformer-alist)))
      (expect fn :to-be 'remoto--embark-transform)))

  (it "registers the candidate transformer for remoto-file"
    (let ((fn (alist-get 'remoto-file embark-transformer-alist)))
      (expect fn :to-be 'remoto--embark-transform)))

  (it "registers the branch keymap and ref transformer"
    (let ((kmap (assoc 'remoto-branch embark-keymap-alist))
          (fn (alist-get 'remoto-branch embark-transformer-alist)))
      (expect kmap :to-equal '(remoto-branch remoto-embark-branch-map))
      (expect fn :to-be 'remoto--embark-transform-ref)))

  (it "registers the issue keymap and transformer"
    (let ((kmap (assoc 'remoto-issue embark-keymap-alist))
          (fn (alist-get 'remoto-issue embark-transformer-alist)))
      (expect kmap :to-equal '(remoto-issue remoto-embark-issue-map))
      (expect fn :to-be 'remoto--embark-transform-ref)))

  (it "registers the browse-table transformer"
    (let ((fn (alist-get 'remoto-browse embark-transformer-alist)))
      (expect fn :to-be 'remoto--embark-browse-transform))))

;;; Target finder (repo-level: no API/cache needed)

(describe "remoto--embark-target-finder"
  (it "finds a repo target in a Dired buffer at a repo root"
    (with-temp-buffer
      (dired-mode)
      (setq-local dired-directory "/github:o/r:/")
      (spy-on 'dired-get-filename :and-return-value nil)
      (expect (remoto--embark-target-finder)
              :to-equal '(remoto-repo "/github:o/r:/"))))

  (it "returns nil outside remoto buffers"
    (with-temp-buffer
      (setq-local buffer-file-name "/home/me/x.el")
      (expect (remoto--embark-target-finder) :to-be nil))))

;;; Actions (repo-level: no API/cache needed)

(describe "remoto-embark actions"
  (it "copies the repo web URL"
    (remoto-embark-copy-repo-url "/github:o/r:/")
    (expect (car kill-ring) :to-equal "https://github.com/o/r"))

  (it "copies the SSH clone URL"
    (remoto-embark-copy-ssh-url "/github:o/r:/")
    (expect (car kill-ring) :to-equal "git@github.com:o/r.git"))

  (it "copies the HTTPS clone URL"
    (remoto-embark-copy-https-url "/github:o/r:/")
    (expect (car kill-ring) :to-equal "https://github.com/o/r.git"))

  (it "browses the repo web URL"
    (spy-on 'browse-url)
    (remoto-embark-browse-url "/github:o/r:/")
    (expect 'browse-url :to-have-been-called-with "https://github.com/o/r"))

  (it "copies the owner page URL"
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

;;; Embark Collect round-trip (no API/cache needed)

(defun remoto-embark-tests--collect-target (type cand)
  "Build a real Embark Collect buffer for CAND of TYPE; return its target.
Renders CAND through `embark-collect--format-entries' and reads the
candidate at point with `embark-target-collect-candidate', exactly as
`embark-act' does in a collect buffer.  This exercises the real property
round-trip: a bare candidate carrying `remoto-target' must come back out
with that property intact and no live minibuffer."
  (with-temp-buffer
    (embark-collect-mode)
    (setq-local embark--type type)
    (embark-collect--format-entries (list (list cand "" "")) nil)
    (tabulated-list-init-header)
    (tabulated-list-print)
    (goto-char (point-min))
    (let ((btn (or (button-at (point)) (next-button (point)))))
      (goto-char (button-start btn))
      (embark-target-collect-candidate))))

(describe "embark-collect candidate round-trip"
  (it "resolves a browse repo candidate from a collect buffer"
    (let* ((cand (propertize "torvalds/linux"
                             'remoto-target "/github:torvalds/linux:/"))
           (target (remoto-embark-tests--collect-target 'remoto-browse cand))
           (extracted (nth 1 target))
           (rt (and extracted (get-text-property 0 'remoto-target extracted)))
           (xform (remoto--embark-browse-transform (car target) extracted)))
      (expect (car target) :to-be 'remoto-browse)
      (expect rt :to-equal "/github:torvalds/linux:/")
      (expect xform :to-equal '(remoto-repo . "/github:torvalds/linux:/"))))

  (it "resolves a file-name repo candidate from a collect buffer"
    (let* ((cand (propertize "remoto.el/"
                             'remoto-target "/github:agzam/remoto.el:/"))
           (target (remoto-embark-tests--collect-target 'remoto-repo cand))
           (extracted (nth 1 target))
           (rt (and extracted (get-text-property 0 'remoto-target extracted)))
           (xform (remoto--embark-transform (car target) extracted)))
      (expect rt :to-equal "/github:agzam/remoto.el:/")
      (expect xform :to-equal '(remoto-repo . "/github:agzam/remoto.el:/"))))

  (it "resolves an issue candidate from a collect buffer"
    (let* ((cand (propertize "42" 'remoto-target "/github:o/r#42"))
           (target (remoto-embark-tests--collect-target 'remoto-issue cand))
           (extracted (nth 1 target))
           (rt (and extracted (get-text-property 0 'remoto-target extracted)))
           (xform (remoto--embark-transform-ref (car target) extracted)))
      (expect rt :to-equal "/github:o/r#42")
      (expect xform :to-equal '(remoto-issue . "/github:o/r#42"))))

  (it "resolves an owner candidate from a collect buffer"
    (let* ((cand (propertize "torvalds/" 'remoto-target "/github:torvalds"))
           (target (remoto-embark-tests--collect-target 'remoto-owner cand))
           (extracted (nth 1 target))
           (rt (and extracted (get-text-property 0 'remoto-target extracted)))
           (xform (remoto--embark-transform-ref (car target) extracted)))
      (expect (car target) :to-be 'remoto-owner)
      (expect rt :to-equal "/github:torvalds")
      (expect xform :to-equal '(remoto-owner . "/github:torvalds")))))

;;; Keymap bindings (exhaustive)

(describe "remoto-embark keymap bindings"
  (it "binds every documented key in each per-type keymap"
    (dolist (spec `((,remoto-embark-repo-map
                     ("y" . remoto-embark-copy-url)
                     ("b" . remoto-embark-browse-url)
                     ("s" . remoto-embark-copy-ssh-url)
                     ("h" . remoto-embark-copy-https-url)
                     ("H" . remoto-embark-copy-history-url)
                     ("c" . remoto-embark-clone))
                    (,remoto-embark-branch-map
                     ("y" . remoto-embark-copy-branch-url)
                     ("b" . remoto-embark-browse-branch)
                     ("d" . remoto-embark-browse-compare)
                     ("n" . remoto-embark-new-pr))
                    (,remoto-embark-dir-map
                     ("y" . remoto-embark-copy-url)
                     ("b" . remoto-embark-browse-url)
                     ("H" . remoto-embark-copy-history-url))
                    (,remoto-embark-file-map
                     ("y" . remoto-embark-copy-url)
                     ("b" . remoto-embark-browse-url)
                     ("B" . remoto-embark-copy-blame-url)
                     ("P" . remoto-embark-copy-permalink)
                     ("r" . remoto-embark-copy-raw-url)
                     ("H" . remoto-embark-copy-history-url))
                    (,remoto-embark-issue-map
                     ("o" . remoto-embark-open-issue)
                     ("b" . remoto-embark-browse-issue)
                     ("y" . remoto-embark-copy-issue-url)
                     ("d" . remoto-embark-browse-pr-diff)
                     ("R" . remoto-embark-copy-issue-ref))
                    (,remoto-embark-owner-map
                     ("b" . remoto-embark-browse-owner)
                     ("y" . remoto-embark-copy-owner-url)
                     ("r" . remoto-embark-browse-owner-repos))))
      (let ((map (car spec)))
        (dolist (kv (cdr spec))
          (expect (lookup-key map (kbd (car kv))) :to-be (cdr kv)))))))

;;; Target routing / classification

(describe "remoto-embark target routing"
  (it "classifies each target shape to its own type"
    (expect (remoto--embark-classify "/github:o/r:/" 'remoto) :to-be 'remoto-repo)
    (expect (remoto--embark-classify "/github:o/r@main:/" 'remoto) :to-be 'remoto-branch)
    (expect (remoto--embark-classify "/github:o/r#42" 'remoto) :to-be 'remoto-issue)
    (expect (remoto--embark-classify "/github:torvalds" 'remoto) :to-be 'remoto-owner))

  (it "routes a bare owner target to the owner type (the repo-map bug)"
    (expect (remoto--embark-transform 'remoto "/github:torvalds")
            :to-equal '(remoto-owner . "/github:torvalds")))

  (it "routes an owner candidate carrying remoto-target to the owner type"
    (let ((cand (propertize "torvalds/" 'remoto-target "/github:torvalds")))
      (expect (remoto--embark-transform 'remoto-repo cand)
              :to-equal '(remoto-owner . "/github:torvalds")))))

;;; Generic copy/browse on every target kind (regression for forge-nil)

(describe "remoto-embark generic actions on any target kind"
  (it "browses an owner target instead of throwing the forge-nil error"
    (spy-on 'browse-url)
    (remoto-embark-browse-url "/github:torvalds")
    (expect 'browse-url :to-have-been-called-with "https://github.com/torvalds"))

  (it "copies an owner target URL"
    (remoto-embark-copy-url "/github:torvalds")
    (expect (car kill-ring) :to-equal "https://github.com/torvalds"))

  (it "browses an issue target"
    (spy-on 'browse-url)
    (remoto-embark-browse-url "/github:o/r#42")
    (expect 'browse-url :to-have-been-called-with "https://github.com/o/r/issues/42"))

  (it "copies an issue target URL"
    (remoto-embark-copy-url "/github:o/r#42")
    (expect (car kill-ring) :to-equal "https://github.com/o/r/issues/42"))

  (it "browses a repo target"
    (spy-on 'browse-url)
    (remoto-embark-browse-url "/github:o/r:/")
    (expect 'browse-url :to-have-been-called-with "https://github.com/o/r"))

  (it "signals a clear error (not forge-nil) for a repo-only action on an owner"
    (expect (remoto-embark-copy-ssh-url "/github:torvalds") :to-throw 'user-error)))

;;; Per-map functional coverage

(describe "remoto-embark repo + clone actions"
  (it "clones using the configured URL kind"
    (spy-on 'remoto--clone)
    (spy-on 'read-directory-name :and-return-value "/tmp/r/")
    (let ((remoto-clone-url-type 'https))
      (remoto-embark-clone "/github:o/r:/"))
    (expect 'remoto--clone
            :to-have-been-called-with "https://github.com/o/r.git" "/tmp/r/"))

  (it "copies the repo history URL with HEAD when the target has no ref"
    (remoto-embark-copy-history-url "/gh:agzam/mxp")
    (expect (car kill-ring) :to-equal "https://github.com/agzam/mxp/commits/HEAD/")))

(describe "remoto-embark branch actions"
  (it "copies the branch tree URL"
    (remoto-embark-copy-branch-url "/github:o/r@main:/")
    (expect (car kill-ring) :to-equal "https://github.com/o/r/tree/main/"))

  (it "browses the branch tree"
    (spy-on 'browse-url)
    (remoto-embark-browse-branch "/github:o/r@main:/")
    (expect 'browse-url :to-have-been-called-with "https://github.com/o/r/tree/main/"))

  (it "browses the compare view"
    (spy-on 'browse-url)
    (remoto-embark-browse-compare "/github:o/r@main:/")
    (expect 'browse-url :to-have-been-called-with "https://github.com/o/r/compare/main"))

  (it "browses the new-PR page"
    (spy-on 'browse-url)
    (remoto-embark-new-pr "/github:o/r@main:/")
    (expect 'browse-url :to-have-been-called-with "https://github.com/o/r/pull/new/main")))

(describe "remoto-embark directory actions"
  (before-each
    (spy-on 'remoto--path-context :and-return-value
            '(:forge github :owner "o" :repo "r" :ref "main" :path "src"
              :kind tree :type remoto-dir :line-start nil :line-end nil)))

  (it "copies the directory tree URL"
    (remoto-embark-copy-url "/github:o/r@main:/src/")
    (expect (car kill-ring) :to-equal "https://github.com/o/r/tree/main/src"))

  (it "copies the directory history URL"
    (remoto-embark-copy-history-url "/github:o/r@main:/src/")
    (expect (car kill-ring) :to-equal "https://github.com/o/r/commits/main/src")))

(describe "remoto-embark file actions"
  (before-each
    (spy-on 'remoto--path-context :and-return-value
            '(:forge github :owner "o" :repo "r" :ref "main" :path "src/a.el"
              :kind blob :type remoto-file :line-start nil :line-end nil)))

  (it "copies the file blob URL"
    (remoto-embark-copy-url "/github:o/r@main:/src/a.el")
    (expect (car kill-ring) :to-equal "https://github.com/o/r/blob/main/src/a.el"))

  (it "browses the file blob URL"
    (spy-on 'browse-url)
    (remoto-embark-browse-url "/github:o/r@main:/src/a.el")
    (expect 'browse-url
            :to-have-been-called-with "https://github.com/o/r/blob/main/src/a.el"))

  (it "copies the blame URL"
    (remoto-embark-copy-blame-url "/github:o/r@main:/src/a.el")
    (expect (car kill-ring) :to-equal "https://github.com/o/r/blame/main/src/a.el"))

  (it "copies the raw URL"
    (remoto-embark-copy-raw-url "/github:o/r@main:/src/a.el")
    (expect (car kill-ring)
            :to-equal "https://raw.githubusercontent.com/o/r/main/src/a.el"))

  (it "copies the file history URL"
    (remoto-embark-copy-history-url "/github:o/r@main:/src/a.el")
    (expect (car kill-ring) :to-equal "https://github.com/o/r/commits/main/src/a.el"))

  (it "copies a permalink pinned to the commit SHA"
    (spy-on 'remoto--resolve-commit-sha :and-return-value "sha123")
    (remoto-embark-copy-permalink "/github:o/r@main:/src/a.el")
    (expect (car kill-ring) :to-equal "https://github.com/o/r/blob/sha123/src/a.el")))

(describe "remoto-embark issue actions"
  (it "browses the issue page"
    (spy-on 'browse-url)
    (remoto-embark-browse-issue "/github:o/r#42")
    (expect 'browse-url :to-have-been-called-with "https://github.com/o/r/issues/42"))

  (it "copies the issue URL"
    (remoto-embark-copy-issue-url "/github:o/r#42")
    (expect (car kill-ring) :to-equal "https://github.com/o/r/issues/42"))

  (it "browses the PR files-diff page"
    (spy-on 'browse-url)
    (remoto-embark-browse-pr-diff "/github:o/r#42")
    (expect 'browse-url :to-have-been-called-with "https://github.com/o/r/pull/42/files"))

  (it "copies the OWNER/REPO#N reference"
    (remoto-embark-copy-issue-ref "/github:o/r#42")
    (expect (car kill-ring) :to-equal "o/r#42"))

  (it "opens an issue target via find-file"
    (spy-on 'find-file)
    (remoto-embark-open-issue "/github:o/r#42")
    (expect 'find-file :to-have-been-called-with "/github:o/r#42")))

(describe "remoto-embark open-in-remoto (embark-url-map R)"
  (it "opens a forge URL as a remoto path"
    (spy-on 'find-file)
    (remoto-embark-open-in-remoto "https://github.com/o/r")
    (expect 'find-file :to-have-been-called-with "/github:o/r:/")))

;;; Input-form equivalence: /gh:, /github: file-name, and canonical must
;;; all behave identically (regression for the shorthand/file-name hole).

(describe "remoto--embark-canonicalize"
  (it "normalizes shorthand and file-name forms to one canonical path"
    (dolist (pair '(("/gh:agzam/mxp"           . "/github:agzam/mxp:/")
                    ("/gh:agzam/mxp/"          . "/github:agzam/mxp:/")
                    ("/github:agzam/mxp"       . "/github:agzam/mxp:/")
                    ("/github:agzam/mxp/"      . "/github:agzam/mxp:/")
                    ("/github:agzam/mxp:/"     . "/github:agzam/mxp:/")
                    ("/gh:agzam/mxp/src/a.el"  . "/github:agzam/mxp:/src/a.el")
                    ("/github:o/r@dev/sub"     . "/github:o/r@dev:/sub")
                    ("/github:o/r@dev:/sub"    . "/github:o/r@dev:/sub")))
      (expect (remoto--embark-canonicalize (car pair)) :to-equal (cdr pair))))

  (it "leaves owner and issue/PR targets for their own parsers"
    (expect (remoto--embark-canonicalize "/gh:torvalds") :to-equal "/github:torvalds")
    (expect (remoto--embark-canonicalize "/gh:o/r#42") :to-equal "/github:o/r#42"))

  (it "passes non-strings through unchanged"
    (expect (remoto--embark-canonicalize nil) :to-be nil)))

(describe "remoto-embark actions accept every input form"
  (it "browses a repo identically from /gh:, /github: file-name, and canonical"
    (dolist (tgt '("/gh:agzam/mxp" "/gh:agzam/mxp/" "/github:agzam/mxp"
                   "/github:agzam/mxp/" "/github:agzam/mxp:/"))
      (spy-on 'browse-url)
      (remoto-embark-browse-url tgt)
      (expect 'browse-url :to-have-been-called-with "https://github.com/agzam/mxp")))

  (it "copies the repo URL identically across forms"
    (dolist (tgt '("/gh:agzam/mxp" "/github:agzam/mxp/" "/github:agzam/mxp:/"))
      (remoto-embark-copy-url tgt)
      (expect (car kill-ring) :to-equal "https://github.com/agzam/mxp")))

  (it "copies the SSH URL from the shorthand form"
    (remoto-embark-copy-ssh-url "/gh:agzam/mxp")
    (expect (car kill-ring) :to-equal "git@github.com:agzam/mxp.git"))

  (it "clones from the shorthand form"
    (spy-on 'remoto--clone)
    (spy-on 'read-directory-name :and-return-value "/tmp/mxp/")
    (let ((remoto-clone-url-type 'https))
      (remoto-embark-clone "/gh:agzam/mxp"))
    (expect 'remoto--clone
            :to-have-been-called-with "https://github.com/agzam/mxp.git" "/tmp/mxp/"))

  (it "browses an owner and an issue from the shorthand form"
    (spy-on 'browse-url)
    (remoto-embark-browse-url "/gh:torvalds")
    (expect 'browse-url :to-have-been-called-with "https://github.com/torvalds")
    (remoto-embark-browse-issue "/gh:o/r#42")
    (expect 'browse-url :to-have-been-called-with "https://github.com/o/r/issues/42")))

(describe "remoto-embark routing across input forms"
  (it "classifies a repo identically regardless of prefix or form"
    (dolist (tgt '("/gh:agzam/mxp" "/gh:agzam/mxp/" "/github:agzam/mxp"
                   "/github:agzam/mxp/" "/github:agzam/mxp:/"))
      (expect (remoto--embark-classify tgt 'remoto) :to-be 'remoto-repo))
    (expect (remoto--embark-classify "/gh:torvalds" 'remoto) :to-be 'remoto-owner)
    (expect (remoto--embark-classify "/gh:o/r#42" 'remoto) :to-be 'remoto-issue)
    (expect (remoto--embark-classify "/gh:o/r@main:/" 'remoto) :to-be 'remoto-branch))

  (it "transforms a /gh: or file-name candidate into a canonical repo target"
    (expect (remoto--embark-transform 'remoto "/gh:agzam/mxp/")
            :to-equal '(remoto-repo . "/github:agzam/mxp:/"))
    (expect (remoto--embark-transform 'remoto-repo "/github:agzam/mxp")
            :to-equal '(remoto-repo . "/github:agzam/mxp:/")))

  (it "resolves a candidate's remoto-target property then canonicalizes"
    (let ((cand (propertize "mxp/" 'remoto-target "/gh:agzam/mxp/")))
      (expect (remoto--embark-transform 'remoto-repo cand)
              :to-equal '(remoto-repo . "/github:agzam/mxp:/")))))

(provide 'remoto-embark-tests)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-embark-tests.el ends here
