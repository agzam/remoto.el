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

(defun remoto-keys--search-left ()
  "Return GitHub's search requests left and the time they come back, or nil."
  (let ((url-request-extra-headers
         (and remoto-keys--token
              `(("Authorization" . ,(concat "token " remoto-keys--token)))))
        (url-show-status nil))
    (when-let* ((buffer (ignore-errors
                          (url-retrieve-synchronously "https://api.github.com/rate_limit"
                                                      t t 10))))
      (with-current-buffer buffer
        (unwind-protect
            (when (re-search-forward "\n\n" nil t)
              (let-alist (json-parse-buffer :object-type 'alist)
                (cons .resources.search.remaining .resources.search.reset)))
          (kill-buffer buffer))))))

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

(defun remoto-keys--env (name profile elpa &optional setup)
  "Return the whole environment of the profile NAME: PROFILE, remoto from ELPA.
SETUP is the plist of a scenario of `remoto-keys--scenarios'.  Git config
never comes from the person running it, so no account name either."
  (append
   (mapcar (lambda (var) (concat var "=" (or (getenv var) "")))
           '("HOME" "USER" "LOGNAME" "SHELL" "TMPDIR" "PATH"))
   (list (concat "LANG=" (or (getenv "LANG") "en_US.UTF-8"))
         ;; A screen TERM keeps Emacs from querying the terminal at startup.
         "TERM=screen-256color"
         "GIT_CONFIG_NOSYSTEM=1"
         (concat "GIT_CONFIG_GLOBAL="
                 (remoto-keys--fixture name "gitconfig" (plist-get setup :gitconfig)))
         (concat "REMOTO_KEYS_ELPA=" elpa)
         (concat "REMOTO_KEYS_PROFILE=" profile)
         (concat "REMOTO_KEYS_SOCKET_DIR=" (expand-file-name "sock/" remoto-keys--dir))
         (concat "REMOTO_KEYS_SERVER=" name))
   (when-let* ((text (plist-get setup :authinfo)))
     (list (concat "REMOTO_KEYS_AUTHINFO=" (remoto-keys--fixture name "authinfo" text))))
   (when-let* ((form (plist-get setup :init)))
     (list (concat "REMOTO_KEYS_INIT=" (prin1-to-string form))))
   (when (and remoto-keys--token (or (null setup) (plist-get setup :token)))
     (let ((file (expand-file-name (concat "token-" name) remoto-keys--dir)))
       (with-file-modes #o600
         (with-temp-file file (insert remoto-keys--token)))
       (list (concat "REMOTO_KEYS_TOKEN_FILE=" file))))))

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
  (ignore-errors (delete-file (expand-file-name (concat "token-" name) remoto-keys--dir))))

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

(defun remoto-keys--steps (parts profile)
  "Return what typing PARTS of a case under PROFILE takes.
A step is (text STRING), (key NAME) for tmux, or (pause).  A string
part may hold keys too: `kbd' gives one when every key is a character."
  (let (steps)
    (dolist (part parts)
      (pcase part
        ('submit (setq part (kbd (cdr (assoc profile remoto-e2e--submit)))))
        ('goto (setq part [f12])))
      (if (eq part 'pause)
          (push '(pause) steps)
        (let (text)
          (seq-doseq (event part)
            (if (remoto-keys--plain-p event)
                (push event text)
              (when text
                (push `(text ,(concat (nreverse text))) steps)
                (setq text nil))
              (push `(key ,(remoto-keys--tmux-key event)) steps)))
          (when text
            (push `(text ,(concat (nreverse text))) steps)))))
    (nreverse steps)))

(defun remoto-keys--type (name script)
  "Type SCRIPT, from `remoto-keys--steps', into the profile NAME."
  (dolist (step script)
    (pcase step
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
      (let ((note (remoto-keys--wait-idle name remoto-keys--case-seconds)))
        (list :label label :seconds (round (- (float-time) start)) :note note
              :line (remoto-keys--eval name '(remoto-keys-line))
              :state (remoto-keys--eval name '(remoto-keys-state)))))))

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
  "The requests one case may make before a check calls it too many.")

(defvar remoto-keys--golden nil
  "The replay's expected states read so far, an alist by profile.")

(defun remoto-keys--expected-state (profile label)
  "Return the replay's expected state of the case LABEL under PROFILE, or nil.
A profile without golden files takes vanilla's, and evil's for ex cases."
  (let ((reference (cond ((member profile remoto-e2e-profiles) profile)
                         ((string-prefix-p "ex " label) "evil")
                         (t "vanilla"))))
    (unless (assoc reference remoto-keys--golden)
      (push (cons reference
                  (remoto-e2e--read-states
                   (expand-file-name (format "e2e/expected/%s.eld" reference)
                                     remoto-keys--test-dir)))
            remoto-keys--golden))
    (cdr (assoc label (cdr (assoc reference remoto-keys--golden))))))

(defun remoto-keys--landing (state)
  "Return where STATE ended: (:dired DIRECTORY), (:file FILE), or nil."
  (cond ((plist-get state :dired) (list :dired (plist-get state :dired)))
        ((plist-get state :file) (list :file (plist-get state :file)))))

(defun remoto-keys--checks (label state expected note)
  "Return the failures of STATE, where the case LABEL ended, as strings.
EXPECTED is the replay's state of the case or nil; NOTE the runner's note.
The checks hold whatever the forge's data: the replay's landing, the typed
name first among matches, no raw HTTP text, a bounded number of requests."
  (let* ((typed (substring label (1+ (or (string-search " " label) -1))))
         ;; Without remoto here, TRAMP would claim a typed name with two colons.
         (leaf (let ((file-name-handler-alist nil))
                 (file-name-nondirectory (directory-file-name typed))))
         (want (remoto-keys--landing expected))
         (got (remoto-keys--landing state))
         (names (plist-get state :names))
         (requests (length (plist-get state :requests)))
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
    (when (< remoto-keys--max-requests requests)
      (push (format "%d requests, more than %d" requests remoto-keys--max-requests) failures))
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
Return a plist of the cases run, the checks failed, the DIFFs with main."
  (let ((names (cons profile (and elpa-main (list (concat profile "-main")))))
        (cases 0) (failed 0) (differ 0)
        branch main)
    (unwind-protect
        (progn
          (princ (format "start %s: %S\n" profile (remoto-keys--start profile profile elpa-branch)))
          (when elpa-main
            (princ (format "start %s-main: %S\n" profile
                           (remoto-keys--start (concat profile "-main") profile elpa-main))))
          (dolist (case (append (mapcar (lambda (c) (cons 'github c)) (remoto-e2e--cases profile))
                                (mapcar (lambda (c) (cons 'codeberg c))
                                        (remoto-e2e--codeberg-cases profile))))
            (let ((forge (car case)) (case (cdr case)))
              (if (nth 1 case)
                  (princ (format "%-16s %-58s skip: needs the replay's fake answers\n"
                                 profile (car case)))
                (let ((result (remoto-keys--run profile case profile)))
                  (cl-incf cases)
                  (remoto-keys--print profile result)
                  (push result branch)
                  (when (remoto-keys--check profile result
                                            (remoto-keys--expected-state profile (car case)))
                    (cl-incf failed))
                  (when (and elpa-main (eq forge 'github))
                    (let* ((other (remoto-keys--run (cadr names) case profile))
                           (diff (remoto-e2e--diff (plist-get other :state)
                                                   (plist-get result :state))))
                      (remoto-keys--print (cadr names) other)
                      (push other main)
                      (when diff
                        (cl-incf differ)
                        (princ (format "DIFF %s | %s\n%s" profile (car case)
                                       (pp-to-string diff)))))))))))
      (unless remoto-keys--keep
        (mapc #'remoto-keys--stop names)))
    (remoto-keys--write (expand-file-name (concat "results/" profile ".eld") remoto-keys--dir)
                        (reverse branch))
    (when main
      (remoto-keys--write (expand-file-name (concat "results/" profile "-main.eld")
                                            remoto-keys--dir)
                          (reverse main)))
    (list :cases cases :failed failed :differ differ)))

(defun remoto-keys-main ()
  "Run the profiles of REMOTO_KEYS_PROFILES and exit."
  (unless (executable-find "tmux")
    (error "The test-keys targets need tmux"))
  (make-directory remoto-keys--dir t)
  (let* ((start (float-time))
         (elpa-branch (expand-file-name "elpa-branch/" remoto-keys--dir))
         (elpa-main (and remoto-keys--main (expand-file-name "elpa-main/" remoto-keys--dir)))
         (cases 0) (failed 0) (differ 0))
    (remoto-keys--install-checkout elpa-branch)
    (when elpa-main
      (princ (format "origin/main %s: remoto %s\n"
                     (string-trim (remoto-keys--sh "git" "-C" remoto-keys--root
                                                   "log" "-1" "--format=%h %s" "origin/main"))
                     (remoto-keys--install (remoto-keys--main-source) elpa-main))))
    (unwind-protect
        (dolist (profile remoto-keys--profiles)
          (let ((counts (remoto-keys--profile profile elpa-branch elpa-main)))
            (cl-incf cases (plist-get counts :cases))
            (cl-incf failed (plist-get counts :failed))
            (cl-incf differ (plist-get counts :differ))))
      (unless remoto-keys--keep
        (ignore-errors (remoto-keys--tmux "kill-server"))))
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
    (kill-emacs (if (< 0 failed) 1 0))))

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
  "Return the answer in the current url.el buffer as the mock Forgejo passes it on.
The pages of a listing link to codeberg.org itself, as they did upstream."
  (goto-char (point-min))
  (let* ((status (if (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
                     (string-to-number (match-string 1))
                   502))
         (end (if (re-search-forward "\r?\n\r?\n" nil t) (point) (point-max)))
         (head (buffer-substring-no-properties (point-min) end))
         (field (lambda (name)
                  (and (string-match (format "^%s: *\\([^\r\n]*\\)" name) head)
                       (match-string 1 head)))))
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

(defun remoto-keys--mock-filter (process chunk)
  "Answer the request that CHUNK completes on PROCESS with `remoto-keys--fault'."
  (let ((head (concat (process-get process :head) chunk)))
    (process-put process :head head)
    (when (and (string-search "\r\n\r\n" head)
               (string-match "\\`[A-Z]+ \\([^ ]+\\)" head))
      (let ((path (match-string 1 head)))
        (princ (format "  [mock Forgejo, fault %s: %s]\n" remoto-keys--fault path))
        (if-let* ((canned (assoc remoto-keys--fault remoto-keys--faults)))
            (remoto-keys--mock-send process (apply #'remoto-keys--answer (cdr canned)))
          (let ((url-request-extra-headers '(("Accept" . "application/json"))))
            (url-retrieve (concat "https://codeberg.org" path)
                          (lambda (_status)
                            (let ((answer (remoto-keys--relay)))
                              (kill-buffer)
                              (remoto-keys--mock-send process answer)))
                          nil t t)))))))

(defun remoto-keys--mock-start ()
  "Start the mock Forgejo on a free port of 127.0.0.1 and return its process."
  (make-network-process :name "remoto-keys-mock" :server t
                        :host 'local :family 'ipv4 :service t
                        :coding 'binary :noquery t
                        :filter #'remoto-keys--mock-filter))

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

(defun remoto-keys--scenarios (port)
  "Return the scenarios that run with the mock Forgejo on PORT.
Each is (NAME SETUP . STEPS).  SETUP has :gitconfig and :authinfo texts,
an :init form, and :token t to need REMOTO_E2E_TOKEN.  A step is (case
LABEL . PARTS), (step LABEL . PARTS), (probe LABEL FORM) or (fault F)."
  (let* ((mock (format "127.0.0.1:%d" port))
         (insecure `(progn (require 'ghub)
                           (setq ghub-insecure-hosts (list ,(concat mock "/api/v1")))))
         (both "[github]\n\tuser = agzam\n[forgejo]\n\tuser = agzam\n"))
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
      ("lit" (:gitconfig ,both :authinfo "" :token t
              :init (progn (global-remoto-mode 1)
                           (setopt remoto-forgejo-instances '(("gitea" "gitea.com")))))
       ,(remoto-keys--ff "/gh:agzam/remoto.el")
       ,(remoto-keys--ff "/cb:forgejo/docs")
       ,(remoto-keys--ff "/cb:forgejo/docs/README.md")
       ,(remoto-keys--ff "/gitea:gitea/tea")
       (probe "auth" (remoto-keys-auth))
       (probe "logins" (remoto-keys-logins)))
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
       (probe "topics" (remoto-keys-topics))))))

(defun remoto-keys--probe (name label form)
  "Print LABEL and the value of FORM in the profile NAME, or its error."
  (princ (format "  %s=%s\n" label
                 (truncate-string-to-width
                  (condition-case err (prin1-to-string (remoto-keys--eval name form))
                    (error (format "error: %s" (error-message-string err))))
                  400))))

(defun remoto-keys--scenario (scenario elpa)
  "Run SCENARIO in a vanilla profile with remoto from ELPA.
A (step ...) types where the last one ended, a (case ...) after a reset.
Return a plist of the cases run and of those that failed a check."
  (pcase-let* ((`(,name ,setup . ,steps) scenario)
               (profile (concat "sc-" name))
               (cases 0) (failed 0) (results nil))
    (if (and (plist-get setup :token) (not remoto-keys--token))
        (princ (format "=== %s: skip, needs REMOTO_E2E_TOKEN\n" name))
      (setq remoto-keys--fault "none")
      (unwind-protect
          (progn
            (princ (format "=== %s\nstart %s: %S\n" name profile
                           (remoto-keys--start profile "vanilla" elpa setup)))
            (dolist (step steps)
              (pcase step
                (`(fault ,fault) (setq remoto-keys--fault fault))
                (`(probe ,label ,form) (remoto-keys--probe profile label form))
                (`(,(and kind (or 'case 'step)) ,label . ,parts)
                 (let ((result (remoto-keys--run profile `(,label nil ,@parts) "vanilla"
                                                 (eq kind 'step))))
                   (cl-incf cases)
                   (push result results)
                   (remoto-keys--print profile result)
                   (when (remoto-keys--check profile result nil)
                     (cl-incf failed))))
                (_ (error "Unknown step %S" step)))))
        (setq remoto-keys--fault "none")
        (unless remoto-keys--keep
          (remoto-keys--stop profile)))
      (remoto-keys--write (expand-file-name (concat "results/" profile ".eld") remoto-keys--dir)
                          (nreverse results)))
    (list :cases cases :failed failed)))

(defun remoto-keys-scenarios-main ()
  "Run the scenarios of REMOTO_KEYS_SCENARIOS, all by default, and exit."
  (unless (executable-find "tmux")
    (error "The test-keys targets need tmux"))
  (make-directory remoto-keys--dir t)
  (let* ((start (float-time))
         (elpa (expand-file-name "elpa-branch/" remoto-keys--dir))
         (port (process-contact (remoto-keys--mock-start) :service))
         (only (split-string (or (getenv "REMOTO_KEYS_SCENARIOS") "") "[ ,]+" t))
         (cases 0) (failed 0))
    (remoto-keys--install-checkout elpa)
    (princ (format "mock Forgejo on 127.0.0.1:%d\n" port))
    (unwind-protect
        (dolist (scenario (remoto-keys--scenarios port))
          (when (or (null only) (member (car scenario) only))
            (let ((counts (remoto-keys--scenario scenario elpa)))
              (cl-incf cases (plist-get counts :cases))
              (cl-incf failed (plist-get counts :failed)))))
      (unless remoto-keys--keep
        (ignore-errors (remoto-keys--tmux "kill-server"))))
    (princ (format "remoto-keys scenarios %s: %d cases, %d failed, %.0f s, results in %s\n"
                   (if only (string-join only " ") "all") cases failed (- (float-time) start)
                   (abbreviate-file-name (expand-file-name "results/" remoto-keys--dir))))
    (kill-emacs (if (< 0 failed) 1 0))))

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
                         (error (format "NOT restored: %s" (error-message-string err))))))))
    (setq results (nreverse results))
    (remoto-keys--write (expand-file-name "results/live.eld" remoto-keys--dir) results)
    (princ (format "remoto-keys live: %d cases, %.0f s, results in %s\n"
                   (length results) (- (float-time) start)
                   (abbreviate-file-name (expand-file-name "results/" remoto-keys--dir))))
    (kill-emacs 0)))

(provide 'remoto-keys)
;;; remoto-keys.el ends here
