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

(defconst remoto-e2e-live-profiles
  (append remoto-e2e-profiles '("ido" "evil-vertico" "full"))
  "The setups of the terminal runs: the replay suite's and three without golden files.")

(defconst remoto-e2e--only (getenv "REMOTO_E2E_ONLY")
  "A regexp: when set, only the cases whose name matches it run.")

(defun remoto-e2e--selected (cases)
  "Return the CASES whose name `remoto-e2e--only' matches, letter case counting."
  (let ((case-fold-search nil))
    (seq-filter (lambda (case)
                  (or (not remoto-e2e--only)
                      (string-match-p remoto-e2e--only (car case))))
                cases)))

(defconst remoto-e2e--submit
  '(("vanilla" . "RET") ("fido" . "M-j") ("vertico" . "M-RET")
    ("orderless" . "M-RET") ("evil" . "RET") ("embark" . "M-RET")
    ("ido" . "C-j") ("evil-vertico" . "M-RET") ("full" . "M-RET"))
  "Per profile, the key that submits a file prompt as typed.")

(defun remoto-e2e-setup (profile)
  "Turn on the completion setup of PROFILE, one of `remoto-e2e-live-profiles'."
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
     (remoto-e2e--embark-keys))
    ("ido" (ido-mode 1) (setq ido-enable-flex-matching t))
    ("evil-vertico"
     (require 'evil) (evil-mode 1)
     (require 'vertico) (require 'orderless) (vertico-mode 1)
     (setq completion-styles '(orderless basic)))
    ("full"
     (require 'evil) (evil-mode 1)
     (require 'vertico) (require 'vertico-directory) (require 'orderless)
     (require 'marginalia) (require 'consult)
     (require 'embark) (require 'embark-consult) (require 'remoto-embark)
     (vertico-mode 1) (marginalia-mode 1)
     (add-hook 'rfn-eshadow-update-overlay-hook #'vertico-directory-tidy)
     (setq completion-styles '(orderless partial-completion basic)
           completion-category-overrides '((file (styles partial-completion))))
     (remoto-embark-register)
     (remoto-e2e--embark-keys))
    (other (error "Unknown profile %s" other))))

(defun remoto-e2e--embark-keys ()
  "Bind Embark's act, collect and export where the cases type them."
  (keymap-global-set "C-c a" #'embark-act)
  (keymap-set minibuffer-local-map "C-c a" #'embark-act)
  (keymap-set minibuffer-local-map "C-c c" #'embark-collect)
  (keymap-set minibuffer-local-map "C-c e" #'embark-export))

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

(defun remoto-e2e--buffer-names ()
  "Return the names a Dired or an Embark Collect buffer lists, or nil."
  (cond ((derived-mode-p 'dired-mode) (remoto-e2e--dired-names))
        ((derived-mode-p 'embark-collect-mode)
         ;; Group titles are entries too, without an id.
         (mapcar #'substring-no-properties (delq nil (mapcar #'car tabulated-list-entries))))))

(defun remoto-e2e--stray-lines ()
  "Return the lines of the current Dired buffer that are neither header nor entry."
  (save-excursion
    (goto-char (point-min))
    (let (stray)
      (while (not (eobp))
        (unless (or (save-excursion (dired-move-to-filename))
                    (looking-at-p "^  \\(?:/\\|total \\|wildcard \\)\\|^[ \t]*$"))
          (push (buffer-substring-no-properties (point) (line-end-position)) stray))
        (forward-line 1))
      (nreverse stray))))

(defun remoto-e2e--odd-char ()
  "Return the first visible control character or raw byte as (LINE . CHAR), or nil.
Dired writes a carriage return as \\015 and a backslash as \\\\, so an
undoubled \\015 there is a carriage return too."
  (save-excursion
    (goto-char (point-min))
    (catch 'found
      ;; In a multibyte buffer \200-\377 matches the raw bytes only.
      (while (re-search-forward "[\0-\11\13-\37\177\200-\377]" nil t)
        (unless (invisible-p (1- (point)))
          (throw 'found (cons (line-number-at-pos) (char-before)))))
      (goto-char (point-min))
      (and (derived-mode-p 'dired-mode)
           (re-search-forward "\\(?:^\\|[^\\]\\)\\(?:\\\\\\\\\\)*\\\\015" nil t)
           (cons (line-number-at-pos) ?\r)))))

(defun remoto-e2e--annotation-start ()
  "Return the start of the annotation on the current Embark Collect line, or nil."
  (let ((pos (line-beginning-position)) (eol (line-end-position)) start)
    (while (and (not start) (< pos eol))
      ;; `text-property-any' compares with `eq', and column names are strings.
      (if (equal (get-text-property pos 'tabulated-list-column-name) "Annotation")
          (setq start pos)
        (setq pos (next-single-property-change pos 'tabulated-list-column-name nil eol))))
    (when start
      (save-excursion
        (goto-char start)
        (skip-chars-forward " " eol)
        (and (< (point) eol) (point))))))

(defun remoto-e2e--embark-problems ()
  "Return what is wrong with the entry lines of the current Embark Collect buffer.
Each entry takes one line.  On a display the annotations of the lines in
the window start at one column; batch Emacs has no columns to compare."
  (let ((window (get-buffer-window (current-buffer)))
        (lines (count-lines (point-min) (point-max)))
        (entries (length tabulated-list-entries))
        problems columns)
    (unless (= lines entries)
      (push (format "%d lines for %d entries" lines entries) problems))
    (when (and window (not noninteractive))
      (save-excursion
        (goto-char (window-start window))
        (while (< (point) (window-end window t))
          (when-let* ((text (remoto-e2e--annotation-start))
                      (posn (posn-at-point text window)))
            (push (car (posn-col-row posn)) columns))
          (forward-line 1)))
      (when (cdr (delete-dups columns))
        (push (format "annotations start at columns %S" (sort columns #'<)) problems)))
    problems))

(defun remoto-e2e--buffer-problems ()
  "Return what is wrong with the lines of the current Dired or Embark buffer.
Each line is a header or an entry, no visible character is a control
character or a raw byte, and Embark's annotations line up."
  (when (or (derived-mode-p 'dired-mode) (derived-mode-p 'embark-collect-mode))
    (append (when-let* ((odd (remoto-e2e--odd-char)))
              (list (format "line %d holds U+%04X" (car odd) (cdr odd))))
            (if (derived-mode-p 'dired-mode)
                (mapcar (lambda (line)
                          (concat "not an entry: "
                                  (replace-regexp-in-string
                                   "[\0-\37\177]" "?" (truncate-string-to-width line 50))))
                        (seq-take (remoto-e2e--stray-lines) 2))
              (remoto-e2e--embark-problems)))))

(defun remoto-e2e-goto (name)
  "Move to the Dired line of NAME, as a person would look for it."
  (interactive "sLine: ")
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal name (remoto-e2e--line-name))))
    (forward-line 1))
  (when (eobp)
    (user-error "No line %s" name)))

(defun remoto-e2e--read-states (file)
  "Return the states in FILE, an alist by case name."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let (states)
        (condition-case nil
            (while t (push (read (current-buffer)) states))
          (end-of-file nil))
        (nreverse states)))))

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

(defconst remoto-e2e--codeberg-names
  '("/cb:forgejo/docs" "/cb:" "/codeberg:" "/cb:forgejo" "/cb:forg" "/cb:forgejo/" "/cb:dnkl/"
    "/cb:forgejo/do" "/cb:forgejo/docs/"
    "/cb:forgejo/docs/README.md" "/cb:forgejo/docs/READ" "/cb:forgejo/docs/nope.txt"
    "/cb:forgejo/docs@" "/cb:forgejo/docs@v1" "/cb:forgejo/docs@next"
    "/cb:forgejo/docs@next:" "/cb:forgejo/docs@next:/docs/" "/cb:forgejo/docs@next:/docs"
    "/cb:forgejo/docs@next:/docs/adm" "/cb:forgejo/docs@v15.0:/" "/cb:forgejo/docs@65faeb1:/"
    "/cb:forgejo/forgejo@v15.0/forgejo:/" "/cb:forgejo/forgejo@v15.0/forgejo"
    "/cb:forgejo/forgejo@v17.0.0:/" "/cb:forgejo/forgejo#14989" "/cb:forgejo/forgejo#14991"
    "/cb:forgejo/.." "/cb:forgejo/docs/.." "/cb:forgejo/docs@next:/docs/.."
    "/cb:Forgejo/Docs" "/cb:forgejo/ru" "/cb:no-such-owner-zz9q/" "/cb:no-such-owner-zz9q"
    "/cb:no-such-owner-zz9q/repo" "/cb:forgejo/zzqqxx" "/cb:forgejo/docs@zzqq"
    "https://codeberg.org/forgejo/docs"
    "https://codeberg.org/forgejo/docs/src/branch/next/README.md"
    "https://codeberg.org/forgejo/forgejo/src/branch/v15.0/forgejo/go.mod"
    "https://codeberg.org/forgejo/forgejo/src/tag/v17.0.0/README.md"
    "https://codeberg.org/forgejo/docs/src/commit/65faeb1c07bbc43cbc3ac32aef19a7671500dd78/README.md"
    "https://codeberg.org/forgejo/forgejo/pulls/14989"
    "https://codeberg.org/forgejo/forgejo/issues/14991"
    "git@codeberg.org:forgejo/docs.git" "codeberg.org/forgejo/docs"
    "/cb:Freeyourgadget/Gadgetbridge" "/gh:Freeyourgadget/Gadgetbridge" "/cb:technomancy/")
  "Names typed against Codeberg, live only: no recorded answers replay them.
The account root comes after a repository: as the first Codeberg request
of a session it asks /user anonymously and url.el prompts for a password.")

(defun remoto-e2e--commands (profile)
  "Return the commands of PROFILE that open a name, each (LABEL . KEYS)."
  (pcase profile
    ("evil" '(("ex" . ": e SPC")))
    ((or "evil-vertico" "full") '(("ff" . "C-x C-f") ("dired" . "C-x d") ("ex" . ": e SPC")))
    (_ '(("ff" . "C-x C-f") ("dired" . "C-x d")))))

(defun remoto-e2e--open-cases (profile names)
  "Return the cases that open each of NAMES with each command of PROFILE.
An ex command line ends with RET whatever completes the file prompts."
  (cl-loop for (command . keys) in (remoto-e2e--commands profile)
           nconc (cl-loop for name in names
                          collect `(,(concat command " " name) nil
                                    ,(kbd keys) ,name
                                    ,(if (equal command "ex") (kbd "RET") 'submit)))))

(defun remoto-e2e--matrix (profile)
  "Return the cases that open each name with each command of PROFILE."
  (remoto-e2e--open-cases profile remoto-e2e--names))

(defun remoto-e2e--codeberg-cases (profile)
  "Return the Codeberg cases of PROFILE, with `remoto-e2e--only' applied."
  (remoto-e2e--selected
   (append (remoto-e2e--open-cases profile remoto-e2e--codeberg-names)
           (and (member profile '("embark" "full"))
                ;; technomancy/sokobelt's description spans lines.
                (remoto-e2e--embark-buffer-cases
                 '("/cb:technomancy/" "/cb:forgejo/forgejo#" "/cb:forgejo/docs@next:/docs/"))))))

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
       ,(kbd "C-x C-f") "/gh:agzam/remoto.el#" ,act "y")
      ,@(remoto-e2e--embark-buffer-cases
         '("/gh:agzam/" "/gh:agzam/remoto.el#" "/gh:agzam/remoto.el@main:/test/")))))

(defun remoto-e2e--embark-buffer-cases (names)
  "Return the cases that collect, and export, the candidates at each of NAMES."
  (cl-loop for name in names
           nconc (cl-loop for (command . key) in '(("collect" . "C-c c") ("export" . "C-c e"))
                          collect `(,(format "embark %s at %s" command name) nil
                                    ,(kbd "C-x C-f") ,name pause ,(kbd key)))))

(defun remoto-e2e--cases (profile)
  "Return the cases of PROFILE, each (NAME BINDINGS . KEYS)."
  (remoto-e2e--selected
   (append (remoto-e2e--matrix profile)
           (pcase profile
             ("vanilla" (append (remoto-e2e--tab-cases)
                                (remoto-e2e--dired-cases)))
             ((or "embark" "full") (remoto-e2e--embark-cases))))))

(provide 'remoto-e2e-cases)
;;; remoto-e2e-cases.el ends here
