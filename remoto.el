;;; remoto.el --- Browse GitHub repos without cloning -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Ag Ibragimov
;;
;; Author: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Assisted-by: ECA:claude-opus-5
;; Maintainer: Ag Ibragimov <agzam.ibragimov@gmail.com>
;; Created: April 24, 2026
;; Version: 2.3.0
;; Keywords: tools vc
;; Homepage: https://github.com/agzam/remoto.el
;; Package-Requires: ((emacs "29.1") (ghub "5.3.0"))
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.

;;; Commentary:

;; remoto.el lets you browse any GitHub repository in Emacs as if it were
;; cloned locally - without cloning it.  It registers a virtual filesystem
;; via `file-name-handler-alist' that translates Emacs file operations into
;; requests to a forge.  A forge is a `remoto-forge' that answers the
;; generic functions of the forge contract with plain data; GitHub's
;; answers live in remoto-github.el and use the `ghub' library.
;;
;; Loading this file defines things and changes nothing.  `global-remoto-mode'
;; is the switch: it installs the file-name handler, the `find-file' and
;; `dired' URL rewriting, the completion metadata, and the auto-enabling of
;; `remoto-mode' in remoto buffers, and removes all of them when turned off.
;;
;; Usage:
;;   C-x C-f /github:torvalds/linux RET
;;   M-x remoto-browse RET https://github.com/torvalds/linux RET
;;
;; Both turn the mode on when it is off: `remoto-browse' itself, and the
;; path through `remoto-autoload-file-name-handler', which the package
;; autoloads register for `/github:' and `/gh:' paths the way TRAMP
;; autoloads on a remote path.  `(global-remoto-mode 1)' in the init file
;; turns it on ahead of time.  `remoto-browse' supports pasting any GitHub
;; URL, git remote URL, or owner/repo shorthand.

;;; Code:

(require 'cl-lib)
(require 'files-x)
(require 'format-spec)
(require 'ghub)
(require 'iso8601)

;;;; Forges

(cl-defstruct (remoto-forge (:constructor remoto-forge-create)
                            (:copier nil))
  "A source of repositories that remoto paths name.
PREFIXES are the path prefixes without slash or colon, the first one
canonical; DELIMITERS the characters after OWNER/REPO it supports."
  name prefixes host delimiters repo-end)

(cl-defstruct (remoto-github (:include remoto-forge)
                             (:constructor remoto-github-create)
                             (:copier nil))
  "The GitHub forge.")

(defvar remoto--forges nil
  "Alist of (PREFIX . FORGE) for every prefix of every registered forge.")

(defvar remoto--handler-regexp "\\`/\\(?:github\\|gh\\):"
  "Regexp matching remoto file paths: every prefix of every forge.
`remoto-register-forge' rebuilds it.  Each forge file carries an
autoload cookie that repeats its prefixes as a literal, in this
spelling, for `remoto-autoload-file-name-handler'.")

(defun remoto--prefix (forge)
  "Return the canonical path prefix of FORGE, such as /github:."
  (concat "/" (car (remoto-forge-prefixes forge)) ":"))

(defun remoto--refresh-handler ()
  "Point the entry of `file-name-handler-alist' at the current prefixes."
  (when (bound-and-true-p global-remoto-mode)
    (setq file-name-handler-alist
          (rassq-delete-all #'remoto-file-name-handler file-name-handler-alist))
    (push (cons remoto--handler-regexp #'remoto-file-name-handler)
          file-name-handler-alist)))

(defun remoto-register-forge (forge)
  "Register FORGE under each of its prefixes and refresh the handler regexp.
Register the delimiters of FORGE with `remoto-register-delimiter' first."
  (setf (remoto-forge-repo-end forge)
        (rx-to-string `(in "/:" ,@(mapcar #'char-to-string
                                          (remoto-forge-delimiters forge)))
                      t))
  (dolist (prefix (remoto-forge-prefixes forge))
    (if-let* ((entry (assoc prefix remoto--forges)))
        (setcdr entry forge)
      (setq remoto--forges (append remoto--forges (list (cons prefix forge))))))
  (setq remoto--handler-regexp
        (concat "\\`/\\(?:"
                (mapconcat #'regexp-quote (mapcar #'car remoto--forges) "\\|")
                "\\):"))
  (remoto--refresh-handler))

(defun remoto-unregister-forge (forge)
  "Remove FORGE from the registry and refresh the handler regexp."
  (setq remoto--forges (seq-remove (lambda (entry) (eq (cdr entry) forge))
                                   remoto--forges))
  (setq remoto--handler-regexp
        (concat "\\`/\\(?:"
                (mapconcat #'regexp-quote (mapcar #'car remoto--forges) "\\|")
                "\\):"))
  (remoto--refresh-handler))

(defun remoto--prefix-of (string)
  "Return (PREFIX . FORGE) for the registered prefix at the head of STRING."
  (seq-find (lambda (entry)
              (string-prefix-p (concat "/" (car entry) ":") string))
            remoto--forges))

(defun remoto--canonical-forge (string)
  "Return the forge whose canonical prefix is the head of STRING, or nil."
  (when-let* (((stringp string))
              (entry (remoto--prefix-of string))
              ((equal (car entry) (car (remoto-forge-prefixes (cdr entry))))))
    (cdr entry)))

(defun remoto--after-prefix (name)
  "Return the text of the remoto NAME after its canonical prefix."
  (substring name (length (remoto--prefix (remoto--canonical-forge name)))))

(defvar remoto--github
  (remoto-github-create :name 'github :prefixes '("github" "gh")
                        :host "github.com" :delimiters '(?@ ?#))
  "The GitHub forge.  A `remoto-path' built without a forge is GitHub's.")

;;;; Forge contract

;; A forge answers these with plain data; the core turns the data into
;; file operations, Dired lines and completion candidates.  The data
;; methods signal `remoto-unsupported' by default; the URL ones say nil.

(define-error 'remoto-unsupported "Remoto: the forge does not support this")

(defun remoto--unsupported (forge operation)
  "Signal `remoto-unsupported' for OPERATION on FORGE."
  (signal 'remoto-unsupported (list (remoto-forge-name forge) operation)))

(cl-defgeneric remoto-forge-default-ref (forge _owner _repo)
  "Return the name of the default branch of OWNER/REPO on FORGE."
  (remoto--unsupported forge 'default-ref))

(cl-defgeneric remoto-forge-tree (forge _owner _repo _ref)
  "Return the tree of OWNER/REPO at REF on FORGE.
A hash table from path to entry, an alist with `type' (\"tree\" or
\"blob\"), `size', `sha' and `mode'; \"\" and \"/\" hold the root entry
and \"\\0truncated\" is t when the tree is partial."
  (remoto--unsupported forge 'tree))

(cl-defgeneric remoto-forge-directory-contents (forge _owner _repo _ref _dir)
  "Return the entries under DIR of OWNER/REPO at REF on FORGE.
A list of (PATH . ENTRY) with PATH from the repository root, asked for
when the tree is truncated."
  (remoto--unsupported forge 'directory-contents))

(cl-defgeneric remoto-forge-children (forge owner repo ref dir)
  "Return the direct children of DIR in OWNER/REPO at REF on FORGE.
A list of (NAME . ENTRY) cheap enough for completion; the tree answers
by default."
  (remoto--tree-children
   (remoto-path-create :forge forge :owner owner :repo repo :ref ref
                       :path (concat "/" dir))))

(cl-defgeneric remoto-forge-content (forge _owner _repo _ref _path)
  "Return the bytes of the file PATH of OWNER/REPO at REF on FORGE.
A unibyte string; the caller decodes it."
  (remoto--unsupported forge 'content))

(cl-defgeneric remoto-forge-commit-sha (forge _owner _repo _ref)
  "Return the commit SHA that REF names in OWNER/REPO on FORGE."
  (remoto--unsupported forge 'commit-sha))

(cl-defgeneric remoto-forge-branches (forge _owner _repo)
  "Return the branch names of OWNER/REPO on FORGE."
  (remoto--unsupported forge 'branches))

(cl-defgeneric remoto-forge-tags (forge _owner _repo)
  "Return the tag names of OWNER/REPO on FORGE."
  (remoto--unsupported forge 'tags))

(cl-defgeneric remoto-forge-forget-refs (_forge _owner _repo)
  "Drop what FORGE remembers of the branches and tags of OWNER/REPO."
  nil)

(cl-defgeneric remoto-forge-topics (forge _owner _repo)
  "Return the open topics of OWNER/REPO on FORGE, newest first.
Each is an alist with `number', `title', `state' and, for a pull
request, `pull_request'."
  (remoto--unsupported forge 'topics))

(cl-defgeneric remoto-forge-search-topics (forge _owner _repo _query)
  "Return the topics of OWNER/REPO on FORGE that match QUERY."
  (remoto--unsupported forge 'search-topics))

(cl-defgeneric remoto-forge-topic (forge _owner _repo _number)
  "Return the topic NUMBER of OWNER/REPO on FORGE, or nil."
  (remoto--unsupported forge 'topic))

(cl-defgeneric remoto-forge-topic-comments (forge _owner _repo _number)
  "Return the comments of the topic NUMBER of OWNER/REPO on FORGE."
  (remoto--unsupported forge 'topic-comments))

(cl-defgeneric remoto-forge-pull-request (_forge _owner _repo _number)
  "Return what FORGE knows of pull request NUMBER of OWNER/REPO beyond the topic."
  nil)

(cl-defgeneric remoto-forge-reviews (_forge _owner _repo _number)
  "Return the reviews of pull request NUMBER of OWNER/REPO on FORGE."
  nil)

(cl-defgeneric remoto-forge-file-commits (_forge _owner _repo _ref _dir _names)
  "Return (NAME . MESSAGE) for the NAMES under DIR of OWNER/REPO at REF on FORGE.
MESSAGE is the first line of the last commit that touched NAME."
  nil)

(cl-defgeneric remoto-forge-user (_forge)
  "Return the login of the account of the token on FORGE, or nil."
  nil)

(cl-defgeneric remoto-forge-user-orgs (_forge _user)
  "Return the organizations of USER on FORGE, logins with account properties."
  nil)

(cl-defgeneric remoto-forge-search-accounts (forge _query _wait)
  "Return the logins of the accounts on FORGE that match QUERY.
With WAIT, ask and answer; without it, answer from a cache and start
the request in the background."
  (remoto--unsupported forge 'search-accounts))

(cl-defgeneric remoto-forge-recent-repos (forge _owner _wait)
  "Return the names of OWNER's repositories on FORGE, newest first.
With WAIT, ask and answer; without it, answer from a cache and start
the request in the background."
  (remoto--unsupported forge 'recent-repos))

(cl-defgeneric remoto-forge-search-repos (forge _owner _query _wait)
  "Return the names of OWNER's repositories on FORGE that match QUERY.
With WAIT, ask and answer; without it, answer from a cache and start
the request in the background."
  (remoto--unsupported forge 'search-repos))

(cl-defgeneric remoto-forge-prefetch-repos (_forge _owner)
  "Start fetching OWNER's repositories on FORGE for the completion that follows."
  nil)

(cl-defgeneric remoto-forge-account-entries (forge _dir)
  "Return the listing entries of DIR, the root of FORGE.
Those are the account of the token and its organizations."
  (remoto--unsupported forge 'account-entries))

(cl-defgeneric remoto-forge-owner-listing (forge _dir)
  "Return the `remoto--listing' of DIR, an owner directory of FORGE, cached.
Later pages may keep loading in the background."
  (remoto--unsupported forge 'owner-listing))

(cl-defgeneric remoto-forge-forget-all (_forge)
  "Drop everything FORGE caches, as `remoto-unload-function' asks."
  nil)

(cl-defgeneric remoto-forge-url-input-p (_forge _input)
  "Return non-nil when INPUT has the shape of a URL or remote of FORGE."
  nil)

(cl-defgeneric remoto-forge-parse-url (_forge _input)
  "Return the `remoto-path' that the URL or remote INPUT names on FORGE, or nil."
  nil)

(cl-defgeneric remoto-forge-parse-topic-url (_forge _input)
  "Return (OWNER REPO NUMBER) when INPUT is the web URL of a topic on FORGE."
  nil)

(defun remoto--url-forge (input)
  "Return the forge for which INPUT is a URL or remote, or nil."
  (seq-find (lambda (forge) (remoto-forge-url-input-p forge input))
            (seq-uniq (mapcar #'cdr remoto--forges))))

;;;; Path parsing

(cl-defstruct (remoto-delimiter (:constructor remoto-delimiter-create)
                                (:copier nil))
  "A character after OWNER/REPO that opens a level of its own."
  char level kind)

(defvar remoto--delimiters nil
  "Alist of (CHAR . `remoto-delimiter') that `remoto--parse' reads.")

(defun remoto-register-delimiter (char level kind)
  "Register CHAR as the delimiter after OWNER/REPO that opens LEVEL.
KIND is `ref' when the text after CHAR names a ref and a colon then
starts its tree, as `@' does, or `topic' when it names a topic that
opens in a buffer of its own, as `#' does.  A forge lists the
delimiters it supports; the others are plain characters in its paths."
  (setf (alist-get char remoto--delimiters)
        (remoto-delimiter-create :char char :level level :kind kind)))

(remoto-register-delimiter ?@ 'refs 'ref)
(remoto-register-delimiter ?# 'topics 'topic)
(remoto-register-forge remoto--github)

(defun remoto--delimiter-of (level)
  "Return the `remoto-delimiter' that opens LEVEL, or nil."
  (seq-find (lambda (d) (eq (remoto-delimiter-level d) level))
            (mapcar #'cdr remoto--delimiters)))

(defun remoto--level-kind (level)
  "Return the kind of the delimiter that opens LEVEL, or nil."
  (when-let* ((delimiter (remoto--delimiter-of level)))
    (remoto-delimiter-kind delimiter)))

(cl-defstruct (remoto-path (:constructor remoto-path-create)
                           (:copier nil))
  "Parsed components of a remoto path.
LEVEL names the directory the path is in, QUERY the text after it.
SHORT marks the /PREFIX:OWNER/REPO/PATH form, a tree on the default branch."
  (forge remoto--github) owner repo ref path level query string short)

(defun remoto--parse-tree (forge string owner repo ref raw short)
  "Build the `remoto-path' of STRING, a tree path of FORGE, from its parts.
OWNER, REPO and REF name the tree; RAW is the text after the colon, or
after the repository in the SHORT form.  A directory ends in a slash,
so the query is what follows the last one."
  (remoto-path-create
   :forge forge :owner owner :repo repo
   :ref (and ref (not (string-empty-p ref)) ref)
   :path (if (string-empty-p raw) "/" raw)
   :level 'tree
   :query (cond ((string-suffix-p "/" raw) "")
                ((string-match-p (rx "/" (* (not "/")) eos) raw)
                 (substring raw (1+ (string-match-p (rx "/" (* (not "/")) eos) raw))))
                (t raw))
   :string string :short short))

(defun remoto--parse (string)
  "Parse STRING, a partial or canonical remoto path, into a `remoto-path'.
Return nil unless STRING starts with the canonical prefix of a forge.
Every string with one parses: LEVEL is the deepest directory it names
and QUERY the text after that, so `remoto-path-directory' + QUERY is STRING."
  (when-let* ((forge (remoto--canonical-forge string)))
    (let* ((rest (substring string (length (remoto--prefix forge))))
           (slash (string-search "/" rest))
           (owner (and slash (substring rest 0 slash)))
           (after-owner (and slash (substring rest (1+ slash))))
           (end (and after-owner
                     (string-match-p (remoto-forge-repo-end forge) after-owner)))
           (repo (and end (substring after-owner 0 end))))
      (cond
       ;; /PREFIX:QUERY, or /PREFIX:/... with no account name
       ((or (null slash) (string-empty-p owner))
        (remoto-path-create :forge forge :level 'root :query rest
                            :path "/" :string string))
       ;; /PREFIX:OWNER/QUERY: no delimiter yet, or one after no name
       ((or (null end) (string-empty-p repo))
        (remoto-path-create :forge forge :level 'owner :owner owner
                            :query after-owner :path "/" :string string))
       (t
        (let ((char (aref after-owner end))
              (tail (substring after-owner (1+ end))))
          (pcase char
            (?: (remoto--parse-tree forge string owner repo nil tail nil))
            (?/ (remoto--parse-tree forge string owner repo nil
                                    (concat "/" tail) t))
            (_
             (let* ((delimiter (alist-get char remoto--delimiters))
                    (colon (and (eq (remoto-delimiter-kind delimiter) 'ref)
                                (string-search ":" tail))))
               (if colon
                   (remoto--parse-tree forge string owner repo
                                       (substring tail 0 colon)
                                       (substring tail (1+ colon)) nil)
                 (remoto-path-create :forge forge
                                     :level (remoto-delimiter-level delimiter)
                                     :owner owner :repo repo :query tail
                                     :path "/" :string string)))))))))))

(defun remoto-path-directory (parsed)
  "Return the directory part of PARSED: its string without its query."
  (let ((string (remoto-path-string parsed)))
    (substring string 0 (- (length string) (length (remoto-path-query parsed))))))

(defun remoto--directory-level (directory)
  "Return the level that DIRECTORY, a remoto directory name, is at, or nil.
A name with a query after its level is no directory, except in a tree,
where a canonical name without a trailing slash lists its parent."
  (when-let* ((parsed (remoto--parse directory)))
    (let ((level (remoto-path-level parsed)))
      (and (or (eq level 'tree) (string-empty-p (remoto-path-query parsed)))
           level))))

(defun remoto--parse-path (filename)
  "Parse canonical remoto FILENAME into a `remoto-path' struct.
Returns nil if FILENAME does not match the canonical format."
  (when-let* ((parsed (remoto--parse filename))
              ((eq (remoto-path-level parsed) 'tree))
              ((not (remoto-path-short parsed))))
    parsed))

(defun remoto--path-prefix (parsed)
  "Return the canonical prefix of the forge of PARSED, such as /github:."
  (remoto--prefix (remoto-path-forge parsed)))

(defun remoto--tree-prefix (parsed)
  "Return the /PREFIX:OWNER/REPO[@REF]: prefix of the canonical PARSED."
  (format "%s%s/%s%s:"
          (remoto--path-prefix parsed)
          (remoto-path-owner parsed)
          (remoto-path-repo parsed)
          (if (remoto-path-ref parsed)
              (concat "@" (remoto-path-ref parsed))
            "")))

(defun remoto--canonical-path (parsed)
  "Build a canonical remoto path string from PARSED `remoto-path'."
  (concat (remoto--tree-prefix parsed) (or (remoto-path-path parsed) "/")))

(defun remoto--unparse (parsed)
  "Build the remoto path string of PARSED, the inverse of `remoto--parse'.
A canonical tree path comes back with the slash after its colon."
  (let ((prefix (remoto--path-prefix parsed))
        (owner (remoto-path-owner parsed))
        (repo (remoto-path-repo parsed))
        (query (remoto-path-query parsed)))
    (pcase (remoto-path-level parsed)
      ('root (concat prefix query))
      ('owner (concat prefix owner "/" query))
      ('tree (if (remoto-path-short parsed)
                 (concat prefix owner "/" repo (remoto-path-path parsed))
               (remoto--canonical-path parsed)))
      (level (concat prefix owner "/" repo
                     (char-to-string
                      (remoto-delimiter-char (remoto--delimiter-of level)))
                     query)))))

(defun remoto--repo-id (forge owner repo)
  "Return the cache key of OWNER/REPO on FORGE: its canonical name.
Two forges may host an OWNER/REPO each, so the prefix is part of the key."
  (concat (remoto--prefix forge) owner "/" repo))

(defun remoto--repo-key (parsed)
  "Return the cache key of the tree PARSED names: /PREFIX:OWNER/REPO@REF."
  (format "%s@%s"
          (remoto--repo-id (remoto-path-forge parsed)
                           (remoto-path-owner parsed)
                           (remoto-path-repo parsed))
          (or (remoto-path-ref parsed) "HEAD")))

;;;; Options, auth and the ghub transport

(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))
(declare-function dired-goto-file "dired" (file))

(defgroup remoto nil
  "Browse GitHub repos without cloning."
  :group 'tools
  :prefix "remoto-")

(defcustom remoto-github-auth nil
  "Auth token source for GitHub API requests via ghub.
nil means use the default ghub token (USERNAME^ghub in auth-source).
A symbol like `forge' uses that package's token instead.
A string is used as a literal token.
See ghub documentation for auth-source setup."
  :type '(choice (const :tag "Default ghub token" nil)
                 (symbol :tag "Package token name")
                 (string :tag "Literal token"))
  :group 'remoto)

(defcustom remoto-auth-timeout 10
  "Seconds to wait for auth-source token lookup before giving up.
When ghub's token lookup (which may trigger GPG decryption of
authinfo) exceeds this limit, remoto falls back to unauthenticated
access for that request.  Use `remoto-reset-auth' to retry after
adding a token."
  :type 'number
  :group 'remoto)

(defcustom remoto-search-cache-ttl 300
  "Seconds before cached API results expire.
Set to 0 to disable caching.  Applies to the search, branch, and
directory-listing caches.  Defined early so functions above the
\"Repository search\" section can reference it at byte-compile time."
  :type 'integer
  :group 'remoto)

(cl-defstruct (remoto--login (:constructor remoto--login-create)
                             (:copier nil))
  "What remoto knows of its login at one API host.
FAILED is non-nil once authenticated access failed for good (a missing
or rejected token, not a timeout), so requests go unauthenticated until
`remoto-reset-auth'; TOKEN is the token that works; USER its account."
  failed token user)

(defvar remoto--logins (make-hash-table :test 'equal)
  "Login state by API host, each a `remoto--login'.
Forges on one host, such as GitHub and gists, share one entry.")

(defun remoto--login (host)
  "Return the `remoto--login' of the API host HOST, made on first use."
  (or (gethash host remoto--logins)
      (puthash host (remoto--login-create) remoto--logins)))

(cl-defgeneric remoto--api-host (forge)
  "Return the host `remoto--api' sends the requests of FORGE to.
In ghub's spelling, with the path of the API: \"api.github.com\",
\"codeberg.org/api/v1\".")

(cl-defmethod remoto--api-host ((_forge remoto-github))
  "GitHub's API host."
  "api.github.com")

(cl-defgeneric remoto--ghub-forge (forge)
  "Return the symbol ghub knows the kind of FORGE by, nil for GitHub.")

(cl-defmethod remoto--ghub-forge ((_forge remoto-github))
  "GitHub is ghub's default kind."
  nil)

(defun remoto--forge-login (forge)
  "Return the `remoto--login' at the API host of FORGE."
  (remoto--login (remoto--api-host forge)))

(defun remoto--json-reader (_status)
  "Parse JSON response with list-type arrays for remoto compatibility.
Finds the JSON body by scanning for the first `{' or `[',
handling both header-present and header-stripped response buffers
across different ghub and url.el versions."
  (goto-char (point-min))
  (when (re-search-forward "[{[]" nil t)
    (backward-char 1)
    (let ((body (buffer-substring-no-properties (point) (point-max))))
      (unless (string-empty-p body)
        (condition-case nil
            (json-parse-string
             (decode-coding-string body 'utf-8)
             :object-type 'alist
             :array-type 'list
             :null-object nil
             :false-object nil)
          (json-error nil))))))

;;;; Fetch indicator

(defcustom remoto-show-fetch-indicator t
  "When non-nil, show a \"fetching\" indicator during GitHub requests.
While completing a remoto path (e.g. with \\[find-file]) or at the
`remoto-browse' prompt, it is drawn as minibuffer text, so it works with
any completion UI (vertico, icomplete, default, ...).  A fetch that
blocks with no such prompt up, as when the chosen path opens, shows it
in the echo area instead."
  :type 'boolean
  :group 'remoto)

(defvar remoto--inflight-count 0
  "Number of API requests the minibuffer overlay stands for.
Every async request of the completion counts, and so does a blocking
fetch that runs while a remoto prompt is up.")

(defvar remoto--status-overlay nil
  "Overlay holding the fetch indicator slot in the active minibuffer.")

(defconst remoto--fetch-indicator-text
  (propertize "⟳" 'face 'shadow)
  "Circle arrow shown by the fetch indicator in both contexts.
Reused by the minibuffer slot and the echo-area message so the two read
identically.  One character, because a word in the minibuffer scrolls
the line as it comes and goes; a text character rather than an emoji,
because a color glyph is taller than the line it sits in and ignores
the `shadow' face.")

(defconst remoto--fetch-indicator-blank
  (make-string (string-width remoto--fetch-indicator-text) ?\s)
  "What the indicator's slot holds between requests.")

(defun remoto--clear-status ()
  "Remove the fetch indicator slot, if any."
  (when (overlayp remoto--status-overlay)
    (delete-overlay remoto--status-overlay))
  (setq remoto--status-overlay nil))

(defun remoto--render-status (buffer busy)
  "Draw the fetch indicator slot in BUFFER, filled when BUSY.
The slot sits between the prompt and the input, never after it.  Emacs
draws the cursor after any string that follows point, and a completion
UI that opens its candidate list there claims the `cursor' property for
its own string - Vertico does - so an indicator after the input drags
the cursor sideways on every request.  The blank keeps the slot's width
between requests, so the input does not shift either."
  (with-current-buffer buffer
    (let ((pos (minibuffer-prompt-end)))
      (unless (and (overlayp remoto--status-overlay)
                   (eq (overlay-buffer remoto--status-overlay) buffer))
        (remoto--clear-status)
        (setq remoto--status-overlay (make-overlay pos pos)))
      (move-overlay remoto--status-overlay pos pos)
      (overlay-put remoto--status-overlay 'priority 1000)
      (overlay-put remoto--status-overlay 'before-string
                   (concat (if busy
                               remoto--fetch-indicator-text
                             remoto--fetch-indicator-blank)
                           " ")))))

(defun remoto--hide-status ()
  "Blank the fetch indicator, keeping its slot while the prompt is up.
A slot that came and went would shift the input left and right as
requests come and go, which is what drawing it at all has to avoid."
  (let ((buf (and (overlayp remoto--status-overlay)
                  (overlay-buffer remoto--status-overlay))))
    (if (and (buffer-live-p buf) (minibufferp buf))
        (remoto--render-status buf nil)
      (remoto--clear-status))))

(defun remoto--completion-minibuffer ()
  "Return the active minibuffer when it is completing for remoto, else nil.
That is a file name inside a remoto path, with either prefix and possibly
behind a shadowed directory (\"~/x//gh:o/\") the way `read-file-name'
reads it, or the `remoto-browse' prompt, whose collection is
`remoto--repo-completion-table'.  A prompt opened inside a remoto
directory counts even with nothing typed: `read-file-name' puts its DIR
argument in the minibuffer's `default-directory', and completion keeps
fetching from there after \\[move-beginning-of-line] \\[kill-line]."
  (when-let* ((win (active-minibuffer-window))
              (buf (window-buffer win)))
    (with-current-buffer buf
      (and (or (eq minibuffer-completion-table #'remoto--repo-completion-table)
               (string-match-p remoto--handler-regexp
                               (condition-case nil
                                   (substitute-in-file-name
                                    (minibuffer-contents-no-properties))
                                 (error "")))
               (string-match-p remoto--handler-regexp
                               (or default-directory "")))
           buf))))

(defun remoto--show-status ()
  "Show the in-flight fetch indicator in the active remoto minibuffer.
No-op unless `remoto-show-fetch-indicator' is non-nil and the active
minibuffer is one that `remoto--completion-minibuffer' recognizes.
Drawn as minibuffer text so it works with any completion UI."
  (when remoto-show-fetch-indicator
    (when-let* ((buf (remoto--completion-minibuffer)))
      (remoto--render-status buf t))))

(defun remoto--inflight-inc ()
  "Register a new in-flight async request and show the indicator."
  (setq remoto--inflight-count (1+ remoto--inflight-count))
  (remoto--show-status))

(defun remoto--inflight-dec ()
  "Mark one in-flight async request as finished.
Blank the indicator once no requests remain."
  (setq remoto--inflight-count (max 0 (1- remoto--inflight-count)))
  (when (zerop remoto--inflight-count)
    (remoto--hide-status)))

(defun remoto--minibuffer-exit-cleanup ()
  "Reset in-flight indicator state when a minibuffer exits."
  (remoto--clear-status)
  (setq remoto--inflight-count 0))

(defvar remoto--sync-fetch-depth 0
  "Nesting depth of `remoto--with-fetch-indicator' bodies.
Only the outermost body draws and clears the indicator, so a command
wrapped as a whole and the API calls inside it draw it once.")

(defvar remoto--sync-fetch-overlay nil
  "Non-nil while the outermost blocking fetch is drawn as the minibuffer overlay.
Decides which of the two indicators the end of that fetch clears.")

(defun remoto--sync-fetch-begin ()
  "Draw the indicator for the blocking fetch about to begin.
In a remoto completion minibuffer that is the overlay of the async
fetches, painted at once because nothing redisplays while the fetch
blocks; anywhere else it is an echo-area message, which the echo area
shows at once."
  (setq remoto--sync-fetch-depth (1+ remoto--sync-fetch-depth))
  (when (= remoto--sync-fetch-depth 1)
    (setq remoto--sync-fetch-overlay (and (remoto--completion-minibuffer) t))
    (if remoto--sync-fetch-overlay
        (progn (remoto--inflight-inc)
               (redisplay))
      (let ((message-log-max nil))
        (message "Remoto %s" remoto--fetch-indicator-text)))))

(defun remoto--sync-fetch-end ()
  "Clear the indicator once the outermost blocking fetch is over.
A message that something else put up meanwhile is left alone."
  (setq remoto--sync-fetch-depth (max 0 (1- remoto--sync-fetch-depth)))
  (when (zerop remoto--sync-fetch-depth)
    (if remoto--sync-fetch-overlay
        (remoto--inflight-dec)
      (when (equal (current-message)
                   (format "Remoto %s" remoto--fetch-indicator-text))
        (let ((message-log-max nil))
          (message nil))))
    (setq remoto--sync-fetch-overlay nil)))

(defmacro remoto--with-fetch-indicator (&rest body)
  "Run BODY, a blocking GitHub round-trip, with the fetch indicator up.
Every synchronous API call goes through this, so `remoto-browse' and a
path at `find-file' or `dired' show the same thing: the minibuffer
overlay while completing, the echo area once the prompt is gone.
Honors `remoto-show-fetch-indicator' and does nothing in batch, where
there is no display.  Returns BODY's value."
  (declare (indent 0) (debug t))
  `(if (or noninteractive (not remoto-show-fetch-indicator))
       (progn ,@body)
     (remoto--sync-fetch-begin)
     (unwind-protect
         (progn ,@body)
       (remoto--sync-fetch-end))))

(cl-defstruct (remoto--request (:constructor remoto--request-create))
  "A GitHub request started under `while-no-input'."
  (status 'pending)
  buffer
  value)

(defvar remoto--pending-requests (make-hash-table :test 'equal)
  "Requests started under `while-no-input', keyed by (HOST RESOURCE AUTH).
Such a request outlives the completion call that started it: the reply
lands in its `remoto--request', and the next call for the same key
waits on that request or reads the landed reply instead of asking
the forge again.  A failed request leaves the table, so the next call
retries.")

(defun remoto--request-condition (err host resource)
  "Turn ERR, as ghub hands it to an errorback, into the condition ghub signals.
HOST and RESOURCE name the request in the condition data."
  (pcase err
    (`(error http ,code . ,rest)
     (list 'ghub-http-error code (nth 2 (assq code url-http-codes))
           (concat "https://" host resource) (car rest)))
    (`(error . ,data) (cons 'ghub-error data))
    (_ err)))

(defun remoto--request-start (key forge resource auth)
  "Start a callback request to FORGE for RESOURCE with AUTH, registered under KEY."
  (let ((req (remoto--request-create))
        (host (remoto--api-host forge)))
    (setf (remoto--request-buffer req)
          (ghub-get resource nil
                    :auth auth
                    :reader #'remoto--json-reader
                    :host host
                    :forge (remoto--ghub-forge forge)
                    :callback (lambda (value &rest _)
                                (setf (remoto--request-value req) value
                                      (remoto--request-status req) 'done))
                    :errorback (lambda (err &rest _)
                                 (remhash key remoto--pending-requests)
                                 (setf (remoto--request-value req)
                                       (remoto--request-condition err host resource)
                                       (remoto--request-status req) 'error))))
    (puthash key req remoto--pending-requests)
    req))

(defun remoto--auth-key (auth)
  "Return a stable identity for AUTH that is not the credential itself.
`remoto--pending-requests' only has to tell two callers apart, and its
keys are readable in a backtrace or a variable dump, so a token string
goes in hashed.  A symbol such as `none' is no secret and stays as is."
  (if (stringp auth) (secure-hash 'sha256 auth) auth))

(defun remoto--ghub-get-interruptible (forge resource auth)
  "GET RESOURCE of FORGE with AUTH through a callback, in a way input can end.
`url-retrieve-synchronously' leaves its buffer behind when `while-no-input'
throws past it, and the reply nobody reads keeps the buffer alive; ghub
kills the buffer of a callback request itself once the reply is handled.
Return the value or signal the condition the synchronous call would."
  (let* ((key (list (remoto--api-host forge) resource (remoto--auth-key auth)))
         (req (or (gethash key remoto--pending-requests)
                  (remoto--request-start key forge resource auth))))
    (while (and (eq (remoto--request-status req) 'pending)
                (buffer-live-p (remoto--request-buffer req)))
      (accept-process-output nil 0.1))
    (remhash key remoto--pending-requests)
    (pcase (remoto--request-status req)
      ('done (remoto--request-value req))
      ('error (let ((err (remoto--request-value req)))
                (signal (car err) (cdr err))))
      (_ (error "Remoto: no reply for %s" resource)))))

(defconst remoto--not-found "Remoto: not found: "
  "How the `user-error' for an answer of 404 starts, or of 422 to a search.
Forgejo's 400 for a ref it lacks is one too.
Callers that take a missing resource for an answer test for it: a child
error of `user-error' would print its message in quotes.")

(defconst remoto--auth-rejected "Remoto: authentication failed for "
  "How the `user-error' for an answer of 401 starts, the API host after it.
`remoto--api' tests for it to go on without the token that was refused.")

(defun remoto--error-payload-message (err)
  "Return the message in the body that came with ERR, a `ghub-http-error'."
  (let ((payload (nth 4 err)))
    (and (listp payload) (stringp (alist-get 'message payload))
         (alist-get 'message payload))))

(defun remoto--http-error-message (forge endpoint err headers)
  "Return the message for ERR, the `ghub-http-error' of ENDPOINT on FORGE.
HEADERS came with the answer; a Retry-After among them says how long to wait."
  (let ((code (nth 1 err))
        (wait (cdr (assoc-string "retry-after" headers t)))
        (detail (remoto--error-payload-message err)))
    (concat (format "Remoto: %s " (remoto--api-host forge))
            (if (eql code 429)
                (format "rate limited %s (429)" endpoint)
              (format "answered %s%s for %s" code
                      (if (nth 2 err) (concat " " (nth 2 err)) "") endpoint))
            (and detail (concat ": " detail))
            (cond ((null wait) (and (eql code 429) "; retry later"))
                  ((string-match-p "\\`[0-9]+\\'" wait)
                   (format "; retry in %s seconds" wait))
                  (t (format "; retry after %s" wait))))))

(defun remoto--ghub-get (forge resource auth endpoint)
  "Call `ghub-get' on RESOURCE of FORGE with AUTH, translating errors.
ENDPOINT is used in error messages for context.  The host is always
explicit: ghub's default for a forge is its web host, which answers HTML."
  ;; A synchronous ghub-get leaves the headers of its answer here, so
  ;; the binding holds this request's and no earlier one's.
  (let ((ghub-response-headers nil))
    (condition-case err
        (remoto--with-fetch-indicator
          (let ((inhibit-message (not ghub-debug)))
            ;; `while-no-input' binds `throw-on-input'; only then can input
            ;; abandon the call, and only then is the callback path needed.
            (if throw-on-input
                (remoto--ghub-get-interruptible forge resource auth)
              (ghub-get resource nil
                        :auth auth
                        :reader #'remoto--json-reader
                        :host (remoto--api-host forge)
                        :forge (remoto--ghub-forge forge)))))
      ;; ghub signals every HTTP failure as (ghub-http-error CODE MESSAGE URL
      ;; PAYLOAD); there are no per-status error symbols to match on.
      (ghub-http-error
       (pcase (cadr err)
         ;; A search answers 422 when its user: qualifier names no account.
         ((or 404 422) (user-error "%s%s" remoto--not-found endpoint))
         ;; Forgejo answers 400 "sha not found [REF]" to a ref it lacks.
         ((and 400 (guard (string-match-p "not found"
                                          (or (remoto--error-payload-message err) ""))))
          (user-error "%s%s" remoto--not-found endpoint))
         (403 (user-error "Remoto: access denied (rate limit or permissions): %s"
                          endpoint))
         (401 (user-error "%s%s; configure a token for it in auth-source, \
then M-x remoto-reset-auth" remoto--auth-rejected (remoto--api-host forge)))
         (_ (user-error "%s" (remoto--http-error-message
                              forge endpoint err ghub-response-headers)))))
      (json-error
       (user-error "Remoto: could not parse API response for %s" endpoint)))))

(cl-defgeneric remoto--literal-token (_forge)
  "Return the token of FORGE from a user option, or nil."
  nil)

(cl-defmethod remoto--literal-token ((_forge remoto-github))
  "A string `remoto-github-auth' is GitHub's token."
  (and (stringp remoto-github-auth) remoto-github-auth))

(defun remoto--auth (forge)
  "Return the `:auth' for a request to FORGE: a token, nil or `none'.
nil leaves the lookup to ghub; `none' goes unauthenticated.  A token
found here is kept in the login of the host, so later calls skip the
auth-source search.  A failed search marks the login (see
`remoto--find-token'), and this call goes unauthenticated at once."
  (let ((login (remoto--forge-login forge)))
    (cond ((remoto--login-failed login) 'none)
          ((remoto--login-token login))
          ((remoto--literal-token forge))
          ((when-let* ((token (remoto--find-token forge)))
             (setf (remoto--login-token login) token)))
          ((remoto--login-failed login) 'none))))

(defun remoto--anonymous-get (forge endpoint)
  "GET ENDPOINT of the API of FORGE without a token.
The endpoints of the token's account, user and below, are not asked:
they answer 401, which url.el takes for a cue to prompt for a password."
  (if (string-match-p (rx bos "user" (or eos (in "/?"))) endpoint)
      (user-error "Remoto: %s needs a token for %s" endpoint (remoto--api-host forge))
    (remoto--ghub-get forge (concat "/" endpoint) 'none endpoint)))

(defun remoto--api (forge endpoint)
  "Call ENDPOINT of the REST API of FORGE via ghub, return parsed JSON.
ENDPOINT should not have a leading slash - one is prepended
automatically.  Auth resolution order: the token of the host's login,
the forge's token option, `remoto--find-token', ghub's own lookup.
When every avenue fails, signals `user-error'.  Public repositories work
without any setup via unauthenticated fallback."
  (let* ((resource (concat "/" endpoint))
         (login (remoto--forge-login forge))
         (auth (remoto--auth forge)))
    (if (eq auth 'none)
        (remoto--anonymous-get forge endpoint)
      (condition-case err
          ;; The timeout guards ghub's own token lookup, which a nil AUTH
          ;; leaves to it.  With the token in hand no lookup is left, and
          ;; a slow answer is no lookup that hangs.
          (if (or (stringp auth) (remoto--login-user login))
              (remoto--ghub-get forge resource auth endpoint)
            (let ((result (with-timeout (remoto-auth-timeout 'remoto--timed-out)
                            (remoto--ghub-get forge resource auth endpoint))))
              (when (eq result 'remoto--timed-out)
                (message "Remoto: auth lookup timed out; retrying next call (see `remoto-auth-timeout')")
                (setq result (remoto--anonymous-get forge endpoint)))
              result))
        (user-error
         (cond
          ;; The forge refused the token: go on without it, as the GitHub
          ;; warm-up does, until `remoto-reset-auth'.
          ((string-prefix-p remoto--auth-rejected (cadr err))
           (setf (remoto--login-failed login) t)
           (message "Remoto: %s rejected the token; reading it anonymously \
until M-x remoto-reset-auth" (remoto--api-host forge))
           (remoto--anonymous-get forge endpoint))
          ;; Any other answer of the API (404, 403, ...) is no auth failure.
          ((string-prefix-p "Remoto:" (cadr err))
           (signal (car err) (cdr err)))
          ;; ghub auth config error.  Every avenue exhausted - fail loudly.
          (t
           (setf (remoto--login-failed login) t)
           (user-error "Remoto: authentication failed for %s; \
configure a token for %s in auth-source, then M-x remoto-reset-auth"
                       endpoint (remoto--api-host forge)))))
        (error
         ;; ghub could not resolve auth at all.  Fail loudly so the
         ;; user knows auth is the problem, not a missing repo.
         (setf (remoto--login-failed login) t)
         (user-error "Remoto: authentication failed for %s (%s); \
configure a token for %s in auth-source, then M-x remoto-reset-auth"
                     endpoint (error-message-string err)
                     (remoto--api-host forge)))))))

(cl-defgeneric remoto--page-params (_forge count &optional page)
  "Return the query that asks FORGE for COUNT items, those of PAGE.
In GitHub's spelling by default."
  (concat (format "per_page=%d" count)
          (and page (format "&page=%d" page))))

(cl-defgeneric remoto--page-size (_forge)
  "Return the most items FORGE lists per page."
  100)

(defun remoto--paginated-api (forge endpoint &optional max-pages)
  "Fetch all pages of the paginated ENDPOINT of FORGE via `remoto--api'.
Request `remoto--page-size' items per page, following pages until a
short page is returned or MAX-PAGES (default 10) is reached.  The cap
bounds latency and request count on very large repositories."
  (let ((query-endpoint (concat endpoint (if (cl-search "?" endpoint) "&" "?")))
        (per-page (remoto--page-size forge)))
    (cl-loop for page from 1 to (or max-pages 10)
             for page-data = (remoto--api
                              forge
                              (concat query-endpoint
                                      (remoto--page-params forge per-page page)))
             append page-data
             until (< (length page-data) per-page))))

(defun remoto-reset-auth (&optional host)
  "Forget the login state of every API host, retrying the token lookup next.
With HOST, one of them, interactively with a prefix argument; an empty
HOST is every host.  Use after adding a token to auth-source."
  (interactive
   (list (and current-prefix-arg
              (completing-read "Remoto: reset the login of host (empty for all): "
                               (hash-table-keys remoto--logins) nil t))))
  (when (equal host "")
    (setq host nil))
  (if host
      (remhash host remoto--logins)
    (clrhash remoto--logins))
  (message "Remoto: login state cleared for %s; retrying the token lookup \
on the next request" (or host "every host")))

(defconst remoto--dir-entry
  '((type . "tree") (size . 0) (sha . "") (mode . "040000"))
  "Alist for synthesized directory entries (root, intermediates, `.', `..').")

;;;; Tree cache

(defvar remoto--tree-cache (make-hash-table :test 'equal)
  "Cache: `remoto--repo-key' -> hash table of path -> entry plist.")

(defvar remoto--default-branch-cache (make-hash-table :test 'equal)
  "Cache: `remoto--repo-id' -> default branch name.")

(cl-defstruct (remoto--listing (:constructor remoto--listing-create)
                               (:copier nil))
  "The entries of a Dired listing above the repository level.
ENTRIES is a list of (NAME . ATTRIBUTES) in the order the API sent them.
STATE is nil once complete, `fetching' while later pages load, `capped'
when `remoto-listing-cap' cut it short, and `failed' when a page failed."
  (time (float-time))
  entries
  state)

(defvar remoto--listing-cache (make-hash-table :test 'equal)
  "Cache: listing directory -> `remoto--listing'.
The directories are /github:, which lists the accounts of the token, and
/github:OWNER/, which lists OWNER's repositories.")

(defvar remoto--entry-cache (make-hash-table :test 'equal)
  "Cache: remoto name, downcased -> the attributes of its Dired line.
The names are /github:ACCOUNT, /github:OWNER/REPO and /github:OWNER/REPO@REF;
listing pages and searches fill it, so a name that a search found gets a
line and opens though no cached listing holds it.")


(defun remoto--resolve-ref (parsed)
  "Ensure PARSED `remoto-path' has a concrete ref, resolving if needed.
Returns a new `remoto-path' with ref filled in."
  (if (remoto-path-ref parsed)
      parsed
    (let* ((forge (remoto-path-forge parsed))
           (owner (remoto-path-owner parsed))
           (repo (remoto-path-repo parsed))
           (repo-id (remoto--repo-id forge owner repo))
           (branch (or (gethash repo-id remoto--default-branch-cache)
                       (let ((b (remoto-forge-default-ref forge owner repo)))
                         (puthash repo-id b remoto--default-branch-cache)
                         b))))
      (remoto-path-create
       :forge forge :owner owner :repo repo :ref branch
       :path (remoto-path-path parsed)))))

(defun remoto--repo-empty-p (forge owner repo ref failure)
  "Non-nil if OWNER/REPO on FORGE has no commit; FAILURE is how REF's tree failed.
GitHub says so in its 409.  Forgejo answers 404 and marks the repository,
which is asked only when REF is the default branch, the one ref an empty
repository names."
  (or (string-match-p "Git Repository is empty" failure)
      (and (string-prefix-p remoto--not-found failure)
           (equal ref (gethash (remoto--repo-id forge owner repo)
                               remoto--default-branch-cache))
           (eq t (alist-get 'empty (ignore-errors
                                     (remoto--api forge (format "repos/%s/%s" owner repo))))))))

(defun remoto--forge-tree (forge owner repo ref)
  "Return the tree of OWNER/REPO at REF on FORGE, an empty one without a commit."
  (condition-case err
      (remoto-forge-tree forge owner repo ref)
    (user-error
     (if (not (remoto--repo-empty-p forge owner repo ref (error-message-string err)))
         (signal (car err) (cdr err))
       (message "Remoto: %s/%s is empty" owner repo)
       (let ((table (make-hash-table :test 'equal)))
         (puthash "" remoto--dir-entry table)
         (puthash "/" remoto--dir-entry table)
         table)))))

(defun remoto--ensure-tree (parsed)
  "Ensure tree is cached for PARSED path, return the tree hash table."
  (let* ((resolved (remoto--resolve-ref parsed))
         (key (remoto--repo-key resolved)))
    (or (gethash key remoto--tree-cache)
        (let* ((tree (remoto--forge-tree
                      (remoto-path-forge resolved)
                      (remoto-path-owner resolved)
                      (remoto-path-repo resolved)
                      (remoto-path-ref resolved))))
          (puthash key tree remoto--tree-cache)
          tree))))

(defun remoto--fetch-directory-contents (parsed dir-key tree)
  "Fetch the entries under DIR-KEY of PARSED's repository, merge them into TREE.
On-demand fallback for repos whose recursive tree was truncated."
  (let* ((resolved (remoto--resolve-ref parsed))
         (entries (condition-case nil
                      (remoto-forge-directory-contents
                       (remoto-path-forge resolved)
                       (remoto-path-owner resolved)
                       (remoto-path-repo resolved)
                       (remoto-path-ref resolved)
                       dir-key)
                    (user-error nil))))
    (puthash (concat "\0fetched:" dir-key) t tree)
    (dolist (entry entries)
      ;; Keep existing entries from the tree (they have richer mode info)
      (unless (gethash (car entry) tree)
        (puthash (car entry) (cdr entry) tree)))))

(defun remoto--tree-lookup-key (path)
  "Normalize PATH for tree hash-table lookup.
Strips leading/trailing slashes and collapses runs of slashes."
  (let ((p (replace-regexp-in-string "/+" "/" path)))
    (when (string-prefix-p "/" p)
      (setq p (substring p 1)))
    (when (and (not (string-empty-p p))
               (string-suffix-p "/" p))
      (setq p (substring p 0 (1- (length p)))))
    p))

(defun remoto--tree-entry (parsed)
  "Look up the tree entry for PARSED path.  Return plist or nil.
For truncated trees, fetches the parent directory on demand."
  (let* ((tree (remoto--ensure-tree parsed))
         (key (remoto--tree-lookup-key (remoto-path-path parsed))))
    (or (gethash key tree)
        (when (and (gethash "\0truncated" tree)
                   (not (string-empty-p key)))
          (let ((parent (if (string-search "/" key)
                            (remoto--tree-lookup-key
                             (file-name-directory (directory-file-name key)))
                          "")))
            (unless (gethash (concat "\0fetched:" parent) tree)
              (remoto--fetch-directory-contents parsed parent tree))
            (gethash key tree))))))

(defun remoto--tree-children (parsed)
  "List direct children of directory at PARSED path.
Returns list of (NAME . PLIST) for each child.
For truncated trees, fetches the directory on demand."
  (let* ((tree (remoto--ensure-tree parsed))
         (dir-path (remoto--tree-lookup-key (remoto-path-path parsed)))
         (_ (when (and (gethash "\0truncated" tree)
                       (not (gethash (concat "\0fetched:" dir-path) tree)))
              (remoto--fetch-directory-contents parsed dir-path tree)))
         (prefix (if (string-empty-p dir-path) "" (concat dir-path "/")))
         (prefix-len (length prefix)))
    (thread-last (hash-table-keys tree)
      (seq-filter (lambda (path)
                    (and (not (string-prefix-p "\0" path))
                         (string-prefix-p prefix path)
                         (not (equal path dir-path))
                         ;; Direct child: no more slashes after prefix
                         (not (string-search "/" (substring path prefix-len))))))
      (mapcar (lambda (path)
                (cons (substring path prefix-len)
                      (gethash path tree))))
      (seq-remove (lambda (child) (string-empty-p (car child))))
      (seq-sort (lambda (a b) (string< (car a) (car b)))))))

;;;; Path normalization helpers

(defun remoto--normalize-path (path)
  "Clean up PATH component: collapse double slashes, resolve . and .."
  (let* ((parts (split-string path "/" t))
         (result nil))
    (dolist (p parts)
      (cond
       ((equal p "."))
       ((equal p "..")
        (when result (pop result)))
       (t (push p result))))
    (let ((normalized (concat "/" (mapconcat #'identity (nreverse result) "/"))))
      ;; Preserve trailing slash for directories
      (if (and (string-suffix-p "/" path)
               (not (string-suffix-p "/" normalized)))
          (concat normalized "/")
        normalized))))

(defun remoto--dot-component-p (name)
  "Return non-nil when the remoto NAME has a . or .. component."
  (string-match-p (rx (or bos "/") (** 1 2 ".") (or "/" eos))
                  (remoto--after-prefix name)))

(defun remoto--normalize-name (name)
  "Resolve the . and .. components of the remoto NAME, collapse its slashes.
The levels above a repository are directories too: .. at a repository
root names its owner, and .. at an owner names the prefix.  A canonical
root keeps the slash after its colon; any other trailing slash stays."
  (let ((prefix (remoto--prefix (remoto--canonical-forge name)))
        (parts nil)
        (dir (string-suffix-p "/" name)))
    (dolist (part (remoto--name-components name))
      (pcase part
        ("." nil)
        (".." (pop parts))
        (_ (push part parts))))
    (pcase-let ((`(,owner ,repo . ,path) (nreverse parts)))
      (cond
       ((null owner) prefix)
       ((null repo) (concat prefix owner "/"))
       ((string-suffix-p ":" repo)
        (concat prefix owner "/" repo "/" (string-join path "/")
                (and path dir "/")))
       (t (concat prefix owner "/" repo
                  (and path (concat "/" (string-join path "/")))
                  (and dir "/")))))))

(defun remoto--name-components (name)
  "Split the remoto NAME after its prefix into its slash-separated parts.
A canonical repository with its ref and colon is one part, since a ref
may hold slashes of its own."
  (if-let* ((parsed (remoto--parse-path name)))
      (cons (remoto-path-owner parsed)
            (cons (substring (remoto--tree-prefix parsed)
                             (+ (length (remoto--path-prefix parsed))
                                (length (remoto-path-owner parsed))
                                1))
                  (split-string (remoto-path-path parsed) "/" t)))
    (split-string (remoto--after-prefix name) "/" t)))

(defun remoto--file-name-prefix (filename)
  "Extract the /PREFIX:owner/repo@ref: prefix from FILENAME."
  (when-let* ((parsed (remoto--parse-path filename)))
    (remoto--tree-prefix parsed)))

;;;; File-name handler

(defun remoto--normalize-shorthand (arg)
  "Rewrite a leading shorthand prefix in ARG, such as /gh:, to its forge's.
A non-string ARG, or a string lacking a shorthand prefix, is returned
unchanged so downstream handlers only ever see canonical paths."
  (if-let* (((stringp arg))
            (entry (remoto--prefix-of arg))
            (forge (cdr entry))
            ((not (equal (car entry) (car (remoto-forge-prefixes forge))))))
      (concat (remoto--prefix forge)
              (substring arg (+ 2 (length (car entry)))))
    arg))

(defun remoto-file-name-handler (operation &rest args)
  "Handle file OPERATION for remoto paths.
Dispatches to `remoto--handle-OPERATION' or falls through to defaults.
The /gh: shorthand in ARGS is normalized to /github: first, so every
resolved handler receives only canonical paths."
  ;; File primitives leave the match data alone for local names, and the
  ;; handlers below call `string-match', so the caller's match data is kept.
  (save-match-data
    (let ((args (mapcar #'remoto--normalize-shorthand args)))
      (if-let* ((handler (intern-soft (format "remoto--handle-%s" operation)))
                ((fboundp handler)))
          (apply handler args)
        ;; Fall through to default handler
        (let ((inhibit-file-name-handlers
               (cons #'remoto-file-name-handler
                     (and (eq inhibit-file-name-operation operation)
                          inhibit-file-name-handlers)))
              (inhibit-file-name-operation operation))
          (apply operation args))))))

;;;; Read operations

(defun remoto--handle-file-exists-p (filename)
  "Return t if FILENAME exists or is openable.
Returns nil for mid-completion paths (no selection made yet),
triggering variable `confirm-nonexistent-file-or-buffer' on RET.
A bare account or repository name exists once a cached listing holds it."
  (when-let* ((parsed (remoto--parse filename))
              (query (remoto-path-query parsed)))
    (pcase (remoto-path-level parsed)
      ;; /github: and /github:OWNER/ exist for navigation.  A bare name is a
      ;; line of their listing; a delimiter after no repository names nothing.
      ((or 'root 'owner)
       (cond ((member query '("" "/")) t)
             ((not (remoto--bare-name parsed)) nil)
             (t (and (remoto--listed-p filename) t))))
      ;; /github:OWNER/REPO@REF is a line of a Dired of matching refs; the
      ;; delimiter alone is still being typed.
      ('refs (and (not (string-empty-p query))
                  (remoto--entry-for filename) t))
      ;; /github:OWNER/REPO#NUM opens on its shape alone.
      ('topics (and (string-match-p (rx bos (+ digit) eos) query) t))
      ;; A short form is openable as Dired on the default branch.  So is the
      ;; repository root at a ref: answering it from the tree would cost one
      ;; recursive tree per ref, because completion asks this of every
      ;; candidate it offers at the @ level.
      ('tree
       (cond ((remoto-path-short parsed) t)
             ((string-empty-p (remoto--tree-lookup-key (remoto-path-path parsed))) t)
             (t (and (remoto--tree-entry parsed) t)))))))

(defun remoto--handle-access-file (filename string)
  "Return nil when FILENAME can be read, else signal `file-missing'.
STRING names the caller's purpose, as `access-file' documents.  Without
this the operation falls through to the local primitive, which sees no
such file and always signals, and `recentf' then drops every remoto
path."
  (unless (remoto--handle-file-exists-p filename)
    (signal 'file-missing
            (list string "No such file or directory" filename))))

(defun remoto--handle-file-directory-p (filename)
  "Return t if FILENAME is a directory in the remote repo.
Also returns t for partial paths like /github: and /github:OWNER/."
  (when-let* ((parsed (remoto--parse filename))
              (query (remoto-path-query parsed)))
    (pcase (remoto-path-level parsed)
      ;; The levels above a repository and every name in them are directories
      ;; by shape; a delimiter after no repository is a line of nothing.
      ((or 'root 'owner)
       (cond ((member query '("" "/")) t)
             ((remoto--bare-name parsed) t)
             (t (and (remoto--entry-for filename) t))))
      ;; /github:OWNER/REPO@ is the Dired of refs; a ref in it is a line of
      ;; a Dired of matching refs.
      ('refs (or (string-empty-p query)
                 (and (remoto--entry-for filename) t)))
      ('topics nil)
      ('tree
       (if (remoto-path-short parsed)
           t
         (when-let* ((entry (remoto--tree-entry parsed)))
           (equal "tree" (alist-get 'type entry))))))))

(defun remoto--handle-file-accessible-directory-p (filename)
  "Return t if FILENAME is an accessible directory.
Delegates to `file-directory-p' - remote dirs are always readable."
  (remoto--handle-file-directory-p filename))

(defun remoto--handle-file-regular-p (filename)
  "Return t if FILENAME is a regular file in the remote repo."
  (when-let* ((parsed (remoto--parse-path filename))
              (entry (remoto--tree-entry parsed)))
    (equal "blob" (alist-get 'type entry))))

(defun remoto--handle-file-readable-p (filename)
  "Return non-nil if remote FILENAME is readable.
A directory reads though `file-exists-p' denies /github:OWNER and
/github:OWNER/REPO@ for the [Confirm] of a half-typed name: Dired asks
this of them before it lists the names that match there."
  (or (remoto--handle-file-exists-p filename)
      (remoto--handle-file-directory-p filename)))

(defun remoto--handle-file-writable-p (_filename)
  "Remote repos are never writable."
  nil)

(defun remoto--handle-file-attributes (filename &optional _id-format)
  "Return file attributes for FILENAME.
Synthesized from tree cache - timestamps are epoch 0."
  (when-let* ((parsed (remoto--parse-path filename))
              (entry (remoto--tree-entry parsed)))
    (let* ((dir? (equal "tree" (alist-get 'type entry)))
           (size (or (alist-get 'size entry) 0))
           (mode-str (or (alist-get 'mode entry) "100644"))
           (mode (string-to-number mode-str 8))
           ;; Use epoch 0 for all timestamps
           (time '(0 0 0 0)))
      ;; Return vector matching `file-attributes' format:
      ;; (type links uid gid atime mtime ctime size mode
      ;;  gid-change inode device)
      (list (if dir? t nil)      ; type: t=dir, nil=file
            1                    ; links
            0                    ; uid
            0                    ; gid
            time                 ; atime
            time                 ; mtime
            time                 ; ctime
            size                 ; size
            (format "%05o" mode) ; mode string
            nil                  ; gid-change
            0                    ; inode
            0))))               ; device

(defun remoto--handle-directory-files (directory &optional full match nosort count)
  "List files in remote DIRECTORY.
FULL, MATCH, NOSORT, COUNT as per `directory-files'."
  (when-let* ((parsed (remoto--parse-path directory)))
    (let ((names (append '("." "..")
                         (mapcar #'car (remoto--tree-children parsed)))))
      (when match
        (setq names (seq-filter (lambda (name)
                                  (string-match-p match name))
                                names)))
      (unless nosort
        (setq names (sort names #'string<)))
      (when count
        (setq names (seq-take names count)))
      (if full
          (let ((prefix (remoto--file-name-prefix directory))
                (dir-path (remoto-path-path parsed)))
            (mapcar (lambda (name)
                      (concat prefix
                              (remoto--normalize-path
                               (concat dir-path "/" name))))
                    names))
        names))))

(defun remoto--handle-directory-files-and-attributes
    (directory &optional full match nosort id-format)
  "Like `directory-files-and-attributes' for remote DIRECTORY.
Pass FULL, MATCH, NOSORT, and ID-FORMAT through unchanged."
  (let* ((parsed (remoto--parse-path directory))
         (prefix (remoto--file-name-prefix directory))
         (base-path (lambda (f)
                      (concat prefix
                              (remoto--normalize-path
                               (concat (remoto-path-path parsed) "/" f))))))
    (thread-last
      (remoto--handle-directory-files directory full match nosort)
      (mapcar (lambda (f)
                (cons f (remoto--handle-file-attributes
                         (if full f (funcall base-path f))
                         id-format)))))))

(defvar remoto-min-search-chars) ; forward-decl for byte-compiler

(defun remoto--owner-candidate (owner prefix)
  "Return a root completion candidate for account OWNER under PREFIX.
Preserves OWNER's text properties (used for affixation) and attaches a
`remoto-target' of the canonical owner path so Embark can act on it."
  (propertize (concat owner "/")
              'remoto-target (concat prefix (substring-no-properties owner))))

(defun remoto--minibuffer-input ()
  "Contents of the current buffer when it is an active completion minibuffer."
  (when (and (minibufferp) minibuffer-completion-table)
    (minibuffer-contents-no-properties)))

(defun remoto--input-query (input directory)
  "Return the text of INPUT after DIRECTORY, or nil when INPUT is elsewhere.
Normalize INPUT with `substitute-in-file-name' first, the way
`read-file-name' does, so a shadowed prefix such as \"~/x//github:o/\"
and the /gh: shorthand both resolve to DIRECTORY.  Return nil as well when
the text after DIRECTORY carries a level delimiter: `partial-completion'
probes parent levels with an empty FILE while the input sits deeper,
and that probe must not turn the deeper path into a search query."
  (when-let* ((effective (condition-case nil
                             (substitute-in-file-name input)
                           (error input)))
              ((string-prefix-p directory effective))
              (rest (substring effective (length directory)))
              ((not (string-match-p (rx (in "/@#:")) rest))))
    rest))

(defun remoto--minibuffer-query (directory)
  "What the user typed after DIRECTORY in the active minibuffer, or nil.
Completion styles that express the typed text as `completion-regexp-list'
\(orderless) hand the table only the text up to the completion boundary,
so FILE in `file-name-all-completions' arrives empty; the search levels
need the typed text as their API query."
  (when-let* ((input (remoto--minibuffer-input)))
    (remoto--input-query input directory)))

(defun remoto--completion-query (file directory)
  "Search query for FILE in DIRECTORY: FILE, or the minibuffer text if empty."
  (if (string-empty-p file)
      (or (remoto--minibuffer-query directory) file)
    file))

(defun remoto--candidate-match-text (candidate)
  "Text that `completion-regexp-list' is matched against for CANDIDATE.
The bare number of an issue and the bare name of a repo or account are
rarely what the user types, so the title or description joins the
name.  The trailing / or : delimiter stays out, as the built-in file
name primitives match names without it."
  (let ((name (string-trim-right candidate "[/:]"))
        (extra (or (remoto--get-prop candidate 'remoto-topic-title)
                   (remoto--get-prop candidate 'remoto-repo-desc)
                   (remoto--get-prop candidate 'remoto-acct-desc))))
    (if (and (stringp extra) (not (string-empty-p extra)))
        (concat name " " extra)
      name)))

(defun remoto--filter-by-completion-regexps (candidates)
  "Drop the CANDIDATES that `completion-regexp-list' rejects.
Completion styles rely on the table applying `completion-regexp-list'
itself: the built-in `file-name-all-completions' and TRAMP both do, and
orderless never filters on its own.  Case folding follows
`completion-ignore-case', as in the built-in primitives."
  (if (null completion-regexp-list)
      candidates
    (let ((case-fold-search completion-ignore-case))
      (seq-filter (lambda (c)
                    (let ((text (remoto--candidate-match-text c)))
                      (seq-every-p (lambda (re) (string-match-p re text))
                                   completion-regexp-list)))
                  candidates))))

(defun remoto--handle-file-name-all-completions (file directory)
  "Return completions for FILE in remote DIRECTORY.
Applies `completion-regexp-list' like the built-in primitive does."
  (remoto--filter-by-completion-regexps
   (remoto--file-name-completions file directory)))

(defun remoto--file-name-completions (file directory)
  "Return unfiltered completions for FILE in remote DIRECTORY.
Handles multiple levels: user search at /github:, repo listing at
/github:OWNER/, branch/tag at /github:OWNER/REPO@, files at
/github:OWNER/REPO/, issues at /github:OWNER/REPO#, and file
listing within a repo.  Search-level calls (user, repo) are
non-blocking: cached results are returned immediately while async
fetches populate the cache in the background.
An empty FILE does not mean an empty query: see `remoto--minibuffer-query'."
  (let* ((parsed (remoto--parse directory))
         (level (and parsed (remoto-path-level parsed)))
         (forge (and parsed (remoto-path-forge parsed)))
         (prefix (and parsed (remoto--path-prefix parsed)))
         (owner (and parsed (remoto-path-owner parsed)))
         (repo (and parsed (remoto-path-repo parsed))))
    (when (and parsed
               (or (eq level 'tree)
                   (string-empty-p (remoto-path-query parsed))))
      (pcase level
        ('root
         ;; Empty query + authenticated: show user + orgs
         ;; Non-empty: search users/orgs matching the query (non-blocking)
         (let ((query (remoto--completion-query file directory))
               (candidate (lambda (acct) (remoto--owner-candidate acct prefix))))
           (if (string-empty-p query)
               (when-let* ((user (remoto--known-user forge)))
                 (let* ((orgs (remoto-forge-user-orgs forge user))
                        (all (cons (propertize user 'remoto-acct-type "User") orgs)))
                   (mapcar candidate all)))
             (when-let* ((result (remoto-forge-search-accounts forge query nil)))
               (let ((filtered (seq-filter (lambda (u) (string-prefix-p file u))
                                           result)))
                 ;; Pre-fetch repos for the top match so the cache is
                 ;; warm by the time the user types "/"
                 (when-let* ((top (car filtered)))
                   (remoto-forge-prefetch-repos forge top))
                 (mapcar candidate filtered))))))
        ('owner
         ;; Repo completion at /github:OWNER/
         ;; Try cached/async results first; on cold-cache nil, fall
         ;; back to a synchronous fetch that yields to user input.
         (let* ((query (remoto--completion-query file directory))
                (repos (if (string-empty-p query)
                           (remoto-forge-recent-repos forge owner nil)
                         (remoto-forge-search-repos forge owner query nil))))
           (unless repos
             (let ((sync (while-no-input
                           (condition-case nil
                               (if (string-empty-p query)
                                   (remoto-forge-recent-repos forge owner t)
                                 (when (<= remoto-min-search-chars (length query))
                                   (remoto-forge-search-repos forge owner query t)))
                             (error nil)))))
               (when (consp sync)
                 (setq repos sync))))
           (mapcar (lambda (r)
                     (let* ((name (if (string-suffix-p "/" r) (substring r 0 -1) r))
                            (cand (concat name "/")))
                       ;; Carry the full canonical path so Embark actions can
                       ;; resolve a bare candidate (see `remoto--embark-transform').
                       (put-text-property 0 (length cand) 'remoto-target
                                          (format "%s%s/%s:/" prefix owner name)
                                          cand)
                       cand))
                   repos)))
        ('refs
         ;; Branch + tag completion at /github:OWNER/REPO@
         (if (string-suffix-p ":" file)
             ;; Ref already selected (e.g. "main:") - exact match
             (list file)
           (let* ((branches (while-no-input
                              (remoto-forge-branches forge owner repo)))
                  (tags (while-no-input
                          (remoto-forge-tags forge owner repo))))
             (when (or (listp branches) (listp tags))
               (let ((branch-set (when (listp branches)
                                   (mapcar (lambda (b)
                                             (propertize (concat b ":")
                                                         'remoto-ref-type "branch"
                                                         'remoto-target
                                                         (format "%s%s/%s@%s:/"
                                                                 prefix owner repo b)))
                                           branches)))
                     (tag-set (when (listp tags)
                                (mapcar (lambda (tg)
                                          (propertize (concat tg ":")
                                                      'remoto-ref-type "tag"
                                                      'remoto-target
                                                      (format "%s%s/%s@%s:/"
                                                              prefix owner repo tg)))
                                        tags))))
                 (thread-last (append branch-set tag-set)
                              (seq-filter (lambda (r)
                                            (or (string-empty-p file)
                                                (string-prefix-p file r))))))))))
        ((and 'tree (guard (remoto-path-short parsed)))
         ;; File completion on default branch: /github:OWNER/REPO/[subdir/]
         ;; Uses lightweight Contents API (single call) instead of
         ;; recursive tree fetch for fast initial display.
         (let* ((branch (condition-case nil
                            (while-no-input
                              (remoto-forge-default-ref forge owner repo))
                          (user-error nil))))
           (when (and (stringp branch) (not (equal branch t)))
             (let* ((subpath (substring (remoto-path-path parsed) 1))
                    (children (while-no-input
                                (remoto-forge-children
                                 forge owner repo branch subpath)))
                    (names (when (listp children)
                             (mapcar (lambda (child)
                                       (if (equal "tree" (alist-get 'type (cdr child)))
                                           (concat (car child) "/")
                                         (car child)))
                                     children)))
                    (filtered (when names
                                (if (string-empty-p file)
                                    names
                                  (seq-filter (lambda (name)
                                                (string-search file name))
                                              names)))))
               (when filtered
                 (mapcar (lambda (name)
                           (propertize name 'remoto-target
                                       (format "%s%s/%s@%s:/%s%s"
                                               prefix owner repo branch subpath name)))
                         filtered))))))
        ('topics
         ;; Issue/PR completion at /github:OWNER/REPO#
         (let* ((query (remoto--completion-query file directory))
                (issues
                 (cond
                  ;; Empty query: show top open issues
                  ((string-empty-p query)
                   (while-no-input
                     (remoto-forge-topics forge owner repo)))
                  ;; Numeric query: direct fetch + filter cached
                  ((string-match-p (rx bos (+ digit) eos) query)
                   (let* ((cached (while-no-input
                                    (remoto-forge-topics forge owner repo)))
                          (direct (while-no-input
                                    (remoto-forge-topic forge owner repo query)))
                          (results (if (listp cached) cached nil)))
                     (if (consp direct)
                         (cl-remove-duplicates
                          (cons direct results)
                          :key (lambda (i) (alist-get 'number i)))
                       results)))
                  ;; Text query: search
                  (t
                   (while-no-input
                     (remoto-forge-search-topics forge owner repo query))))))
           (when (listp issues)
             (let* ((candidates
                     (mapcar (lambda (i)
                               (let* ((num (number-to-string (alist-get 'number i)))
                                      (is-pr (and (alist-get 'pull_request i) t))
                                      (title (or (alist-get 'title i) ""))
                                      (state (or (alist-get 'state i) "")))
                                 (propertize num
                                             'remoto-topic-pr is-pr
                                             'remoto-topic-title title
                                             'remoto-topic-state state
                                             'remoto-target
                                             (format "%s%s/%s#%s"
                                                     prefix owner repo num))))
                             issues))
                    (filtered
                     (if (or (string-empty-p file)
                             (string-match-p (rx bos (+ digit) eos) file))
                         (seq-filter (lambda (n) (string-prefix-p file n)) candidates)
                       candidates)))
               ;; Sort: PRs first, then issues; within each group by number descending
               (sort filtered
                     (lambda (a b)
                       (let ((a-pr (get-text-property 0 'remoto-topic-pr a))
                             (b-pr (get-text-property 0 'remoto-topic-pr b)))
                         (cond
                          ((and a-pr (not b-pr)) t)
                          ((and (not a-pr) b-pr) nil)
                          (t (< (string-to-number b) (string-to-number a)))))))))))
        ('tree
         ;; Canonical path: entries of the tree at the ref
         (let* ((ref (remoto-path-ref parsed))
                (path (remoto-path-path parsed))
                ;; A directory's files join it with one slash: test/x, not test//x.
                (dir-path (string-trim path "/+" "/+"))
                (children (remoto--tree-children parsed))
                (names (thread-last children
                                    (mapcar (lambda (child)
                                              (if (equal "tree" (alist-get 'type (cdr child)))
                                                  (concat (car child) "/")
                                                (car child))))
                                    (seq-filter (lambda (name)
                                                  (string-prefix-p file name)))))
                (commits (when ref
                           (remoto-forge-file-commits
                            forge owner repo ref dir-path names))))
           (mapcar (lambda (name)
                     (let ((cand (copy-sequence name))
                           (msg (alist-get name commits nil nil #'equal)))
                       (when msg
                         (put-text-property 0 (length cand) 'remoto-file-commit msg cand))
                       (put-text-property 0 (length cand) 'remoto-target
                                          (concat directory name) cand)
                       cand))
                   names)))))))

(defun remoto--handle-file-name-completion (file directory &optional predicate)
  "Complete FILE in remote DIRECTORY using optional PREDICATE.
Handles partial /github: paths for pre-repo completion.
PREDICATE may be a function, nil, or a string directory-prefix
passed through by `completion-file-name-table' - strings are
ignored since remoto paths always qualify."
  (let ((completions (remoto--handle-file-name-all-completions file directory))
        ;; completion-file-name-table passes the read-file-name
        ;; directory as a string predicate - not a callable filter
        (pred (if (stringp predicate) nil predicate)))
    (cond
     ((null completions) nil)
     ((null (cdr completions))
      (if (equal file (car completions)) t (car completions)))
     (t (try-completion file completions pred)))))

(defun remoto--handle-expand-file-name (name &optional dir)
  "Expand NAME relative to DIR for remoto paths."
  (let ((inhibit-file-name-handlers
         (cons #'remoto-file-name-handler
               (and (eq inhibit-file-name-operation 'expand-file-name)
                    inhibit-file-name-handlers)))
        (inhibit-file-name-operation 'expand-file-name))
    (cond
     ;; Absolute remoto path.  Primitives such as `file-exists-p' expand
     ;; their argument first, so this is where . and .. must resolve.
     ((remoto--canonical-forge name)
      (if (remoto--dot-component-p name)
          (remoto--normalize-name name)
        name))
     ;; Local absolute or home-relative path - never resolve under remoto
     ((or (string-prefix-p "/" name)
          (string-prefix-p "~" name))
      (expand-file-name name))
     ;; Relative path under a remoto directory
     ((and dir (remoto--canonical-forge dir))
      (if-let* ((parsed (remoto--parse-path dir))
                (prefix (remoto--file-name-prefix dir)))
          (remoto--normalize-name
           (concat prefix (remoto-path-path parsed) "/" name))
        ;; Partial path (e.g. /github:owner/ or /github:owner/repo@)
        (let ((joined (concat dir name)))
          (if (remoto--dot-component-p joined)
              (remoto--normalize-name joined)
            joined))))
     ;; Not our path, delegate
     (t (expand-file-name name dir)))))

(defun remoto--handle-file-truename (filename &optional _counter _prev-dirs)
  "Return FILENAME as-is - no symlink resolution for remote repos."
  filename)

(defun remoto--reached-p (filename)
  "Return non-nil when FILENAME's repository was already reached this session.
A cached default branch or tree is as close as remoto comes to an open
connection: it means GitHub answered for that repository without a new
request."
  (when-let* ((parsed (remoto--parse-path filename)))
    (or (gethash (remoto--repo-id (remoto-path-forge parsed)
                                  (remoto-path-owner parsed)
                                  (remoto-path-repo parsed))
                 remoto--default-branch-cache)
        (gethash (remoto--repo-key parsed) remoto--tree-cache))))

(defun remoto--evil-ex-argument-p (filename)
  "Return non-nil when FILENAME is the argument of the running Evil ex command."
  (when-let* (((if (boundp 'evil-called-from-ex-p)
                   evil-called-from-ex-p
                 ;; An Evil without that flag binds this around each command.
                 (bound-and-true-p evil-ex-point)))
              (argument (bound-and-true-p evil-ex-argument))
              ((stringp argument)))
    (equal filename (remoto--normalize-shorthand argument))))

(defun remoto--localname (filename prefix)
  "Return the `localname' of FILENAME, whose remote prefix is PREFIX.
That is PREFIX, since callers pass it to local programs and remoto runs
none, except for an Evil ex argument: Evil rebuilds that from both
answers and replaces a bare `#' or `%' in it, so both come back escaped."
  (if (remoto--evil-ex-argument-p filename)
      (replace-regexp-in-string
       (rx (? "\\") (in "#%"))
       (lambda (s) (if (string-prefix-p "\\" s) s (concat "\\" s)))
       (substring filename (length prefix)) t t)
    prefix))

(defun remoto--handle-file-remote-p (filename &optional identification connected)
  "Return remote identification for FILENAME.
Use IDENTIFICATION to select which remote field to report.
CONNECTED asks for an answer only while the repository is reachable
without a request, which is what keeps `recentf' and `auto-revert' from
making remoto fetch a tree just to classify a path.  The symbol `never'
means the opposite - answer, but never open a connection - so it reads
like a nil CONNECTED here, where no answer costs one.
Handles partial paths for pre-repo completion."
  (when-let* ((forge (remoto--canonical-forge filename))
              ((or (not connected)
                   (eq connected 'never)
                   (remoto--reached-p filename))))
    (if-let* ((parsed (remoto--parse-path filename))
              (prefix (remoto--file-name-prefix filename)))
        (pcase identification
          ('method (symbol-name (remoto-forge-name forge)))
          ('host (format "%s/%s" (remoto-path-owner parsed)
                         (remoto-path-repo parsed)))
          ('localname (remoto--localname filename prefix))
          (_ prefix))
      ;; Partial path - still remote
      (pcase identification
        ('method (symbol-name (remoto-forge-name forge)))
        ('host (remoto-forge-host forge))
        ('localname (remoto--localname filename (remoto--prefix forge)))
        (_ (remoto--prefix forge))))))

(defun remoto--handle-file-name-directory (filename)
  "Return directory part of remote FILENAME: the level it is in.
The result must be a prefix of FILENAME: `completion-file-name-table'
derives the completion boundary from its length, so a synthesized slash
after the colon would push the boundary past the text being completed
and make the UI append the candidate to it."
  (when-let* ((parsed (remoto--parse filename)))
    (remoto-path-directory parsed)))

(defun remoto--handle-file-name-nondirectory (filename)
  "Return non-directory part of remote FILENAME: the text after its level.
A directory name keeps nothing after its slash, or Dired lists it as a
wildcard and completion matches its own name."
  (if-let* ((parsed (remoto--parse filename)))
      (remoto-path-query parsed)
    (file-name-nondirectory filename)))

;;;; File contents

(defun remoto--relative-path (path)
  "Strip leading slash from PATH for API requests."
  (if (string-prefix-p "/" path) (substring path 1) path))

(defun remoto--topic-path (filename)
  "Return (REPO-PATH . NUMBER) when FILENAME names an issue or pull request.
The /github:OWNER/REPO#NUM shape belongs to `remoto-topic-display', not
to any file operation, so both the `find-file' advice and the handler
recognize it here."
  (when-let* ((parsed (remoto--parse filename))
              ((eq (remoto-path-level parsed) 'topics))
              (query (remoto-path-query parsed))
              ((string-match-p (rx bos (+ digit) eos) query)))
    (cons (format "%s%s/%s" (remoto--path-prefix parsed)
                  (remoto-path-owner parsed) (remoto-path-repo parsed))
          query)))

(defun remoto--handle-insert-file-contents
    (filename &optional visit beg end replace)
  "Insert contents of remote FILENAME into current buffer.
VISIT, BEG, END, REPLACE as per `insert-file-contents'."
  ;; Reached when the `find-file-noselect' advice did not run, which is
  ;; the case for the very first remoto call of a session.  Say what the
  ;; path is and take the buffer `find-file-noselect' made with it: that
  ;; function has no unwind of its own, so the error would leave an empty
  ;; buffer named after the number.  The emptiness test is what tells that
  ;; buffer apart from a caller's own.
  (when (remoto--topic-path filename)
    ;; An empty buffer with no file name, under VISIT, is the state
    ;; `find-file-noselect' leaves: that call reached the handler because it
    ;; started before `remoto--install' added the advice that turns a #NUM
    ;; path into a topic buffer, and the advice is in place by now, so
    ;; repeating the call works.  Any other caller asked for file contents
    ;; directly and needs the command that goes through the advice.
    (let ((from-find-file (and visit (zerop (buffer-size)) (not buffer-file-name))))
      (when from-find-file
        (set-buffer-modified-p nil)
        (kill-buffer (current-buffer)))
      (user-error
       "Remoto: %s is an issue or pull request, not a file - %s"
       filename
       (if from-find-file
           "remoto is loaded now, run the command again"
         "open it with `find-file'"))))
  (let ((parsed (remoto--parse-path filename)))
    (unless parsed
      (error "Remoto: cannot parse path: %s" filename))
    ;; `find-file-noselect' treats a `file-error' as a nonexistent file and
    ;; otherwise keeps the buffer it created; the tree is cached, so the
    ;; check costs no request.  Like the primitive and TRAMP, a visiting
    ;; call still records the file name so the new-file path can go on.
    (unless (remoto--tree-entry parsed)
      (when visit
        (setq buffer-file-name filename)
        (set-buffer-modified-p nil))
      (signal 'file-missing
              (list "Opening input file" "No such file or directory" filename)))
    (let* ((resolved (remoto--resolve-ref parsed))
           (path (remoto--relative-path (remoto-path-path resolved)))
           (bytes (remoto-forge-content
                   (remoto-path-forge resolved)
                   (remoto-path-owner resolved)
                   (remoto-path-repo resolved)
                   (remoto-path-ref resolved)
                   path)))
      (when replace (erase-buffer))
      (let ((pt (point))
            len)
        ;; Insert the bytes and decode them in place, so the file gets the
        ;; coding the primitive would pick from disk: cookies and
        ;; `auto-coding-alist' by name, then detection.  A binary such as
        ;; an image stays raw bytes under `no-conversion', which is how
        ;; `image-mode' recovers the data from a remote buffer.  The
        ;; primitive sets `buffer-file-coding-system' from the result once
        ;; this handler returns the decoded length.
        (save-restriction
          (narrow-to-region pt pt)
          (insert (if (or beg end) (substring bytes (or beg 0) end) bytes))
          (decode-coding-inserted-region (point-min) (point-max) filename
                                         visit beg end replace)
          (setq len (- (point-max) (point-min))))
        (goto-char pt)
        (when visit
          (setq buffer-file-name filename)
          (setq buffer-read-only t)
          (set-buffer-modified-p nil)
          (set-visited-file-modtime 0))
        (list filename len)))))

;;;; Dired integration

(defun remoto--mode-to-string (mode-str dir?)
  "Convert git MODE-STR to an ls-style permission string for DIR?."
  (cond
   (dir?                "drwxr-xr-x")
   ((equal mode-str "100755") "-rwxr-xr-x")
   ((equal mode-str "120000") "lrwxrwxrwx")
   (t                   "-rw-r--r--")))

(defun remoto--ls-switch-p (switches short &optional long)
  "Return non-nil when ls options ask for SHORT, or for LONG spelled out.
SWITCHES holds the options as a string, the way Dired passes them.
Like Dired, look for SHORT in a group of short options."
  (and (stringp switches)
       (let ((case-fold-search nil))
         (string-match-p
          (rx-to-string `(seq (or bos " ")
                              (or (seq "-" (* alnum) ,short)
                                  ,@(and long `((seq "--" ,long eow))))))
          switches))))

(defun remoto--classify-p (switches)
  "Return non-nil when ls options ask for -F file type indicators.
SWITCHES holds the options as a string, the way Dired passes them."
  (remoto--ls-switch-p switches "F" "classify"))

(defun remoto--ls-indicator (plist classify)
  "Return the ls -F type indicator for an entry with PLIST, if CLASSIFY."
  (let ((mode (alist-get 'mode plist)))
    (cond ((not classify) "")
          ((equal "tree" (alist-get 'type plist)) "/")
          ((equal mode "120000") "@")
          ((equal mode "100755") "*")
          (t ""))))

(defun remoto--ls-time (time)
  "Format TIME as ls -l does, or the fixed date of tree entries when nil.
Within the last six months it shows the hour, before that the year.
English month names, as in the fixed date, keep the columns aligned."
  (let ((system-time-locale "C"))
    (cond ((null time) "Jan  1  2000")
          ((< (float-time (time-subtract nil time)) (* 182 24 60 60))
           (format-time-string "%b %e %H:%M" time))
          (t (format-time-string "%b %e  %Y" time)))))

(defun remoto--one-line (text)
  "Return TEXT with each line break, and the blanks around it, as one space.
A forge's description may span lines; a Dired line or an annotation cannot."
  (if (string-match-p "[\n\r\f\v]" text)
      (mapconcat #'identity (split-string text "[\n\r\f\v]+" t "[ \t]+") " ")
    text))

(defun remoto--format-dired-entry (name plist &optional classify widths)
  "Format a single Dired line for NAME with PLIST attributes.
CLASSIFY appends the ls -F type indicator.  WIDTHS, the size and name
column widths, line up a listing; a note in PLIST starts 4 columns past
the names, where `dired-hide-details-mode' hides it with symlink targets."
  (let* ((dir? (equal "tree" (alist-get 'type plist)))
         (indicator (remoto--ls-indicator plist classify))
         (note (and (alist-get 'note plist) (remoto--one-line (alist-get 'note plist)))))
    (concat (or (alist-get 'perms plist)
                (remoto--mode-to-string (alist-get 'mode plist) dir?))
            "  1 github github "
            (string-pad (number-to-string (or (alist-get 'size plist) 0))
                        (or (car widths) 8) nil t)
            " " (remoto--ls-time (alist-get 'time plist)) " "
            ;; Dired reads exactly the name by this property, whatever
            ;; the switches; a name with a note after it needs it as well.
            (propertize name 'dired-filename t)
            indicator
            (and note (not (string-empty-p note))
                 (concat (make-string (max 4 (- (+ 4 (or (cdr widths) 0))
                                                (string-width name)
                                                (length indicator)))
                                      ?\s)
                         note))
            "\n")))

(defun remoto--listing-widths (entries classify)
  "Return the size and name column widths that line up ENTRIES.
CLASSIFY counts the ls -F indicator into the name.  The name column
stops at 40, so that one long name moves only its own note."
  (cons (apply #'max 8 (mapcar (lambda (entry)
                                 (length (number-to-string
                                          (or (alist-get 'size (cdr entry)) 0))))
                               entries))
        (min 40 (apply #'max 0 (mapcar (lambda (entry)
                                         (+ (string-width (car entry))
                                            (length (remoto--ls-indicator
                                                     (cdr entry) classify))))
                                       entries)))))

(defun remoto--listing-note (listing)
  "Return the note on the . line of LISTING, or nil once it is complete.
Not the total line: Dired deletes that under the default `dired-free-space'."
  (let ((count (length (remoto--listing-entries listing))))
    (pcase (remoto--listing-state listing)
      ('fetching (format "%d so far, fetching the rest" count))
      ('capped (format "the %d most recently pushed, as `remoto-listing-cap' allows"
                       count))
      ('failed (format "%d, the rest failed to load; `remoto-refresh' retries"
                       count)))))

(defun remoto--sort-entries (entries switches)
  "Return listing ENTRIES in the order that ls would give them.
That is by name, or with -t in the ls options SWITCHES by the last push,
newest first."
  (let ((entries (sort (copy-sequence entries)
                       (lambda (a b) (string< (car a) (car b))))))
    (if (remoto--ls-switch-p switches "t")
        (sort entries
              (lambda (a b)
                (time-less-p (or (alist-get 'time (cdr b)) 0)
                             (or (alist-get 'time (cdr a)) 0))))
      entries)))

(defun remoto--insert-listing (dir switches)
  "Insert the Dired listing of DIR, accounts or repositories.
SWITCHES are the ls options, which decide the order."
  (let* ((listing (remoto--listing dir))
         (classify (remoto--classify-p switches))
         (lines (append (list (cons "." `((note . ,(remoto--listing-note listing))
                                          ,@remoto--dir-entry))
                              (cons ".." remoto--dir-entry))
                        (remoto--sort-entries (remoto--listing-entries listing)
                                              switches)))
         (widths (remoto--listing-widths lines classify)))
    (insert "total 0\n")
    (dolist (line lines)
      (insert (remoto--format-dired-entry (car line) (cdr line)
                                          classify widths)))))

(defvar-local remoto--entry-widths nil
  "(NAMES . WIDTHS) for the Dired of a list of names in this buffer.
Dired asks for each line on its own, and the widths need all the names;
the first name of each reading computes them again.")

(defun remoto--insert-entry-line (filename switches)
  "Insert the Dired line of FILENAME, an account, repository or ref.
SWITCHES are the ls options.  A Dired of a list of names asks for each
line on its own; the names in `dired-directory' line the notes up."
  (let* ((classify (remoto--classify-p switches))
         (dir (remoto--handle-file-name-directory filename))
         (name (remoto--handle-file-name-nondirectory filename))
         (listed (bound-and-true-p dired-directory))
         (names (if (and (consp listed)
                         (equal dir (car listed))
                         (member name (cdr listed)))
                    (cdr listed)
                  (list name))))
    (unless (and (eq names (car remoto--entry-widths))
                 (not (equal name (car names))))
      (setq remoto--entry-widths
            (cons names
                  (remoto--listing-widths
                   (mapcar (lambda (each)
                             (cons each (or (remoto--entry-for (concat dir each))
                                            remoto--dir-entry)))
                           names)
                   classify))))
    ;; Two columns of our own: Dired gives a list of names whose lines
    ;; bring none one column per line and then two more.
    (insert "  " (remoto--format-dired-entry
                  name (or (remoto--entry-for filename) remoto--dir-entry)
                  classify (cdr remoto--entry-widths)))))

(defun remoto--handle-insert-directory
    (filename switches &optional _wildcard full-directory-p)
  "Insert a Dired-format listing for remote FILENAME.
SWITCHES may ask for -F indicators; FULL-DIRECTORY-P asks for a listing
and without it FILENAME gets its one line, as with ls-lisp.  /github: and
/github:OWNER/ list accounts and repositories."
  ;; A Dired of a list of names passes each one relative to its directory,
  ;; and the first Dired of a session passes a short form as typed.
  (let* ((filename (expand-file-name filename))
         (entry (and (not full-directory-p) (remoto--entry-name-p filename)))
         (filename (if entry filename (remoto--maybe-rewrite filename)))
         (dir (and (not entry) (remoto--listing-dir filename)))
         (classify (remoto--classify-p switches)))
    (cond
     (entry (remoto--insert-entry-line filename switches))
     (dir (when (or full-directory-p
                    (equal filename dir)
                    (string-suffix-p "/" filename))
            (remoto--insert-listing dir switches)))
     (t
      (when-let* ((parsed (remoto--parse-path filename))
                  (entry (remoto--tree-entry parsed)))
        (if full-directory-p
            (progn
              (insert "total 0\n")
              (insert (remoto--format-dired-entry "." remoto--dir-entry classify))
              (insert (remoto--format-dired-entry ".." remoto--dir-entry classify))
              (dolist (child (remoto--tree-children parsed))
                (insert (remoto--format-dired-entry
                         (car child) (cdr child) classify))))
          (insert "  " (remoto--format-dired-entry
                        (file-name-nondirectory
                         (directory-file-name (remoto-path-path parsed)))
                        entry classify))))))))

(defun remoto--handle-file-local-copy (filename)
  "Download remote FILENAME to a temp file, return temp path."
  (when-let* ((parsed (remoto--parse-path filename))
              (resolved (remoto--resolve-ref parsed))
              (path (remoto--relative-path (remoto-path-path resolved)))
              (content (remoto-forge-content
                        (remoto-path-forge resolved)
                        (remoto-path-owner resolved)
                        (remoto-path-repo resolved)
                        (remoto-path-ref resolved)
                        path)))
    (let* ((ext (file-name-extension path t))
           (temp (make-temp-file "remoto-" nil ext))
           (coding-system-for-write 'no-conversion))
      (write-region content nil temp nil 0)
      temp)))

(defun remoto--handle-make-nearby-temp-file (prefix &optional dir-flag suffix)
  "Create a temp file using PREFIX in the system temp dir.
Pass DIR-FLAG and SUFFIX through to `make-temp-file'."
  (make-temp-file prefix dir-flag suffix))

;;;; Additional operations needed by dired and other Emacs internals

(defun remoto--handle-file-name-as-directory (filename)
  "Append / to FILENAME if not already present.
/github: and /github:OWNER/REPO@ are directory names as they are: with a
slash after them, every name their Dired holds would read /github:/OWNER
or /github:OWNER/REPO@/REF."
  (let ((parsed (remoto--parse filename)))
    (if (or (string-suffix-p "/" filename)
            (and parsed
                 (string-empty-p (remoto-path-query parsed))
                 (let ((level (remoto-path-level parsed)))
                   (or (eq level 'root)
                       (eq (remoto--level-kind level) 'ref)))))
        filename
      (concat filename "/"))))

(defun remoto--handle-directory-file-name (directory)
  "Strip trailing / from DIRECTORY."
  (if (and (string-suffix-p "/" directory)
           ;; Don't strip the / after the colon in /github:o/r@ref:/
           (not (string-suffix-p ":/" directory)))
      (substring directory 0 (1- (length directory)))
    directory))

(defun remoto--handle-file-name-case-insensitive-p (_filename)
  "GitHub repos are case-sensitive."
  nil)

(defun remoto--handle-vc-registered (_filename)
  "Remote files are not under local vc."
  nil)

(defun remoto--handle-make-directory (dir &optional _parents)
  "Ignore existing DIR and signal an error otherwise.
Any name below an owner is a directory by its shape, so it must exist
too, or Dired adds a line for the repository that `+' did not create."
  (unless (and (remoto--handle-file-directory-p dir)
               (remoto--handle-file-exists-p dir))
    (user-error "Remoto: repository is read-only")))

(defun remoto--handle-abbreviate-file-name (filename)
  "Return FILENAME as-is - no abbreviation for remote paths."
  filename)

(defun remoto--handle-unhandled-file-name-directory (_filename)
  "Return nil - no local equivalent for remote paths."
  nil)

;;;; Write operations (all read-only)

(defun remoto--read-only (&rest _args)
  "Signal that remote repos are read-only."
  (user-error "Remoto: repository is read-only"))

(defalias 'remoto--handle-write-region #'remoto--read-only)
(defalias 'remoto--handle-delete-file #'remoto--read-only)
(defalias 'remoto--handle-delete-directory #'remoto--read-only)
(defalias 'remoto--handle-rename-file #'remoto--read-only)
(defun remoto--handle-copy-file (file newname
                                      &optional ok-if-already-exists keep-time
                                      preserve-uid-gid preserve-permissions)
  "Copy FILE to NEWNAME.  Works when destination is outside remoto.
OK-IF-ALREADY-EXISTS, KEEP-TIME, PRESERVE-UID-GID, and
PRESERVE-PERMISSIONS are passed through to `copy-file'."
  (if (remoto--parse-path newname)
      (remoto--read-only 'copy-file file newname)
    (let ((local-copy (remoto--handle-file-local-copy file)))
      (unless local-copy
        (error "Remoto: failed to download %s" file))
      (unwind-protect
          (let ((inhibit-file-name-handlers
                 (cons #'remoto-file-name-handler
                       (and (eq inhibit-file-name-operation 'copy-file)
                            inhibit-file-name-handlers)))
                (inhibit-file-name-operation 'copy-file))
            (copy-file local-copy newname ok-if-already-exists keep-time
                       preserve-uid-gid preserve-permissions))
        (when (file-exists-p local-copy)
          (delete-file local-copy))))))
(defalias 'remoto--handle-set-file-modes #'remoto--read-only)
(defalias 'remoto--handle-set-file-times #'remoto--read-only)

;;;; Refresh

;;;###autoload
(defun remoto-refresh ()
  "Invalidate cached tree for the current repo, re-fetch on next access.
In a listing of /github: or /github:OWNER/, fetch that listing again.  In
a Dired of branches and tags, forget the repository's branches and tags."
  (interactive)
  (let* ((dir (or dired-directory default-directory))
         (dir (if (consp dir) (car dir) dir))
         (listing-dir (remoto--listing-dir dir))
         (parsed (remoto--parse-path dir)))
    (cond
     (listing-dir
      (remhash listing-dir remoto--listing-cache)
      (message "Remoto: cache cleared for %s" listing-dir)
      (when (derived-mode-p 'dired-mode)
        (revert-buffer)))
     (parsed
      (let* ((resolved (remoto--resolve-ref parsed))
             (key (remoto--repo-key resolved)))
        (remhash key remoto--tree-cache)
        (remoto-forge-forget-refs (remoto-path-forge resolved)
                                  (remoto-path-owner resolved)
                                  (remoto-path-repo resolved))
        (message "Remoto: cache cleared for %s" key)
        (when (derived-mode-p 'dired-mode)
          (revert-buffer))))
     ((remoto--refs-dir-p dir)
      (let* ((refs (remoto--parse dir))
             (repo-id (format "%s/%s" (remoto-path-owner refs)
                              (remoto-path-repo refs))))
        (remoto-forge-forget-refs (remoto-path-forge refs)
                                  (remoto-path-owner refs) (remoto-path-repo refs))
        (message "Remoto: cache cleared for %s" repo-id)
        (when (derived-mode-p 'dired-mode)
          (revert-buffer))))
     (t (user-error "Remoto: not in a remoto buffer")))))

;;;; Forge web URLs

(defvar remoto-forge-url-templates
  '((github
     (blob    . "https://github.com/%o/%r/blob/%R/%p%L")
     (tree    . "https://github.com/%o/%r/tree/%R/%p%L")
     (blame   . "https://github.com/%o/%r/blame/%R/%p%L")
     (history . "https://github.com/%o/%r/commits/%R/%p")
     (raw     . "https://raw.githubusercontent.com/%o/%r/%R/%p")
     (repo    . "https://github.com/%o/%r")
     (ssh     . "git@github.com:%o/%r.git")
     (https   . "https://github.com/%o/%r.git")
     (compare . "https://github.com/%o/%r/compare/%R")
     (new-pr  . "https://github.com/%o/%r/pull/new/%R")
     (issue   . "https://github.com/%o/%r/issues/%N")
     (pr      . "https://github.com/%o/%r/pull/%N")
     (pr-diff . "https://github.com/%o/%r/pull/%N/files")
     (owner       . "https://github.com/%o")
     (owner-repos . "https://github.com/%o?tab=repositories")
     (line    . "#L%s")
     (region  . "#L%s-L%e")))
  "Per-forge web-URL templates, keyed by forge symbol.

Each value is an alist of (KIND . TEMPLATE).  Path-level kinds: `blob',
`tree', `blame', `history', `raw'.  Repository-level kinds: `repo' (web
root), `ssh' and `https' (clone URLs).  Account-level kinds: `owner' for
the profile page and `owner-repos' for the repositories tab.  Plus the
line-fragment builders `line' and `region'.  Templates are expanded with
`format-spec' using:

  %o  repository owner
  %r  repository name
  %R  git ref (branch, tag, or commit SHA)
  %k  the kind of %R where the forge spells it out: branch, tag or commit
  %p  path relative to the repository root
  %L  line fragment built from the `line'/`region' templates
  %s  start line (in the `line' and `region' templates)
  %e  end line (in the `region' template)

A forge registered with `remoto-register-forge' needs an entry here
under its name.")

(cl-defgeneric remoto--ref-kind (_forge _owner _repo _ref)
  "Return \"branch\", \"tag\" or \"commit\" for REF of OWNER/REPO on FORGE.
Only a forge whose URL templates use %k answers; nil by default."
  nil)

(defun remoto--forge-type (path)
  "Return the forge symbol for remoto PATH, or nil when undetermined.
Derived from the path prefix, e.g. \"/github:...\" -> `github'."
  (when-let* (((stringp path))
              (entry (remoto--prefix-of path)))
    (remoto-forge-name (cdr entry))))

(defun remoto--url-encode-path (path)
  "Percent-encode each segment of PATH for a web URL, keeping the slashes."
  (mapconcat #'url-hexify-string (split-string (or path "") "/") "/"))

(defun remoto--forge-url (forge kind owner repo ref path &optional line-start line-end)
  "Build a FORGE web URL of KIND for OWNER/REPO at REF and PATH.
KIND is one of `blob', `tree', `blame', `history', `raw'.  A nil REF
defaults to \"HEAD\" (the forge resolves it to the default branch), so a
repo-level target with no ref still produces a valid URL.  LINE-START and
LINE-END add a line or line-range fragment when KIND's template includes
one."
  (let* ((templates (or (alist-get forge remoto-forge-url-templates)
                        (user-error "Remoto: no URL templates for forge `%s'"
                                    forge)))
         (template (or (alist-get kind templates)
                       (user-error "Remoto: forge `%s' has no `%s' URL"
                                   forge kind)))
         (line (cond
                ((and line-start line-end)
                 (format-spec (alist-get 'region templates)
                              `((?s . ,line-start) (?e . ,line-end))))
                (line-start
                 (format-spec (alist-get 'line templates)
                              `((?s . ,line-start))))
                (t "")))
         (kind (and (string-search "%k" template)
                    (remoto--ref-kind (remoto--forge-named forge) owner repo ref))))
    (format-spec template `((?o . ,owner)
                            (?r . ,repo)
                            (?R . ,(or ref "HEAD"))
                            (?k . ,(or kind "branch"))
                            (?p . ,(remoto--url-encode-path path))
                            (?L . ,line)))))

(defun remoto--forge-issue-url (forge owner repo number &optional kind)
  "Build a web URL for issue/PR NUMBER in OWNER/REPO on FORGE.
KIND selects the %N-based template (default `issue'); the PR files-diff
page uses `pr-diff'."
  (let* ((kind (or kind 'issue))
         (template (or (alist-get kind (alist-get forge remoto-forge-url-templates))
                       (user-error "Remoto: forge `%s' has no `%s' URL" forge kind))))
    (format-spec template `((?o . ,owner) (?r . ,repo) (?N . ,number)))))

(defun remoto--forge-owner-url (forge owner &optional kind)
  "Build a web URL for the account/organization OWNER on FORGE.
KIND selects the %o-based template (default `owner'); the repositories
tab uses `owner-repos'."
  (let* ((kind (or kind 'owner))
         (template (or (alist-get kind (alist-get forge remoto-forge-url-templates))
                       (user-error "Remoto: forge `%s' has no `%s' URL" forge kind))))
    (format-spec template `((?o . ,owner)))))

(defun remoto--forge-named (name)
  "Return the registered forge called NAME, a symbol, or nil."
  (seq-find (lambda (forge) (eq (remoto-forge-name forge) name))
            (mapcar #'cdr remoto--forges)))

(defun remoto--context-commit-sha (ctx)
  "Return the commit SHA that the ref of the context plist CTX names.
Used for permalinks so the link survives the ref moving on."
  (let ((owner (plist-get ctx :owner))
        (repo (plist-get ctx :repo))
        (ref (plist-get ctx :ref)))
    (or (remoto-forge-commit-sha (remoto--forge-named (plist-get ctx :forge))
                                 owner repo ref)
        (user-error "Remoto: could not resolve commit SHA for %s/%s@%s"
                    owner repo ref))))

(defun remoto--url-path (input)
  "Return the `remoto-path' that the URL, remote or shorthand INPUT names.
Each forge is asked in turn; signal a `user-error' when none answers."
  (or (seq-some (lambda (forge) (remoto-forge-parse-url forge input))
                (seq-uniq (mapcar #'cdr remoto--forges)))
      (user-error "Remoto: cannot parse input: %s" input)))

(defun remoto--path-context (path &optional line-start line-end)
  "Build a forge-agnostic context plist for the remoto PATH string.
Return nil when PATH is not a remoto path.

Plist keys: :forge :owner :repo :ref :path :kind :type :line-start
:line-end.  :kind is `tree' or `blob'.  :type is the Embark target type,
one of `remoto-repo', `remoto-dir', `remoto-file'.  A repository root is
classified as `remoto-repo' without resolving the ref or fetching the
tree (so it works offline and on bare `owner/repo' targets).  LINE-START
and LINE-END are retained only for `remoto-file' targets."
  (when-let* ((parsed (remoto--parse-path path)))
    (if (member (remoto-path-path parsed) '("" "/"))
        (list :forge (remoto--forge-type path)
              :owner (remoto-path-owner parsed)
              :repo (remoto-path-repo parsed)
              :ref (remoto-path-ref parsed)
              :path "" :kind 'tree :type 'remoto-repo
              :line-start nil :line-end nil)
      (let* ((resolved (remoto--resolve-ref parsed))
             (entry (remoto--tree-entry resolved))
             (filep (not (and entry (equal "tree" (alist-get 'type entry))))))
        (list :forge (remoto--forge-type path)
              :owner (remoto-path-owner resolved)
              :repo (remoto-path-repo resolved)
              :ref (remoto-path-ref resolved)
              :path (remoto--relative-path (remoto-path-path resolved))
              :kind (if filep 'blob 'tree)
              :type (if filep 'remoto-file 'remoto-dir)
              :line-start (and filep line-start)
              :line-end (and filep line-end))))))

(defun remoto--buffer-file-context ()
  "Return a context plist describing the current buffer's remoto target.

Works in file buffers (line/region at point) and in Dired (entry at
point, falling back to the directory).  Resolves the ref so the context
carries a concrete branch, then delegates classification to
`remoto--path-context'.  Signals a `user-error' when the current buffer
is not a remoto buffer."
  (let* ((dired (derived-mode-p 'dired-mode))
         (file (or buffer-file-name
                   (and dired (dired-get-filename nil t))
                   (and dired (if (listp dired-directory)
                                  (car dired-directory)
                                dired-directory))
                   default-directory))
         (parsed (and file (remoto--parse-path file))))
    (unless parsed
      (user-error "Remoto: not in a remoto buffer"))
    (let* ((canonical (remoto--canonical-path (remoto--resolve-ref parsed)))
           (region (and (not dired) (use-region-p)))
           (line-start (and (not dired)
                            (line-number-at-pos
                             (if region (region-beginning) (point)))))
           (line-end (and region (line-number-at-pos (region-end)))))
      (remoto--path-context canonical line-start line-end))))

(defun remoto--context-url (ctx kind &optional ref)
  "Build a URL of KIND from context plist CTX.
Optional REF overrides the ref in CTX (used for permalinks)."
  (remoto--forge-url (plist-get ctx :forge)
                     kind
                     (plist-get ctx :owner)
                     (plist-get ctx :repo)
                     (or ref (plist-get ctx :ref))
                     (plist-get ctx :path)
                     (plist-get ctx :line-start)
                     (plist-get ctx :line-end)))

(defun remoto--context-web-url (ctx)
  "Return the human-facing web URL for context CTX, chosen by its :type.
A repo target yields the repository page, a directory the tree view, and
a file the blob view (with any line fragment)."
  (remoto--context-url ctx (pcase (plist-get ctx :type)
                             ('remoto-repo 'repo)
                             ('remoto-dir 'tree)
                             (_ 'blob))))

(defun remoto--require-blob (ctx what)
  "Signal a `user-error' unless CTX refers to a file.
WHAT names the operation, for the error message."
  (unless (eq (plist-get ctx :kind) 'blob)
    (user-error "Remoto: %s is only available for files, not directories"
                what)))

(defun remoto--kill-url (url)
  "Put URL on the kill ring and report it in the echo area."
  (kill-new url)
  (message "Copied: %s" url))

;;;; URL commands

;;;###autoload
(defun remoto-copy-url ()
  "Copy the forge web URL for the current file or directory.
In a file buffer the link targets the current line, or the active
region as a line range.  In Dired it targets the entry at point, or
the directory itself."
  (interactive)
  (let ((ctx (remoto--buffer-file-context)))
    (remoto--kill-url (remoto--context-url ctx (plist-get ctx :kind)))))

;;;###autoload
(defun remoto-copy-blame-url ()
  "Copy the forge blame URL for the current file and line/region."
  (interactive)
  (let ((ctx (remoto--buffer-file-context)))
    (remoto--require-blob ctx "Blame")
    (remoto--kill-url (remoto--context-url ctx 'blame))))

;;;###autoload
(defun remoto-copy-permalink ()
  "Copy a permalink: the web URL pinned to the current commit SHA.
Resolves the ref to a commit via the forge API so the link keeps
pointing at the same content even after the branch advances."
  (interactive)
  (let* ((ctx (remoto--buffer-file-context))
         (sha (remoto--context-commit-sha ctx)))
    (remoto--kill-url (remoto--context-url ctx (plist-get ctx :kind) sha))))

;;;###autoload
(defun remoto-copy-raw-url ()
  "Copy the raw-content URL for the current file."
  (interactive)
  (let ((ctx (remoto--buffer-file-context)))
    (remoto--require-blob ctx "Raw URL")
    (remoto--kill-url (remoto--context-url ctx 'raw))))

;;;###autoload
(defun remoto-copy-history-url ()
  "Copy the commit-history URL for the current file or directory."
  (interactive)
  (let ((ctx (remoto--buffer-file-context)))
    (remoto--kill-url (remoto--context-url ctx 'history))))

;;;###autoload
(defun remoto-browse-url ()
  "Open the forge web page for the current file or directory in a browser."
  (interactive)
  (let* ((ctx (remoto--buffer-file-context))
         (url (remoto--context-url ctx (plist-get ctx :kind))))
    (browse-url url)
    (message "Browsing: %s" url)))

;;;###autoload
(define-obsolete-function-alias 'remoto-copy-github-url #'remoto-copy-url "1.8.0")

;;;; Search cache and background requests

(defvar remoto--search-cache (make-hash-table :test 'equal)
  "Cache: query string -> (TIMESTAMP . RESULTS).
Entries expire after `remoto-search-cache-ttl' seconds.")

(defcustom remoto-debounce-delay 0.3
  "Seconds of idle time before firing an async search request.
Lower values feel more responsive but generate more API calls."
  :type 'number
  :group 'remoto)

(defcustom remoto-min-search-chars 3
  "Minimum characters before searching users or repos.
Prevents premature API requests while typing short prefixes."
  :type 'integer
  :group 'remoto)

(defcustom remoto-repo-cache-ttl 1800
  "Seconds before repo list cache entries expire.
Repo lists change infrequently, so a longer TTL (default 30 min)
avoids repeated fetches during a session."
  :type 'integer
  :group 'remoto)

(defvar remoto--debounce-timer nil
  "Active idle timer for debounced async searches.")

(defvar remoto--debounce-key nil
  "Key identifying the currently pending debounce.
When a new debounce request arrives with the same key, the
existing timer is kept rather than cancelled and rescheduled.
This prevents completion frameworks (vertico, icomplete) from
starving the async fetch by re-calling the completion function
on every `post-command-hook' cycle.")

(defvar remoto--async-generation 0
  "Monotonic counter for invalidating stale async callbacks.
Incremented on each new debounce schedule; callbacks whose
captured generation doesn't match the current value are stale
and skip UI refresh (but still cache their results).")

(defun remoto--search-cache-get (key &optional ttl)
  "Return cached results for KEY if not expired.
TTL overrides `remoto-search-cache-ttl' when provided.
Returns two values via list: (HIT-P RESULTS).  HIT-P is non-nil
when KEY was found and not expired.  RESULTS may be nil for
queries that returned zero results."
  (let ((cache-ttl (or ttl remoto-search-cache-ttl)))
    (if-let* ((entry (gethash key remoto--search-cache))
              (timestamp (car entry))
              (fresh-p (or (zerop cache-ttl)
                           (< (- (float-time) timestamp) cache-ttl))))
        (list t (cdr entry))
      (when entry (remhash key remoto--search-cache))
      '(nil nil))))

(defun remoto--search-cache-put (key results)
  "Store RESULTS for KEY with current timestamp."
  (puthash key (cons (float-time) results) remoto--search-cache)
  results)

(defun remoto--api-async (forge endpoint callback &optional errback)
  "Call ENDPOINT of the REST API of FORGE asynchronously via ghub.
CALLBACK receives the parsed JSON response; on a failure ERRBACK, when
non-nil, is called with no arguments.  The `:host' is explicit, or ghub
may resolve the HTML site.  The call counts toward the fetch indicator."
  (let* ((resource (concat "/" endpoint))
         (auth (remoto--auth forge)))
    (condition-case nil
        (let ((inhibit-message t))
          (remoto--inflight-inc)
          ;; ghub calls :callback as (value headers status req) and retries
          ;; with (value) on `wrong-number-of-arguments'.  Accept the full
          ;; arglist so the retry never fires and the in-flight counter is
          ;; decremented exactly once.  All callers pass a 1-arg callback.
          (ghub-get resource nil
                    :auth auth
                    :reader #'remoto--json-reader
                    :host (remoto--api-host forge)
                    :forge (remoto--ghub-forge forge)
                    :callback (lambda (value &rest _)
                                (remoto--inflight-dec)
                                (funcall callback value))
                    :errorback (lambda (&rest _)
                                 (remoto--inflight-dec)
                                 (when errback (funcall errback)))))
      (error (remoto--inflight-dec)
             (when errback (funcall errback))))))

(defun remoto--debounce (key fn)
  "Schedule FN after `remoto-debounce-delay' seconds of idle time.
KEY identifies this request; if a timer is already pending for
the same KEY, it is kept as-is (no cancel/reschedule).  A
different KEY cancels the old timer and schedules a new one."
  (unless (and remoto--debounce-timer
               (equal key remoto--debounce-key))
    (when remoto--debounce-timer
      (cancel-timer remoto--debounce-timer))
    (setq remoto--debounce-key key)
    (cl-incf remoto--async-generation)
    (let ((gen remoto--async-generation))
      (setq remoto--debounce-timer
            (run-with-idle-timer
             remoto-debounce-delay nil
             (lambda ()
               (setq remoto--debounce-timer nil
                     remoto--debounce-key nil)
               (when (= gen remoto--async-generation)
                 (funcall fn))))))))

(defun remoto--invalidate-completion-ui ()
  "Void live front-ends' recompute caches in the selected minibuffer.
Emacs has no single API for refreshing an in-progress completion UI,
so poke the popular front-ends explicitly and fall back to
`post-command-hook' for anything else.  Assumes the active minibuffer
window is selected."
  ;; Default cycling cache.
  (when (boundp 'completion-all-sorted-completions)
    (setq completion-all-sorted-completions nil))
  ;; Vertico skips recompute while the input is `equal', so a
  ;; late-arriving fetch is ignored unless its cache is voided.
  ;; `set' avoids a free-variable warning when vertico is absent.
  (when (boundp 'vertico--input)
    (set 'vertico--input t))
  ;; Icomplete/fido and any UI that recomputes on this hook.
  (run-hooks 'post-command-hook)
  ;; The default *Completions* buffer is not live; rebuild it only
  ;; when it is already on screen.
  (when (get-buffer-window "*Completions*" 0)
    (minibuffer-completion-help)))

(defun remoto--refresh-minibuffer-completions ()
  "Refresh the active minibuffer's completion display.
Called from async callbacks after updating the cache, so freshly
cached candidates appear without the user editing the input."
  (run-at-time
   0 nil
   (lambda ()
     (when-let* ((win (active-minibuffer-window)))
       (with-selected-window win
         (remoto--invalidate-completion-ui))))))

(defvar remoto--user-timer nil
  "Idle timer of the lookup of the token's account that completion waits for.")

(defun remoto--known-user (forge)
  "Return the login of the account of the token on FORGE, or nil until known.
An unknown one is looked up after `remoto-debounce-delay' of idle time,
as a search waits, and the completions refresh when it answers.  The
lookup asks nothing without a token, and settles the login either way."
  (let ((login (remoto--forge-login forge)))
    (or (remoto--login-user login)
        (unless (remoto--login-failed login)
          (when (timerp remoto--user-timer)
            (cancel-timer remoto--user-timer))
          (setq remoto--user-timer
                (run-with-idle-timer
                 remoto-debounce-delay nil
                 (lambda ()
                   (setq remoto--user-timer nil)
                   (when (stringp (while-no-input
                                    (remoto--get-authenticated-user forge)))
                     (remoto--refresh-minibuffer-completions)))))
          nil))))

;;;; Listings above the repository level

(defcustom remoto-listing-cap 1000
  "Most repositories a Dired listing of /github:OWNER/ holds.
The listing keeps the most recently pushed ones.  Its first page arrives
before Dired shows it; the later ones load in the background."
  :type 'integer
  :group 'remoto)

(defun remoto--listing-dir (filename)
  "Return the listing directory that FILENAME names, or nil.
That is /github:, the accounts of the token, or /github:OWNER/, OWNER's
repositories: the two levels above a repository."
  (when-let* ((parsed (remoto--parse
                       (remoto--handle-file-name-as-directory filename)))
              (query (remoto-path-query parsed)))
    (pcase (remoto-path-level parsed)
      ('root (and (member query '("" "/")) (remoto--path-prefix parsed)))
      ('owner (and (string-empty-p query)
                   (format "%s%s/" (remoto--path-prefix parsed)
                           (remoto-path-owner parsed)))))))

(defun remoto--refs-dir-p (filename)
  "Return non-nil when FILENAME is a /github:OWNER/REPO@ directory."
  (when-let* ((parsed (remoto--parse filename)))
    (and (eq (remoto-path-level parsed) 'refs)
         (string-empty-p (remoto-path-query parsed)))))

(defun remoto--bare-name (parsed)
  "Return the query of PARSED when it is a bare name at its level, else nil.
A bare name holds no slash, colon or delimiter: it is one line of a
listing, not a path into it."
  (let ((query (remoto-path-query parsed)))
    (and (not (string-empty-p query))
         (not (string-match-p (remoto-forge-repo-end (remoto-path-forge parsed))
                              query))
         query)))

(defun remoto--bare-repo-parts (filename)
  "Return (OWNER . NAME) when FILENAME is a bare /github:OWNER/NAME."
  (when-let* ((parsed (remoto--parse filename))
              ((eq (remoto-path-level parsed) 'owner))
              (name (remoto--bare-name parsed)))
    (cons (remoto-path-owner parsed) name)))

(defun remoto--entry-name-p (filename)
  "Return non-nil when FILENAME names an account, a repository or a ref.
Those are the lines of a listing or of a Dired of matches."
  (when-let* ((parsed (remoto--parse filename))
              (query (remoto-path-query parsed)))
    (pcase (remoto-path-level parsed)
      ((or 'root 'owner) (and (remoto--bare-name parsed) t))
      ('refs (and (not (string-empty-p query))
                  (not (string-search ":" query))
                  (not (string-suffix-p "/" query)))))))

(defun remoto--entry-for (name)
  "Return the remembered Dired line attributes of the remoto NAME."
  (gethash (downcase name) remoto--entry-cache))

(defun remoto--remember (name entry)
  "Remember ENTRY as the Dired line attributes of the remoto NAME.
Return ENTRY."
  (puthash (downcase name) entry remoto--entry-cache))

(defun remoto--listed-p (filename)
  "Return non-nil when FILENAME is an entry of a cached listing.
The age of the listing does not matter: a Dired buffer that still shows
the name has to open it.  A name that a search found counts too."
  (or (when-let* ((listing (gethash (remoto--handle-file-name-directory filename)
                                    remoto--listing-cache)))
        (assoc (remoto--handle-file-name-nondirectory filename)
               (remoto--listing-entries listing)))
      (remoto--entry-for filename)))

(defun remoto--listing-fresh-p (listing)
  "Return non-nil when LISTING may be shown without fetching it again.
Its time renews when the background pages end, failed or not: the revert
that shows the end would otherwise fetch it all again, and again."
  (or (zerop remoto-repo-cache-ttl)
      (< (- (float-time) (remoto--listing-time listing))
         remoto-repo-cache-ttl)))

(defun remoto--listing (dir)
  "Return the listing of DIR, fetching it unless a fresh one is cached.
DIR is what `remoto--listing-dir' returns."
  (let ((cached (gethash dir remoto--listing-cache))
        (forge (remoto--canonical-forge dir)))
    (cond
     ((and cached (remoto--listing-fresh-p cached)) cached)
     ((eq (remoto--directory-level dir) 'root)
      (puthash dir (remoto--listing-create
                    :entries (remoto-forge-account-entries forge dir))
               remoto--listing-cache))
     (t (remoto-forge-owner-listing forge dir)))))

(defun remoto--listing-done (dir listing owner)
  "Say how the background fetch of LISTING ended, and revert DIR's buffers.
OWNER names the account in the message."
  (let ((count (length (remoto--listing-entries listing))))
    (pcase (remoto--listing-state listing)
      ('capped (message "Remoto: listed the %d most recently pushed \
repositories of %s, as `remoto-listing-cap' allows" count owner))
      ('failed (message "Remoto: listing the repositories of %s stopped \
after %d; M-x remoto-refresh retries" owner count))
      (_ (message "Remoto: listed all %d repositories of %s" count owner))))
  (setf (remoto--listing-time listing) (float-time))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'dired-mode)
                 (equal dir (if (consp dired-directory)
                                (car dired-directory)
                              dired-directory)))
        (revert-buffer)))))

;;;; Matches of a name that names nothing

(defun remoto--if-found (fn &rest args)
  "Call FN with ARGS, or return nil when GitHub answers 404 to it.
Any other failure signals."
  (condition-case err
      (apply fn args)
    (user-error
     (unless (string-prefix-p remoto--not-found (cadr err))
       (signal (car err) (cdr err))))))

(defun remoto--repository-p (forge owner name)
  "Return non-nil when OWNER has a repository NAME on FORGE, asking if need be.
A NAME with a character that no repository name has is not asked about."
  (and (string-match-p (rx bos (+ (in "A-Za-z0-9._-")) eos) name)
       (remoto--if-found #'remoto--resolve-ref
                         (remoto-path-create :forge forge :owner owner
                                             :repo name :path "/"))))

(defun remoto--ref-p (forge owner repo ref)
  "Return non-nil when OWNER/REPO on FORGE has a tree at REF.
REF is a branch, tag or commit; one with a character that no ref has is
not asked about."
  (and (not (string-empty-p ref))
       (not (string-match-p (rx (or (in " \t~^:?*[\\") "..")) ref))
       (remoto--if-found #'remoto--ensure-tree
                         (remoto-path-create :forge forge :owner owner :repo repo
                                             :ref ref :path "/"))))

(defun remoto--words-match-p (query name)
  "Return non-nil when each word of QUERY is in NAME, ignoring case."
  (let ((name (downcase name)))
    (seq-every-p (lambda (word) (string-search word name))
                 (split-string (downcase query)))))

(defun remoto--dired-line-p (name)
  "Return non-nil when the remoto NAME is a line of the current Dired buffer.
Dired opens its lines by name, and the name of an account line is the
same as the account typed as a query."
  (and (derived-mode-p 'dired-mode)
       (save-excursion (dired-goto-file name))))

(defun remoto--sorted-names (dir names query)
  "Return NAMES, lines of a Dired of DIR, in the order of `dired-listing-switches'.
A name that is QUERY, ignoring case, comes first: it is what was typed,
and capitals sort first.  Their text properties go."
  (let* ((sorted (mapcar #'car
                         (remoto--sort-entries
                          (mapcar (lambda (name)
                                    (let ((name (substring-no-properties name)))
                                      (cons name (remoto--entry-for (concat dir name)))))
                                  names)
                          dired-listing-switches)))
         (exact (seq-find (lambda (name) (string-equal-ignore-case name query))
                          sorted)))
    (if exact (cons exact (delete exact sorted)) sorted)))

(defun remoto--account-matches (name)
  "Return (/github: . LOGINS) when NAME is a bare /github:QUERY.
LOGINS are the accounts of the search that hold each word of QUERY.  A
line of the current Dired buffer is the account to open, no query.
Signal a `user-error' when no account matches."
  (when-let* ((parsed (remoto--parse name))
              ((eq (remoto-path-level parsed) 'root))
              (query (remoto--bare-name parsed))
              ((not (remoto--dired-line-p name))))
    (let ((prefix (remoto--path-prefix parsed))
          (logins (seq-filter (lambda (login) (remoto--words-match-p query login))
                              (remoto-forge-search-accounts
                               (remoto-path-forge parsed) query t))))
      (dolist (login logins)
        (remoto--remember (concat prefix login)
                          `((type . "tree")
                            (note . ,(get-text-property 0 'remoto-acct-type login)))))
      (cons prefix
            (or (remoto--sorted-names prefix logins query)
                (user-error "Remoto: no account matches %s" query))))))

(defun remoto--repo-matches (name)
  "Return (DIR . NAMES) when NAME, a bare /github:OWNER/QUERY, is no repository.
NAMES are the owner's repositories that the search of completion finds
for QUERY; DIR is the owner's listing.  Signal a `user-error' when no
repository matches, or when OWNER is no account."
  (when-let* ((parts (remoto--bare-repo-parts name))
              (forge (remoto--canonical-forge name))
              ((not (remoto--repository-p forge (car parts) (cdr parts)))))
    (pcase-let* ((`(,owner . ,query) parts)
                 (dir (format "%s%s/" (remoto--prefix forge) owner))
                 (names (condition-case err
                            (remoto-forge-search-repos forge owner query t)
                          (user-error
                           (if (string-prefix-p remoto--not-found (cadr err))
                               (user-error "Remoto: no account %s" owner)
                             (signal (car err) (cdr err)))))))
      (cons dir
            (or (remoto--sorted-names dir names query)
                (user-error "Remoto: no repository of %s matches %s"
                            owner query))))))

(defun remoto--ref-matches (name)
  "Return (DIR . REFS) when NAME, a /github:OWNER/REPO@QUERY, is no ref.
REFS are the branches and tags that hold each word of QUERY, all of
them for an empty QUERY; DIR is /github:OWNER/REPO@.  Signal a
`user-error' when no ref matches."
  (when-let* ((parsed (remoto--parse name))
              ((eq (remoto-path-level parsed) 'refs))
              (owner (remoto-path-owner parsed))
              (repo (remoto-path-repo parsed))
              (query (string-remove-suffix "/" (remoto-path-query parsed)))
              (forge (remoto-path-forge parsed))
              ((not (remoto--ref-p forge owner repo query))))
    (let* ((dir (format "%s%s/%s@" (remoto--path-prefix parsed) owner repo))
           (branches (remoto-forge-branches forge owner repo))
           (refs (seq-filter (lambda (ref) (remoto--words-match-p query ref))
                             (seq-uniq (append branches
                                               (remoto-forge-tags forge owner repo))))))
      (dolist (ref refs)
        (remoto--remember (concat dir ref)
                          `((type . "tree")
                            (note . ,(if (member ref branches) "branch" "tag")))))
      (cons dir
            (or (remoto--sorted-names dir refs query)
                (user-error "Remoto: no branch or tag of %s/%s%s" owner repo
                            (if (string-empty-p query)
                                ""
                              (concat " matches " query))))))))

(defun remoto--file-matches (filename)
  "Return (DIR . NAMES) when the canonical FILENAME is missing from its tree.
NAMES are the entries of its directory DIR that hold each word of its
name.  A name with a trailing slash or a wildcard is no query, and one
that nothing matches visits a new file, as a local name does."
  (when-let* ((parsed (remoto--parse-path filename))
              (path (remoto-path-path parsed))
              (name (file-name-nondirectory path))
              ((not (string-empty-p name)))
              ((not (string-match-p "[[*?]" name)))
              ((not (remoto--tree-entry parsed)))
              (dir (concat (remoto--file-name-prefix filename)
                           (or (file-name-directory path) "/")))
              (dir-parsed (remoto--parse-path dir))
              ((equal "tree" (alist-get 'type (remoto--tree-entry dir-parsed))))
              (names (seq-filter (lambda (child)
                                   (remoto--words-match-p name child))
                                 (mapcar #'car (remoto--tree-children dir-parsed)))))
    (cons dir names)))

(defun remoto--query-matches (filename)
  "Return (DIR . NAMES) when FILENAME is a short remoto name that names nothing.
The names are /github:QUERY, /github:OWNER/QUERY and
/github:OWNER/REPO@QUERY; NAMES are the accounts, repositories or refs
that match QUERY, for a Dired of DIR."
  (when-let* ((name (remoto--normalize-shorthand filename))
              ((remoto--canonical-forge name))
              ;; /github:OWNER/.. names no repository called "..".
              (name (if (remoto--dot-component-p name)
                        (remoto--normalize-name name)
                      name)))
    (or (remoto--account-matches name)
        (remoto--repo-matches name)
        (remoto--ref-matches name))))

(defun remoto--name-or-matches (filename)
  "Return what visiting FILENAME opens: the (DIR . NAMES) of matches or a name.
The matches are those of a name that names nothing.  Any other FILENAME
comes back as `remoto--maybe-rewrite' makes it."
  (or (remoto--query-matches filename)
      (let ((name (remoto--maybe-rewrite filename)))
        (or (remoto--file-matches name) name))))

(defun remoto--get-authenticated-user (forge)
  "Return the login of the account of the token on FORGE, or nil.
Caches the result for the session.  Returns nil when auth has
failed or the API call errors."
  (let ((login (remoto--forge-login forge)))
    (or (remoto--login-user login)
        (unless (remoto--login-failed login)
          (condition-case nil
              (when-let* ((data (remoto--api forge "user"))
                          (user (alist-get 'login data)))
                (setf (remoto--login-user login) user))
            (user-error nil))))))

;;;; Rewriting what find-file and dired receive

(defun remoto--repo-root (parsed)
  "Return the `remoto-path' of the repository root that PARSED names, or nil.
That is a bare /github:OWNER/REPO, or /github:OWNER/REPO@REF with or
without a slash after the ref; its ref is nil for the default branch."
  (pcase (remoto-path-level parsed)
    ('owner
     (when-let* ((repo (remoto--bare-name parsed)))
       (remoto-path-create :forge (remoto-path-forge parsed)
                           :owner (remoto-path-owner parsed) :repo repo
                           :ref nil :path "/")))
    ('refs
     (let ((ref (string-remove-suffix "/" (remoto-path-query parsed))))
       (unless (string-empty-p ref)
         (remoto-path-create :forge (remoto-path-forge parsed)
                             :owner (remoto-path-owner parsed)
                             :repo (remoto-path-repo parsed)
                             :ref ref :path "/"))))))

(defun remoto--maybe-rewrite (input)
  "If INPUT is a GitHub URL/shorthand, return canonical remoto path.
Also handles partial canonical paths like /github:OWNER/REPO and the
/gh: shorthand prefix.  Otherwise return INPUT unchanged.  The . and ..
components resolve first: a short form reads /github:OWNER/.. as a repo."
  (setq input (remoto--normalize-shorthand input))
  (when (and (remoto--canonical-forge input)
             (remoto--dot-component-p input))
    (setq input (remoto--normalize-name input)))
  (let* ((parsed (remoto--parse input))
         (root (and parsed (remoto--repo-root parsed))))
    (cond
     ;; Already a full canonical path
     ((remoto--parse-path input) input)
     ;; Files-default short form: /github:owner/repo/ or /github:owner/repo/path
     ((and parsed (eq (remoto-path-level parsed) 'tree))
      (let* ((owner (remoto-path-owner parsed))
             (repo (remoto-path-repo parsed))
             (subpath (substring (remoto-path-path parsed) 1))
             (repo-id (remoto--repo-id (remoto-path-forge parsed) owner repo))
             (branch (or (gethash repo-id remoto--default-branch-cache)
                         (let ((b (remoto-forge-default-ref
                                   (remoto-path-forge parsed) owner repo)))
                           (when b (puthash repo-id b remoto--default-branch-cache))
                           b))))
        (if branch
            (format "%s%s/%s@%s:/%s" (remoto--path-prefix parsed)
                    owner repo branch subpath)
          input)))
     ;; Partial canonical path: /github:owner/repo or /github:owner/repo@ref
     (root
      (remoto--canonical-path (remoto--resolve-ref root)))
     ;; A URL or remote of a forge
     ((remoto--url-forge input)
      (if-let* ((parsed (remoto-forge-parse-url (remoto--url-forge input) input)))
          (remoto--canonical-path (remoto--resolve-ref parsed))
        input))
     (t input))))

(defun remoto--dired-around-a (orig-fn dir-or-list &rest args)
  "Rewrite GitHub URLs and short remoto paths for Dired, then call ORIG-FN.
DIR-OR-LIST and ARGS go to ORIG-FN; a name that names nothing becomes the
list of the matching ones.  The advice sits on `dired-noselect', which
every Dired command calls, so each buffer gets a canonical directory."
  (if-let* ((raw (if (consp dir-or-list) (car dir-or-list) dir-or-list))
            ((stringp raw))
            (dir (remoto--normalize-shorthand raw))
            ((or (remoto--url-forge dir)
                 (remoto--canonical-forge dir))))
      (apply orig-fn
             (if (consp dir-or-list)
                 (cons (remoto--maybe-rewrite dir) (cdr dir-or-list))
               (remoto--name-or-matches dir))
             args)
    (apply orig-fn dir-or-list args)))

(defun remoto--find-file-around-a (orig-fn filename &rest args)
  "Rewrite GitHub URLs to canonical remoto paths for `find-file'.
Intercepts #NUM patterns to display issues instead of file operations.
Call ORIG-FN with FILENAME and ARGS after any rewrite.  A name that names
nothing opens a Dired of the names that match it."
  (setq filename (remoto--normalize-shorthand filename))
  ;; A pull request or issue web URL is the topic, not the repository root
  ;; the URL parser would make of it.
  (when-let* ((forge (remoto--url-forge filename))
              (topic (remoto-forge-parse-topic-url forge filename)))
    (setq filename (apply #'format "%s%s/%s#%s" (remoto--prefix forge) topic)))
  ;; Check for #NUM BEFORE rewrite (rewrite would mangle the # delimiter)
  (if-let* ((topic (remoto--topic-path filename)))
      (progn
        (remoto--require-topic)
        (remoto-topic-display (cdr topic) (car topic)))
    (let ((target (remoto--name-or-matches filename)))
      (if (consp target)
          (dired-noselect target)
        (apply orig-fn target args)))))

;;;; Eager auth warm-up

(defun remoto--git-user-key (forge)
  "Return the git config key, in ghub's spelling, of the account name for FORGE.
KIND.user serves only the domain of ghub's default host for the kind of
forge, which is api.github.com or github.com by ghub's version; any
other host needs KIND.HOST.user."
  (let ((kind (or (remoto--ghub-forge forge) 'github))
        (host (remoto-forge-host forge)))
    (if (equal (ghub--host-domain host)
               (ghub--host-domain (alist-get kind ghub-default-host-alist)))
        (format "%s.user" kind)
      (format "%s.%s.user" kind host))))

(defun remoto--find-token (forge)
  "Search auth-source for a token of the API host of FORGE.
Follow ghub's conventions for the kind of forge: the user name from
git config, under the API host or the web host, as USER^forge,
USER^ghub or USER.  Without a user name in git config no token can be
found, by ghub either, so the login goes unauthenticated for good."
  (let* ((login (remoto--forge-login forge))
         (api-host (remoto--api-host forge))
         (web-host (remoto-forge-host forge))
         (username (condition-case nil
                       (ghub--username web-host (remoto--ghub-forge forge))
                     (error nil))))
    (if (null username)
        (progn
          (setf (remoto--login-failed login) t)
          (message "Remoto: no %s in git config, reading %s anonymously"
                   (remoto--git-user-key forge) web-host)
          nil)
      (catch 'found
        (dolist (host (delete-dups (list api-host web-host)))
          (dolist (pkg '("forge" "ghub" nil))
            (let* ((user (if pkg (format "%s^%s" username pkg) username))
                   (results (condition-case err
                                (auth-source-search :host host :user user :max 1)
                              ;; A broken backend (say, a .authinfo.gpg that
                              ;; does not decrypt) fails the same way for
                              ;; every combination and for every later API
                              ;; call, which would repeat this lookup.  Report
                              ;; it once, go unauthenticated, and leave the
                              ;; retry to `remoto-reset-auth'.
                              (error
                               (setf (remoto--login-failed login) t)
                               (message "Remoto: auth-source lookup failed (%s); \
using unauthenticated access until M-x remoto-reset-auth"
                                        (error-message-string err))
                               (throw 'found nil))))
                   (secret (plist-get (car results) :secret))
                   (token (if (functionp secret) (funcall secret) secret)))
              (when (and token (not (string-empty-p token)))
                (throw 'found token)))))))))

(defun remoto--warm-auth ()
  "Pre-fetch the authenticated GitHub user in the background.
Runs on an idle timer so GPG decryption happens before the user
types anything.  Bypasses ghub's own token resolution (which may
look up the wrong auth-source host) by searching auth-source
directly and passing the token string to ghub.  GitHub only: the
other forges look their token up on their first request."
  (let ((login (remoto--forge-login remoto--github)))
    (unless (or (remoto--login-user login) (remoto--login-failed login))
      (if-let* ((token (or (remoto--literal-token remoto--github)
                           (remoto--find-token remoto--github))))
          (condition-case err
              (when-let* ((data (let ((inhibit-message t))
                                  (ghub-get "/user" nil
                                            :auth token
                                            :host (remoto--api-host remoto--github)
                                            :reader #'remoto--json-reader)))
                          (user (alist-get 'login data)))
                (setf (remoto--login-user login) user
                      (remoto--login-token login) token)
                (message "Remoto: authenticated as %s" user))
            (error
             (setf (remoto--login-failed login) t)
             (message "Remoto: token found but API call failed (%s); \
using unauthenticated access"
                      (error-message-string err))))
        ;; No token found yet - don't mark the login failed, so remoto--api
        ;; can still try ghub's own auth-source resolution on demand.
        ;; The warm-up is opportunistic; failing here should not lock
        ;; out the session permanently.  A failure inside the lookup has
        ;; already marked the login and said so.
        (unless (remoto--login-failed login)
          (message "Remoto: no token found during warm-up; \
will try ghub auth on first API call"))))))

(defvar remoto--warm-auth-timer nil
  "Pending idle timer for `remoto--warm-auth', or nil.
Held so turning `global-remoto-mode' off before the timer fires can
cancel it.")

;;;; Minor mode

(defvar remoto-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "u" #'remoto-copy-url)
    (define-key map "b" #'remoto-copy-blame-url)
    (define-key map "p" #'remoto-copy-permalink)
    (define-key map "r" #'remoto-copy-raw-url)
    (define-key map "h" #'remoto-copy-history-url)
    (define-key map "w" #'remoto-browse-url)
    map)
  "Keymap of remoto URL commands, meant to be bound to a prefix key.

Short mnemonic keys: `u' copy-url, `b' blame, `p' permalink, `r' raw,
`h' history, `w' browse.  It is intentionally bound to no key by
default, so it claims none of the user-reserved \\=`C-c LETTER\\=' space.
Bind it as a unit under a prefix of your choice, e.g.:

  (with-eval-after-load \\='remoto
    (keymap-set remoto-mode-map \"C-c g\" remoto-command-map))")
(defalias 'remoto-command-map remoto-command-map)

(defvar remoto-mode-map (make-sparse-keymap)
  "Keymap for `remoto-mode'.
Empty by default.  Populate it in your configuration, commonly by
binding the variable `remoto-command-map' to a prefix key.")

;;;###autoload
(define-minor-mode remoto-mode
  "Minor mode for buffers backed by a remoto virtual filesystem.

Offers forge-agnostic commands to copy or open the web URL of the file
or directory shown in the current buffer.  The commands work the same in
file buffers and in Dired, and adapt to the forge behind the path (only
GitHub today, but designed for more).

While `global-remoto-mode' is on, `remoto-mode' is enabled automatically
when visiting a remoto path.  Its keymap is empty by default; the
commands are grouped in the variable `remoto-command-map', which you can
bind to a prefix of your choosing."
  :lighter " Remoto"
  :keymap remoto-mode-map)

(defun remoto--maybe-enable-mode ()
  "Enable `remoto-mode' when the current buffer is a remoto buffer.
`global-remoto-mode' runs it from `find-file-hook' and `dired-mode-hook'."
  (let ((file (or buffer-file-name
                  (and (derived-mode-p 'dired-mode)
                       (if (listp dired-directory)
                           (car dired-directory)
                         dired-directory)))))
    (when (and (stringp file)
               (string-match-p remoto--handler-regexp file))
      (remoto-mode 1))))

(defun remoto--get-prop (candidate prop)
  "Get text property PROP from CANDIDATE.
Searches from the end backwards, skipping trailing delimiters.
Handles candidates with prefix prepended by completion framework."
  (let ((len (length candidate)))
    (when (< 0 len)
      ;; Try near end (skip trailing / : characters which lack props)
      (or (and (< 1 len) (get-text-property (- len 2) prop candidate))
          (get-text-property (1- len) prop candidate)
          (get-text-property 0 prop candidate)))))

(defface remoto-annotation
  '((t :inherit completions-annotations))
  "Face for remoto completion annotations.")

(defvar remoto-annotation-width-step 10
  "Round annotation alignment width up to this step size.")

(defun remoto--affixate (items)
  "Format ITEMS as affixation triples with aligned suffixes.
ITEMS is a list of (candidate prefix suffix).
Uses display property for alignment (works in any completion UI)."
  (let* ((max-len (apply #'max 0 (mapcar (lambda (x) (length (car x))) items)))
         (align-to (* (ceiling (/ (float (+ max-len 4))
                                  remoto-annotation-width-step))
                      remoto-annotation-width-step)))
    (mapcar (lambda (x)
              (let* ((c (nth 0 x))
                     (prefix (nth 1 x))
                     (suffix (remoto--one-line (nth 2 x))))
                (list c prefix
                      (if (string-empty-p suffix) ""
                        (concat (propertize " " 'display
                                            `(space :align-to ,align-to))
                                (propertize suffix 'face 'remoto-annotation))))))
            items)))

(defun remoto--completion-metadata (directory)
  "Return completion metadata alist for DIRECTORY, or nil.
Provides group-function and affixation-function for @ and # modes."
  (pcase (remoto--directory-level directory)
    ;; Issues mode: /github:OWNER/REPO#
    ('topics
     (let ((group-fn (lambda (candidate transform)
                       (if transform candidate
                         (if (remoto--get-prop candidate 'remoto-topic-pr)
                             "Pull Request"
                           "Issue"))))
           (affix-fn (lambda (candidates)
                       (remoto--affixate
                        (mapcar (lambda (c)
                                  (let ((title (or (remoto--get-prop c 'remoto-topic-title) ""))
                                        (state (or (remoto--get-prop c 'remoto-topic-state) ""))
                                        (is-pr (remoto--get-prop c 'remoto-topic-pr)))
                                    (list c
                                          (if is-pr "PR " "   ")
                                          (format "%s [%s]" title state))))
                                candidates)))))
       ;; The candidates come pre-sorted (pull requests first, newest first);
       ;; without these two entries the UI re-sorts them by length or name.
       `((category . remoto-issue)
         (display-sort-function . identity)
         (cycle-sort-function . identity)
         (group-function . ,group-fn)
         (affixation-function . ,affix-fn))))
    ;; Branches/tags mode: /github:OWNER/REPO@
    ('refs
     (let ((group-fn (lambda (candidate transform)
                       (if transform candidate
                         (if (equal "tag" (remoto--get-prop candidate 'remoto-ref-type))
                             "Tag"
                           "Branch")))))
       `((category . remoto-branch)
         (group-function . ,group-fn))))
    ;; File mode: canonical path or files-default (owner/repo/ with optional subpath)
    ('tree
     (let ((affix-fn (lambda (candidates)
                       (remoto--affixate
                        (mapcar (lambda (c)
                                  (let ((msg (or (remoto--get-prop c 'remoto-file-commit) "")))
                                    (list c "" msg)))
                                candidates)))))
       `((category . remoto-file)
         (affixation-function . ,affix-fn))))
    ;; Owner mode: /github:OWNER/ - repo descriptions
    ('owner
     (let ((affix-fn (lambda (candidates)
                       (remoto--affixate
                        (mapcar (lambda (c)
                                  (let ((desc (or (remoto--get-prop c 'remoto-repo-desc) "")))
                                    (list c "" desc)))
                                candidates)))))
       `((category . remoto-repo)
         (affixation-function . ,affix-fn))))
    ;; Root mode: /github: - user/org type
    ('root
     (let ((affix-fn (lambda (candidates)
                       (remoto--affixate
                        (mapcar (lambda (c)
                                  (let* ((acct-type (or (remoto--get-prop c 'remoto-acct-type) ""))
                                         (desc (or (remoto--get-prop c 'remoto-acct-desc) ""))
                                         (suffix (cond
                                                  ((not (string-empty-p desc))
                                                   (format "%s  %s" acct-type desc))
                                                  (t acct-type))))
                                    (list c "" suffix)))
                                candidates)))))
       `((category . remoto-owner)
         (affixation-function . ,affix-fn))))))

(defun remoto--read-file-name-internal-a (orig string pred action)
  "Inject remoto completion metadata inside `read-file-name'.
Completion itself is delegated to ORIG so candidates stay relative to the
completion boundary.  Re-basing them to full paths makes frameworks like
Vertico prepend the directory twice (e.g. /github: + /github:owner ->
/github:/github:owner).  Only category/affixation metadata is added, for the
@ (branches/tags), # (issues), and owner/repo levels.  The /gh: shorthand is
already canonicalized by `substitute-in-file-name', so EFFECTIVE is /github:.
Args: ORIG, STRING, PRED, ACTION."
  (let ((effective (substitute-in-file-name string)))
    (if (not (and (eq action 'metadata) (remoto--canonical-forge effective)))
        (funcall orig string pred action)
      (let* ((dir (or (file-name-directory effective) ""))
             (extra (remoto--completion-metadata dir))
             (base (funcall orig string pred action))
             (base-alist (and (consp base) (eq (car base) 'metadata) (cdr base))))
        (if extra
            ;; Replace category so Marginalia doesn't override our annotations.
            ;; Use the per-level category from `remoto--completion-metadata' when
            ;; it provides one, else the generic `remoto'.
            (let ((cat (or (alist-get 'category extra) 'remoto)))
              (cons 'metadata (append (assq-delete-all 'category (copy-alist extra))
                                      `((category . ,cat))
                                      (assq-delete-all 'category (copy-alist base-alist)))))
          (or base (cons 'metadata nil)))))))

;;;; Inhibited functions

(defvar remoto--inhibited nil
  "Functions advised with `remoto--inhibit-a'.")

(defun remoto--buffer-p ()
  "Return non-nil in a remoto buffer."
  (string-match-p remoto--handler-regexp
                  (or buffer-file-name default-directory "")))

(defun remoto--inhibit-a (fn &rest args)
  "Call FN with ARGS outside remoto buffers."
  (unless (remoto--buffer-p)
    (apply fn args)))

(defun remoto--sync-inhibited (functions)
  "Advise exactly FUNCTIONS with `remoto--inhibit-a'."
  (dolist (f remoto--inhibited)
    (advice-remove f #'remoto--inhibit-a))
  (dolist (f functions)
    (advice-add f :around #'remoto--inhibit-a))
  (setq remoto--inhibited (copy-sequence functions)))

(defcustom remoto-inhibited-functions '(lsp eglot-ensure)
  "Functions that do nothing in remoto buffers, like LSP clients."
  :type '(repeat (symbol :tag "Function"))
  :set (lambda (symbol value)
         (set-default-toplevel-value symbol value)
         (when (bound-and-true-p global-remoto-mode)
           (remoto--sync-inhibited value)))
  :group 'remoto)

;;;; Global mode

(defun remoto--drop-autoload-handler ()
  "Remove the bootstrap entry of the autoloads from `file-name-handler-alist'."
  (setq file-name-handler-alist
        (rassq-delete-all #'remoto-autoload-file-name-handler
                          file-name-handler-alist)))

(defun remoto--install ()
  "Install the handler, the advice, the hooks and the auth warm-up timer.
Each step is idempotent, so a second call while on is a no-op."
  ;; The real handler takes over from the bootstrap entry; left behind, that
  ;; entry would catch the operations the real handler passes down.
  (remoto--drop-autoload-handler)
  (unless (equal (cdr (assoc remoto--handler-regexp file-name-handler-alist))
                 #'remoto-file-name-handler)
    (push (cons remoto--handler-regexp #'remoto-file-name-handler)
          file-name-handler-alist))
  (advice-add 'dired-noselect :around #'remoto--dired-around-a)
  (advice-add 'find-file-noselect :around #'remoto--find-file-around-a)
  (advice-add 'read-file-name-internal :around
              #'remoto--read-file-name-internal-a)
  (remoto--sync-inhibited remoto-inhibited-functions)
  (add-hook 'find-file-hook #'remoto--maybe-enable-mode)
  (add-hook 'dired-mode-hook #'remoto--maybe-enable-mode)
  ;; Clear the fetch indicator and reset in-flight state whenever a
  ;; minibuffer exits.
  (add-hook 'minibuffer-exit-hook #'remoto--minibuffer-exit-cleanup)
  (unless (timerp remoto--warm-auth-timer)
    (setq remoto--warm-auth-timer
          (run-with-idle-timer 2 nil #'remoto--warm-auth))))

(defun remoto--uninstall ()
  "Remove the handler, the advice, the hooks and the auth warm-up timer."
  (setq file-name-handler-alist
        (assoc-delete-all remoto--handler-regexp file-name-handler-alist))
  (advice-remove 'dired-noselect #'remoto--dired-around-a)
  (advice-remove 'find-file-noselect #'remoto--find-file-around-a)
  (advice-remove 'read-file-name-internal #'remoto--read-file-name-internal-a)
  (remoto--sync-inhibited nil)
  (remove-hook 'find-file-hook #'remoto--maybe-enable-mode)
  (remove-hook 'dired-mode-hook #'remoto--maybe-enable-mode)
  (remove-hook 'minibuffer-exit-hook #'remoto--minibuffer-exit-cleanup)
  (when (timerp remoto--warm-auth-timer)
    (cancel-timer remoto--warm-auth-timer))
  (setq remoto--warm-auth-timer nil))

;;;###autoload
(define-minor-mode global-remoto-mode
  "Toggle remoto's virtual filesystem for GitHub repositories.

When on, `/github:OWNER/REPO...' and `/gh:...' paths work in `find-file',
`dired', and every other file operation, GitHub URLs typed at those
prompts are rewritten to remoto paths, `find-file' completion inside a
remoto path shows remoto's annotations, `remoto-mode' turns on in remoto
buffers, and a GitHub token is looked up once Emacs is idle.  When off,
all of that is removed again.

Loading remoto does not turn this mode on.  Enable it in your init file,
or let the first use do it: `remoto-browse', the Embark open actions,
and a `/github:' or `/gh:' path at any file prompt all turn it on."
  :global t
  :group 'remoto
  (if global-remoto-mode
      (remoto--install)
    (remoto--uninstall)))

(defun remoto--ensure-global-mode ()
  "Turn on `global-remoto-mode' when it is off, and say so.
For remoto's own entry points: the buffers they open need the
file-name handler for as long as they live, so the mode has to stay on."
  (unless global-remoto-mode
    (global-remoto-mode 1)
    (message "Remoto: `global-remoto-mode' enabled")))

;;;###autoload
(defun remoto-autoload-file-name-handler (operation &rest args)
  "Turn on `global-remoto-mode' for the first remoto path, then run OPERATION.
ARGS are the arguments of OPERATION.  The package autoloads register
this handler in `file-name-handler-alist', so a `/github:' or `/gh:'
path typed at a file prompt works before remoto is loaded, the way a
remote path loads TRAMP.  Calling it loads remoto; it then leaves the
alist for good, and `remoto--install' puts the real handler in front.

The call that brings remoto in runs without the advice `remoto--install'
adds, because the advice arrives while that call is already under way.
`expand-file-name' is what `find-file-noselect' asks first, and what it
gets back is the name it visits, so canonicalizing here gives that one
call the rewrite the advice would have given it.  A file prompt asks
`substitute-in-file-name' first instead, and a prompt is still being
typed into, so it is left alone."
  (remoto--drop-autoload-handler)
  (remoto--ensure-global-mode)
  (when (and (eq operation 'expand-file-name) (stringp (car args)))
    (setcar args (remoto--maybe-rewrite (car args))))
  (apply operation args))

;;;; Issue display (see remoto-topic.el for full implementation)

(declare-function remoto-topic-display "remoto-topic" (number repo-path))

(defun remoto--require-topic ()
  "Load remoto-topic if not already loaded.
Adds the package directory to `load-path' if needed."
  (unless (featurep 'remoto-topic)
    (when-let* ((dir (file-name-directory
                      (or load-file-name
                          (locate-library "remoto")
                          buffer-file-name))))
      (add-to-list 'load-path dir))
    (require 'remoto-topic)))

;;;; Unload

(defun remoto-unload-function ()
  "Turn `global-remoto-mode' off and drop the caches.
The bootstrap entry of the autoloads goes too: it is still there when
remoto was loaded some other way and the mode never turned on."
  (when global-remoto-mode
    (global-remoto-mode -1))
  (remoto--drop-autoload-handler)
  (clrhash remoto--tree-cache)
  (clrhash remoto--default-branch-cache)
  (clrhash remoto--search-cache)
  (clrhash remoto--listing-cache)
  (clrhash remoto--entry-cache)
  (clrhash remoto--pending-requests)
  (clrhash remoto--logins)
  (dolist (forge (seq-uniq (mapcar #'cdr remoto--forges)))
    (remoto-forge-forget-all forge))
  nil)

(provide 'remoto)

;; The forges that come with remoto load after the core they extend, as
;; magit's own libraries do; each registers itself when loaded.  They load
;; from this file's directory: an upgrade by package.el reloads this file
;; before that directory is on `load-path'.
(require 'remoto-github
         (expand-file-name "remoto-github" (file-name-directory (macroexp-file-name))))
(require 'remoto-forgejo
         (expand-file-name "remoto-forgejo" (file-name-directory (macroexp-file-name))))

;;; remoto.el ends here
