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
            :to-be t)))

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
    (expect 'browse-url :to-have-been-called-with "https://github.com/o/r")))

(provide 'remoto-embark-tests)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-embark-tests.el ends here
