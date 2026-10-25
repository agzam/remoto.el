;;; remoto-keys-init.el --- Init of one emacs -nw -q that remoto-keys.el types into -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  remoto as package.el installs it, one completion profile, and a server
;;  through which the runner resets, waits and reads.  The runner passes
;;  everything through REMOTO_KEYS_* variables of an otherwise empty env.
;;
;;; Code:

(setq package-user-dir (getenv "REMOTO_KEYS_ELPA"))
(require 'package)
(package-activate-all)
(require 'server)
(require 'subr-x)
(require 'remoto-e2e-cases (expand-file-name "remoto-e2e-cases"
                                             (file-name-directory load-file-name)))

;; A sandbox never reaches the auth-source files of the person running it.
(setq auth-sources (when-let* ((file (getenv "REMOTO_KEYS_AUTHINFO"))) (list file)))
(when-let* ((file (getenv "REMOTO_KEYS_TOKEN_FILE"))
            ((file-exists-p file)))
  (setq remoto-github-auth (with-temp-buffer
                             (insert-file-contents file)
                             (string-trim (buffer-string))))
  (delete-file file))

(defvar remoto-keys--browsed nil
  "URLs the case sent to a browser, newest first.")

(setq inhibit-startup-screen t
      ring-bell-function #'ignore
      make-backup-files nil
      auto-save-default nil
      select-enable-clipboard nil
      interprogram-cut-function nil
      browse-url-browser-function (lambda (url &rest _)
                                    (push url remoto-keys--browsed)))

;; F12 runs `remoto-e2e-goto', the key the replay suite types as f33,
;; because tmux sends function keys up to F12 only.
(keymap-global-set "<f12>" #'remoto-e2e-goto)
(remoto-e2e-setup (getenv "REMOTO_KEYS_PROFILE"))

;;; Requests

(defvar remoto-keys--calls nil
  "The requests of remoto since the last reset, newest first.")

(defun remoto-keys--call-name (args)
  "Return the endpoint in ARGS of `remoto--api', with its forge prefix.
origin/main's `remoto--api' takes (ENDPOINT), the branch's (FORGE
ENDPOINT); GitHub's go unprefixed, so the two compare."
  (let ((forge (and (not (stringp (car args))) (car args)))
        (endpoint (seq-find #'stringp args)))
    (if (and forge (fboundp 'remoto-forge-name) (fboundp 'remoto--prefix)
             (not (eq (remoto-forge-name forge) 'github)))
        (concat (remoto--prefix forge) endpoint)
      endpoint)))

(with-eval-after-load 'remoto
  (advice-add 'remoto--api :before
              (lambda (&rest args) (push (remoto-keys--call-name args) remoto-keys--calls))
              '((name . remoto-keys-log)))
  (advice-add 'remoto--api-async :before
              (lambda (&rest args)
                (push (concat "async " (remoto-keys--call-name args)) remoto-keys--calls))
              '((name . remoto-keys-log))))

(defvar remoto-keys--auth-log nil
  "Per request, newest first: its host, whether it had a token, whether GitHub's.")

(defun remoto-keys--auth-record (url &rest _)
  "Note the host of URL and which token the request to it carries."
  (let ((auth (cdr (assoc "Authorization" url-request-extra-headers)))
        (url (if (stringp url) (url-generic-parse-url url) url)))
    (push (list (url-host url) (and auth t)
                (and auth (stringp (bound-and-true-p remoto-github-auth))
                     (string-search remoto-github-auth auth) t))
          remoto-keys--auth-log)))

(with-eval-after-load 'url
  (advice-add 'url-retrieve-internal :before #'remoto-keys--auth-record))

;;; What the runner calls

(defun remoto-keys-busy-p ()
  "Non-nil while this Emacs still works on the keys sent to it."
  (or (null (current-idle-time))
      (input-pending-p)
      ;; The depth can leak (a throw from `while-no-input' between its
      ;; increment and the `unwind-protect'), so it counts only until idle.
      (and (boundp 'remoto--sync-fetch-depth) (< 0 remoto--sync-fetch-depth)
           (< (float-time (current-idle-time)) 2))
      (and (boundp 'remoto--debounce-timer) (timerp remoto--debounce-timer)
           (memq remoto--debounce-timer timer-idle-list) t)))

(defvar remoto-keys--mark 1
  "Where *Messages* stood when the case began.")

(defvar remoto-keys--home default-directory
  "The directory every case starts in.")

(defun remoto-keys--remoto-buffer-p (buffer)
  "Non-nil if BUFFER is one a case may have opened."
  (with-current-buffer buffer
    (and (not (string-prefix-p " " (buffer-name)))
         (not (member (buffer-name) '("*scratch*" "*Messages*")))
         (or (derived-mode-p 'dired-mode)
             buffer-file-name
             (string-match-p "\\`\\*\\(?:Embark\\|remoto\\|Remoto\\|Completions\\|Warnings\\)"
                             (buffer-name))))))

(defun remoto-keys-reset ()
  "Kill the buffers the last case opened; back to *scratch* in the home directory."
  (dolist (buffer (buffer-list))
    (when (remoto-keys--remoto-buffer-p buffer)
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer))))
  (delete-other-windows)
  (switch-to-buffer "*scratch*")
  (setq default-directory remoto-keys--home)
  (remoto-keys-mark)
  'reset)

(defun remoto-keys-mark ()
  "Begin a case where the last one ended: no requests and no messages yet."
  (setq remoto-keys--calls nil
        remoto-keys--browsed nil)
  (message "")
  (setq remoto-keys--mark (with-current-buffer (messages-buffer) (point-max)))
  'mark)

(defun remoto-keys--messages ()
  "Return the lines *Messages* got since the case began."
  (with-current-buffer (messages-buffer)
    (split-string (buffer-substring-no-properties
                   (min remoto-keys--mark (point-max)) (point-max))
                  "\n" t)))

(defconst remoto-keys--raw-http
  "HTTP/[0-9.]+ [0-9]\\{3\\}\\|<!DOCTYPE\\|<html\\|{\"message\":"
  "Text of a raw HTTP answer, which a message to a person never holds.")

(defun remoto-keys-state ()
  "Return where the case ended, without the parts that are nil."
  (let ((minibuffer (and (active-minibuffer-window)
                         (with-current-buffer (window-buffer (active-minibuffer-window))
                           (minibuffer-contents-no-properties)))))
    (with-current-buffer (window-buffer (or (minibuffer-selected-window) (selected-window)))
      (let* ((dired (derived-mode-p 'dired-mode))
             (names (remoto-e2e--buffer-names)))
        (cl-loop for (key value) on
                 (list :buffer (unless (or dired buffer-file-name) (buffer-name))
                       :mode major-mode
                       :dired (and dired (if (consp dired-directory)
                                             (car dired-directory)
                                           dired-directory))
                       :matches (and dired (consp dired-directory))
                       :problems (remoto-e2e--buffer-problems)
                       :names (seq-take names 10)
                       :count (and names (length names))
                       :point (and dired (remoto-e2e--line-name))
                       :file buffer-file-name
                       :minibuffer minibuffer
                       :completions (seq-take (remoto-e2e--completions) 10)
                       :messages (seq-filter (lambda (line)
                                               (string-match-p
                                                "\\`\\(?:[Rr]emoto\\|Error\\)" line))
                                             (remoto-keys--messages))
                       :raw (seq-filter (lambda (line)
                                          (string-match-p remoto-keys--raw-http line))
                                        (remoto-keys--messages))
                       :kill (car kill-ring)
                       :browsed (reverse remoto-keys--browsed)
                       :requests (reverse remoto-keys--calls))
                 by #'cddr
                 when value append (list key value))))))

(defun remoto-keys-line ()
  "Return one line about the window: its buffer, directory, names, requests and messages."
  (let ((buffer (window-buffer (or (minibuffer-selected-window) (selected-window))))
        (messages (string-join (remoto-keys--messages) " // ")))
    (with-current-buffer buffer
      (format "%s | %s | n=%d | calls=%d | %s"
              (buffer-name)
              (cond ((consp dired-directory)
                     (format "%s +%d" (car dired-directory) (length (cdr dired-directory))))
                    ((derived-mode-p 'dired-mode) dired-directory)
                    (buffer-file-name buffer-file-name)
                    (t major-mode))
              (length (remoto-e2e--buffer-names))
              (length remoto-keys--calls)
              (truncate-string-to-width messages 200)))))

;;; What the scenarios probe

(defun remoto-keys-auth ()
  "Return per host the requests, those with a token, and those with GitHub's."
  (mapcar (lambda (host)
            (let ((rows (seq-filter (lambda (row) (equal (car row) host))
                                    remoto-keys--auth-log)))
              (list host :requests (length rows) :token (seq-count #'cadr rows)
                    :github-token (seq-count #'caddr rows))))
          (delete-dups (reverse (mapcar #'car remoto-keys--auth-log)))))

(defun remoto-keys-logins ()
  "Return the logins of remoto by host, without their tokens."
  (when (boundp 'remoto--logins)
    (let (logins)
      (maphash (lambda (host login)
                 (push (list host :failed (remoto--login-failed login)
                             :token (and (remoto--login-token login) t)
                             :user (remoto--login-user login))
                       logins))
               remoto--logins)
      (nreverse logins))))

(defun remoto-keys-prompt ()
  "Return the prompt and the input of the minibuffer, or nil."
  (when-let* ((window (active-minibuffer-window)))
    (with-current-buffer (window-buffer window)
      (concat (minibuffer-prompt) (minibuffer-contents-no-properties)))))

(defun remoto-keys-forges ()
  "Return the prefixes of remoto's forges and the text of *Warnings*."
  (list :forges (and (boundp 'remoto--forges) (mapcar #'car remoto--forges))
        :warnings (when-let* ((buffer (get-buffer "*Warnings*")))
                    (with-current-buffer buffer
                      (string-trim (buffer-substring-no-properties (point-min) (point-max)))))))

(defun remoto-keys-topics ()
  "Return the topic buffers, each with the path of its repository."
  (cl-loop for buffer in (buffer-list)
           when (local-variable-p 'remoto-topic--repo-path buffer)
           collect (list (buffer-name buffer)
                         (buffer-local-value 'remoto-topic--repo-path buffer))))

;; A scenario's setup, such as its servers, or the run's, such as a planted regression.
(when-let* ((form (getenv "REMOTO_KEYS_INIT")))
  (with-demoted-errors "REMOTO_KEYS_INIT: %S"
    (eval (car (read-from-string form)) t)))

(setq server-socket-dir (getenv "REMOTO_KEYS_SOCKET_DIR")
      server-name (getenv "REMOTO_KEYS_SERVER"))
(server-start)

;;; remoto-keys-init.el ends here
