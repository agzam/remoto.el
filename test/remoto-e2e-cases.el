;;; remoto-e2e-cases.el --- The E2E cases and completion profiles -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  What a person types, and under which completion setup, shared by the
;;  replay suite (remoto-e2e.el) and the terminal runs (remoto-keys.el).
;;  Loading it changes nothing; `remoto-e2e-setup' turns a profile on.
;;
;;; Code:

(require 'cl-lib)
(require 'dired)

(declare-function remoto-embark-register "remoto-embark")

(defconst remoto-e2e-profiles '("vanilla" "fido" "vertico" "orderless" "evil" "embark")
  "The completion setups the cases run under.")

(defconst remoto-e2e--only (getenv "REMOTO_E2E_ONLY")
  "A regexp: when set, only the cases whose name matches it run.")

(defconst remoto-e2e--submit
  '(("vanilla" . "RET") ("fido" . "M-j") ("vertico" . "M-RET")
    ("orderless" . "M-RET") ("evil" . "RET") ("embark" . "M-RET"))
  "Per profile, the key that submits a file prompt as typed.")

(defun remoto-e2e-setup (profile)
  "Turn on the completion setup of PROFILE, one of `remoto-e2e-profiles'."
  (pcase profile
    ("vanilla")
    ("fido"
     (fido-vertical-mode 1)
     ;; Icomplete leaves alone a minibuffer that a keyboard macro opens.
     (advice-add 'icomplete-simple-completing-p :around
                 (lambda (fn) (let ((executing-kbd-macro nil)) (funcall fn)))))
    ("vertico" (require 'vertico) (vertico-mode 1))
    ("orderless"
     (require 'vertico) (require 'orderless) (vertico-mode 1)
     (setq completion-styles '(orderless basic)
           completion-category-overrides '((file (styles partial-completion)))))
    ("evil" (require 'evil) (evil-mode 1))
    ("embark"
     (require 'vertico) (require 'orderless) (require 'marginalia)
     (require 'embark) (require 'remoto-embark)
     (vertico-mode 1) (marginalia-mode 1)
     (setq completion-styles '(orderless basic))
     (remoto-embark-register)
     (keymap-global-set "C-c a" #'embark-act)
     (keymap-set minibuffer-local-map "C-c a" #'embark-act))
    (other (error "Unknown profile %s" other))))

;;; What a case looks at

(defun remoto-e2e--completions ()
  "Return the candidates on display in the *Completions* buffer."
  (when-let* ((buffer (get-buffer "*Completions*")))
    (with-current-buffer buffer
      (let ((pos (point-min)) candidates)
        (while (setq pos (next-single-property-change pos 'completion--string))
          (when-let* ((candidate (get-text-property pos 'completion--string)))
            (push (substring-no-properties candidate) candidates)))
        (delete-dups (nreverse candidates))))))

(defun remoto-e2e--line-name ()
  "Return the name on the current Dired line, or nil."
  (and (dired-move-to-filename) (dired-get-filename 'verbatim t)))

(defun remoto-e2e--dired-names ()
  "Return the names on the lines of the current Dired buffer."
  (save-excursion
    (goto-char (point-min))
    (let (names)
      (while (not (eobp))
        (when-let* ((name (remoto-e2e--line-name)))
          (push name names))
        (forward-line 1))
      (nreverse names))))

(defun remoto-e2e-goto (name)
  "Move to the Dired line of NAME, as a person would look for it."
  (interactive "sLine: ")
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal name (remoto-e2e--line-name))))
    (forward-line 1))
  (when (eobp)
    (user-error "No line %s" name)))

(defun remoto-e2e--diff (expected actual)
  "Return the keys whose values differ between plists EXPECTED and ACTUAL."
  (cl-loop for key in (delete-dups (append (cl-loop for (k) on expected by #'cddr
                                                    collect k)
                                           (cl-loop for (k) on actual by #'cddr
                                                    collect k)))
           unless (equal (plist-get expected key) (plist-get actual key))
           collect (list key :expected (plist-get expected key)
                         :actual (plist-get actual key))))

;;; Cases

(defconst remoto-e2e--names
  '("/gh:" "/github:" "/gh:agzam" "/gh:qlik" "/gh:agzam/"
    "/gh:agzam/remoto.el" "/gh:agzam/remoto" "/gh:agzam/remoto.el/"
    "/gh:agzam/remoto.el/README.org" "/gh:agzam/remoto.el/READ"
    "/gh:agzam/remoto.el/nope.txt" "/gh:agzam/remoto.el@"
    "/gh:agzam/remoto.el@ma" "/gh:agzam/remoto.el@main"
    "/gh:agzam/remoto.el@main:" "/gh:agzam/remoto.el@main:/test/"
    "/gh:agzam/remoto.el@main:/test" "/gh:agzam/remoto.el@main:/test/remo"
    "/gh:agzam/remoto.el@2.2.0:/" "/gh:agzam/remoto.el@2.2"
    "/gh:agzam/remoto.el@ceaf310:/" "/gh:agzam/remoto.el#47"
    "/gh:agzam/.." "/gh:agzam/remoto.el/.." "/gh:agzam/remoto.el@main:/test/.."
    "/gh:agzam/.emacs.d" "/gh:agzam/.doom" "/gh:Agzam/Remoto.el"
    "/gh:agzam/remoto el" "/gh:no-such-owner-zz9q/" "/gh:no-such-owner-zz9q"
    "/gh:no-such-owner-zz9q/repo" "/gh:agzam/zzqqxx" "/gh:agzam/remoto.el@zzqq"
    "https://github.com/agzam/remoto.el")
  "Names typed at a file prompt: every level of a remoto name, and mistakes.")

(defconst remoto-e2e--tab-names
  '("/gh:" "/gh:agz" "/gh:agzam/" "/gh:agzam/rem" "/gh:agzam/remoto.el/"
    "/gh:agzam/remoto.el/RE" "/gh:agzam/remoto.el@" "/gh:agzam/remoto.el@ma"
    "/gh:agzam/remoto.el@main:/te" "/gh:agzam/remoto.el#")
  "Names completed with TAB after a pause, one or two per level.")

(defun remoto-e2e--matrix (profile)
  "Return the cases that open each name with each command of PROFILE."
  (cl-loop for (command . keys) in (if (equal profile "evil")
                                       '(("ex" . ": e SPC"))
                                     '(("ff" . "C-x C-f") ("dired" . "C-x d")))
           nconc (cl-loop for name in remoto-e2e--names
                          collect `(,(concat command " " name) nil
                                    ,(kbd keys) ,name submit))))

(defun remoto-e2e--tab-cases ()
  "Return the cases that complete a name with TAB."
  (mapcar (lambda (name)
            `(,(concat "tab " name) nil ,(kbd "C-x C-f") ,name pause ,(kbd "TAB")))
          remoto-e2e--tab-names))

(defun remoto-e2e--in (dir &rest keys)
  "Return the keys that open DIR in Dired, then KEYS."
  `(,(kbd "C-x d") ,dir submit ,@keys))

(defun remoto-e2e--dired-cases ()
  "Return the cases of Dired operations in remoto's listings."
  (let ((ret (kbd "RET")))
    `(("dired RET on a repository line" nil
       ,@(remoto-e2e--in "/gh:agzam/" 'goto "remoto.el" ret ret))
      ("dired RET on an account line" nil
       ,@(remoto-e2e--in "/gh:" 'goto "emacs-mirror" ret ret))
      ("dired RET on a ref line" nil
       ,@(remoto-e2e--in "/gh:agzam/remoto.el@" 'goto "main" ret ret))
      ("dired RET on a file line" nil
       ,@(remoto-e2e--in "/gh:agzam/remoto.el/" 'goto "README.org" ret ret))
      ("dired RET on a match line" nil
       ,@(remoto-e2e--in "/gh:agzam/remoto" 'goto "remoto.el" ret ret))
      ("dired RET on .. at a repository root" nil
       ,@(remoto-e2e--in "/gh:agzam/remoto.el/" 'goto ".." ret ret))
      ("dired ^ in an owner listing" nil ,@(remoto-e2e--in "/gh:agzam/" "^"))
      ("dired ^ at a repository root" nil
       ,@(remoto-e2e--in "/gh:agzam/remoto.el/" "^"))
      ("dired g in an owner listing" nil ,@(remoto-e2e--in "/gh:agzam/" "g"))
      ("dired s in an owner listing" nil ,@(remoto-e2e--in "/gh:agzam/" "s"))
      ("dired ( in an owner listing" nil ,@(remoto-e2e--in "/gh:agzam/" "("))
      ("dired i on a repository line" nil
       ,@(remoto-e2e--in "/gh:agzam/" 'goto "remoto.el" ret "i"))
      ("dired + in an owner listing" nil
       ,@(remoto-e2e--in "/gh:agzam/" "+" "foo" ret))
      ("dired D on a repository line" nil
       ,@(remoto-e2e--in "/gh:agzam/" 'goto "remoto.el" ret "D" "yes" ret))
      ("dired R on a repository line" nil
       ,@(remoto-e2e--in "/gh:agzam/" 'goto "remoto.el" ret "R" "renamed" ret))
      ("dired remoto-refresh in an owner listing" nil
       ,@(remoto-e2e--in "/gh:agzam/" (kbd "M-x") "remoto-refresh" ret))
      ("dired remoto-refresh in a Dired of refs" nil
       ,@(remoto-e2e--in "/gh:agzam/remoto.el@" (kbd "M-x") "remoto-refresh" ret))
      ("dired owner listing whose pages outlast its cache"
       ((remoto-repo-cache-ttl . 0.05) (remoto-e2e-answer-delay . 0.1))
       ,@(remoto-e2e--in "/gh:agzam/")))))

(defun remoto-e2e--embark-cases ()
  "Return the cases of Embark actions on remoto targets."
  (let ((ret (kbd "RET"))
        (act (kbd "C-c a")))
    `(("embark y on a repository line" nil
       ,@(remoto-e2e--in "/gh:agzam/" 'goto "remoto.el" ret act "y"))
      ("embark b on a repository line" nil
       ,@(remoto-e2e--in "/gh:agzam/" 'goto "remoto.el" ret act "b"))
      ("embark y on an account line" nil
       ,@(remoto-e2e--in "/gh:agzam" 'goto "agzam" ret act "y"))
      ("embark y on a ref line" nil
       ,@(remoto-e2e--in "/gh:agzam/remoto.el@" 'goto "main" ret act "y"))
      ("embark y on a file line" nil
       ,@(remoto-e2e--in "/gh:agzam/remoto.el/" 'goto "README.org" ret act "y"))
      ("embark y on a file candidate" nil
       ,(kbd "C-x C-f") "/gh:agzam/remoto.el@main:/test/" ,act "y")
      ("embark y on an issue candidate" nil
       ,(kbd "C-x C-f") "/gh:agzam/remoto.el#" ,act "y"))))

(defun remoto-e2e--cases (profile)
  "Return the cases of PROFILE, each (NAME BINDINGS . KEYS)."
  (seq-filter (lambda (case)
                (or (not remoto-e2e--only)
                    (string-match-p remoto-e2e--only (car case))))
              (append (remoto-e2e--matrix profile)
                      (pcase profile
                        ("vanilla" (append (remoto-e2e--tab-cases)
                                           (remoto-e2e--dired-cases)))
                        ("embark" (remoto-e2e--embark-cases))))))

(provide 'remoto-e2e-cases)
;;; remoto-e2e-cases.el ends here
