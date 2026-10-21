;;; remoto-e2e.el --- Keystroke E2E of remoto against recorded GitHub answers -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Types names and keys into the real commands with `execute-kbd-macro' in
;;  batch Emacs, answers `ghub-get' from test/e2e/fixtures.jsonl, and compares
;;  where each case ends with test/e2e/expected.  The test-e2e targets of the
;;  Makefile run it; REMOTO_E2E_PROFILE picks the completion setup.
;;
;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'ghub)
(require 'remoto)

(defconst remoto-e2e--dir
  (expand-file-name "e2e/" (file-name-directory (or load-file-name
                                                    buffer-file-name)))
  "Where the fixtures and the expected states live.")

(defconst remoto-e2e-profile (or (getenv "REMOTO_E2E_PROFILE") "vanilla")
  "The completion setup the cases run under.")

(defconst remoto-e2e--update (getenv "REMOTO_E2E_UPDATE")
  "Non-nil to write the expected states instead of comparing with them.")

(defconst remoto-e2e--token (getenv "REMOTO_E2E_TOKEN")
  "A GitHub token.  With one, answers the fixtures lack come from GitHub.")

(defconst remoto-e2e--only (getenv "REMOTO_E2E_ONLY")
  "A regexp: when set, only the cases whose name matches it run.")

;;; Fake GitHub

(defconst remoto-e2e--account "remoto-e2e"
  "The account of the fake token, one that GitHub does not have.")

(defun remoto-e2e--repo (name description &rest fields)
  "Return a repository of the fake account, NAME, as a list endpoint sends it.
DESCRIPTION and FIELDS, an alist, override the fields of a plain one."
  (append fields
          `((name . ,name) (full_name . ,(concat remoto-e2e--account "/" name))
            (description . ,description) (private . :false)
            (archived . :false) (fork . :false) (size . 20)
            (pushed_at . "2026-09-01T10:00:00Z") (default_branch . "main"))))

(defun remoto-e2e--hand-fixtures ()
  "Return the answers about the fake account, which no recording can give."
  `(("/user" 200 ((login . ,remoto-e2e--account) (type . "User")))
    ("/user/orgs?per_page=100&page=1" 200
     [((login . "emacs-mirror")
       (description . "Mirrors of the GNU Emacs repositories"))])
    ("/user/repos?affiliation=owner&sort=pushed&per_page=100&page=1" 200
     [,(remoto-e2e--repo "notes" "Private notes" '(private . t))
      ,(remoto-e2e--repo "old-config" "Retired" '(archived . t))
      ,(remoto-e2e--repo "magit" "It's Magit! A Git porcelain inside Emacs"
                         '(fork . t))])))

(defconst remoto-e2e--fixtures-file
  (expand-file-name "fixtures.jsonl" remoto-e2e--dir)
  "GitHub's recorded answers, one JSON object a line.")

(defvar remoto-e2e--fixtures (make-hash-table :test 'equal)
  "GitHub's answers by resource, each (CODE BODY), BODY parsed JSON.")

(defvar remoto-e2e--recorded nil
  "Non-nil once this run recorded an answer.")

(defun remoto-e2e--parse (text)
  "Parse the JSON TEXT the way the fixtures keep it."
  (json-parse-string text :object-type 'alist :array-type 'array
                     :null-object :null :false-object :false))

(defun remoto-e2e--load-fixtures ()
  "Read the recorded and the hand-written answers."
  (when (file-exists-p remoto-e2e--fixtures-file)
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents remoto-e2e--fixtures-file))
      (dolist (line (split-string (buffer-string) "\n" t))
        (let ((entry (remoto-e2e--parse line)))
          (puthash (alist-get 'resource entry)
                   (list (alist-get 'status entry) (alist-get 'body entry))
                   remoto-e2e--fixtures)))))
  (pcase-dolist (`(,resource . ,answer) (remoto-e2e--hand-fixtures))
    (puthash resource answer remoto-e2e--fixtures)))

(defun remoto-e2e--save-fixtures ()
  "Write the recorded answers, sorted by resource."
  (let ((hand (mapcar #'car (remoto-e2e--hand-fixtures)))
        lines)
    (maphash (lambda (resource answer)
               (unless (member resource hand)
                 (push (cons resource
                             (remoto-e2e--json
                              `((resource . ,resource) (status . ,(car answer))
                                (body . ,(cadr answer)))))
                       lines)))
             remoto-e2e--fixtures)
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file remoto-e2e--fixtures-file
        (dolist (line (sort lines (lambda (a b) (string< (car a) (car b)))))
          (insert (cdr line) "\n"))))))

(defun remoto-e2e--json (value)
  "Return VALUE as JSON text in UTF-8 bytes, the way GitHub sends it."
  (let ((text (json-serialize value)))
    (if (multibyte-string-p text) (encode-coding-string text 'utf-8) text)))

;;;; Recording

(defconst remoto-e2e--kept-keys
  '(additions archived base body changed_files commit content created_at
    default_branch deletions description draft encoding fork full_name head
    incomplete_results items labels line login merged mergeable_state message
    mode name number path private pull_request pushed_at ref sha size state
    title total_count tree truncated type user)
  "The keys of GitHub's answers that remoto reads.  A recording drops the rest.")

(defun remoto-e2e--private-p (value)
  "Return non-nil when VALUE, parsed JSON, is a private repository."
  (and (consp value) (consp (car value)) (eq t (alist-get 'private value))))

(defun remoto-e2e--trim (value)
  "Return VALUE, parsed JSON, without private repositories and unread keys.
An issue's `pull_request' stays whole: remoto only asks whether it is there."
  (cond ((vectorp value)
         (vconcat (delq nil (mapcar (lambda (item)
                                      (unless (remoto-e2e--private-p item)
                                        (remoto-e2e--trim item)))
                                    value))))
        ((and (consp value) (consp (car value)) (symbolp (caar value)))
         (cl-loop for (key . val) in value
                  when (memq key remoto-e2e--kept-keys)
                  collect (cons key (if (eq key 'pull_request)
                                        val
                                      (remoto-e2e--trim val)))))
        (t value)))

(defun remoto-e2e--read-raw (_status)
  "Parse the body of a GitHub answer in the current buffer, or return nil."
  (goto-char (point-min))
  (when (re-search-forward "[{[]" nil t)
    (condition-case nil
        (remoto-e2e--parse (decode-coding-string
                            (buffer-substring-no-properties (1- (point))
                                                            (point-max))
                            'utf-8))
      (json-error nil))))

(defun remoto-e2e--pace (ghub-get)
  "Wait while GitHub's search budget is spent, asking with GHUB-GET."
  (let* ((limit (alist-get 'search (alist-get 'resources
                                              (funcall ghub-get "/rate_limit" nil
                                                       :auth remoto-e2e--token
                                                       :host "api.github.com"
                                                       :reader #'remoto-e2e--read-raw))))
         (wait (- (alist-get 'reset limit) (float-time) -1)))
    (when (and (< (alist-get 'remaining limit) 2) (< 0 wait))
      (princ (format "search budget spent, waiting %d s\n" wait)
             #'external-debugging-output)
      (sleep-for wait))))

(defun remoto-e2e--fetch (ghub-get resource)
  "Ask GitHub for RESOURCE with GHUB-GET, the real one; return (CODE BODY)."
  (when (string-prefix-p "/search/" resource)
    (remoto-e2e--pace ghub-get))
  (condition-case err
      (list 200 (remoto-e2e--trim
                 (funcall ghub-get resource nil
                          :auth remoto-e2e--token :host "api.github.com"
                          :reader #'remoto-e2e--read-raw)))
    (ghub-http-error
     ;; Not what GitHub holds but what the token or the service is up to.
     (when (or (memql (nth 1 err) '(401 403 429)) (<= 500 (nth 1 err)))
       (error "GitHub answered %s to %s, not recorded" (nth 1 err) resource))
     (list (nth 1 err) (nth 4 err)))))

(defconst remoto-e2e--not-found '(404 ((message . "Not Found")))
  "GitHub's answer for what is missing, or private to a public reader.")

(defun remoto-e2e--record (ghub-get resource)
  "Return GitHub's answer to RESOURCE as a public reader gets it.
GHUB-GET is the real `ghub-get'.  Anything of a private repository is
missing, so a repository is asked about before what is inside it."
  (setq remoto-e2e--recorded t)
  (let* ((repo (and (string-match "\\`/repos/[^/?]+/[^/?]+" resource)
                    (match-string 0 resource)))
         (answer (if (and repo (not (equal repo resource))
                          (not (eql 200 (car (remoto-e2e--answer ghub-get repo)))))
                     remoto-e2e--not-found
                   (remoto-e2e--fetch ghub-get resource))))
    (princ (format "recorded %s %s\n" (car answer) resource)
           #'external-debugging-output)
    (if (remoto-e2e--private-p (cadr answer)) remoto-e2e--not-found answer)))

;;;; Answering

(defvar remoto-e2e--requests nil
  "Resources asked for since the case began, newest first.
One asked for with a callback reads \"async RESOURCE\".")

(defvar remoto-e2e--missing nil
  "Resources asked for that the fixtures lack, newest first.")

(defvar remoto-e2e--in-flight 0
  "Answers to callback requests that a timer has yet to deliver.")

(defvar remoto-e2e--timers nil
  "The timers that deliver answers to callback requests.")

(defvar remoto-e2e-answer-delay 0
  "Seconds an answer to a callback request takes to arrive.")

(defun remoto-e2e--answer (ghub-get resource)
  "Return (CODE BODY) for RESOURCE: recorded, or recorded now with GHUB-GET.
The account of the token is the fake one, never recorded."
  (or (gethash resource remoto-e2e--fixtures)
      (and remoto-e2e--token
           (not (string-match-p "\\`/user\\(?:[/?]\\|\\'\\)" resource))
           (puthash resource (remoto-e2e--record ghub-get resource)
                    remoto-e2e--fixtures))
      (progn (push resource remoto-e2e--missing)
             remoto-e2e--not-found)))

(cl-defun remoto-e2e--ghub-get (ghub-get resource &optional _params
                                         &key reader callback errorback
                                         &allow-other-keys)
  "Answer the `ghub-get' of RESOURCE as GitHub did, parsed by READER.
GHUB-GET is the real one.  Without CALLBACK and ERRORBACK the answer
returns or signals at once; with them a timer delivers it, and the value
is a live buffer, as ghub's would be."
  (push (if (or callback errorback) (concat "async " resource) resource)
        remoto-e2e--requests)
  (pcase-let* ((`(,code ,body) (remoto-e2e--answer ghub-get resource))
               (value (with-temp-buffer
                        (insert (remoto-e2e--json body))
                        (funcall reader nil))))
    (if (not (or callback errorback))
        (if (eql code 200)
            value
          (signal 'ghub-http-error
                  (list code (nth 2 (assq code url-http-codes))
                        (concat "https://api.github.com" resource) value)))
      (let ((buffer (generate-new-buffer " *remoto-e2e-request*" t)))
        (cl-incf remoto-e2e--in-flight)
        (push (run-at-time
               remoto-e2e-answer-delay nil
               (lambda ()
                 (unwind-protect
                     (cond ((eql code 200)
                            (when callback
                              (with-current-buffer buffer
                                (funcall callback value nil nil nil))))
                           (errorback
                            (funcall errorback (list 'error 'http code)
                                     nil nil nil)))
                   (cl-decf remoto-e2e--in-flight)
                   (kill-buffer buffer))))
              remoto-e2e--timers)
        buffer))))

(defun remoto-e2e--settle ()
  "Deliver the pending answers, as waiting until Emacs is idle would.
Return non-nil when answers keep coming."
  (let ((rounds 0))
    (while (and (< 0 remoto-e2e--in-flight) (< rounds 300))
      (accept-process-output nil 0.01)
      (cl-incf rounds))
    (< 0 remoto-e2e--in-flight)))

;;; Emacs as a person starts it

(remoto-e2e--load-fixtures)
(advice-add 'ghub-get :around #'remoto-e2e--ghub-get)

(defvar remoto-e2e--browsed nil
  "URLs the case sent to a browser, newest first.")

(setq auth-sources nil
      remoto-github-auth (or remoto-e2e--token "e2e-fake-token")
      browse-url-browser-function (lambda (url &rest _)
                                    (push url remoto-e2e--browsed))
      select-enable-clipboard nil
      ;; t on macOS only, and then RET asks for annotations.
      read-file-name-completion-ignore-case nil
      ;; A message like [No match] waits for the next key, which batch Emacs
      ;; does not see coming: it would sleep for the whole timeout.
      minibuffer-message-timeout 0)
(unless remoto-e2e--token
  ;; A request that gets past the fake goes to a dead port.
  (setq url-proxy-services '(("http" . "127.0.0.1:9") ("https" . "127.0.0.1:9"))))
(global-remoto-mode 1)
;; Emacs left idle a while after it starts: the token is known.
(remoto--warm-auth)
;; The first remote-looking name loads TRAMP, whose version check runs git
;; on an Emacs built from a checkout and logs it.
(require 'tramp)

(declare-function remoto-embark-register "remoto-embark")

(defconst remoto-e2e--submit
  '(("vanilla" . "RET") ("fido" . "M-j") ("vertico" . "M-RET")
    ("orderless" . "M-RET") ("evil" . "RET") ("embark" . "M-RET"))
  "Per profile, the key that submits a file prompt as typed.")

(pcase remoto-e2e-profile
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
  (other (error "Unknown profile %s" other)))

;;; Keys of the harness

(defvar remoto-e2e--open-minibuffer nil
  "The contents of the minibuffer the keys of a case left open, or nil.")

(defvar remoto-e2e--completions nil
  "The candidates *Completions* showed when the case ended.")

(defun remoto-e2e--completions ()
  "Return the candidates on display in the *Completions* buffer."
  (when-let* ((buffer (get-buffer "*Completions*")))
    (with-current-buffer buffer
      (let ((pos (point-min)) candidates)
        (while (setq pos (next-single-property-change pos 'completion--string))
          (when-let* ((candidate (get-text-property pos 'completion--string)))
            (push (substring-no-properties candidate) candidates)))
        (delete-dups (nreverse candidates))))))

(defun remoto-e2e-checkpoint ()
  "Note a minibuffer the keys of a case left open, and close it.
A keyboard macro that ends in a minibuffer submits it as typed in batch
Emacs, so each case ends with this key."
  (interactive)
  (setq remoto-e2e--completions (remoto-e2e--completions)
        remoto-e2e--open-minibuffer (and (minibufferp)
                                         (minibuffer-contents-no-properties)))
  (when (minibufferp)
    (abort-minibuffers)))

(defconst remoto-e2e-pause-seconds 0.5
  "How long a pause the pause key stands for.")

(defun remoto-e2e-pause ()
  "Stand for a pause in typing: run the idle timers due, let answers land.
Batch Emacs is never idle while a keyboard macro runs, so no idle timer
fires otherwise, remoto's debounced searches among them."
  (interactive)
  (dolist (timer (copy-sequence timer-idle-list))
    (when (time-less-p (timer--time timer) remoto-e2e-pause-seconds)
      (timer-event-handler timer)))
  (remoto-e2e--settle))

(defun remoto-e2e--line-name ()
  "Return the name on the current Dired line, or nil."
  (and (dired-move-to-filename) (dired-get-filename 'verbatim t)))

(defun remoto-e2e-goto (name)
  "Move to the Dired line of NAME, as a person would look for it."
  (interactive "sLine: ")
  (goto-char (point-min))
  (while (and (not (eobp)) (not (equal name (remoto-e2e--line-name))))
    (forward-line 1))
  (when (eobp)
    (user-error "No line %s" name)))

(keymap-global-set "<f35>" #'remoto-e2e-checkpoint)
(keymap-global-set "<f34>" #'remoto-e2e-pause)
(keymap-global-set "<f33>" #'remoto-e2e-goto)

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

(defun remoto-e2e--matrix ()
  "Return the cases that open each name with each command of the profile."
  (cl-loop for (command . keys) in (if (equal remoto-e2e-profile "evil")
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

(defun remoto-e2e--cases ()
  "Return the cases of the profile, each (NAME BINDINGS . KEYS)."
  (seq-filter (lambda (case)
                (or (not remoto-e2e--only)
                    (string-match-p remoto-e2e--only (car case))))
              (append (remoto-e2e--matrix)
                      (pcase remoto-e2e-profile
                        ("vanilla" (append (remoto-e2e--tab-cases)
                                           (remoto-e2e--dired-cases)))
                        ("embark" (remoto-e2e--embark-cases))))))

(defun remoto-e2e--keys (parts)
  "Return the key vector of PARTS: text, key vectors, and named keys."
  (apply #'vconcat
         (mapcar (lambda (part)
                   (pcase part
                     ('submit (kbd (cdr (assoc remoto-e2e-profile
                                               remoto-e2e--submit))))
                     ('pause [f34])
                     ('goto [f33])
                     (_ part)))
                 parts)))

;;; Running a case

(defun remoto-e2e--reset ()
  "Forget the buffers, caches, timers, history and kill ring of the last case."
  (mapc #'cancel-timer remoto-e2e--timers)
  (setq remoto-e2e--timers nil
        remoto-e2e--in-flight 0)
  (dolist (buffer (buffer-list))
    (unless (or (string-prefix-p " " (buffer-name buffer))
                (member (buffer-name buffer) '("*scratch*" "*Messages*")))
      (with-current-buffer buffer
        (set-buffer-modified-p nil))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer))))
  (mapatoms (lambda (symbol)
              (when (and (string-prefix-p "remoto--" (symbol-name symbol))
                         (boundp symbol)
                         (hash-table-p (symbol-value symbol)))
                (clrhash (symbol-value symbol)))))
  (when (timerp remoto--debounce-timer)
    (cancel-timer remoto--debounce-timer))
  (setq remoto--debounce-timer nil
        remoto--debounce-key nil
        remoto--inflight-count 0
        file-name-history nil
        minibuffer-history nil
        extended-command-history nil
        kill-ring nil
        kill-ring-yank-pointer nil)
  (when (boundp 'evil-ex-history)
    (set 'evil-ex-history nil))
  (delete-other-windows)
  (switch-to-buffer "*scratch*")
  (setq default-directory "/tmp/"))

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

(defun remoto-e2e--state (failure mark unsettled)
  "Return where the case ended, without the parts that are nil.
FAILURE is the message of the error that ended it, MARK where *Messages*
stood when it began, UNSETTLED non-nil when answers kept coming."
  (with-current-buffer (window-buffer (selected-window))
    (let* ((dired (derived-mode-p 'dired-mode))
           (names (and dired (remoto-e2e--dired-names)))
           (messages (with-current-buffer (messages-buffer)
                       (split-string (buffer-substring-no-properties
                                      mark (point-max))
                                     "\n" t))))
      (cl-loop for (key value) on
               ;; Emacs names a Dired or file buffer, differently by version.
               (list :buffer (unless (or dired buffer-file-name) (buffer-name))
                     :mode major-mode
                     :dired (and dired (if (consp dired-directory)
                                           (car dired-directory)
                                         dired-directory))
                     :matches (and dired (consp dired-directory))
                     :names (seq-take names 10)
                     :count (and names (length names))
                     :point (and dired (remoto-e2e--line-name))
                     :file buffer-file-name
                     :minibuffer remoto-e2e--open-minibuffer
                     :completions (seq-take remoto-e2e--completions 10)
                     :error failure
                     :messages (seq-filter (lambda (line)
                                             (string-match-p
                                              "\\`\\(?:[Rr]emoto\\|Error\\)" line))
                                           messages)
                     :kill (car kill-ring)
                     :browsed (reverse remoto-e2e--browsed)
                     :requests (reverse remoto-e2e--requests)
                     :missing (reverse remoto-e2e--missing)
                     :unsettled unsettled)
               by #'cddr
               when value append (list key value)))))

(defun remoto-e2e--command-error (data _context _caller)
  "End the case at the error DATA of a command in a minibuffer.
Emacs ends a keyboard macro at such an error and leaves the minibuffer
waiting for keys that batch Emacs never gets."
  (unless (memq (car data) '(minibuffer-quit quit))
    (setq remoto-e2e--open-minibuffer (and (minibufferp)
                                           (minibuffer-contents-no-properties)))
    (throw 'remoto-e2e--error (error-message-string data))))

(defun remoto-e2e--run (case)
  "Run CASE, (NAME BINDINGS . KEYS), and return where it ended."
  (pcase-let ((`(,_name ,bindings . ,parts) case))
    (remoto-e2e--reset)
    (cl-progv (mapcar #'car bindings) (mapcar #'cdr bindings)
      (let ((mark (with-current-buffer (messages-buffer)
                    (copy-marker (point-max)))))
        (setq remoto-e2e--requests nil
              remoto-e2e--missing nil
              remoto-e2e--open-minibuffer nil
              remoto-e2e--completions nil
              remoto-e2e--browsed nil)
        (remoto-e2e--state
         (catch 'remoto-e2e--error
           (let ((command-error-function #'remoto-e2e--command-error))
             (condition-case err
                 (progn (execute-kbd-macro (vconcat (remoto-e2e--keys parts)
                                                    [f35]))
                        nil)
               ((error quit) (error-message-string err)))))
         mark (remoto-e2e--settle))))))

;;; Expected states

(defun remoto-e2e--expected-file ()
  "Return the file of the expected states of the profile."
  (expand-file-name (format "expected/%s.eld" remoto-e2e-profile)
                    remoto-e2e--dir))

(defun remoto-e2e--read-expected ()
  "Return the expected states of the profile, an alist by case name."
  (when (file-exists-p (remoto-e2e--expected-file))
    (with-temp-buffer
      (insert-file-contents (remoto-e2e--expected-file))
      (let (states)
        (condition-case nil
            (while t (push (read (current-buffer)) states))
          (end-of-file nil))
        (nreverse states)))))

(defun remoto-e2e--write-expected (results)
  "Write RESULTS, an alist by case name, as the expected states."
  (make-directory (file-name-directory (remoto-e2e--expected-file)) t)
  (let ((coding-system-for-write 'utf-8-unix)
        (print-length nil)
        (print-level nil))
    (with-temp-file (remoto-e2e--expected-file)
      (insert ";; -*- mode: lisp-data -*-\n;; Written by make test-e2e-update.\n")
      (dolist (result results)
        (insert "\n")
        (pp result (current-buffer))))))

(defun remoto-e2e--diff (expected actual)
  "Return the keys whose values differ between plists EXPECTED and ACTUAL."
  (cl-loop for key in (delete-dups (append (cl-loop for (k) on expected by #'cddr
                                                    collect k)
                                           (cl-loop for (k) on actual by #'cddr
                                                    collect k)))
           unless (equal (plist-get expected key) (plist-get actual key))
           collect (list key :expected (plist-get expected key)
                         :actual (plist-get actual key))))

(defun remoto-e2e-main ()
  "Run the cases of the profile, compare or write, and exit."
  (let* ((start (float-time))
         (expected (remoto-e2e--read-expected))
         (failed 0)
         (results
          (mapcar (lambda (case)
                    (let* ((name (car case))
                           (state (remoto-e2e--run case))
                           (want (cdr (assoc name expected)))
                           (problem (cond ((plist-get state :missing)
                                           "fixtures lack an answer")
                                          (remoto-e2e--update nil)
                                          ((not (assoc name expected))
                                           "no expected state")
                                          ((not (equal want state))
                                           (remoto-e2e--diff want state)))))
                      (if (not problem)
                          (princ (format "ok   %s | %s\n" remoto-e2e-profile name))
                        (cl-incf failed)
                        (princ (format "FAIL %s | %s\n%s\n" remoto-e2e-profile name
                                       (pp-to-string (if (stringp problem)
                                                         (list problem state)
                                                       problem)))))
                      (cons name state)))
                  (remoto-e2e--cases))))
    (when remoto-e2e--recorded
      (remoto-e2e--save-fixtures))
    (when remoto-e2e--update
      (remoto-e2e--write-expected results))
    (princ (format "remoto-e2e %s: %d cases, %d failed, %.1f s%s\n"
                   remoto-e2e-profile (length results) failed
                   (- (float-time) start)
                   (if remoto-e2e--update ", expected states written" "")))
    (kill-emacs (min failed 1))))

(remoto-e2e-main)

;;; remoto-e2e.el ends here
