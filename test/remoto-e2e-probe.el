;;; remoto-e2e-probe.el --- Drive remoto by keys in batch Emacs -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Types a name into the real commands with `execute-kbd-macro' in batch
;;  Emacs, against a GitHub faked at `ghub-get', and checks the Dired of
;;  matches it opens.  REMOTO_E2E_PROFILE picks vanilla, fido, vertico or evil.
;;
;;; Code:

(require 'cl-lib)
(require 'dired)
(require 'ghub)
(require 'remoto)

;;; Fake GitHub

(defun remoto-e2e--repo (name description pushed size)
  "Return a public repository of agzam, NAME, as the search endpoints send it.
DESCRIPTION, PUSHED and SIZE are its fields of the same names."
  `((name . ,name) (full_name . ,(concat "agzam/" name))
    (description . ,description) (private . :false) (archived . :false)
    (fork . :false) (size . ,size) (pushed_at . ,pushed)
    (default_branch . "main")))

(defun remoto-e2e--search (total &rest repos)
  "Return the JSON of a repository search that found TOTAL, REPOS first."
  (json-serialize `((total_count . ,total) (incomplete_results . :false)
                    (items . ,(vconcat repos)))))

(defconst remoto-e2e--remoto
  (remoto-e2e--repo "remoto.el" "Browse GitHub repos without cloning"
                    "2026-10-21T01:45:05Z" 10024))

(defvar remoto-e2e--fixtures
  `(("/repos/agzam/remoto" 404 "{\"message\":\"Not Found\"}")
    ("/search/repositories?q=user%3Aagzam&sort=updated&per_page=30" 200
     ,(remoto-e2e--search
       79 remoto-e2e--remoto
       (remoto-e2e--repo ".emacs.d" "My Emacs config" "2026-10-20T18:23:24Z" 2608)
       (remoto-e2e--repo "go-jira.el" "Emacs Jira integration utilizing go-jira CLI"
                         "2026-10-19T18:59:05Z" 219)))
    ("/search/repositories?q=rem%20in%3Aname%20user%3Aagzam&per_page=100" 200
     ,(remoto-e2e--search 1 remoto-e2e--remoto))
    ("/search/repositories?q=remoto%20in%3Aname%20user%3Aagzam&per_page=100" 200
     ,(remoto-e2e--search 1 remoto-e2e--remoto)))
  "GitHub's answers, each (RESOURCE CODE BODY).")

(defvar remoto-e2e--requests nil
  "Resources asked for since the case began, newest first.
One asked for with a callback reads \"async RESOURCE\".")

(defvar remoto-e2e--missing nil
  "Resources asked for that `remoto-e2e--fixtures' lacks, newest first.")

(defvar remoto-e2e--in-flight 0
  "Answers to callback requests that a timer has yet to deliver.")

(defun remoto-e2e--answer (resource)
  "Return (CODE BODY) for RESOURCE; one the fixtures lack is a 404."
  (or (cdr (assoc resource remoto-e2e--fixtures))
      (progn (push resource remoto-e2e--missing)
             (list 404 "{\"message\":\"Not Found\"}"))))

(cl-defun remoto-e2e--ghub-get (resource &optional _params
                                         &key reader callback errorback
                                         &allow-other-keys)
  "Answer `ghub-get' of RESOURCE from the fixtures, parsed by READER.
Without CALLBACK and ERRORBACK the answer returns or signals at once.
With them a timer delivers it, and the value is the live buffer that
`remoto--ghub-get-interruptible' waits on, as ghub's would be."
  (push (if (or callback errorback) (concat "async " resource) resource)
        remoto-e2e--requests)
  (pcase-let* ((`(,code ,body) (remoto-e2e--answer resource))
               (value (with-temp-buffer (insert body) (funcall reader nil))))
    (if (not (or callback errorback))
        (if (= code 200)
            value
          (signal 'ghub-http-error
                  (list code (nth 2 (assq code url-http-codes))
                        (concat "https://api.github.com" resource) value)))
      (let ((buffer (generate-new-buffer " *remoto-e2e-request*" t)))
        (cl-incf remoto-e2e--in-flight)
        (run-at-time
         0 nil
         (lambda ()
           (unwind-protect
               (cond ((= code 200)
                      (when callback
                        (with-current-buffer buffer
                          (funcall callback value nil nil nil))))
                     (errorback
                      (funcall errorback (list 'error 'http code) nil nil nil)))
             (cl-decf remoto-e2e--in-flight)
             (kill-buffer buffer))))
        buffer))))

(advice-add 'ghub-get :override #'remoto-e2e--ghub-get)

;;; Emacs as a person starts it

(setq auth-sources nil
      remoto-github-auth "e2e-fake-token"
      ;; A request that gets past the fake goes to a dead port.
      url-proxy-services '(("http" . "127.0.0.1:9") ("https" . "127.0.0.1:9")))
(global-remoto-mode 1)
;; The first remote-looking name loads TRAMP, whose version check runs git
;; on an Emacs built from a checkout and logs it: keep that out of the case.
(require 'tramp)

(defconst remoto-e2e-profile (or (getenv "REMOTO_E2E_PROFILE") "vanilla")
  "The completion setup the cases run under.")

(defconst remoto-e2e--prompt-keys
  '(("vanilla" "C-x C-f" "RET")
    ("fido" "C-x C-f" "M-j")
    ("vertico" "C-x C-f" "M-RET")
    ("evil" ": e SPC" "RET"))
  "Per profile, the keys that open its file prompt and submit it as typed.")

(pcase remoto-e2e-profile
  ("vanilla")
  ("fido"
   (fido-vertical-mode 1)
   ;; Icomplete leaves alone a minibuffer that a keyboard macro opens.
   (advice-add 'icomplete-simple-completing-p :around
               (lambda (fn) (let ((executing-kbd-macro nil)) (funcall fn)))))
  ("vertico" (require 'vertico) (vertico-mode 1))
  ("evil" (require 'evil) (evil-mode 1))
  (other (error "Unknown profile %s" other)))

;;; Cases

(defvar remoto-e2e--open-minibuffer nil
  "The contents of the minibuffer the keys of a case left open, or nil.")

(defun remoto-e2e-checkpoint ()
  "Note a minibuffer the keys of a case left open, and close it.
A keyboard macro that ends in a minibuffer submits it as typed in batch
Emacs, so each case ends with this key."
  (interactive)
  (setq remoto-e2e--open-minibuffer
        (and (minibufferp) (minibuffer-contents-no-properties)))
  (when (minibufferp)
    (abort-minibuffers)))

(global-set-key [f35] #'remoto-e2e-checkpoint)

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
  (while (< 0 remoto-e2e--in-flight)
    (accept-process-output nil 0.01)))

(global-set-key [f34] #'remoto-e2e-pause)

(defun remoto-e2e--reset ()
  "Forget the buffers, caches, timers and history of the last case."
  (dolist (buffer (buffer-list))
    (when (with-current-buffer buffer
            (or (derived-mode-p 'dired-mode)
                (and buffer-file-name
                     (string-match-p remoto--handler-regexp buffer-file-name))))
      (kill-buffer buffer)))
  (mapatoms (lambda (symbol)
              (when (and (string-prefix-p "remoto--" (symbol-name symbol))
                         (boundp symbol)
                         (hash-table-p (symbol-value symbol)))
                (clrhash (symbol-value symbol)))))
  (when (timerp remoto--debounce-timer)
    (cancel-timer remoto--debounce-timer))
  (setq remoto--debounce-timer nil
        remoto--debounce-key nil
        file-name-history nil)
  (switch-to-buffer "*scratch*"))

(defun remoto-e2e--dired-names ()
  "Return the names on the lines of the current Dired buffer."
  (save-excursion
    (goto-char (point-min))
    (let (names)
      (while (not (eobp))
        (when (dired-move-to-filename)
          (push (dired-get-filename 'verbatim t) names))
        (forward-line 1))
      (nreverse names))))

(defun remoto-e2e-run (keys)
  "Type KEYS and the checkpoint key, and return where Emacs ended up."
  (let ((start (float-time))
        (mark (with-current-buffer (messages-buffer) (point-max)))
        failure)
    (setq remoto-e2e--requests nil
          remoto-e2e--missing nil
          remoto-e2e--open-minibuffer nil)
    (condition-case err
        (execute-kbd-macro (vconcat keys [f35]))
      (error (setq failure (error-message-string err))))
    (with-current-buffer (window-buffer (selected-window))
      (list :buffer (buffer-name)
            :mode major-mode
            :dired (and (derived-mode-p 'dired-mode) dired-directory)
            :names (and (derived-mode-p 'dired-mode) (remoto-e2e--dired-names))
            :file buffer-file-name
            :open-minibuffer remoto-e2e--open-minibuffer
            :error failure
            :messages (with-current-buffer (messages-buffer)
                        (split-string (buffer-substring-no-properties
                                       mark (point-max))
                                      "\n" t))
            :requests (reverse remoto-e2e--requests)
            :missing (reverse remoto-e2e--missing)
            :idle-timers (mapcar (lambda (timer)
                                   (let ((fn (timer--function timer)))
                                     (if (symbolp fn) fn 'lambda)))
                                 timer-idle-list)
            :seconds (/ (round (* 100 (- (float-time) start))) 100.0)))))

(defconst remoto-e2e--cases
  '(("typed" "/gh:agzam/remoto")
    ("paused" "/gh:agzam/rem" [f34] "oto"))
  "Each case: its name, then what is typed at the file prompt.
The key f34 in it is a pause, see `remoto-e2e-pause'.")

(let ((failed 0))
  (pcase-dolist (`(,name . ,input) remoto-e2e--cases)
    (remoto-e2e--reset)
    (pcase-let* ((`(,open ,submit) (cdr (assoc remoto-e2e-profile
                                                remoto-e2e--prompt-keys)))
                 (state (remoto-e2e-run
                         (apply #'vconcat (kbd open)
                                (append input (list (kbd submit))))))
                 (pass (and (equal (plist-get state :dired)
                                   '("/github:agzam/" "remoto.el"))
                            (null (plist-get state :missing)))))
      (unless pass
        (cl-incf failed))
      (princ (format "%s %s %s: %s\n" (if pass "PASS" "FAIL")
                     remoto-e2e-profile name (pp-to-string state)))))
  (kill-emacs (min failed 1)))

;;; remoto-e2e-probe.el ends here
