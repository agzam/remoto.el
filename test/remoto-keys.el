;;; remoto-keys.el --- Keystrokes into emacs -nw -q under tmux, against the real forges -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  Types the cases of remoto-e2e-cases.el, and scenarios of auth and of other
;;  servers, into terminal Emacsen under a private tmux server, so no window
;;  takes focus, and reads each through its server.  REMOTO_KEYS_MAIN runs
;;  origin/main's remoto beside the checkout's and prints where they differ.
;;
;;; Code:

(require 'cl-lib)
(require 'server)
(require 'subr-x)
(require 'url)
(require 'remoto-e2e-cases (expand-file-name "remoto-e2e-cases"
                                             (file-name-directory
                                              (or load-file-name buffer-file-name))))

(defconst remoto-keys--test-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "The directory of the test files.")

(defconst remoto-keys--root
  (file-name-directory (directory-file-name remoto-keys--test-dir))
  "The checkout.")

(defconst remoto-keys--dir
  (file-name-as-directory (expand-file-name (or (getenv "REMOTO_KEYS_DIR") ".keys")
                                            remoto-keys--root))
  "Where a run keeps its packages, sockets and results.")

(defconst remoto-keys--profiles
  (split-string (or (getenv "REMOTO_KEYS_PROFILES") (string-join remoto-e2e-live-profiles " "))
                "[ ,]+" t)
  "The profiles of this run.")

(defconst remoto-keys--main (getenv "REMOTO_KEYS_MAIN")
  "Non-nil to run origin/main's remoto beside the checkout's.")

(defconst remoto-keys--token (getenv "REMOTO_E2E_TOKEN")
  "A GitHub token for the profiles, or nil to read anonymously.")

(defconst remoto-keys--codeberg-token (getenv "REMOTO_E2E_CODEBERG_TOKEN")
  "A Codeberg token for the scenario that signs in to Codeberg, or nil.")

(defconst remoto-keys--gpg (executable-find "gpg")
  "The gpg that makes the scenarios' GnuPG homes, or nil without one.")

(defconst remoto-keys--passphrase "e2e-passphrase"
  "The passphrase of the scenarios' GnuPG homes, which their pinentry gives.")

(defvar remoto-keys--github-login nil
  "The GitHub account of `remoto-keys--token', as GitHub names it.")

(defvar remoto-keys--codeberg-login nil
  "The Codeberg account of `remoto-keys--codeberg-token', as Codeberg names it.")

(defvar remoto-keys--codeberg-org nil
  "An organization of `remoto-keys--codeberg-login', which the run finds, or nil.")

(defvar remoto-keys--codeberg-private nil
  "A private OWNER/REPO that `remoto-keys--codeberg-token' reads, or nil.")

(defconst remoto-keys--keep (getenv "REMOTO_KEYS_KEEP")
  "Non-nil to leave the profiles running after the cases, to explore by hand.")

(defconst remoto-keys--size (split-string (or (getenv "REMOTO_KEYS_SIZE") "100x40") "x")
  "Columns and lines of every profile's terminal.")

(defconst remoto-keys--case-seconds 60
  "How long a case may keep Emacs busy.")

(defconst remoto-keys--pause 0.5
  "How long a pause in typing lasts.")

;;; Processes

(defun remoto-keys--sh (program &rest args)
  "Run PROGRAM with ARGS and return its output; signal an error when it fails."
  (with-temp-buffer
    (let ((status (apply #'call-process program nil t nil args)))
      (unless (eql status 0)
        (error "%s %s: %s" program (string-join args " ") (string-trim (buffer-string))))
      (buffer-string))))

(defun remoto-keys--tmux-arg (arg)
  "Return ARG as tmux must get it: a trailing semicolon would end its command."
  (if (string-suffix-p ";" arg)
      (concat (substring arg 0 -1) "\\;")
    arg))

(defun remoto-keys--tmux (&rest args)
  "Run tmux with ARGS on the private server of the run, without ~/.tmux.conf."
  (apply #'remoto-keys--sh "tmux" "-f" "/dev/null"
         "-S" (expand-file-name "tmux.sock" remoto-keys--dir)
         (mapcar #'remoto-keys--tmux-arg args)))

(defun remoto-keys--target (name)
  "Return the tmux pane of the profile NAME."
  (concat "=rk-" name ":"))

(defun remoto-keys--eval (name form &optional seconds)
  "Evaluate FORM in the Emacs of NAME and return its value.
Signal an error when no answer comes within SECONDS, 30 by default."
  (let ((server-socket-dir (expand-file-name "sock/" remoto-keys--dir))
        (seconds (or seconds 30)))
    (with-timeout (seconds (error "No answer from %s in %ss" name seconds))
      (server-eval-at name form))))

(defun remoto-keys--busy-p (name)
  "Non-nil while the Emacs of NAME works, or does not answer."
  (condition-case nil
      (remoto-keys--eval name '(remoto-keys-busy-p) 5)
    (error t)))

(defun remoto-keys--wait-idle (name seconds)
  "Wait until the Emacs of NAME is idle.
Return nil, or a note when it still worked after SECONDS."
  (sleep-for 0.2)
  (let ((end (+ (float-time) seconds)))
    (while (and (< (float-time) end) (remoto-keys--busy-p name))
      (sleep-for 0.25))
    (and (<= end (float-time)) (format "still busy after %ss" seconds))))

(defvar remoto-keys--no-curl-said nil
  "Non-nil once the run said what it does without curl.")

(defun remoto-keys--curl-p ()
  "Non-nil when curl is at hand; else say once what the run skips for want of it."
  (or (executable-find "curl")
      (progn
        (unless remoto-keys--no-curl-said
          (setq remoto-keys--no-curl-said t)
          (princ (concat "No curl: web URLs go unchecked, and the run asks no forge"
                         " for a token's account or for GitHub's search budget\n")))
        nil)))

(defun remoto-keys--curl (address &optional token &rest args)
  "Return (EXIT . OUTPUT) of curl asking ADDRESS with ARGS, and TOKEN if any.
curl reads the token on its standard input, so no process listing shows
it.  A batch Emacs exits on an error in a process sentinel, so no url.el."
  (with-temp-buffer
    (let ((exit (apply #'call-process-region
                       (if token (concat "Authorization: token " token "\n") "")
                       nil "curl" nil t nil "-s" "-S" "--max-time" "15"
                       (append (and token '("-H" "@-")) args (list address)))))
      (cons exit (buffer-string)))))

(defun remoto-keys--ask (address token)
  "Return the JSON that ADDRESS answers, asked with TOKEN if any.
Signal an error that says why when no answer of status 2xx comes."
  (unless (remoto-keys--curl-p)
    (error "No curl"))
  (pcase-let ((`(,exit . ,output) (remoto-keys--curl address token "-w" "\n%{http_code}")))
    (unless (eql exit 0)
      (error "%s" (string-trim output)))
    (let* ((end (string-match "\n\\([0-9]+\\)\\'" output))
           (status (if end (string-to-number (match-string 1 output)) 0))
           (body (substring output 0 end)))
      (unless (<= 200 status 299)
        (error "HTTP %d: %s" status
               (truncate-string-to-width
                (replace-regexp-in-string "[ \t\r\n]+" " " (string-trim body)) 100)))
      (json-parse-string body :object-type 'alist))))

(defun remoto-keys--json (address token)
  "Return the JSON that ADDRESS answers, asked with TOKEN if any, or nil."
  (ignore-errors (remoto-keys--ask address token)))

(defun remoto-keys--search-left ()
  "Return GitHub's search requests left and the time they come back, or nil."
  (let-alist (remoto-keys--json "https://api.github.com/rate_limit" remoto-keys--token)
    (and (numberp .resources.search.remaining)
         (cons .resources.search.remaining .resources.search.reset))))

(defconst remoto-keys--account-pauses '(0 5 15)
  "The seconds to wait before each time the run asks for a token's account.")

(defun remoto-keys--account (forge address token)
  "Return the account that ADDRESS of FORGE names for TOKEN.
Ask again after a failure; signal an error that says why when no answer
names one, since a profile without it would read FORGE anonymously."
  (let (why)
    (or (seq-some (lambda (pause)
                    (sleep-for pause)
                    (condition-case err
                        (let ((data (remoto-keys--ask address token)))
                          (or (and (listp data) (alist-get 'login data))
                              (ignore (setq why "the answer names no login"))))
                      (error (ignore (setq why (error-message-string err))))))
                  remoto-keys--account-pauses)
        (error "%s names no account for its token: %s" forge why))))

(defvar remoto-keys--url-statuses (make-hash-table :test #'equal)
  "The status each web URL a case copied or browsed answered, by URL.")

(defun remoto-keys--url-status (url)
  "Return the HTTP status that URL answers curl after redirects, or nil for none.
Codeberg answers any other client its bot check, a 200, whatever the path."
  (with-memoization (gethash url remoto-keys--url-statuses)
    (with-temp-buffer
      (and (eql 0 (ignore-errors
                    (call-process "curl" nil t nil "-s" "-L" "-o" "/dev/null" "--max-time" "15"
                                  "-w" "%{http_code}" url)))
           (let ((code (string-to-number (buffer-string))))
             (and (< 0 code) code))))))

(defun remoto-keys--dead-urls (state)
  "Return (URL . STATUS) for the web URLs STATE copied or browsed that fail to load.
Without curl no URL is checked, which the run says once."
  (let ((urls (seq-filter (lambda (url) (and (stringp url) (string-match-p "\\`https?://" url)))
                          (delete-dups (cons (plist-get state :kill)
                                             (copy-sequence (plist-get state :browsed)))))))
    (cond
     ((null urls) nil)
     ((not (remoto-keys--curl-p)) nil)
     (t (seq-keep (lambda (url)
                    (let ((status (remoto-keys--url-status url)))
                      (unless (and status (< status 400)) (cons url status))))
                  urls)))))

(defun remoto-keys--learn-logins (&optional codeberg)
  "Learn the account of GitHub's token and, with CODEBERG, of Codeberg's.
Only the scenarios use Codeberg's.  Signal an error when a forge names
no account for its token, as `remoto-keys--account' does."
  (when remoto-keys--token
    (setq remoto-keys--github-login
          (remoto-keys--account "GitHub" "https://api.github.com/user" remoto-keys--token)
          remoto-e2e--root-account remoto-keys--github-login)
    (princ (format "GitHub token of %s\n" remoto-keys--github-login)))
  (when (and codeberg remoto-keys--codeberg-token)
    (setq remoto-keys--codeberg-login
          (remoto-keys--account "Codeberg" "https://codeberg.org/api/v1/user"
                                remoto-keys--codeberg-token))
    (princ (format "Codeberg token of %s\n" remoto-keys--codeberg-login))
    (let ((orgs (remoto-keys--json "https://codeberg.org/api/v1/user/orgs"
                                   remoto-keys--codeberg-token))
          (repos (remoto-keys--json "https://codeberg.org/api/v1/user/repos?limit=50"
                                    remoto-keys--codeberg-token)))
      (setq remoto-keys--codeberg-org
            (and (vectorp orgs) (< 0 (length orgs)) (alist-get 'username (aref orgs 0)))
            remoto-keys--codeberg-private
            (and (vectorp repos)
                 (seq-some (lambda (repo)
                             (and (eq t (alist-get 'private repo)) (alist-get 'full_name repo)))
                           repos)))
      (princ (format "Codeberg organization %s, private repository %s\n"
                     (or remoto-keys--codeberg-org "none")
                     (or remoto-keys--codeberg-private "none"))))))

(defun remoto-keys--wait-for-search ()
  "Wait while GitHub has fewer than 8 search requests left for the run."
  (while-let ((left (remoto-keys--search-left))
              ((< (car left) 8)))
    (princ (format "  [search budget %d, waiting]\n" (car left)))
    (sleep-for (max 1 (min 60 (- (cdr left) (float-time)))))))

;;; Packages

(defun remoto-keys--header (file field)
  "Return the value of the header FIELD of FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (and (re-search-forward (format "^;; %s: \\(.*\\)$" (regexp-quote field)) nil t)
         (match-string 1))))

(defun remoto-keys--install (source elpa)
  "Install the remoto files of SOURCE, a directory, into ELPA as package.el does.
The dependencies come from the .elpa of the checkout, linked in."
  (let* ((main (expand-file-name "remoto.el" source))
         (version (remoto-keys--header main "Version"))
         (requires (remoto-keys--header main "Package-Requires"))
         (staging (make-temp-file "remoto-keys" t))
         (package (expand-file-name (concat "remoto-" version) staging))
         (deps (expand-file-name ".elpa" remoto-keys--root)))
    (when (file-exists-p elpa)
      (delete-directory elpa t))
    (make-directory elpa t)
    (dolist (dep (directory-files deps t "\\`[^.]"))
      (unless (member (file-name-nondirectory dep) '("archives" "gnupg"))
        (make-symbolic-link dep (expand-file-name (file-name-nondirectory dep) elpa))))
    (make-directory package)
    (dolist (file (directory-files source t "\\`remoto.*\\.el\\'"))
      (unless (string-match-p "-\\(?:autoloads\\|pkg\\)\\.el\\'" file)
        (copy-file file (file-name-as-directory package))))
    (with-temp-file (expand-file-name "remoto-pkg.el" package)
      (insert (format ";; -*- no-byte-compile: t; lexical-binding: nil -*-\n(define-package \"remoto\" %S \"Browse GitHub repos without cloning\" '%s)\n"
                      version requires)))
    (remoto-keys--sh "tar" "-cf" (concat package ".tar") "-C" staging
                     (file-name-nondirectory package))
    (remoto-keys--sh (expand-file-name invocation-name invocation-directory)
                     "-Q" "--batch" "--init-directory" (expand-file-name "sandbox" staging)
                     "--eval" (format "(setq package-user-dir %S)" elpa)
                     "--eval" "(require 'package)" "--eval" "(package-initialize)"
                     "--eval" (format "(package-install-file %S)" (concat package ".tar")))
    (delete-directory staging t)
    version))

(defun remoto-keys--main-source ()
  "Return a directory with origin/main's remoto files."
  (let* ((dir (expand-file-name "main-src/" remoto-keys--dir))
         (tar (expand-file-name "main.tar" remoto-keys--dir))
         (files (seq-filter (lambda (f) (string-match-p "\\`remoto.*\\.el\\'" f))
                            (split-string (remoto-keys--sh "git" "-C" remoto-keys--root
                                                           "ls-tree" "--name-only" "origin/main")
                                          "\n" t))))
    (when (file-exists-p dir)
      (delete-directory dir t))
    (make-directory dir t)
    (apply #'remoto-keys--sh "git" "-C" remoto-keys--root "archive" "-o" tar "origin/main" files)
    (remoto-keys--sh "tar" "-xf" tar "-C" dir)
    (delete-file tar)
    dir))

(defun remoto-keys--install-checkout (elpa)
  "Install the remoto of the checkout into ELPA and print its commit."
  (princ (format "checkout %s%s: remoto %s\n"
                 (string-trim (remoto-keys--sh "git" "-C" remoto-keys--root
                                               "log" "-1" "--format=%h %s"))
                 (if (string-empty-p (remoto-keys--sh "git" "-C" remoto-keys--root
                                                      "status" "--porcelain"))
                     ""
                   " (with uncommitted changes)")
                 (remoto-keys--install remoto-keys--root elpa))))

;;; Profiles

(defun remoto-keys--fixture (name kind text)
  "Write TEXT, or nothing, to the KIND file of the profile NAME; return the file."
  (let ((file (expand-file-name (format "fixtures/%s.%s" name kind) remoto-keys--dir)))
    (make-directory (file-name-directory file) t)
    (with-file-modes #o600
      (with-temp-file file (insert (or text ""))))
    file))

(defun remoto-keys--codeberg-authinfo (name)
  "Write the Codeberg token to the authinfo of the profile NAME; return the file."
  (let ((file (expand-file-name (format "fixtures/%s.authinfo" name) remoto-keys--dir)))
    (make-directory (file-name-directory file) t)
    (with-file-modes #o600
      (with-temp-file file
        (insert "machine codeberg.org/api/v1 login " remoto-keys--codeberg-login
                "^ghub password " remoto-keys--codeberg-token "\n")))
    file))

(defun remoto-keys--path-without-gpg (path)
  "Return PATH, a search path, without the directories that hold gpg or gpg2."
  (string-join (seq-remove (lambda (dir)
                             (or (file-executable-p (expand-file-name "gpg" dir))
                                 (file-executable-p (expand-file-name "gpg2" dir))))
                           (split-string path path-separator t))
               path-separator))

(defun remoto-keys--env (name profile elpa &optional setup)
  "Return the whole environment of the profile NAME: PROFILE, remoto from ELPA.
SETUP is the plist of a scenario of `remoto-keys--scenarios'.  Git config
never comes from the person running it: it names the account of a token
the profile gets, since ghub uses no token without one."
  (let ((github (and remoto-keys--token (or (null setup) (plist-get setup :token))))
        (codeberg (and (plist-get setup :codeberg) remoto-keys--codeberg-login))
        (home (plist-get setup :home)))
    (append
     ;; An empty TMPDIR would put temporary files in the current, remoto, directory.
     (seq-keep (lambda (var)
                 (when-let* ((value (pcase var
                                      ((and "HOME" (guard (stringp home))) home)
                                      ((and "PATH" (guard (plist-get setup :no-gpg)))
                                       (remoto-keys--path-without-gpg (getenv "PATH")))
                                      (_ (getenv var)))))
                   (concat var "=" value)))
               '("HOME" "USER" "LOGNAME" "SHELL" "TMPDIR" "PATH"))
     (when (stringp home)
       (list "REMOTO_KEYS_DEFAULT_AUTH=1"))
     (when (and (plist-get setup :gnupg) remoto-keys--gpg)
       (list (concat "REMOTO_KEYS_GPG=" remoto-keys--gpg)))
     (list (concat "LANG=" (or (getenv "LANG") "en_US.UTF-8"))
           ;; A screen TERM keeps Emacs from querying the terminal at startup.
           "TERM=screen-256color"
           "GIT_CONFIG_NOSYSTEM=1"
           (concat "GIT_CONFIG_GLOBAL="
                   (remoto-keys--fixture
                    name "gitconfig"
                    (concat (plist-get setup :gitconfig)
                            (and github remoto-keys--github-login
                                 (format "[github]\n\tuser = %s\n" remoto-keys--github-login))
                            (and codeberg
                                 (format "[forgejo]\n\tuser = %s\n" remoto-keys--codeberg-login)))))
           (concat "REMOTO_KEYS_ELPA=" elpa)
           (concat "REMOTO_KEYS_PROFILE=" profile)
           (concat "REMOTO_KEYS_SOCKET_DIR=" (expand-file-name "sock/" remoto-keys--dir))
           (concat "REMOTO_KEYS_SERVER=" name))
     (cond (codeberg
            (list (concat "REMOTO_KEYS_AUTHINFO=" (remoto-keys--codeberg-authinfo name))))
           ((plist-get setup :authinfo)
            (list (concat "REMOTO_KEYS_AUTHINFO="
                          (remoto-keys--fixture name "authinfo" (plist-get setup :authinfo))))))
     ;; The run's own REMOTO_KEYS_INIT, say a planted regression, when SETUP has none.
     (when-let* ((form (if (plist-get setup :init)
                           (prin1-to-string (plist-get setup :init))
                         (getenv "REMOTO_KEYS_INIT"))))
       (list (concat "REMOTO_KEYS_INIT=" form)))
     (when github
       (let ((file (expand-file-name (concat "token-" name) remoto-keys--dir)))
         (with-file-modes #o600
           (with-temp-file file (insert remoto-keys--token)))
         (list (concat "REMOTO_KEYS_TOKEN_FILE=" file)))))))

(defun remoto-keys--start (name profile elpa &optional setup)
  "Start the profile NAME, a terminal Emacs of PROFILE with remoto from ELPA.
SETUP is a scenario's, as in `remoto-keys--env'.  Return what the Emacs
reports about itself."
  (let ((sockets (expand-file-name "sock/" remoto-keys--dir))
        (home (expand-file-name "home/" remoto-keys--dir))
        (init-dir (expand-file-name (concat "profiles/" name "/") remoto-keys--dir)))
    (make-directory sockets t)
    (set-file-modes sockets #o700)
    (make-directory home t)
    (when (file-exists-p init-dir)
      (delete-directory init-dir t))
    (make-directory init-dir t)
    (ignore-errors (delete-file (expand-file-name name sockets)))
    (ignore-errors (remoto-keys--tmux "kill-session" "-t" (concat "=rk-" name)))
    ;; A tmux server that outlives the run holds make's jobserver pipe: make -j never exits.
    (add-hook 'kill-emacs-hook #'remoto-keys--kill-server)
    (apply #'remoto-keys--tmux "new-session" "-d" "-s" (concat "rk-" name)
           "-x" (car remoto-keys--size) "-y" (cadr remoto-keys--size) "-c" home
           "env" "-i" (append (remoto-keys--env name profile elpa setup)
                              (list (expand-file-name invocation-name invocation-directory)
                                    "-nw" "-q" "--init-directory" init-dir
                                    "-l" (expand-file-name "remoto-keys-init.el"
                                                           remoto-keys--test-dir))))
    (let ((end (+ (float-time) 30)))
      (while (and (not (file-exists-p (expand-file-name name sockets)))
                  (< (float-time) end))
        (sleep-for 0.25)))
    (remoto-keys--wait-idle name 20)
    (remoto-keys--eval name '(list :lib (locate-library "remoto")
                                   :token (stringp (bound-and-true-p remoto-github-auth))
                                   :size (list (frame-width) (frame-height))))))

(defun remoto-keys--stop (name)
  "Stop the profile NAME."
  (ignore-errors (remoto-keys--eval name '(run-at-time 0.1 nil #'kill-emacs 0) 5))
  (sleep-for 0.3)
  (ignore-errors (remoto-keys--tmux "kill-session" "-t" (concat "=rk-" name)))
  (dolist (file (list (concat "token-" name) (format "fixtures/%s.authinfo" name)))
    (ignore-errors (delete-file (expand-file-name file remoto-keys--dir)))))

(defun remoto-keys--kill-server ()
  "Kill the tmux server of the run, unless REMOTO_KEYS_KEEP is set."
  (unless remoto-keys--keep
    (ignore-errors (remoto-keys--tmux "kill-server"))))

(defconst remoto-keys--revive-seconds 60
  "How long an Emacs that failed a case has to answer again before a restart.")

(defun remoto-keys--answers-p (name seconds)
  "Non-nil when the Emacs of NAME answers within SECONDS."
  (let ((end (+ (float-time) seconds))
        answered)
    (while (and (not answered) (< (float-time) end))
      (unless (setq answered (ignore-errors (remoto-keys--eval name t 5)))
        (sleep-for 1)))
    answered))

(defun remoto-keys--revive (name profile elpa)
  "Restart the Emacs of NAME, PROFILE with remoto from ELPA, unless it answers.
An Emacs blocked in a host lookup answers when the lookup ends; meanwhile
macOS refuses connections past the server's backlog of five."
  (unless (remoto-keys--answers-p name remoto-keys--revive-seconds)
    (princ (format "%s gives no answer in %ss, restarting it\n" name remoto-keys--revive-seconds))
    (remoto-keys--stop name)
    (princ (format "start %s: %S\n" name (remoto-keys--start name profile elpa)))))

;;; Typing

(defun remoto-keys--plain-p (event)
  "Non-nil if EVENT types itself: a character, no control, no modifier."
  (and (characterp event) (<= 32 event) (/= event 127)))

(defun remoto-keys--tmux-key (event)
  "Return the tmux name of key EVENT, or nil when it is a plain character."
  (let* ((description (key-description (vector event)))
         (mods (progn (string-match "\\`\\(\\(?:[CMS]-\\)*\\)\\(.+\\)\\'" description)
                      (match-string 1 description)))
         (base (match-string 2 description))
         (base (pcase base
                 ("RET" "Enter") ("SPC" "Space") ("TAB" "Tab") ("ESC" "Escape")
                 ("DEL" "BSpace")
                 ((rx bos "<" (let key (+ (not ">"))) ">" eos)
                  (pcase key
                    ((and (rx bos "f" (let n (+ digit)) eos)
                          (guard (<= 1 (string-to-number n) 12)))
                     (upcase key))
                    ((or "up" "down" "left" "right") (capitalize key))
                    ("return" "Enter") ("tab" "Tab") ("backspace" "BSpace")
                    (_ (error "No tmux key for %s" description))))
                 (_ base))))
    (unless (remoto-keys--plain-p event)
      (concat mods base))))

(defconst remoto-keys--settle-keys (list (kbd "C-c a") (kbd "C-c c") (kbd "C-c e"))
  "The Embark keys, which act on what a live forge may still be fetching.")

(defun remoto-keys--steps (parts profile)
  "Return what typing PARTS of a case under PROFILE takes.
A step is (text STRING), (key NAME) for tmux, (paste TOKEN) or (pause).
A string part may hold keys: `kbd' gives one when all are characters.
Pending input cancels a fetch, so Embark and keys after a submit wait."
  (let (steps)
    (while parts
      (let ((part (pop parts)))
        (when (and (member part remoto-keys--settle-keys) (not (equal (car steps) '(pause))))
          (push '(pause) steps))
        (pcase part
          ('submit (setq part (kbd (cdr (assoc profile remoto-e2e--submit))))
                   (when (and parts (not (eq (car parts) 'pause)))
                     (push 'pause parts)))
          ('goto (setq part [f12])))
        (cond
         ((eq part 'pause)
          (push '(pause) steps))
         ((memq part '(token padded-token codeberg-token))
          (push `(paste ,part) steps))
         (t
          (let (text)
            (seq-doseq (event part)
              (if (remoto-keys--plain-p event)
                  (push event text)
                (when text
                  (push `(text ,(concat (nreverse text))) steps)
                  (setq text nil))
                (push `(key ,(remoto-keys--tmux-key event)) steps)))
            (when text
              (push `(text ,(concat (nreverse text))) steps)))))))
    (nreverse steps)))

(defun remoto-keys--type (name script)
  "Type SCRIPT, from `remoto-keys--steps', into the profile NAME."
  (dolist (step script)
    (pcase step
      (`(paste ,which) (remoto-keys--paste name which))
      (`(text ,text) (remoto-keys--tmux "send-keys" "-t" (remoto-keys--target name)
                                        "-l" "--" text))
      (`(key ,key) (remoto-keys--tmux "send-keys" "-t" (remoto-keys--target name) key))
      ('(pause) (sleep-for remoto-keys--pause)
       (remoto-keys--wait-idle name 20)))))

(defun remoto-keys--run (name case profile &optional continue)
  "Run CASE, (LABEL BINDINGS . PARTS), in the profile NAME of PROFILE.
CONTINUE types into what the last case left, instead of after a reset.
Return a plist of the label, seconds, a note, the line and the state."
  (pcase-let ((`(,label ,_bindings . ,parts) case))
    (if continue
        (remoto-keys--eval name '(remoto-keys-mark))
      ;; One C-g at a time: two into a busy Emacs make an emergency escape.
      (dotimes (_ 3)
        (when (ignore-errors (remoto-keys--eval name '(and (active-minibuffer-window) t)))
          (remoto-keys--tmux "send-keys" "-t" (remoto-keys--target name) "C-g")
          (remoto-keys--wait-idle name 5)))
      (remoto-keys--eval name '(remoto-keys-reset)))
    (remoto-keys--wait-for-search)
    (let ((start (float-time)))
      (remoto-keys--type name (remoto-keys--steps parts profile))
      (let* ((note (remoto-keys--wait-idle name remoto-keys--case-seconds))
             (seconds (round (- (float-time) start)))
             (state (remoto-keys--redact (remoto-keys--eval name '(remoto-keys-state))))
             (dead (remoto-keys--dead-urls state)))
        (list :label label :seconds seconds :note note
              :line (remoto-keys--redact (remoto-keys--eval name '(remoto-keys-line)))
              :state (if dead (append state (list :dead dead)) state))))))

(defun remoto-keys--run-safely (name case profile elpa)
  "Run CASE in the profile NAME of PROFILE as `remoto-keys--run' does.
When the case signals, return a result without a state whose note says
why, and give the Emacs of NAME, remoto from ELPA, a chance to recover."
  (let ((start (float-time)))
    (condition-case err
        (remoto-keys--run name case profile)
      (error
       ;; A refused connection's data goes on with the whole process plist.
       (let ((why (format "no state: %s" (error-message-string (seq-take err 3))))
             (seconds (round (- (float-time) start))))
         (remoto-keys--revive name profile elpa)
         (list :label (car case) :seconds seconds :note why :line "no state"))))))

;;; Runs

(defun remoto-keys--print (name result)
  "Print the line of RESULT, a case of the profile NAME."
  (princ (format "%-16s %-58s %3ss => %s%s\n" name (plist-get result :label)
                 (plist-get result :seconds) (plist-get result :line)
                 (if-let* ((note (plist-get result :note))) (format " [%s]" note) ""))))

(defun remoto-keys--write (file results)
  "Write RESULTS, plists of `remoto-keys--run', to FILE as one state per case."
  (let ((print-length nil) (print-level nil)
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";; -*- mode: lisp-data -*-\n")
      (dolist (result results)
        (insert "\n")
        (pp (cons (plist-get result :label) (plist-get result :state)) (current-buffer))))))

;;; Fixed checks

(defconst remoto-keys--max-requests 20
  "The distinct requests one case may make before a check calls it too many.
The commit annotations count apart, as many again per directory: remoto
asks for up to 20, one per file of the directory it lists.")

(defun remoto-keys--annotation-p (request)
  "Non-nil when REQUEST asks for the last commit of one file, an annotation."
  (string-match-p "/commits\\?sha=[^&]*&path=" request))

(defun remoto-keys--annotation-dir (request)
  "Return the repository, ref and directory of the file annotation REQUEST, or nil."
  (when (string-match "\\`\\(?:async \\)?\\(.*/commits\\?sha=[^&]*\\)&path=\\([^&]*\\)"
                      request)
    (let ((path (url-unhex-string (match-string 2 request))))
      (concat (match-string 1 request) " " (or (file-name-directory path) "")))))

(defun remoto-keys--request-counts (requests)
  "Return (DISTINCT . ANNOTATIONS) for REQUESTS, the calls of one case.
DISTINCT counts each endpoint once, the commit annotations aside, so a
call that a pending request answers again is no new request; ANNOTATIONS
is the most distinct annotations of one directory."
  (let ((endpoints (delete-dups (mapcar (lambda (request)
                                          (string-remove-prefix "async " request))
                                        requests))))
    (cons (seq-count (lambda (endpoint) (not (remoto-keys--annotation-p endpoint)))
                     endpoints)
          (apply #'max 0 (mapcar (lambda (group) (length (cdr group)))
                                 (seq-group-by #'remoto-keys--annotation-dir
                                               (seq-filter #'remoto-keys--annotation-p
                                                           endpoints)))))))

(defconst remoto-keys--ido-landings
  '(("ff /gh:agzam/remoto.el/") ("ff /gh:agzam/remoto.el@2.2.0:/")
    ("ff /gh:agzam/remoto.el@ceaf310:/") ("ff /gh:agzam/remoto el")
    ("ff /gh:Agzam/Remoto.el" :dired "/github:agzam/Remoto.el@main:/")
    ("dired /gh:agzam" :dired "/github:agzam/") ("dired /gh:qlik" :dired "/github:qlik/")
    ("dired /gh:agzam/remoto") ("dired /gh:agzam/remoto.el/")
    ("dired /gh:agzam/remoto.el/README.org" :dired "/github:agzam/remoto.el@main:/README.org/")
    ("dired /gh:agzam/remoto.el/READ" :dired "/github:agzam/remoto.el@main:/READ/")
    ("dired /gh:agzam/remoto.el/nope.txt" :dired "/github:agzam/remoto.el@main:/nope.txt/")
    ("dired /gh:agzam/remoto.el@ma") ("dired /gh:agzam/remoto.el@main:/test/remo")
    ("dired /gh:agzam/remoto.el@2.2.0:/") ("dired /gh:agzam/remoto.el@2.2")
    ("dired /gh:agzam/remoto.el@ceaf310:/") ("dired /gh:agzam/.doom")
    ("dired /gh:Agzam/Remoto.el" :dired "/github:agzam/Remoto.el@main:/")
    ("dired /gh:agzam/remoto el") ("dired https://github.com/agzam/remoto.el"))
  "Where ido ends a case that vanilla ends elsewhere, origin/main as the branch.
ido's C-j submits what ido completed, not what was typed.  A label with
no landing ends in no Dired and no file, so it has no landing to check.")

(defvar remoto-keys--golden nil
  "The replay's expected states read so far, an alist by profile.")

(defun remoto-keys--expected-state (profile label)
  "Return the replay's expected state of the case LABEL under PROFILE, or nil.
A profile without golden files takes vanilla's, and evil's for ex cases;
ido's own landings come from `remoto-keys--ido-landings'.  RET on an
account line opens `remoto-e2e--root-account'."
  (let ((reference (cond ((member profile remoto-e2e-profiles) profile)
                         ((string-prefix-p "ex " label) "evil")
                         (t "vanilla"))))
    (unless (assoc reference remoto-keys--golden)
      (push (cons reference
                  (remoto-e2e--read-states
                   (expand-file-name (format "e2e/expected/%s.eld" reference)
                                     remoto-keys--test-dir)))
            remoto-keys--golden))
    (let ((state (cdr (assoc label (cdr (assoc reference remoto-keys--golden))))))
      (cond ((and (equal profile "ido") (assoc label remoto-keys--ido-landings))
             (cdr (assoc label remoto-keys--ido-landings)))
            ((and state (equal label "dired RET on an account line"))
             (plist-put (copy-sequence state) :dired
                        (format "/github:%s/" remoto-e2e--root-account)))
            (t state)))))

(defun remoto-keys--landing (state)
  "Return where STATE ended: (:dired DIRECTORY), (:file FILE), or nil."
  (cond ((plist-get state :dired) (list :dired (plist-get state :dired)))
        ((plist-get state :file) (list :file (plist-get state :file)))))

(defun remoto-keys--checks (label state expected note)
  "Return the failures of STATE, where the case LABEL ended, as strings.
EXPECTED is the replay's state or nil; NOTE the runner's.  The checks hold
whatever the data: the replay's landing, the typed name first among matches,
clean Dired and Embark lines, no raw HTTP text, few requests, live URLs."
  (let* ((typed (substring label (1+ (or (string-search " " label) -1))))
         ;; Without remoto here, TRAMP would claim a typed name with two colons.
         (leaf (let ((file-name-handler-alist nil))
                 (file-name-nondirectory (directory-file-name typed))))
         (want (remoto-keys--landing expected))
         (got (remoto-keys--landing state))
         (names (plist-get state :names))
         (counts (remoto-keys--request-counts (plist-get state :requests)))
         (requests (car counts))
         (annotations (cdr counts))
         failures)
    (when note
      (push note failures))
    (when (and want (not (equal want got)))
      (push (format "the replay ends in %S, this run in %S" want got) failures))
    (when (and (plist-get state :matches) (member leaf names) (not (equal leaf (car names))))
      (push (format "the typed name %s is not the first line" leaf) failures))
    (when-let* ((raw (car (plist-get state :raw))))
      (push (format "raw HTTP text in the messages: %s" (truncate-string-to-width raw 60))
            failures))
    (dolist (problem (plist-get state :problems))
      (push (format "%s: %s" (if (plist-get state :dired) "Dired" (plist-get state :buffer))
                    problem)
            failures))
    (pcase-dolist (`(,url . ,status) (plist-get state :dead))
      (push (format "%s answers %s" url (or status "nothing")) failures))
    (when (and (string-match-p "\\bembark y on\\b" label) (not (plist-get state :kill)))
      (push "Embark's y copied nothing" failures))
    (when (and (string-match-p "\\bembark b on\\b" label) (not (plist-get state :browsed)))
      (push "Embark's b browsed nothing" failures))
    (when (< remoto-keys--max-requests requests)
      (push (format "%d requests, more than %d" requests remoto-keys--max-requests) failures))
    (when (< remoto-keys--max-requests annotations)
      (push (format "%d commit annotations in one directory, more than %d" annotations
                    remoto-keys--max-requests)
            failures))
    (nreverse failures)))

(defun remoto-keys--check (name result expected)
  "Print the failures of RESULT, a case of the profile NAME, and return them.
EXPECTED is the replay's state of the case, or nil."
  (let ((failures (remoto-keys--checks (plist-get result :label) (plist-get result :state)
                                       expected (plist-get result :note))))
    (dolist (failure failures)
      (princ (format "FAIL %s | %s: %s\n" name (plist-get result :label) failure)))
    failures))

(defun remoto-keys--profile (profile elpa-branch elpa-main)
  "Run the cases of PROFILE under the remoto in ELPA-BRANCH.
With ELPA-MAIN, run each GitHub case also under origin/main's remoto
there; Codeberg cases run on the branch only, main has no Codeberg.
Return a plist of the cases run, the checks failed, the DIFFs with main.
An Emacs that cannot start stops the profile with a failure that says
why; the results so far are written all the same."
  (let ((names (cons profile (and elpa-main (list (concat profile "-main")))))
        (cases 0) (failed 0) (differ 0)
        branch main)
    (unwind-protect
        (condition-case err
            (progn
              (princ (format "start %s: %S\n" profile
                             (remoto-keys--start profile profile elpa-branch)))
              (when elpa-main
                (princ (format "start %s-main: %S\n" profile
                               (remoto-keys--start (concat profile "-main") profile elpa-main))))
              (dolist (case (append (mapcar (lambda (c) (cons 'github c))
                                            (remoto-e2e--cases profile))
                                    (mapcar (lambda (c) (cons 'codeberg c))
                                            (remoto-e2e--codeberg-cases profile))))
                (let ((forge (car case)) (case (cdr case)))
                  (if (nth 1 case)
                      (princ (format "%-16s %-58s skip: needs the replay's fake answers\n"
                                     profile (car case)))
                    (let ((result (remoto-keys--run-safely profile case profile elpa-branch)))
                      (cl-incf cases)
                      (remoto-keys--print profile result)
                      (push result branch)
                      (when (remoto-keys--check profile result
                                                (remoto-keys--expected-state profile (car case)))
                        (cl-incf failed))
                      (when (and elpa-main (eq forge 'github))
                        (let* ((other (remoto-keys--run-safely (cadr names) case profile
                                                               elpa-main))
                               (diff (and (plist-get other :state) (plist-get result :state)
                                          (remoto-e2e--diff (plist-get other :state)
                                                            (plist-get result :state)))))
                          (remoto-keys--print (cadr names) other)
                          (push other main)
                          (cond (diff
                                 (cl-incf differ)
                                 (princ (format "DIFF %s | %s\n%s" profile (car case)
                                                (pp-to-string diff))))
                                ((not (plist-get other :state))
                                 (cl-incf differ)
                                 (princ (format "DIFF %s | %s: origin/main has %s\n" profile
                                                (car case) (plist-get other :note))))))))))))
          (error
           (cl-incf failed)
           (princ (format "FAIL %s | stopped: %s\n" profile (error-message-string err)))))
      (unless remoto-keys--keep
        (mapc #'remoto-keys--stop names))
      (remoto-keys--write (expand-file-name (concat "results/" profile ".eld") remoto-keys--dir)
                          (reverse branch))
      (when main
        (remoto-keys--write (expand-file-name (concat "results/" profile "-main.eld")
                                              remoto-keys--dir)
                            (reverse main))))
    (list :cases cases :failed failed :differ differ)))

(defun remoto-keys--exit (what thunk)
  "Exit with the status from THUNK; on an error, say why WHAT stopped and exit 1.
A batch Emacs exits 255 on an error nothing catches, before any results."
  (kill-emacs (condition-case err
                  (funcall thunk)
                (error (princ (format "remoto-keys %s: stopped: %s\n" what
                                      (error-message-string err)))
                       1))))

(defun remoto-keys-main ()
  "Run the profiles of REMOTO_KEYS_PROFILES and exit."
  (remoto-keys--exit (string-join remoto-keys--profiles " ") #'remoto-keys--run-profiles))

(defun remoto-keys--run-profiles ()
  "Run the profiles of REMOTO_KEYS_PROFILES; return the exit status."
  (unless (executable-find "tmux")
    (error "The test-keys targets need tmux"))
  (make-directory remoto-keys--dir t)
  (let* ((start (float-time))
         (elpa-branch (expand-file-name "elpa-branch/" remoto-keys--dir))
         (elpa-main (and remoto-keys--main (expand-file-name "elpa-main/" remoto-keys--dir)))
         (cases 0) (failed 0) (differ 0))
    (remoto-keys--install-checkout elpa-branch)
    (remoto-keys--learn-logins)
    (when elpa-main
      (princ (format "origin/main %s: remoto %s\n"
                     (string-trim (remoto-keys--sh "git" "-C" remoto-keys--root
                                                   "log" "-1" "--format=%h %s" "origin/main"))
                     (remoto-keys--install (remoto-keys--main-source) elpa-main))))
    (dolist (profile remoto-keys--profiles)
      (let ((counts (remoto-keys--profile profile elpa-branch elpa-main)))
        (cl-incf cases (plist-get counts :cases))
        (cl-incf failed (plist-get counts :failed))
        (cl-incf differ (plist-get counts :differ))))
    (princ (format "remoto-keys %s: %d cases, %d failed%s, %.0f s, results in %s\n"
                   (string-join remoto-keys--profiles " ") cases failed
                   (if elpa-main (format ", %d differ from origin/main" differ) "")
                   (- (float-time) start)
                   (abbreviate-file-name (expand-file-name "results/" remoto-keys--dir))))
    (when remoto-keys--keep
      (let ((tmux (format "tmux -S %s" (abbreviate-file-name
                                        (expand-file-name "tmux.sock" remoto-keys--dir))))
            (name (car remoto-keys--profiles)))
        (princ (format (concat "kept running:\n  %s attach -t =rk-%s\n"
                               "  emacsclient -s %s --eval '(remoto-keys-line)'\n"
                               "  %s kill-server\n")
                       tmux name
                       (abbreviate-file-name (expand-file-name (concat "sock/" name)
                                                               remoto-keys--dir))
                       tmux))))
    (if (< 0 failed) 1 0)))

;;; Mock Forgejo

(defvar remoto-keys--fault "none"
  "What the mock Forgejo answers: \"none\" passes codeberg.org's answer on.")

(defconst remoto-keys--faults
  '(("429" 429 "text/plain" "Too Many Requests\n" ("Retry-After" . "60"))
    ("500" 500 "application/json" "{\"message\":\"internal error\"}")
    ("502" 502 "text/html" "<html><body><h1>502 Bad Gateway</h1></body></html>")
    ("503" 503 "application/json" "{\"message\":\"internal error\"}" ("Retry-After" . "30")))
  "The canned answers of the mock Forgejo, each (FAULT STATUS TYPE BODY . HEADERS).")

(defun remoto-keys--answer (status type body &rest headers)
  "Return the bytes of an HTTP answer of STATUS with BODY of TYPE and HEADERS."
  (let ((body (if (multibyte-string-p body) (encode-coding-string body 'utf-8) body)))
    (concat (format "HTTP/1.1 %d Mock\r\nContent-Type: %s\r\nContent-Length: %d\r\n"
                    status type (length body))
            (mapconcat (lambda (header) (format "%s: %s\r\n" (car header) (cdr header)))
                       headers "")
            "Connection: close\r\n\r\n" body)))

(defun remoto-keys--relay ()
  "Return the HTTP answer in the current buffer as the mock Forgejo passes it on.
The pages of a listing link to codeberg.org itself, as they did upstream."
  (goto-char (point-min))
  (let* ((status (if (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
                     (string-to-number (match-string 1))
                   502))
         (end (if (re-search-forward "\r?\n\r?\n" nil t) (point) (point-max)))
         (head (buffer-substring-no-properties (point-min) end))
         (field (lambda (name)
                  (let ((case-fold-search t))
                    (and (string-match (format "^%s: *\\([^\r\n]*\\)" name) head)
                         (match-string 1 head))))))
    (apply #'remoto-keys--answer status
           (or (funcall field "Content-Type") "application/json")
           (buffer-substring-no-properties end (point-max))
           (cl-loop for name in '("Link" "X-Total-Count")
                    for value = (funcall field name)
                    when value collect (cons name value)))))

(defun remoto-keys--mock-send (process answer)
  "Send ANSWER on PROCESS, a connection to the mock Forgejo, and close it."
  (when (process-live-p process)
    (process-send-string process answer)
    (delete-process process)))

(defun remoto-keys--upstream (path)
  "Return codeberg.org's answer to PATH as the mock Forgejo passes it on.
When none comes, return a 502 that says why."
  (pcase-let ((`(,exit . ,output)
               (if (remoto-keys--curl-p)
                   (let ((coding-system-for-read 'binary))
                     (remoto-keys--curl (concat "https://codeberg.org" path) nil
                                        "-i" "--http1.1" "-H" "Accept: application/json"))
                 '(nil . "No curl"))))
    (if (eql exit 0)
        (with-temp-buffer
          (insert output)
          (remoto-keys--relay))
      (remoto-keys--answer 502 "text/plain"
                           (format "mock Forgejo upstream: %s\n" (string-trim output))))))

(defun remoto-keys--mock-filter (process chunk)
  "Answer the request that CHUNK completes on PROCESS with `remoto-keys--fault'.
An error answers 502, since one that left a filter would end the batch run."
  (condition-case err
      (let ((head (concat (process-get process :head) chunk)))
        (process-put process :head head)
        (when (and (string-search "\r\n\r\n" head)
                   (string-match "\\`[A-Z]+ \\([^ ]+\\)" head))
          (let ((path (match-string 1 head)))
            (princ (format "  [mock Forgejo, fault %s: %s]\n" remoto-keys--fault path))
            (remoto-keys--mock-send
             process
             (if-let* ((canned (assoc remoto-keys--fault remoto-keys--faults)))
                 (apply #'remoto-keys--answer (cdr canned))
               (remoto-keys--upstream path))))))
    (error (remoto-keys--mock-send
            process (remoto-keys--answer 502 "text/plain"
                                         (format "mock Forgejo: %s\n"
                                                 (error-message-string err)))))))

(defun remoto-keys--mock-start ()
  "Start the mock Forgejo on a free port of 127.0.0.1 and return its process."
  (make-network-process :name "remoto-keys-mock" :server t
                        :host 'local :family 'ipv4 :service t
                        :coding 'binary :noquery t
                        :filter #'remoto-keys--mock-filter))

;;; Homes

(defun remoto-keys--with-token (text)
  "Return TEXT with %TOKEN% replaced by GitHub's token, or nil for no TEXT."
  (and text (string-replace "%TOKEN%" (or remoto-keys--token "") text)))

(defun remoto-keys--gnupg (home)
  "Make ~/.gnupg in HOME, whose agent asks a pinentry that opens no window.
The pinentry answers with `remoto-keys--passphrase' and logs each request
but the passphrase to ~/.gnupg/pinentry.log.  Return the directory."
  (let* ((dir (expand-file-name ".gnupg" home))
         (pinentry (expand-file-name "pinentry.sh" dir))
         (log (shell-quote-argument (expand-file-name "pinentry.log" dir))))
    (make-directory dir t)
    (set-file-modes dir #o700)
    (with-temp-file pinentry
      (insert "#!/bin/sh\necho 'OK Pleased to meet you'\n"
              "while IFS= read -r line; do\n  case $line in\n"
              "    SETDESC*|SETPROMPT*|SETREPEAT*|GETPIN*|CONFIRM*) printf '%s\\n' \"$line\" >> " log ";;\n"
              "  esac\n  case $line in\n"
              "    GETPIN*) echo 'D " remoto-keys--passphrase "'; echo OK;;\n"
              "    BYE*) echo 'OK closing connection'; exit 0;;\n"
              "    *) echo OK;;\n  esac\ndone\n"))
    (set-file-modes pinentry #o700)
    (with-temp-file (expand-file-name "gpg-agent.conf" dir)
      (insert "pinentry-program " pinentry "\nallow-loopback-pinentry\n"))
    dir))

(defun remoto-keys--gpg-call (dir &rest args)
  "Run gpg on the GnuPG home DIR with ARGS, no prompt, and return its output."
  (apply #'remoto-keys--sh remoto-keys--gpg "--homedir" dir "--batch" "--yes"
         "--pinentry-mode" "loopback" args))

(defun remoto-keys--encrypt (dir rows file how)
  "Write ROWS to FILE encrypted by the GnuPG home DIR, HOW being key or symmetric.
The rows pass through a file only the run can read, deleted at once."
  (let ((plain (with-file-modes #o600 (make-temp-file "rk-rows-"))))
    (unwind-protect
        (progn
          (with-temp-file plain (insert rows))
          (if (eq how 'symmetric)
              (remoto-keys--gpg-call dir "--passphrase" remoto-keys--passphrase
                                     "-c" "-o" file plain)
            (remoto-keys--gpg-call dir "--trust-model" "always"
                                   "-e" "-r" "e2e@remoto.invalid" "-o" file plain)))
      (delete-file plain))
    (set-file-modes file #o600)))

(defun remoto-keys--make-home (setup)
  "Make a HOME for a scenario of SETUP, with no file of the person running it.
:gnupg makes ~/.gnupg empty, with a key, or for a ~/.authinfo.gpg of the
:authinfo-gpg rows encrypted to that key, symmetrically, or to a key the
home lacks; :netrc writes ~/.netrc.  Short, under /tmp, for gpg's sockets."
  (let* ((home (file-name-as-directory (make-temp-file "/tmp/rk-home-" t)))
         (gnupg (plist-get setup :gnupg))
         (rows (remoto-keys--with-token (plist-get setup :authinfo-gpg)))
         (file (expand-file-name ".authinfo.gpg" home)))
    (when gnupg
      (let ((dir (remoto-keys--gnupg home)))
        (when (memq gnupg '(key otherkey))
          (let ((keys (if (eq gnupg 'key) dir (make-temp-file "/tmp/rk-keys-" t))))
            (remoto-keys--gpg-call keys "--passphrase" "" "--quick-gen-key"
                                   "remoto e2e <e2e@remoto.invalid>" "default" "default" "never")
            (when rows
              (remoto-keys--encrypt keys rows file 'key))
            (unless (eq gnupg 'key)
              (ignore-errors (call-process "gpgconf" nil nil nil "--homedir" keys "--kill" "all"))
              (delete-directory keys t))))
        (when (and rows (eq gnupg 'symmetric))
          (remoto-keys--encrypt dir rows file 'symmetric))))
    (when-let* ((mode (plist-get setup :authinfo-mode)))
      (set-file-modes file mode))
    (when-let* ((netrc (remoto-keys--with-token (plist-get setup :netrc))))
      (with-file-modes #o600
        (with-temp-file (expand-file-name ".netrc" home) (insert netrc))))
    home))

(defun remoto-keys--wipe-home (home)
  "Stop the gpg-agent of HOME and delete HOME, with the tokens it may hold."
  (ignore-errors (call-process "gpgconf" nil nil nil "--homedir"
                               (expand-file-name ".gnupg" home) "--kill" "all"))
  (ignore-errors (delete-directory home t)))

(defun remoto-keys--anonymous-left ()
  "Return GitHub's core requests left for this IP without a token, and their reset."
  (let-alist (remoto-keys--json "https://api.github.com/rate_limit" nil)
    (and (numberp .resources.core.remaining)
         (cons .resources.core.remaining .resources.core.reset))))

(defun remoto-keys--spend-anonymous ()
  "Spend what is left of GitHub's hourly requests without a token, from this IP.
GitHub's count lags between its servers, so it asks until three answers in
a row refuse.  Every read without a token then fails with GitHub's rate
limit until the reset, which is printed."
  (let ((spent 0) (refused 0))
    (while (and (< refused 3) (< spent 150))
      (pcase-let ((`(,exit . ,status)
                   (remoto-keys--curl "https://api.github.com/repos/agzam/remoto.el" nil
                                      "-o" "/dev/null" "-w" "%{http_code}")))
        (cl-incf spent)
        (setq refused (if (and (eql exit 0) (equal (string-trim status) "403")) (1+ refused) 0))))
    (princ (format "  [spent %d of GitHub's requests without a token; such reads fail until %s]\n"
                   spent (if-let* ((left (remoto-keys--anonymous-left)))
                             (format-time-string "%H:%M" (cdr left))
                           "?")))))

(defun remoto-keys--paste (name which)
  "Paste the token WHICH names into the profile NAME, as a terminal pastes text.
It goes through a file only the run can read and a tmux buffer, both
deleted at once, so no command line, trace or result holds it."
  (let ((token (pcase which
                 ('token remoto-keys--token)
                 ('padded-token (concat "  " remoto-keys--token "  \n"))
                 ('codeberg-token remoto-keys--codeberg-token)))
        (file (with-file-modes #o600 (make-temp-file "rk-paste-"))))
    (unwind-protect
        (progn
          (with-temp-file file (insert token))
          (remoto-keys--tmux "load-buffer" "-b" "rk-paste" file)
          (remoto-keys--tmux "paste-buffer" "-p" "-d" "-b" "rk-paste"
                             "-t" (remoto-keys--target name)))
      (delete-file file))))

(defun remoto-keys--visit (name file)
  "Visit FILE in the Emacs of NAME as `emacsclient -n FILE' does: from a process filter."
  (call-process (or (executable-find "emacsclient")
                    (expand-file-name "emacsclient" invocation-directory))
                nil nil nil "-s" (expand-file-name name (expand-file-name "sock/" remoto-keys--dir))
                "-n" file)
  (remoto-keys--wait-idle name 30))

(defun remoto-keys--redact (object)
  "Return OBJECT with the run's tokens replaced by <token> in every string.
A token pasted into a terminal Emacs lands in its kill ring, so a state,
a probe or a check can hold one."
  (let ((tokens (delq nil (list remoto-keys--token remoto-keys--codeberg-token))))
    (cl-labels ((walk (x)
                  (cond ((stringp x)
                         (seq-reduce (lambda (s token) (string-replace token "<token>" s)) tokens x))
                        ((consp x) (cons (walk (car x)) (walk (cdr x))))
                        ((vectorp x) (apply #'vector (mapcar #'walk x)))
                        (t x))))
      (walk object))))

(defun remoto-keys--check-value (value expected)
  "Non-nil when VALUE meets EXPECTED: a regexp it matches when a string, else equal."
  (if (stringp expected)
      (and (stringp value) (string-match-p expected value) t)
    (equal value expected)))

(defun remoto-keys--check-step (name label form expected)
  "Print LABEL with whether FORM's value in the Emacs of NAME meets EXPECTED.
Return non-nil when it does."
  (let* ((value (remoto-keys--redact
                 (condition-case err
                     (remoto-keys--eval name form)
                   (error (list 'error (error-message-string err))))))
         (pass (remoto-keys--check-value value expected)))
    (princ (format "%s %s | %s%s\n" (if pass "PASS" "FAIL") name label
                   (if pass ""
                     (format ": got %s, want %s"
                             (truncate-string-to-width (prin1-to-string value) 300)
                             (prin1-to-string expected)))))
    pass))

;;; Scenarios

(defun remoto-keys--ff (name)
  "Return the step that opens NAME with `find-file' after a reset."
  `(case ,(concat "ff " name) ,(kbd "C-x C-f") ,name submit))

(defun remoto-keys--setopt (instances &optional continue)
  "Return a setopt of `remoto-forgejo-instances' to INSTANCES for a scenario.
It types the form at `eval-expression', after a reset unless CONTINUE,
then shows the forges and the warnings."
  `((,(if continue 'step 'case) ,(format "setopt %S" instances)
     ,(kbd "M-:") ,(format "(setopt remoto-forgejo-instances '%S)" instances) ,(kbd "RET"))
    (probe "forges" (remoto-keys-forges))))

;;; Logins

(defconst remoto-keys--kept-rows
  "machine example.org login someone password kept\nmachine imap.example.org login someone port 993 password e2e-imap\n"
  "Rows of other hosts in a ~/.authinfo.gpg, which a login must keep.")

(defconst remoto-keys--hint
  "\\`Remoto: no GitHub token, 60 requests/hour\\. M-x remoto-login\\'"
  "What the first remoto buffer of a session without a token says.")

(defconst remoto-keys--limit-prompt
  "\\`GitHub rate limited until [0-9]+:[0-9]+\\. Log in now\\? (y or n) \\'"
  "The question a command meets when GitHub limits reads without a token.")

(defconst remoto-keys--limit-message
  "\\`Remoto: GitHub rate limited until [0-9]+:[0-9]+\\. M-x remoto-login\\'"
  "What remoto says of GitHub's limit when it may not ask.")

(defconst remoto-keys--refused-prompt
  "\\`GitHub refused the token\\. Log in again\\? (y or n) \\'"
  "The question a command meets when GitHub refuses the token.")

(defconst remoto-keys--token-page
  "\\`https://github\\.com/settings/tokens/new\\?scopes=repo,read:org&description=remoto\\'"
  "GitHub's page for a new classic token, its scopes ticked.")

(defun remoto-keys--open (profile name)
  "Return the parts that open NAME under PROFILE: its ex command under Evil alone."
  (if (equal profile "evil")
      `(,(kbd ": e SPC") ,name ,(kbd "RET"))
    `(,(kbd "C-x C-f") ,name submit)))

(defun remoto-keys--logged-in (forge)
  "Return the check that FORGE's login message names the token's account."
  `(check "says who logged in"
          (remoto-keys-message-count
           ,(format "^Remoto: logged in to %s as %s$" forge
                    (if (equal forge "GitHub") remoto-keys--github-login
                      remoto-keys--codeberg-login)))
          1))

(defconst remoto-keys--kill-clean
  '(check "the pasted token left the kill ring" (remoto-keys-kill-has-token-p) nil)
  "The check that no token of a login stays in the kill ring.")

(defun remoto-keys--rows (host login &optional others)
  "Return the check of ~/.authinfo.gpg: LOGIN's remoto row for HOST first.
OTHERS are the rows after it, the kept rows by default; the mode is 600."
  `(check "remoto's row first, the others kept, mode 600" (remoto-keys-authinfo)
          (:mode "600"
                 :rows (,(format "machine %s login %s^remoto password <login>" host login)
                        ,@(split-string (or others remoto-keys--kept-rows) "\n" t)))))

(defun remoto-keys--login-steps (&optional token)
  "Return what logging in to GitHub with `remoto-login' takes; TOKEN is a paste part."
  `((case "M-x remoto-login" ,(kbd "M-x") "remoto-login" ,(kbd "RET"))
    (check "offers GitHub first" (remoto-keys-prompt) "\\`Remoto: log in to (default GitHub): \\'")
    (step "RET for GitHub" ,(kbd "RET"))
    (check "opens GitHub's token page" (car remoto-keys--browsed) ,remoto-keys--token-page)
    (check "names the token page in *Messages*"
           (remoto-keys-message-count "^Remoto: make a GitHub token at https://github\\.com/settings/tokens/new")
           1)
    (check "asks for the token" (remoto-keys-prompt) "\\`GitHub token: \\'")
    (step "paste the token" ,(or token 'token) ,(kbd "RET"))
    ,remoto-keys--kill-clean))

(defun remoto-keys--first-contact (profile)
  "Return the scenario of a new user's first names under PROFILE, no token anywhere."
  (let ((open (lambda (name) (remoto-keys--open profile name))))
    `(,(concat "first-" profile) (:profile ,profile :home t :gitconfig "")
      (case "open a public repository" ,@(funcall open "/gh:agzam/remoto.el"))
      (check "it opens" (remoto-keys-directory) "\\`/github:agzam/remoto\\.el@main:/\\'")
      (check "the hint shows" (current-message) ,remoto-keys--hint)
      ;; Vertico and Marginalia would annotate the files of the repository at a
      ;; request each, which the hourly budget without a token cannot pay.
      ,@(unless (member profile '("vertico" "orderless" "embark" "evil-vertico" "full"))
          `((case "open a file of it" ,@(funcall open "/gh:agzam/remoto.el/README.org"))
            (check "the hint shows once a session" (remoto-keys-message-count "no GitHub token") 1)))
      (case "open a repository that does not exist"
            ,@(funcall open "/gh:agzam/no-such-repo-zz9q"))
      (check "says not found or private"
             (current-message)
             "\\`Remoto: agzam/no-such-repo-zz9q not found or private\\. M-x remoto-login\\'")
      (case "open /gh:" ,@(funcall open "/gh:"))
      (check "asks to log in" (remoto-keys-prompt) "needs a GitHub token\\. Log in now\\? (y or n) \\'")
      (step "n" "n")
      (check "n says how to log in" (current-message) "needs a GitHub token\\. M-x remoto-login\\'")
      (check "no request carried a token" (remoto-keys-tokenless-p "api.github.com") t)
      (check "url.el stored no password" (bound-and-true-p url-http-real-basic-auth-storage) nil))))

(defun remoto-keys--login-flow (profile)
  "Return the scenario of a new user's login under PROFILE, GitHub's limit run out.
It needs the run to spend GitHub's requests without a token, so it runs
only by name."
  (let ((open (remoto-keys--open profile "/gh:agzam/remoto.el"))
        (user remoto-keys--github-login))
    `(,(concat "login-" profile)
      (:profile ,profile :home t :limited t :paste t :gitconfig "" :gnupg key
                :authinfo-gpg ,remoto-keys--kept-rows)
      (case "open, rate limited" ,@open)
      (check "asks to log in, saying until when" (remoto-keys-prompt) ,remoto-keys--limit-prompt)
      (step "n" "n")
      (check "n says until when and how to log in" (current-message) ,remoto-keys--limit-message)
      (case "open again" ,@open)
      (check "asks no more this session" (remoto-keys-prompt) nil)
      (restart)
      (case "open in a new session" ,@open)
      (check "a new session asks again" (remoto-keys-prompt) ,remoto-keys--limit-prompt)
      (step "C-g at the question" ,(kbd "C-g"))
      (check "C-g leaves no question" (remoto-keys-prompt) nil)
      (case "open after C-g" ,@open)
      (check "C-g declined nothing" (remoto-keys-prompt) ,remoto-keys--limit-prompt)
      (step "y" "y")
      (check "opens GitHub's token page" (car remoto-keys--browsed) ,remoto-keys--token-page)
      (check "asks for the token" (remoto-keys-prompt) "\\`GitHub token: \\'")
      (step "paste the token" token ,(kbd "RET"))
      ,(remoto-keys--logged-in "GitHub")
      ,remoto-keys--kill-clean
      (check "the command finishes" (remoto-keys-directory) "\\`/github:agzam/remoto\\.el@main:/\\'")
      ,(remoto-keys--rows "github.com" user)
      (restart)
      (case "open in the next session" ,@open)
      (check "no question" (remoto-keys-prompt) nil)
      (check "no hint" (remoto-keys-message-count "no GitHub token") 0)
      (check "the next session sends the token" (remoto-keys-tokened-p "api.github.com") t))))

(defun remoto-keys--login-scenarios ()
  "Return the scenarios of remoto-login: a new user, the store, the questions.
The ones that spend GitHub's requests without a token run only by name."
  (let* ((user remoto-keys--github-login)
         (ff (lambda (name) (remoto-keys--ff name)))
         (stored (remoto-keys--rows "github.com" user))
         (opens '(check "the command finishes" (remoto-keys-directory)
                        "\\`/github:agzam/remoto\\.el@main:/\\'"))
         (no-question '(check "no question" (remoto-keys-prompt) nil))
         (existing (lambda (name setup)
                     `(,name (:home t :paste t ,@setup)
                             ,(funcall ff "/gh:agzam/remoto.el")
                             ,no-question ,opens
                             (check "no hint" (remoto-keys-message-count "no GitHub token") 0)
                             (check "every GitHub request sends the token"
                                    (remoto-keys-tokened-p "api.github.com") t)))))
    `(,@(mapcar #'remoto-keys--first-contact '("vanilla" "evil" "full"))
      ;; The first store: no ~/.authinfo.gpg yet.
      ("store-new" (:home t :paste t :gitconfig "" :gnupg empty)
       ,@(remoto-keys--login-steps)
       (check "no key list for a new file" (and (get-buffer-window "*Keys*") t) nil)
       (check "the agent's pinentry asked a new passphrase, twice"
              (seq-count (lambda (line) (string-prefix-p "GETPIN" line)) (remoto-keys-pinentry))
              2)
       ,(remoto-keys--logged-in "GitHub")
       ,(remoto-keys--rows "github.com" user ""))
      ("store-loopback" (:home t :paste t :gitconfig "" :gnupg empty
                               :init (setq epg-pinentry-mode 'loopback))
       ,@(remoto-keys--login-steps)
       (check "no key list for a new file" (and (get-buffer-window "*Keys*") t) nil)
       (check "asks a passphrase in the minibuffer" (remoto-keys-prompt)
              "\\`Passphrase for symmetric encryption for .*authinfo\\.gpg: \\'")
       (step "the passphrase" ,remoto-keys--passphrase ,(kbd "RET"))
       (check "asks it again" (remoto-keys-prompt) "\\`Confirm password: \\'")
       (step "the passphrase again" ,remoto-keys--passphrase ,(kbd "RET"))
       (check "the agent's pinentry was not asked" (remoto-keys-pinentry) nil)
       ,(remoto-keys--logged-in "GitHub")
       ,remoto-keys--kill-clean
       ,(remoto-keys--rows "github.com" user ""))
      ("store-nogpg" (:home t :paste t :gitconfig "" :no-gpg t)
       ,@(remoto-keys--login-steps)
       (check "says why it logged in for the session only" (current-message)
              ,(format "\\`Remoto: logged in to GitHub as %s for this session; ~/\\.authinfo\\.gpg: .*GPG error"
                       user))
       (check "a failed store keeps the token for the session" (remoto-keys-github-token-p) t))
      ("store-readonly" (:home t :paste t :gitconfig "" :gnupg key
                               :authinfo-gpg ,remoto-keys--kept-rows :authinfo-mode #o400)
       ,@(remoto-keys--login-steps)
       (check "says why it logged in for the session only" (current-message)
              ,(format "\\`Remoto: logged in to GitHub as %s for this session; ~/\\.authinfo\\.gpg: .*Permission denied"
                       user))
       (check "a failed store keeps the token for the session" (remoto-keys-github-token-p) t)
       (check "the file stays as it was" (plist-get (remoto-keys-authinfo) :rows)
              ,(split-string remoto-keys--kept-rows "\n" t)))
      ("store-nobrowser" (:home t :paste t :gitconfig "" :gnupg key :authinfo-gpg ,remoto-keys--kept-rows
                                :init (setq browse-url-browser-function
                                            (lambda (&rest _) (error "No usable browser found"))))
       (case "M-x remoto-login" ,(kbd "M-x") "remoto-login" ,(kbd "RET") ,(kbd "RET"))
       (check "the prompt names the token page" (remoto-keys-prompt)
              "\\`GitHub token, from https://github\\.com/settings/tokens/new\\?scopes=repo,read:org&description=remoto: \\'")
       (step "paste the token" token ,(kbd "RET"))
       ,(remoto-keys--logged-in "GitHub")
       ,stored)
      ("store-symmetric" (:home t :paste t :gitconfig "" :gnupg symmetric
                                :authinfo-gpg ,remoto-keys--kept-rows)
       ,@(remoto-keys--login-steps)
       (probe "pinentry" (remoto-keys-pinentry))
       ,(remoto-keys--logged-in "GitHub")
       ,stored)
      ("store-plain" (:home t :paste t :gitconfig ""
                            :init (setq auth-sources (list "~/.authinfo")))
       ,@(remoto-keys--login-steps)
       (check "logs in for the session" (remoto-keys-message-count
                                         ,(format "^Remoto: logged in to GitHub as %s for this session$"
                                                  user))
              1)
       (restart)
       (check "the next session has no token" (progn (require 'remoto)
                                                    (eq (remoto--auth remoto--github) 'none))
              t))
      ;; Tokens typed wrong, and tokens GitHub stopped taking.
      ("mistyped" (:home t :paste t :gitconfig "" :gnupg key :authinfo-gpg ,remoto-keys--kept-rows)
       (case "M-x remoto-login, a mistyped token" ,(kbd "M-x") "remoto-login" ,(kbd "RET")
             ,(kbd "RET") "ghp_e2eMistyped000000000000000000000000000" ,(kbd "RET"))
       (check "says GitHub refused it" (current-message) "\\`Remoto: GitHub refused the token\\'")
       (check "url.el asked no password" (bound-and-true-p url-http-real-basic-auth-storage) nil)
       (check "no login" (remoto-keys-github-token-p) nil)
       (case "M-x remoto-login, nothing typed" ,(kbd "M-x") "remoto-login" ,(kbd "RET")
             ,(kbd "RET") ,(kbd "RET"))
       (check "says no token was given" (current-message) "\\`Remoto: no token given\\'")
       (case "M-x remoto-login, a pasted token with spaces and a newline" ,(kbd "M-x")
             "remoto-login" ,(kbd "RET") ,(kbd "RET") padded-token ,(kbd "RET"))
       ,(remoto-keys--logged-in "GitHub")
       ,stored)
      ("revoked" (:home t :paste t :gitconfig "" :gnupg key
                         :authinfo-gpg ,(concat "machine github.com login " user
                                                "^remoto password ghp_e2eRevoked00000000000000000000000000\n"
                                                "machine github.com login " user "^forge password e2e-forge\n"
                                                remoto-keys--kept-rows))
       ,(funcall ff "/gh:agzam/remoto.el")
       (check "asks to log in again" (remoto-keys-prompt) ,remoto-keys--refused-prompt)
       (step "y" "y")
       (step "paste the token" token ,(kbd "RET"))
       ,opens
       ,(remoto-keys--rows "github.com" user
                           (concat "machine github.com login " user "^forge password e2e-forge\n"
                                   remoto-keys--kept-rows)))
      ("option-stale" (:home t :paste t :gitconfig "" :gnupg key :authinfo-gpg ,remoto-keys--kept-rows
                             :init (setq remoto-github-auth "ghp_e2eStale0000000000000000000000000000"))
       ,(funcall ff "/gh:agzam/remoto.el")
       (check "asks to log in again" (remoto-keys-prompt) ,remoto-keys--refused-prompt)
       (step "y" "y")
       (step "paste the token" token ,(kbd "RET"))
       ,opens
       (restart)
       ,(funcall ff "/gh:agzam/remoto.el")
       (check "the stored token serves the next session" (remoto-keys-prompt) nil)
       ,opens
       (check "says the option's token was refused"
              (remoto-keys-message-count
               "^Remoto: GitHub refused the token in remoto-github-auth, using the one auth-source holds$")
              1))
      ;; Setups from before remoto-login: none needs git config any more.
      ,(funcall existing "existing-ghub"
                `(:gitconfig ,(format "[github]\n\tuser = %s\n" user) :gnupg key
                             :authinfo-gpg ,(format "machine api.github.com login %s^ghub password %%TOKEN%%\n" user)))
      ,(funcall existing "existing-forge"
                `(:gitconfig "" :gnupg key
                             :authinfo-gpg ,(format "machine api.github.com login %s^forge password %%TOKEN%%\n" user)))
      ,(funcall existing "existing-netrc"
                `(:gitconfig "" :netrc ,(format "machine github.com login %s password %%TOKEN%%\n" user)))
      ,(funcall existing "accounts-gitconfig"
                `(:gitconfig ,(format "[github]\n\tuser = %s\n" user) :gnupg key
                             :authinfo-gpg ,(format "machine api.github.com login other^ghub password ghp_e2eOther0000000000000000000000000000\nmachine api.github.com login %s^ghub password %%TOKEN%%\n" user)))
      ("accounts" (:home t :paste t :gitconfig "" :gnupg key
                          :authinfo-gpg ,(format "machine api.github.com login other^ghub password ghp_e2eOther0000000000000000000000000000\nmachine api.github.com login %s^ghub password %%TOKEN%%\n" user))
       ,(funcall ff "/gh:agzam/remoto.el")
       ,no-question ,opens
       (check "the next row's token serves"
              (remoto-keys-message-count
               "^Remoto: GitHub refused a token, using the next one auth-source holds$")
              1))
      ("codeberg-login" (:home t :codeberg-paste t :gitconfig "" :gnupg key
                                :authinfo-gpg ,remoto-keys--kept-rows)
       ,(funcall ff "/cb:forgejo/docs")
       (check "no hint for Codeberg" (remoto-keys-message-count "no Codeberg token") 0)
       ,(funcall ff "/cb:")
       (check "asks to log in" (remoto-keys-prompt) "needs a Codeberg token\\. Log in now\\? (y or n) \\'")
       (step "y" "y")
       (check "opens Codeberg's applications page" (car remoto-keys--browsed)
              "\\`https://codeberg\\.org/user/settings/applications\\'")
       (check "names the permissions to tick" (remoto-keys-prompt)
              "\\`Codeberg token (Read: repository, issue, organization, user): \\'")
       (step "paste the token" codeberg-token ,(kbd "RET"))
       ,(remoto-keys--logged-in "Codeberg")
       (check "lists the account and its organizations" (remoto-keys-directory) "\\`/codeberg:")
       ,(remoto-keys--rows "codeberg.org" remoto-keys--codeberg-login)
       (check "GitHub got no request" (car (remoto-keys-token-share "api.github.com")) 0))
      ;; From here GitHub's requests without a token are spent.
      ("dired-ret" (:home t :spends t :gitconfig "")
       ,(funcall ff "/gh:agzam/remoto.el")
       ,opens
       (spend)
       (step "RET on README.org" ,(kbd "M-:")
             "(dired-goto-file \"/github:agzam/remoto.el@main:/README.org\")" ,(kbd "RET")
             ,(kbd "RET"))
       (check "RET on a file asks" (remoto-keys-prompt) ,remoto-keys--limit-prompt)
       (step "n" "n")
       (check "n says until when" (current-message) ,remoto-keys--limit-message)
       (step "RET on README.org again" ,(kbd "RET"))
       (check "asks no more this session" (remoto-keys-prompt) nil))
      ("option-none" (:home t :limited t :gitconfig "" :init (setq remoto-github-auth 'none))
       ,(funcall ff "/gh:agzam/remoto.el")
       (check "asks nothing" (remoto-keys-prompt) nil)
       (check "says until when" (current-message) "\\`Remoto: GitHub rate limited until [0-9]+:[0-9]+")
       (check "no hint" (remoto-keys-message-count "no GitHub token") 0))
      ("entry-points" (:home t :limited t :gitconfig ""
                              :init (progn (require 'bookmark)
                                           (bookmark-store "rk-readme"
                                                           '((filename . "/gh:agzam/remoto.el/README.org"))
                                                           nil)))
       ,@(mapcan
          (lambda (entry)
            `((case ,(car entry) ,@(cdr entry))
              (check ,(concat (car entry) " asks") (remoto-keys-prompt) ,remoto-keys--limit-prompt)
              (step "C-g" ,(kbd "C-g"))))
          `(("C-x d" ,(kbd "C-x d") "/gh:agzam/remoto.el" submit)
            ("C-x 4 f" ,(kbd "C-x 4 f") "/gh:agzam/remoto.el/README.org" submit)
            ("M-x remoto-browse" ,(kbd "M-x") "remoto-browse" ,(kbd "RET") "agzam/remoto.el"
             ,(kbd "RET"))
            ("C-x r b of a bookmark" ,(kbd "C-x r b") "rk-readme" ,(kbd "RET"))
            ("an org link" ,(kbd "M-:")
             "(progn (require 'org) (org-link-open-from-string \"[[file:/gh:agzam/remoto.el/README.org]]\"))"
             ,(kbd "RET"))))
       (case "TAB in the file prompt" ,(kbd "C-x C-f") "/gh:agzam/rem" pause ,(kbd "TAB"))
       (check "TAB asks nothing" (string-match-p "Log in" (or (remoto-keys-prompt) "")) nil)
       (case "a timer opens a file" ,(kbd "M-:")
             "(run-at-time 0 nil #'find-file \"/gh:agzam/remoto.el/README.org\")" ,(kbd "RET"))
       (check "a timer asks nothing" (remoto-keys-prompt) nil)
       (check "a timer's error prints plain text" (remoto-keys-message-count "user-error #(") 0)
       (visit "/gh:agzam/remoto.el/README.org")
       (check "emacsclient asks nothing" (remoto-keys-prompt) nil)
       (probe "messages" (with-current-buffer (messages-buffer)
                           (buffer-substring-no-properties
                            (max (point-min) (- (point-max) 600)) (point-max)))))
      ,@(mapcar #'remoto-keys--login-flow remoto-e2e-live-profiles))))

(defun remoto-keys--scenarios (port)
  "Return the scenarios that run with the mock Forgejo on PORT.
Each is (NAME SETUP . STEPS).  SETUP has :gitconfig and :authinfo texts, an
:init form, :token t and :codeberg t to need either forge's token.  A step is
\(case LABEL . PARTS), (step LABEL . PARTS), (probe LABEL FORM) or (fault F)."
  (let* ((mock (format "127.0.0.1:%d" port))
         (insecure `(progn (require 'ghub)
                           (setq ghub-insecure-hosts (list ,(concat mock "/api/v1")))))
         (mine (concat "/cb:" remoto-keys--codeberg-login "/")))
    `(("none" (:gitconfig "" :authinfo "")
       ,(remoto-keys--ff "/gh:") (probe "prompt" (remoto-keys-prompt))
       ,(remoto-keys--ff "/gh:agzam/remoto.el")
       ,(remoto-keys--ff "/cb:") (probe "prompt" (remoto-keys-prompt))
       ,(remoto-keys--ff "/cb:forgejo/docs")
       (probe "logins" (remoto-keys-logins))
       (probe "basic auth" (bound-and-true-p url-http-real-basic-auth-storage))
       (probe "auth" (remoto-keys-auth)))
      ("cbbad" (:gitconfig "[forgejo]\n\tuser = agzam\n"
                :authinfo "machine codeberg.org/api/v1 login agzam^ghub password not-a-token\n")
       ,(remoto-keys--ff "/cb:forgejo/docs")
       ,(remoto-keys--ff "/cb:forgejo/docs/README.md")
       ,(remoto-keys--ff "/cb:") (probe "prompt" (remoto-keys-prompt))
       ,(remoto-keys--ff "/gh:agzam/remoto.el")
       (probe "logins" (remoto-keys-logins))
       (case "C-u M-x remoto-reset-auth" ,(kbd "C-u M-x") "remoto-reset-auth"
             ,(kbd "RET") ,(kbd "RET"))
       (probe "logins" (remoto-keys-logins))
       (probe "auth" (remoto-keys-auth)))
      ("lit" (:gitconfig "[forgejo]\n\tuser = agzam\n" :authinfo "" :token t
              :init (progn (global-remoto-mode 1)
                           (setopt remoto-forgejo-instances '(("gitea" "gitea.com")))))
       ,(remoto-keys--ff "/gh:agzam/remoto.el")
       ,(remoto-keys--ff "/cb:forgejo/docs")
       ,(remoto-keys--ff "/cb:forgejo/docs/README.md")
       ,(remoto-keys--ff "/gitea:gitea/tea")
       (probe "auth" (remoto-keys-auth))
       (probe "logins" (remoto-keys-logins)))
      ("cbtoken" (:gitconfig "" :codeberg t)
       ,(remoto-keys--ff "/cb:") (probe "logins" (remoto-keys-logins))
       (case ,(concat "dired " mine) ,(kbd "C-x d") ,mine submit)
       ,@(when-let* ((org remoto-keys--codeberg-org)
                     (dir (concat "/cb:" org "/")))
           `((case ,(concat "dired " dir) ,(kbd "C-x d") ,dir submit)))
       ,@(when remoto-keys--codeberg-private
           (list (remoto-keys--ff (concat "/cb:" remoto-keys--codeberg-private))))
       ,(remoto-keys--ff "/cb:forgejo/docs")
       ,(remoto-keys--ff "/gh:agzam/remoto.el")
       (probe "auth" (remoto-keys-auth)))
      ("mock" (:gitconfig "" :authinfo ""
               :init (progn ,insecure (global-remoto-mode 1)
                            (setopt remoto-forgejo-instances '(("mock" ,mock)))))
       ,@(mapcan (lambda (fault)
                   `((fault ,fault)
                     (case ,(format "ff /mock:forgejo/docs, fault %s" fault)
                           ,(kbd "C-x C-f") "/mock:forgejo/docs" submit)))
                 '("429" "503" "502" "500" "none")))
      ("instances" (:gitconfig "" :authinfo "")
       ,(remoto-keys--ff "/cb:forgejo/docs")
       ,(remoto-keys--ff "/gitea:gitea/tea")
       ,@(remoto-keys--setopt '(("gitea" "gitea.com")))
       ,(remoto-keys--ff "/gitea:gitea/tea")
       (case "dired /gitea:gitea/" ,(kbd "C-x d") "/gitea:gitea/" submit)
       ,(remoto-keys--ff "/gitea:gitea/tea@main:/README.md")
       (step "M-x remoto-copy-url" ,(kbd "M-x") "remoto-copy-url" ,(kbd "RET"))
       (probe "kill" (car kill-ring))
       ,(remoto-keys--ff "https://gitea.com/gitea/tea")
       (case "dired /gitea:gitea/tea" ,(kbd "C-x d") "/gitea:gitea/tea" submit)
       ,@(remoto-keys--setopt nil t)
       (step "g in the /gitea: Dired" "g")
       ,(remoto-keys--ff "/gitea:gitea/tea")
       ,@(remoto-keys--setopt '(("gh" "gitea.com") ("cb" "example.org") ("gitea" "gitea.com")))
       ,(remoto-keys--ff "/gh:agzam/remoto.el")
       ,(remoto-keys--ff "/cb:forgejo/docs")
       ,@(remoto-keys--setopt '(("gs" "https://gitea.com")))
       ,(remoto-keys--ff "/gs:gitea/tea")
       ,@(remoto-keys--setopt '(("gt" "gitea.com/")))
       ,(remoto-keys--ff "/gt:gitea/tea")
       ,@(remoto-keys--setopt '(("gitea:" "gitea.com")))
       ,(remoto-keys--ff "/gitea::gitea/tea")
       (probe "insecure" ,insecure)
       ,@(remoto-keys--setopt `(("mock" ,mock)))
       ,(remoto-keys--ff "/mock:forgejo/forgejo#14989")
       (step "ff /cb:forgejo/forgejo#14989"
             ,(kbd "C-x C-f") "/cb:forgejo/forgejo#14989" submit)
       (probe "topics" (remoto-keys-topics)))
      ;; The first operation of a fresh session loads remoto through an autoload.
      ,@(mapcar (lambda (name)
                  `(,(concat "boot" (replace-regexp-in-string "[^[:alnum:]]+" "-" name))
                    (:gitconfig "")
                    ,(remoto-keys--ff name)
                    (probe "loaded" (remoto-keys-loaded))))
                '("/cb:forgejo/docs" "/cb:forgejo/docs/README.md" "/cb:forgejo/forgejo#14989"
                  "/gh:agzam/remoto.el" "/gh:agzam/remoto.el/README.org"
                  "/gh:agzam/remoto.el#51"))
      ,@(remoto-keys--login-scenarios))))

(defun remoto-keys--probe (name label form)
  "Print LABEL and the value of FORM in the profile NAME, or its error."
  (princ (format "  %s=%s\n" label
                 (truncate-string-to-width
                  (condition-case err
                      (prin1-to-string (remoto-keys--redact (remoto-keys--eval name form)))
                    (error (format "error: %s" (error-message-string err))))
                  400))))

(defun remoto-keys--skip (setup)
  "Return why a scenario of SETUP cannot run, or nil."
  (cond ((and (or (plist-get setup :token) (plist-get setup :paste)) (not remoto-keys--token))
         "needs REMOTO_E2E_TOKEN")
        ((and (or (plist-get setup :codeberg) (plist-get setup :codeberg-paste))
              (not remoto-keys--codeberg-token))
         "needs REMOTO_E2E_CODEBERG_TOKEN")
        ((and (plist-get setup :gnupg) (not remoto-keys--gpg))
         "needs gpg")))

(defun remoto-keys--scenario (scenario elpa)
  "Run SCENARIO in its profile, vanilla by default, with remoto from ELPA.
A (step ...) types where the last one ended, a (case ...) after a reset, a
\(check LABEL FORM EXPECTED) tests FORM's value, a (restart) starts a new
session, a (visit FILE) opens FILE through emacsclient, and a (spend) uses
up GitHub's requests without a token.  Return a plist of the cases and
checks run and of those that failed; a step that signals stops the
scenario with a failure that says why."
  (pcase-let* ((`(,name ,setup . ,steps) scenario)
               (profile (concat "sc-" name))
               (kind (or (plist-get setup :profile) "vanilla"))
               (cases 0) (failed 0) (results nil))
    (if-let* ((why (remoto-keys--skip setup)))
        (princ (format "=== %s: skip, %s\n" name why))
      (setq remoto-keys--fault "none")
      (unwind-protect
          (condition-case err
              (progn
                (princ (format "=== %s\n" name))
                (when (plist-get setup :limited)
                  (remoto-keys--spend-anonymous))
                (when (plist-get setup :home)
                  (setq setup (plist-put (copy-sequence setup) :home
                                         (remoto-keys--make-home setup))))
                (princ (format "start %s: %S\n" profile
                               (remoto-keys--start profile kind elpa setup)))
                (dolist (step steps)
                  (pcase step
                    (`(fault ,fault) (setq remoto-keys--fault fault))
                    (`(probe ,label ,form) (remoto-keys--probe profile label form))
                    (`(check ,label ,form ,expected)
                     (cl-incf cases)
                     (unless (remoto-keys--check-step profile label form expected)
                       (cl-incf failed)))
                    ('(restart)
                     (remoto-keys--stop profile)
                     (princ (format "restart %s: %S\n" profile
                                    (remoto-keys--start profile kind elpa setup))))
                    (`(visit ,file) (remoto-keys--visit profile file))
                    ('(spend) (remoto-keys--spend-anonymous))
                    (`(,(and kind (or 'case 'step)) ,label . ,parts)
                     (let ((result (remoto-keys--run profile `(,label nil ,@parts)
                                                     (or (plist-get setup :profile) "vanilla")
                                                     (eq kind 'step))))
                       (cl-incf cases)
                       (push result results)
                       (remoto-keys--print profile result)
                       (when (remoto-keys--check profile result nil)
                         (cl-incf failed))))
                    (_ (error "Unknown step %S" step)))))
            (error
             (cl-incf failed)
             (princ (format "FAIL %s | stopped: %s\n" profile (error-message-string err)))))
        (setq remoto-keys--fault "none")
        (unless remoto-keys--keep
          (remoto-keys--stop profile)
          (when (stringp (plist-get setup :home))
            (remoto-keys--wipe-home (plist-get setup :home))))
        (remoto-keys--write (expand-file-name (concat "results/" profile ".eld") remoto-keys--dir)
                            (reverse results))))
    (list :cases cases :failed failed)))

(defun remoto-keys--chosen-p (scenario only)
  "Return non-nil to run SCENARIO: ONLY names it, or ONLY is empty and it spends nothing.
A scenario that spends GitHub's requests without a token runs only by name."
  (if only
      (member (car scenario) only)
    (not (or (plist-get (cadr scenario) :limited) (plist-get (cadr scenario) :spends)))))

(defun remoto-keys-scenarios-main ()
  "Run the scenarios of REMOTO_KEYS_SCENARIOS, all by default, and exit."
  (remoto-keys--exit "scenarios" #'remoto-keys--run-scenarios))

(defun remoto-keys--run-scenarios ()
  "Run the scenarios of REMOTO_KEYS_SCENARIOS, all by default; return the exit status."
  (unless (executable-find "tmux")
    (error "The test-keys targets need tmux"))
  (make-directory remoto-keys--dir t)
  (let* ((start (float-time))
         (elpa (expand-file-name "elpa-branch/" remoto-keys--dir))
         (port (process-contact (remoto-keys--mock-start) :service))
         (only (split-string (or (getenv "REMOTO_KEYS_SCENARIOS") "") "[ ,]+" t))
         (cases 0) (failed 0))
    (remoto-keys--install-checkout elpa)
    (remoto-keys--learn-logins t)
    (princ (format "mock Forgejo on 127.0.0.1:%d\n" port))
    (dolist (scenario (remoto-keys--scenarios port))
      (when (remoto-keys--chosen-p scenario only)
        (let ((counts (remoto-keys--scenario scenario elpa)))
          (cl-incf cases (plist-get counts :cases))
          (cl-incf failed (plist-get counts :failed)))))
    (princ (format "remoto-keys scenarios %s: %d cases, %d failed, %.0f s, results in %s\n"
                   (if only (string-join only " ") "all") cases failed (- (float-time) start)
                   (abbreviate-file-name (expand-file-name "results/" remoto-keys--dir))))
    (if (< 0 failed) 1 0)))

;;; The running Emacs

(defconst remoto-keys--live-server (or (getenv "REMOTO_KEYS_SERVER") "server")
  "The server name of the running Emacs the live target types into.")

(defun remoto-keys--live (form &optional seconds)
  "Evaluate FORM in the running Emacs; signal an error after SECONDS, 30 by default."
  (let ((seconds (or seconds 30)))
    (with-timeout (seconds (error "No answer from the Emacs server %s in %ss"
                                  remoto-keys--live-server seconds))
      (server-eval-at remoto-keys--live-server form))))

(defconst remoto-keys--live-busy
  '(or (null (current-idle-time))
       (input-pending-p)
       (and (boundp 'remoto--sync-fetch-depth) (< 0 remoto--sync-fetch-depth)
            (< (float-time (current-idle-time)) 2))
       (and (boundp 'remoto--debounce-timer) (timerp remoto--debounce-timer)
            (memq remoto--debounce-timer timer-idle-list) t))
  "Non-nil in the running Emacs while it works on the keys of a case.")

(defun remoto-keys--live-wait (seconds)
  "Wait until the running Emacs is idle; return a note after SECONDS, else nil."
  (sleep-for 0.2)
  (let ((end (+ (float-time) seconds)))
    (while (and (< (float-time) end)
                (condition-case nil (remoto-keys--live remoto-keys--live-busy 5) (error t)))
      (sleep-for 0.25))
    (and (<= end (float-time)) (format "still busy after %ss" seconds))))

(defconst remoto-keys--live-save
  '(progn
     (defvar remoto-keys--live-saved nil)
     (defvar remoto-keys--live-calls nil)
     (setq remoto-keys--live-saved
           (list :windows (current-window-configuration)
                 :buffers (buffer-list)
                 :histories (mapcar (lambda (var) (cons var (copy-sequence (symbol-value var))))
                                    (seq-filter #'boundp '(file-name-history minibuffer-history
                                                           extended-command-history evil-ex-history
                                                           recentf-list)))
                 :places (and (boundp 'save-place-alist) (copy-alist save-place-alist)))
           remoto-keys--live-calls nil)
     (advice-add 'remoto--api :before
                 (lambda (&rest args)
                   (push (seq-find #'stringp args) remoto-keys--live-calls))
                 '((name . remoto-keys-live)))
     (advice-add 'remoto--api-async :before
                 (lambda (&rest args)
                   (push (concat "async " (seq-find #'stringp args)) remoto-keys--live-calls))
                 '((name . remoto-keys-live)))
     (list :remoto (locate-library "remoto")
           :submit (cond ((bound-and-true-p vertico-mode) "M-RET")
                         ((or (bound-and-true-p fido-mode) (bound-and-true-p fido-vertical-mode))
                          "M-j")
                         (t "RET"))))
  "Save what the cases touch, log remoto's requests, and say how to submit a prompt.")

(defconst remoto-keys--live-reset
  '(let ((saved remoto-keys--live-saved))
     (dolist (buffer (buffer-list))
       (unless (or (memq buffer (plist-get saved :buffers))
                   (string-prefix-p " " (buffer-name buffer))
                   (equal (buffer-name buffer) "*remoto-keys*"))
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (let ((kill-buffer-query-functions nil))
           (kill-buffer buffer))))
     (set-window-configuration (plist-get saved :windows))
     ;; Keys go to a buffer of their own, never to a terminal the run started from.
     (switch-to-buffer (get-buffer-create "*remoto-keys*"))
     (setq default-directory temporary-file-directory
           remoto-keys--live-calls nil)
     (message "")
     (with-current-buffer (messages-buffer) (point-max)))
  "Kill the buffers the last case opened, put the windows back; return the messages mark.")

(defconst remoto-keys--live-restore
  `(let ((saved remoto-keys--live-saved))
     (advice-remove 'remoto--api 'remoto-keys-live)
     (advice-remove 'remoto--api-async 'remoto-keys-live)
     ,remoto-keys--live-reset
     (set-window-configuration (plist-get saved :windows))
     (kill-buffer "*remoto-keys*")
     (dolist (history (plist-get saved :histories))
       (set (car history) (cdr history)))
     (when (boundp 'save-place-alist)
       (setq save-place-alist (plist-get saved :places)))
     (makunbound 'remoto-keys--live-saved)
     (makunbound 'remoto-keys--live-calls)
     'restored)
  "Undo everything the live target did to the running Emacs.")

(defun remoto-keys--live-state (mark)
  "Return a form that gives (LINE . STATE) of the case begun at *Messages* MARK."
  `(let* ((minibuffer (and (active-minibuffer-window)
                           (with-current-buffer (window-buffer (active-minibuffer-window))
                             (minibuffer-contents-no-properties))))
          (buffer (window-buffer (or (minibuffer-selected-window) (selected-window))))
          (messages (with-current-buffer (messages-buffer)
                      (split-string (buffer-substring-no-properties
                                     (min ,mark (point-max)) (point-max))
                                    "\n" t)))
          (calls remoto-keys--live-calls))
     (with-current-buffer buffer
       (let* ((dired (derived-mode-p 'dired-mode))
              (names (and dired
                          (save-excursion
                            (goto-char (point-min))
                            (let (names)
                              (while (not (eobp))
                                (when (dired-move-to-filename)
                                  (push (dired-get-filename 'verbatim t) names))
                                (forward-line 1))
                              (nreverse names))))))
         (cons (format "%s | %s | n=%d | calls=%d | %s"
                       (buffer-name)
                       (cond ((consp dired-directory)
                              (format "%s +%d" (car dired-directory) (length (cdr dired-directory))))
                             (dired dired-directory)
                             (buffer-file-name buffer-file-name)
                             (t major-mode))
                       (length names) (length calls)
                       (truncate-string-to-width (mapconcat #'identity messages " // ") 200))
               (cl-loop for (key value) on
                        (list :buffer (unless (or dired buffer-file-name) (buffer-name))
                              :mode major-mode
                              :dired (and dired (if (consp dired-directory)
                                                    (car dired-directory)
                                                  dired-directory))
                              :names (seq-take names 10)
                              :count (and names (length names))
                              :file buffer-file-name
                              :minibuffer minibuffer
                              :messages (seq-filter (lambda (line)
                                                      (string-match-p
                                                       "\\`\\(?:[Rr]emoto\\|Error\\)" line))
                                                    messages)
                              :requests (reverse calls))
                        by #'cddr
                        when value append (list key value)))))))

(defun remoto-keys--live-run (case submit)
  "Type CASE into the running Emacs; SUBMIT is the key that ends a prompt."
  (pcase-let ((`(,label ,_bindings . ,parts) case))
    (dotimes (_ 3)
      (when (ignore-errors (remoto-keys--live '(and (active-minibuffer-window) t)))
        (remoto-keys--live '(progn (setq unread-command-events (list ?\C-g)) t))
        (remoto-keys--live-wait 5)))
    (let ((mark (remoto-keys--live remoto-keys--live-reset))
          (keys (apply #'vconcat (mapcar (lambda (part) (if (eq part 'submit) (kbd submit) part))
                                         parts)))
          (start (float-time)))
      (remoto-keys--wait-for-search)
      (remoto-keys--live `(progn (setq unread-command-events
                                       (append unread-command-events (listify-key-sequence ,keys)))
                                 t))
      (let* ((note (remoto-keys--live-wait remoto-keys--case-seconds))
             (result (remoto-keys--live (remoto-keys--live-state mark))))
        (list :label label :seconds (round (- (float-time) start)) :note note
              :line (car result) :state (cdr result))))))

(defun remoto-keys-live-main ()
  "Type the file and Dired cases into the running Emacs, restore it, and exit."
  (remoto-keys--exit "live" #'remoto-keys--run-live))

(defun remoto-keys--run-live ()
  "Type the file and Dired cases into the running Emacs and restore it; return 0.
The results so far are written, and the Emacs restored, when a case signals."
  (let* ((start (float-time))
         (cases (remoto-e2e--selected (remoto-e2e--matrix "vanilla")))
         results)
    (let ((setup (remoto-keys--live remoto-keys--live-save)))
      (princ (format "running Emacs: %S\nhands off the keyboard: %d cases start in 3 s\n"
                     setup (length cases)))
      (sleep-for 3)
      (unwind-protect
          (dolist (case cases)
            (let ((result (remoto-keys--live-run case (plist-get setup :submit))))
              (remoto-keys--print "live" result)
              (push result results)))
        (princ (format "running Emacs %s\n"
                       (condition-case err (remoto-keys--live remoto-keys--live-restore)
                         (error (format "NOT restored: %s" (error-message-string err))))))
        (remoto-keys--write (expand-file-name "results/live.eld" remoto-keys--dir)
                            (reverse results))))
    (princ (format "remoto-keys live: %d cases, %.0f s, results in %s\n"
                   (length results) (- (float-time) start)
                   (abbreviate-file-name (expand-file-name "results/" remoto-keys--dir))))
    0))

(provide 'remoto-keys)
;;; remoto-keys.el ends here
