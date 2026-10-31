;;; remoto-project.el --- project.el backend for remoto repositories -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ag Ibragimov
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Assisted-by: ECA:claude-opus-5
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The autoloads put `remoto-project-try' on `project-find-functions'.
;; project.el asks it about every directory, so it lives apart from
;; remoto.el and loads remoto only for a directory remoto serves.  The
;; project methods and `remoto-project-find-file' live in remoto.el.

;;; Code:

(declare-function remoto--project "remoto")

;;;###autoload
(defun remoto-project-try (dir)
  "Return the remoto project that DIR is in, or nil.
A directory in a repository tree belongs to the tree at its ref, whose
root is /PREFIX:OWNER/REPO@REF:/.  For `project-find-functions'."
  (when (memq (find-file-name-handler dir 'file-exists-p)
              '(remoto-file-name-handler remoto-autoload-file-name-handler))
    (require 'remoto)
    (remoto--project dir)))

;; Ahead of the finders that look for marker files: each file they ask
;; about in a repository tree can cost a request to the forge.
;;;###autoload (with-eval-after-load 'project (add-hook 'project-find-functions #'remoto-project-try -90))

;; Runs once, from the autoloads; the map exists before project.el loads.
;; A key the user bound earlier stays, and a later binding replaces this.
;;;###autoload (when (and (boundp 'project-prefix-map) (not (keymap-lookup project-prefix-map "R"))) (keymap-set project-prefix-map "R" #'remoto-project-find-file))

(provide 'remoto-project)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-project.el ends here
