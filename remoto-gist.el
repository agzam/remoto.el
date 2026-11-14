;;; remoto-gist.el --- GitHub's gists behind remoto's forge contract  -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.

;;; Commentary:

;; A gist is a repository with one flat tree and no refs, always at its
;; latest revision: /gist:OWNER/ID:/FILE.  The root lists the gists of the
;; token's account and the ones it starred; GitHub's token reads them all.

;;; Code:

(require 'ucs-normalize)
(require 'url)
(require 'remoto)
(require 'remoto-github)

;; package.el reloads this file before remoto.el when it upgrades remoto in
;; a running session, and the struct below needs the core of its version.
;; `remoto--core-directory' names the core that is in, or loading now.
(when-let* ((file (macroexp-file-name))
            (dir (file-name-directory file))
            ((not (and (bound-and-true-p remoto--core-directory)
                       (file-equal-p remoto--core-directory dir)))))
  (load (expand-file-name "remoto" dir) nil t))

(cl-defstruct (remoto-gist (:include remoto-forge (title "GitHub Gist"))
                           (:constructor remoto-gist-create)
                           (:copier nil))
  "GitHub's gists: repositories of one flat tree, with no refs.")

;;;; Transport

(cl-defmethod remoto--api-host ((_forge remoto-gist))
  "Gists are read through GitHub's API."
  "api.github.com")

(cl-defmethod remoto--ghub-forge ((_forge remoto-gist))
  "GitHub is ghub's default kind."
  nil)

(cl-defmethod remoto--literal-token ((_forge remoto-gist))
  "GitHub's token, from `remoto-github-auth'."
  (remoto--literal-token remoto--github))

(cl-defmethod remoto--token-prompt ((_forge remoto-gist))
  "A gist is read with GitHub's token."
  "GitHub token: ")

;;;; Gists

(defvar remoto-gist--gists (make-hash-table :test 'equal)
  "Cache: gist id -> the answer of gists/ID, with every file's content.")

(defvar remoto-gist--listed (make-hash-table :test 'equal)
  "Cache: gist id -> the gist as a listing page gave it, its files without content.")

(defvar remoto-gist--fetched (make-hash-table :test 'equal)
  "Cache: gist id -> the `float-time' its answer in `remoto-gist--gists' came.")

(defconst remoto-gist--fresh-seconds 10
  "Seconds a read of a file of one's own gist trusts the cached gist.
Another session, or the website, may have changed it since.")

(defun remoto-gist--owner (gist)
  "Return the login of the owner of GIST, an answer of the gists API."
  (alist-get 'login (alist-get 'owner gist)))

(defun remoto-gist--version (gist)
  "Return the latest revision of GIST, an answer of gists/ID."
  (alist-get 'version (car (alist-get 'history gist))))

(defun remoto-gist--stale-p (id max-age)
  "Return non-nil when the cached answer of the gist ID is older than MAX-AGE.
MAX-AGE is in seconds; nil keeps every answer, as does an answer whose
time the cache lacks."
  (when-let* ((max-age)
              (time (gethash id remoto-gist--fetched)))
    (< max-age (- (float-time) time))))

(defun remoto-gist--keep (forge id answer)
  "Cache ANSWER, the gist ID on FORGE as gists/ID gave it now; return it.
A revision other than the cached one drops the gist's tree, so its Dired
shows what GitHub holds."
  (when-let* ((old (gethash id remoto-gist--gists))
              ((not (equal (remoto-gist--version old) (remoto-gist--version answer)))))
    (remoto-gist--changed forge (remoto-gist--owner answer) id))
  (puthash id (float-time) remoto-gist--fetched)
  (puthash id answer remoto-gist--gists))

(defun remoto-gist--get (forge owner id &optional max-age)
  "Return the gist ID on FORGE, as gists/ID answers it, cached.
OWNER nil takes the gist's own; another owner than the gist's finds
none, as on the gist site.  An answer older than MAX-AGE seconds is
asked for again."
  (let ((gist (or (and (not (remoto-gist--stale-p id max-age))
                       (gethash id remoto-gist--gists))
                  (when-let* ((answer (remoto--api forge (concat "gists/"
                                                                 (url-hexify-string id)))))
                    (remoto-gist--keep forge id answer)))))
    (if (or (null gist)
            (and owner (not (string-equal-ignore-case owner (remoto-gist--owner gist)))))
        (user-error "%sthe gist %s of %s" remoto--not-found id owner)
      gist)))

(defun remoto-gist--known (forge owner id)
  "Return the gist ID of OWNER on FORGE as known, asking only when it is not.
Its answer of gists/ID comes first, then its item of a listing page, which
names its files without their content."
  (if-let* (((not (gethash id remoto-gist--gists)))
            (item (gethash id remoto-gist--listed))
            ((or (null owner)
                 (string-equal-ignore-case owner (or (remoto-gist--owner item) "")))))
      item
    (remoto-gist--get forge owner id)))

(defun remoto-gist--files (gist)
  "Return the files of GIST as (NAME . FILE), in the order of its answer."
  (mapcar (lambda (file) (cons (symbol-name (car file)) (cdr file)))
          (alist-get 'files gist)))

(defun remoto-gist--file (forge owner id path &optional max-age)
  "Return the file PATH of the gist ID of OWNER on FORGE, or signal none.
An answer of the gist older than MAX-AGE seconds is asked for again."
  (let ((name (string-remove-prefix "/" path)))
    (or (cdr (assoc name (remoto-gist--files (remoto-gist--get forge owner id max-age))))
        (user-error "%s%s in the gist %s" remoto--not-found name id))))

(defun remoto-gist--me (forge)
  "Return the account of the token of FORGE, asked for once; nil without one."
  (or (remoto--login-user (remoto--forge-login forge))
      (and (not (eq (remoto--auth forge) 'none))
           (remoto--get-authenticated-user forge))))

(defun remoto-gist--mine-p (forge owner)
  "Return non-nil when OWNER is the account of the token of FORGE."
  (when-let* ((me (and owner (remoto-gist--me forge))))
    (string-equal-ignore-case owner me)))

(defun remoto-gist--raw-end (req url)
  "End REQ with the answer to URL in the current buffer, and kill the buffer."
  (let ((buffer (current-buffer))
        (status (bound-and-true-p url-http-response-status)))
    (unwind-protect
        (cond ((null status)
               (remoto--request-end
                req 'error (list 'user-error (format "Remoto: no answer from %s" url))))
              ((not (eql 200 status))
               (remoto--request-end
                req 'error (list 'user-error (format "Remoto: %s answered %s" url status))))
              (t (goto-char (point-min))
                 (re-search-forward "\r?\n\r?\n")
                 (remoto--request-end
                  req 'done (buffer-substring-no-properties (point) (point-max)))))
      (kill-buffer buffer))))

(defun remoto-gist--raw (url)
  "Return the bytes at URL, the raw URL of a file, as a unibyte string.
The request ends as every request does when its host sends nothing."
  (let ((req (remoto--request-create :host (url-host (url-generic-parse-url url))
                                     :resource url)))
    (setf (remoto--request-buffer req)
          (url-retrieve url (lambda (_status) (remoto-gist--raw-end req url)) nil t t))
    (remoto--request-watch req)
    (remoto--request-result (remoto--request-wait req))))

(cl-defmethod remoto-forge-default-ref ((_forge remoto-gist) _owner _id)
  "A gist has no refs: its one tree is its latest revision."
  nil)

(cl-defmethod remoto-forge-tree ((forge remoto-gist) owner id _ref)
  "The files of the gist ID of OWNER on FORGE, one flat tree.
The language of a file is its note."
  (let ((table (make-hash-table :test 'equal)))
    (puthash "" remoto--dir-entry table)
    (puthash "/" remoto--dir-entry table)
    (dolist (file (remoto-gist--files (remoto-gist--known forge owner id)) table)
      (puthash (car file)
               `((type . "blob") (size . ,(or (alist-get 'size (cdr file)) 0))
                 (sha . "") (mode . "100644")
                 ,@(when-let* ((language (alist-get 'language (cdr file))))
                     `((note . ,language))))
               table))))

(cl-defmethod remoto--root-file ((forge remoto-gist) owner id _ref)
  "The one file of the gist ID of OWNER on FORGE, nil for a gist of more.
A gist of one file opens at it, as its line in a listing does."
  (pcase (remoto-gist--files (remoto-gist--known forge owner id))
    (`((,name . ,_)) name)))

(defun remoto-gist--bytes (file)
  "Return the bytes of FILE, a file of an answer of gists/ID.
The answer holds each file up to 1MB, a binary one in base64; a larger
one comes truncated, and its raw URL has the rest."
  (let ((content (or (alist-get 'content file) "")))
    (cond ((eq (alist-get 'truncated file) t) (remoto-gist--raw (alist-get 'raw_url file)))
          ((equal "base64" (alist-get 'encoding file)) (base64-decode-string content))
          (t (encode-coding-string content 'utf-8 t)))))

(cl-defmethod remoto-forge-content ((forge remoto-gist) owner id _ref path)
  "The bytes of the file PATH of the gist ID of OWNER on FORGE.
A gist of one's own may have changed elsewhere: its cached answer serves
for `remoto-gist--fresh-seconds', and a revert asks anew."
  (remoto-gist--bytes
   (remoto-gist--file forge owner id path
                      (and (remoto-gist--mine-p forge owner)
                           (if remoto--read-anew 0 remoto-gist--fresh-seconds)))))

(cl-defmethod remoto-forge-resolve-ref ((forge remoto-gist) owner id _ref)
  "The latest revision of the gist ID of OWNER on FORGE, for a permalink."
  (alist-get 'version (car (alist-get 'history (remoto-gist--get forge owner id)))))

(cl-defmethod remoto-forge-entry-notes ((forge remoto-gist) owner id _ref _dir names)
  "The language of each of NAMES in the gist ID of OWNER on FORGE."
  (let ((files (remoto-gist--files (remoto-gist--known forge owner id))))
    (seq-keep (lambda (name)
                (when-let* ((language (alist-get 'language (cdr (assoc name files)))))
                  (cons name language)))
              names)))

(cl-defmethod remoto-forge-forget ((_forge remoto-gist) &optional _owner id)
  "Drop the cached gist ID, or every cached gist without ID."
  (if id
      (progn (remhash id remoto-gist--gists)
             (remhash id remoto-gist--listed)
             (remhash id remoto-gist--fetched))
    (clrhash remoto-gist--gists)
    (clrhash remoto-gist--listed)
    (clrhash remoto-gist--fetched)))

;;;; Writes

(defvar remoto-gist--revert-timer nil
  "The timer that reverts the Dired buffers of gists once a command is over.")

(defun remoto-gist--revert-direds (forge)
  "Revert the Dired buffers of the gists and the listings of FORGE."
  (setq remoto-gist--revert-timer nil)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when-let* (((derived-mode-p 'dired-mode))
                  (dir (if (consp dired-directory) (car dired-directory) dired-directory))
                  ((stringp dir))
                  ((string-prefix-p (remoto--prefix forge) dir)))
        (revert-buffer)))))

(defun remoto-gist--changed (forge owner id)
  "Drop the tree of the gist ID of OWNER on FORGE; its Dired reverts later.
Later is once the command is over, so a Dired command that is still
running keeps its buffer as it is."
  (remhash (remoto--repo-key (remoto-gist--tree forge owner id)) remoto--tree-cache)
  (unless (timerp remoto-gist--revert-timer)
    (setq remoto-gist--revert-timer
          (run-at-time 0 nil #'remoto-gist--revert-direds forge))))

(defun remoto-gist--relist (forge id answer)
  "Put ANSWER, the gist ID now, in place of its lines in FORGE's cached listings."
  (remoto--remember (remoto--repo-id forge (remoto-gist--owner answer) id)
                    (remoto-gist--attributes answer t))
  (maphash (lambda (dir listing)
             (when (string-prefix-p (remoto--prefix forge) dir)
               (setf (remoto--listing-entries listing)
                     (mapcar (lambda (entry)
                               (if (equal id (alist-get 'gist-id (cdr entry)))
                                   (remoto-gist--entry answer (equal dir (remoto--prefix forge))
                                                       (alist-get 'gist-group (cdr entry)))
                                 entry))
                             (remoto--listing-entries listing)))))
           remoto--listing-cache))

(defun remoto-gist--take (forge id answer)
  "Make ANSWER, what a write of the gist ID on FORGE answered, every cache's.
Its listing lines and its tree follow; return ANSWER."
  (puthash id answer remoto-gist--gists)
  (puthash id (float-time) remoto-gist--fetched)
  (puthash id answer remoto-gist--listed)
  (remoto-gist--relist forge id answer)
  (remoto-gist--changed forge (remoto-gist--owner answer) id)
  answer)

(defun remoto-gist--patch (forge id files)
  "Send FILES, as PATCH gists/ID takes them, to the gist ID on FORGE.
Return the gist as GitHub answers it, which every cache takes."
  (remoto-gist--take forge id (remoto--api-write forge "PATCH"
                                                 (concat "gists/" (url-hexify-string id))
                                                 `((files . ,files)))))

(defun remoto-gist--flat (path)
  "Refuse PATH, the name of a gist file, with a slash in it: a gist is flat."
  (when (string-search "/" path)
    (user-error "Remoto: a gist has no directories, so no %s" path)))

(defun remoto-gist--text (path bytes &optional exists)
  "Return BYTES, the new content of the gist file PATH, as the API takes it.
Refuse what GitHub refuses or turns into a deletion: a name with a slash,
bytes that are no UTF-8, and a blank file, whose deletion, when the file
EXISTS, the message names."
  (let ((text (decode-coding-string bytes 'utf-8-unix)))
    (remoto-gist--flat path)
    (cond ((string-match-p "[\200-\377]" text)
           (user-error "%s" (format (substitute-command-keys "Remoto: a gist keeps UTF-8 text \
only, so not %s; \\[set-buffer-file-coding-system] utf-8 recodes a buffer")
                                    path)))
          ((not (string-match-p "\\`[ \t\n\r\f\v]*\\'" text)) text)
          (exists (user-error "Remoto: a gist file cannot be blank; D in the Dired of the \
gist deletes %s" path))
          (t (user-error "Remoto: a gist file cannot be blank, so %s needs text first" path)))))

(defun remoto-gist--binary-p (id path)
  "Return non-nil when PATH of the cached gist ID is in base64, a binary file."
  (when-let* ((gist (gethash id remoto-gist--gists))
              (file (cdr (assoc path (remoto-gist--files gist)))))
    (equal "base64" (alist-get 'encoding file))))

(cl-defmethod remoto--forge-writable-p ((forge remoto-gist) owner id _ref path)
  "A gist of the token's account on FORGE is writable, its binary files aside.
OWNER and ID name the gist, PATH the file."
  (and id (remoto-gist--mine-p forge owner)
       (not (remoto-gist--binary-p id path))))

(cl-defmethod remoto--forge-check-write ((_forge remoto-gist) _owner id _ref path bytes)
  "Refuse BYTES as the file PATH of the gist ID where GitHub would.
It costs no request: the cached gist tells whether PATH exists."
  (remoto-gist--text path bytes
                     (assoc path (remoto-gist--files (gethash id remoto-gist--gists))))
  nil)

(cl-defmethod remoto--forge-rename ((forge remoto-gist) owner id _ref path newpath)
  "Rename the file PATH of the gist ID of OWNER on FORGE to NEWPATH, one PATCH.
Over a name the gist holds, the text goes under NEWPATH and PATH goes: a
rename there would copy the text and keep both names."
  (remoto-gist--flat newpath)
  (let* ((files (remoto-gist--files (remoto-gist--get forge owner id 0)))
         (file (or (cdr (assoc path files))
                   (signal 'file-missing (list "Renaming" "No such file or directory" path)))))
    (unless (equal path newpath)
      (remoto-gist--patch
       forge id
       (if (assoc newpath files)
           `((,(intern newpath) . ((content . ,(remoto-gist--text
                                                  newpath (remoto-gist--bytes file) t))))
             (,(intern path) . :null))
         `((,(intern path) . ((filename . ,newpath))))))))
  nil)

(cl-defmethod remoto--forge-delete ((forge remoto-gist) owner id _ref path)
  "Delete the file PATH of the gist ID of OWNER on FORGE, in one PATCH.
It stays in the gist's revisions.  GitHub keeps the last file of a gist,
which goes only with the gist; a file the gist lacks needs no request."
  (let ((files (remoto-gist--files (remoto-gist--get forge owner id 0))))
    (cond ((not (assoc path files)) nil)
          ((null (cdr files))
           (user-error "Remoto: GitHub keeps the last file of a gist; D on the line \
of the gist deletes it"))
          (t (remoto-gist--patch forge id `((,(intern path) . :null)))
             nil))))

(cl-defmethod remoto--forge-current-content ((forge remoto-gist) owner id _ref path)
  "The bytes of PATH in the gist ID of OWNER on FORGE, asked for anew, or nil."
  (when-let* ((file (cdr (assoc path (remoto-gist--files (remoto-gist--get forge owner id 0))))))
    (remoto-gist--bytes file)))

(cl-defmethod remoto--forge-write ((forge remoto-gist) _owner id _ref path bytes)
  "Make BYTES the file PATH of the gist ID on FORGE, in one PATCH.
Return the note of the save's message: a public gist says so."
  (let ((answer (remoto-gist--patch
                 forge id `((,(intern path) . ((content . ,(remoto-gist--text path bytes))))))))
    (and (eq (alist-get 'public answer) t) " (public gist)")))

;;;; Listings

(defun remoto-gist--endpoints (path)
  "Return the endpoints whose pages, one after another, list PATH.
The root lists the token's gists, then the ones it starred."
  (if (eq (remoto-path-level path) 'root)
      '("gists" "gists/starred")
    (list (format "users/%s/gists" (remoto-path-owner path)))))

(defun remoto-gist--hide (text)
  "Return TEXT, displayed as nothing on its Dired line."
  (propertize text 'display ""))

(defun remoto-gist--label (names)
  "Return the label of a gist of the file NAMES: the names, comma-separated."
  (string-join names ", "))

(defun remoto-gist--texts (item shown icons)
  "Return (LABEL . ANNOTATION) of ITEM, a gist from a list endpoint, in completion.
Its description leads, and SHOWN, the name its Dired line shows, follows;
without a description SHOWN leads.  The annotation starts with secret or
public, or, with ICONS, the Nerd Font glyph nf-oct-lock or nf-oct-globe."
  (let* ((description (string-trim (remoto--one-line (or (alist-get 'description item) ""))))
         (public (eq (alist-get 'public item) t))
         (mark (cond ((not icons) (if public "public" "secret"))
                     (public "\uF484")
                     (t "\uF456"))))
    (if (string-empty-p description)
        (cons shown mark)
      (cons description (concat mark (if icons " " "  ") shown)))))

(defun remoto-gist--attributes (item folder)
  "Return the Dired attributes of ITEM, a gist from a list endpoint.
FOLDER gives those of a line of the gist itself, else those of its one
file.  The links are its files, the size theirs, and a secret one is the
owner's alone, as a private repository is."
  (let ((files (remoto-gist--files item))
        (public (eq (alist-get 'public item) t))
        (updated (alist-get 'updated_at item)))
    `((type . ,(if folder "tree" "blob"))
      (size . ,(apply #'+ (mapcar (lambda (file) (or (alist-get 'size (cdr file)) 0))
                                  files)))
      (perms . ,(concat (if folder "drwx" "-rw-")
                        (cond ((not public) "------") (folder "r-xr-x") (t "r--r--"))))
      (links . ,(length files))
      (time . ,(and updated (encode-time (iso8601-parse updated))))
      (note . ,(remoto--one-line (or (alist-get 'description item) ""))))))

(defun remoto-gist--entry (item root group)
  "Return the Dired line of ITEM, a gist from a list endpoint.
At an owner it is ID/FILE for a gist of one file and ID for more, the
ROOT puts OWNER/ before it, and GROUP names its group there.  The line
hides the id, and the owner of the token's own gists at the root."
  (pcase-let* ((id (alist-get 'id item))
               (owner (remoto-gist--owner item))
               (names (mapcar #'car (remoto-gist--files item)))
               (head (cond ((not root) "")
                           ((equal group "Your gists") (remoto-gist--hide (concat owner "/")))
                           (t (concat owner "/"))))
               (name (if (cdr names)
                         (concat head (propertize id 'display (remoto-gist--label names)))
                       (concat head (remoto-gist--hide (concat id "/")) (car names))))
               ;; A user of nerd-icons has the font that draws its glyphs.
               (`(,label . ,annotation) (remoto-gist--texts item (remoto--shown-name name)
                                                            (featurep 'nerd-icons))))
    (cons name
          `(,@(remoto-gist--attributes item (cdr names))
            (gist-id . ,id)
            (gist-owner . ,owner)
            (gist-label . ,label)
            (gist-annotation . ,annotation)
            ,@(and root `((gist-group . ,group)))))))

(defun remoto-gist--page (forge path endpoint page items)
  "Return (ENTRIES . NEXT) of ITEMS, PAGE of ENDPOINT, for the listing at PATH.
Each gist is remembered as /gist:OWNER/ID on FORGE, so a Dired of its name
finds it.  The token's own gists among the starred ones stay under its own,
listed before.  A short page ends ENDPOINT; the next endpoint starts."
  (let* ((root (eq (remoto-path-level path) 'root))
         (later (cadr (member endpoint (remoto-gist--endpoints path))))
         (user (remoto--login-user (remoto--forge-login forge)))
         (own (lambda (item)
                (and user (string-equal-ignore-case user (or (remoto-gist--owner item) "")))))
         (shown (if (equal endpoint "gists/starred") (seq-remove own items) items)))
    (dolist (item items)
      (puthash (alist-get 'id item) item remoto-gist--listed)
      (remoto--remember (remoto--repo-id forge (remoto-gist--owner item) (alist-get 'id item))
                        (remoto-gist--attributes item t)))
    (cons (mapcar (lambda (item)
                    (remoto-gist--entry item root
                                        (and root (if (equal endpoint "gists")
                                                      "Your gists"
                                                    "Starred"))))
                  shown)
          (cond ((<= (remoto--page-size forge) (length items)) (cons endpoint (1+ page)))
                (later (cons later 1))))))

(cl-defmethod remoto--page-size ((_forge remoto-gist))
  "GitHub takes about 50 ms a gist to list, so a page of 30 comes in 1.4 s.
One of 100 takes 6 s and more, near the 10 s GitHub allows a request."
  30)

(defun remoto-gist--user (forge dir)
  "Return the token's account on FORGE, offering a login for DIR without one."
  (or (remoto--get-authenticated-user forge)
      (and (remoto--offer-login forge (format "%s needs a GitHub token. Log in now? " dir))
           (remoto--get-authenticated-user forge))
      (user-error "Remoto: %s needs a GitHub token%s" dir (remoto--login-tail))))

(cl-defmethod remoto-forge-entries ((forge remoto-gist) path &optional continuation callback)
  "A page of the gists at PATH on FORGE, see `remoto-forge-entries'.
CONTINUATION is (ENDPOINT . PAGE); CALLBACK takes a page in the background."
  (when (eq (remoto-path-level path) 'root)
    (remoto-gist--user forge (remoto--path-prefix path)))
  (pcase-let* ((`(,endpoint . ,page) (or continuation
                                         (cons (car (remoto-gist--endpoints path)) 1)))
               (resource (format "%s?%s" endpoint
                                 (remoto--page-params forge (remoto--page-size forge) page))))
    (if callback
        (ignore
         (remoto--api-async
          forge resource
          (lambda (items)
            (funcall callback (remoto-gist--page forge path endpoint page items)))
          (lambda () (funcall callback 'failed))))
      (remoto-gist--page forge path endpoint page (remoto--api forge resource)))))

;;;; Completion

(defun remoto-gist--listing-dir (path)
  "Return the directory of the listing at PATH, a root or owner path."
  (if (eq (remoto-path-level path) 'root)
      (remoto--path-prefix path)
    (format "%s%s/" (remoto--path-prefix path) (remoto-path-owner path))))

(defun remoto-gist--candidates (path fetch)
  "Return the gists of the listing at PATH as candidates.
Each carries the label shown for its id, and the annotation after it.
The cached listing answers; FETCH fetches it when there is none."
  (let* ((dir (remoto-gist--listing-dir path))
         (root (eq (remoto-path-level path) 'root))
         (listing (if fetch (remoto--listing dir) (gethash dir remoto--listing-cache))))
    (when listing
      (mapcar (lambda (entry)
                (let-alist (cdr entry)
                  (if root
                      (propertize (concat .gist-owner "/" .gist-id)
                                  'remoto-group .gist-group
                                  'remoto-label .gist-label
                                  'remoto-acct-desc .gist-annotation)
                    (propertize .gist-id
                                'remoto-label .gist-label
                                'remoto-repo-desc .gist-annotation))))
              (remoto--listing-entries listing)))))

(cl-defmethod remoto--keeps-order-p ((_forge remoto-gist))
  "Gists come newest first, and their ids sort by nothing a reader sees."
  t)

(defun remoto-gist--users (query)
  "Return the GitHub users that a search for QUERY found, never blocking.
Organizations own no gists."
  (seq-keep (lambda (login)
              (when (equal "User" (get-text-property 0 'remoto-acct-type login))
                (propertize login 'remoto-group "Users")))
            (remoto--search-users remoto--github query)))

(cl-defmethod remoto-forge-complete ((forge remoto-gist) path query wait)
  "Candidates of gists at PATH on FORGE for QUERY, see `remoto-forge-complete'.
The root offers the token's gists and the starred ones once the token's
account is known, and typed text adds users; an owner offers its gists,
fetched only with WAIT.  The prefetch, a nil QUERY, asks nothing."
  (cond
   ((null query) nil)
   ((eq (remoto-path-level path) 'root)
    (append (and (remoto--known-user forge) (remoto-gist--candidates path t))
            (and (not (string-empty-p query)) (remoto-gist--users query))))
   (t (remoto-gist--candidates path wait))))

;;;; Web URLs

(defun remoto-gist--slug (name)
  "Return the slug of the file NAME in the anchors of its gist's page.
As Rails' parameterize makes it: accents go, - and _ stay, any other run
is one -, and the ends lose theirs."
  (thread-last
    (ucs-normalize-NFKD-string name)
    (seq-filter (lambda (char) (< char 128)))
    concat
    (replace-regexp-in-string "[^A-Za-z0-9_-]+" "-")
    (replace-regexp-in-string "--+" "-")
    (replace-regexp-in-string "\\`-\\|-\\'" "")
    downcase))

(defun remoto-gist--anchor (name start end)
  "Return the fragment of the file NAME on its gist's page, at lines START to END."
  (concat "#file-" (remoto-gist--slug name)
          (cond ((and start end) (format "-L%d-L%d" start end))
                (start (format "-L%d" start)))))

(cl-defmethod remoto-forge-url ((_forge remoto-gist) kind context)
  "The gist URL of KIND for CONTEXT, nil for a kind a gist lacks.
A ref in CONTEXT is a revision, as a permalink pins; without one the
URLs name the latest."
  (let* ((owner (plist-get context :owner))
         (id (plist-get context :repo))
         (rev (plist-get context :ref))
         (name (plist-get context :path))
         (page (concat "https://gist.github.com/" owner "/" id (and rev (concat "/" rev)))))
    (pcase kind
      ((or 'repo 'tree) page)
      ('blob (concat page (and name (not (string-empty-p name))
                               (remoto-gist--anchor name (plist-get context :line-start)
                                                    (plist-get context :line-end)))))
      ('raw (and name (not (string-empty-p name))
                 (concat "https://gist.githubusercontent.com/" owner "/" id "/raw/"
                         (and rev (concat rev "/")) (url-hexify-string name))))
      ('history (concat "https://gist.github.com/" owner "/" id "/revisions"))
      ('ssh (format "git@gist.github.com:%s.git" id))
      ('https (format "https://gist.github.com/%s.git" id))
      ((or 'owner 'owner-repos) (concat "https://gist.github.com/" owner)))))

;;;; Links in

(defun remoto-gist--id-p (text)
  "Return non-nil when TEXT has the shape of a gist id: 20 or 32 hex, or digits."
  (string-match-p (rx bos (or (= 20 hex) (= 32 hex) (+ digit)) eos) text))

(defun remoto-gist--tree (forge owner id &optional name)
  "Return the `remoto-path' of the gist ID of OWNER on FORGE, at its file NAME."
  (remoto--parse (concat (remoto--repo-id forge owner id) ":/" name)))

(defun remoto-gist--anchored (forge owner id anchor)
  "Return the path of the gist ID of OWNER on FORGE at the file of ANCHOR.
ANCHOR is file-SLUG, maybe with lines after it; the gist's files are
asked for only while `remoto--url-ref-lookup' allows it."
  (let ((slug (and anchor remoto--url-ref-lookup
                   (string-match (rx bos "file-" (group (+? nonl))
                                     (? "-L" (+ digit) (? "-L" (+ digit))) eos)
                                 anchor)
                   (match-string 1 anchor))))
    (remoto-gist--tree
     forge owner id
     (and slug
          (car (seq-find (lambda (file) (equal slug (remoto-gist--slug (car file))))
                         (remoto-gist--files (remoto-gist--get forge owner id))))))))

(defun remoto-gist--owned (forge id &optional anchor)
  "Return the path of the gist ID on FORGE at ANCHOR, its owner asked for.
While `remoto--url-ref-lookup' is nil the shape tells the forge only,
and the root stands for the gist."
  (if remoto--url-ref-lookup
      (remoto-gist--anchored forge (remoto-gist--owner (remoto-gist--get forge nil id))
                             id anchor)
    (remoto--path-at forge 'root)))

(cl-defmethod remoto-forge-parse-url ((forge remoto-gist) input)
  "The path that INPUT, a gist URL or clone URL, names on FORGE, or nil.
The web pages of gist.github.com, the raw files of either host and the
clone URLs; a revision in a URL is left out, as a gist opens at its
latest."
  (let ((input (string-trim input))
        ;; A file prompt hands a pasted URL over as /gist.github.com/...:
        ;; `substitute-in-file-name' drops what comes before its //.
        (scheme '(? (or "https://" "http://" "/"))))
    (cond
     ((string-match (rx-to-string
                     `(seq bos ,scheme (or "gist.githubusercontent.com/" "gist.github.com/")
                           (group (+ (not "/"))) "/" (group (+ (not "/"))) "/raw/"
                           (? (= 40 hex) "/") (group (+ (not (in "?#"))))
                           (? (in "?#") (* nonl)) eos))
                    input)
      (remoto-gist--tree forge (match-string 1 input) (match-string 2 input)
                         (url-unhex-string (match-string 3 input))))
     ((string-match (rx-to-string
                     `(seq bos (or "git@gist.github.com:" (seq ,scheme "gist.github.com/"))
                           (group (+ alnum)) ".git" eos))
                    input)
      (remoto-gist--owned forge (match-string 1 input)))
     ((string-match (rx-to-string
                     `(seq bos ,scheme "gist.github.com"
                           (? "/" (group (+ (not (in "/?#")))))
                           (? "/" (group (+ (not (in "/?#")))))
                           (? "/" (+ (not (in "/?#"))))
                           (? "/") (? "?" (* (not "#"))) (? "#" (group (* nonl))) eos))
                    input)
      (let ((first (match-string 1 input))
            (id (and (match-string 2 input)
                     (string-remove-suffix ".git" (match-string 2 input))))
            (anchor (match-string 3 input)))
        (cond ((or (null first) (member first '("starred" "discover" "search")))
               (remoto--path-at forge 'root))
              ((and (null id) (remoto-gist--id-p first))
               (remoto-gist--owned forge first anchor))
              ((null id) (remoto--path-at forge 'owner first))
              (t (remoto-gist--anchored forge first id anchor))))))))

;;;; Registration

;; Made anew at each load, as `remoto--github' is.
(defconst remoto--gist
  (let ((forge (remoto-gist-create :name 'gist :prefixes '("gist") :host "github.com")))
    (remoto-register-forge forge)
    forge)
  "GitHub's gists, at /gist:.")

;; A /gist: path at a file prompt loads remoto before the mode is on, as a
;; remote path loads TRAMP.
;;;###autoload (add-to-list 'file-name-handler-alist '("\\`/gist:" . remoto-autoload-file-name-handler))

(provide 'remoto-gist)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-gist.el ends here
