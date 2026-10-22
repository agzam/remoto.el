;;; remoto-github.el --- GitHub behind remoto's forge contract  -*- lexical-binding: t; -*-
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

;; The GitHub side of remoto: the REST endpoints behind each generic
;; function of the forge contract, the URL parsers, and `remoto-browse'.
;; Everything here speaks GitHub; the core never calls it directly.

;;; Code:

(require 'remoto)

;; remoto-topic loads on demand, through `remoto--require-topic'.
(declare-function remoto-topic-display "remoto-topic")

;;;; Repository data

(defun remoto--default-branch (owner repo)
  "Fetch the default branch for OWNER/REPO."
  (let ((data (remoto--api (format "repos/%s/%s" owner repo))))
    (alist-get 'default_branch data)))

(defvar remoto--branches-cache (make-hash-table :test 'equal)
  "Cache: \"owner/repo\" -> (TIMESTAMP . BRANCH-NAMES).")

(defvar remoto--users-cache (make-hash-table :test 'equal)
  "Cache: query string -> (TIMESTAMP . USER-NAMES).
Entries expire after `remoto-search-cache-ttl' seconds.")

(defvar remoto--content-cache (make-hash-table :test 'equal)
  "Cache: sha -> raw file bytes as a unibyte string.")

(defun remoto--fetch-file-content (owner repo path ref)
  "Fetch the raw bytes of the file at PATH in OWNER/REPO@REF.
Uses Contents API for files under 1MB, Blobs API otherwise.
Return a unibyte string; the caller decides how to decode it."
  (let* ((endpoint (format "repos/%s/%s/contents/%s?ref=%s"
                           owner repo
                           (url-hexify-string path) ref))
         (data (remoto--api endpoint))
         (sha (alist-get 'sha data))
         (cached (gethash sha remoto--content-cache)))
    (or cached
        (let* ((encoding (alist-get 'encoding data))
               (content
                (if (equal encoding "base64")
                    (let ((raw (alist-get 'content data)))
                      (base64-decode-string (string-replace "\n" "" raw)))
                  ;; Too large - use Blobs API
                  (remoto--fetch-blob owner repo sha))))
          (puthash sha content remoto--content-cache)
          content))))

(defun remoto--fetch-blob (owner repo sha)
  "Fetch a git blob by SHA from OWNER/REPO.  Return its raw bytes."
  (let* ((endpoint (format "repos/%s/%s/git/blobs/%s" owner repo sha))
         (data (remoto--api endpoint))
         (raw (alist-get 'content data)))
    (base64-decode-string (string-replace "\n" "" raw))))

(defun remoto--parse-github-url (input)
  "Parse GitHub web INPUT into a `remoto-path' struct."
  (cond
   ((string-match
     (rx bos "https://github.com/"
         (group (+ (not "/")))
         "/"
         (group (+ (not (in "/#"))))
         (? "/" (or "tree" "blob") "/"
            (group (+ (not "/")))
            (? "/" (group (+ (not "#")))))
         (* nonl)
         eos)
     input)
    (remoto-path-create
     :owner (match-string 1 input)
     :repo (let ((repo (match-string 2 input)))
             (if (string-suffix-p ".git" repo) (substring repo 0 -4) repo))
     :ref (match-string 3 input)
     :path (concat "/" (or (match-string 4 input) ""))))
   ((string-match
     (rx bos "https://github.com/"
         (group (+ (not "/")))
         "/"
         (group (+ (not (in "/#. "))))
         (* (in "/."))
         eos)
     input)
    (remoto-path-create
     :owner (match-string 1 input)
     :repo (match-string 2 input)
     :ref nil
     :path "/"))))

(defun remoto--parse-topic-url (input)
  "Return (OWNER REPO NUMBER) for a pull request or issue web URL INPUT.
Accepts the https and bare github.com forms.  Whatever follows the
number is ignored: /files, /commits, an #issuecomment fragment, a query.
Return nil for any other input."
  (when (string-match (rx bos (? "/") (? "https://") "github.com/"
                          (group (+ (not (in "/#?")))) "/"
                          (group (+ (not (in "/#?")))) "/"
                          (or "pull" "issues") "/"
                          (group (+ digit))
                          (or eos (in "/#?")))
                      input)
    (list (match-string 1 input) (match-string 2 input) (match-string 3 input))))

(defun remoto--parse-git-remote (input)
  "Parse git remote INPUT into a `remoto-path' struct."
  (when (string-match
         (rx bos "git@github.com:"
             (group (+ (not "/")))
             "/"
             (group (+ (not (in "/ "))))
             eos)
         input)
    (let ((repo (match-string 2 input)))
      (remoto-path-create
       :owner (match-string 1 input)
       :repo (if (string-suffix-p ".git" repo)
                 (substring repo 0 -4)
               repo)
       :ref nil
       :path "/"))))

(defun remoto--parse-repo-shorthand (input)
  "Parse owner/repo INPUT into a `remoto-path' struct."
  (when (string-match
         (rx bos
             (group (+ (not (in "/@"))))
             "/"
             (group (+ (not (in "/@"))))
             (? "@" (group (+ nonl)))
             eos)
         input)
    (remoto-path-create
     :owner (match-string 1 input)
     :repo (match-string 2 input)
     :ref (match-string 3 input)
     :path "/")))

(defun remoto--parse-input (input)
  "Normalize user INPUT into a `remoto-path' struct.
Accept GitHub URLs, git remote URLs, or owner/repo shorthand."
  (let ((input (string-trim input)))
    (or (remoto--parse-github-url input)
        (remoto--parse-git-remote input)
        (remoto--parse-repo-shorthand input)
        (user-error "Remoto: cannot parse input: %s" input))))

(defun remoto--search-query (input)
  "Build a GitHub search query string from INPUT.
When INPUT contains a slash, searches within that owner's repos.
Otherwise searches by repository name."
  (if-let* ((slash-pos (string-search "/" input))
            (owner (substring input 0 slash-pos))
            (repo-part (substring input (1+ slash-pos))))
      (if (string-empty-p repo-part)
          (format "user:%s" owner)
        (format "%s in:name user:%s" repo-part owner))
    (format "%s in:name" input)))

(defun remoto--fetch-branches (owner repo)
  "Fetch branch names for OWNER/REPO, cached per `remoto-search-cache-ttl'."
  (let* ((key (format "%s/%s" owner repo))
         (entry (gethash key remoto--branches-cache))
         (now (float-time)))
    (if (and entry
             (or (zerop remoto-search-cache-ttl)
                 (< (- now (car entry)) remoto-search-cache-ttl)))
        (cdr entry)
      (condition-case nil
          (let* ((endpoint (format "repos/%s/%s/branches" owner repo))
                 (data (remoto--paginated-api endpoint 100))
                 (branches (mapcar (lambda (item) (alist-get 'name item)) data)))
            (puthash key (cons now branches) remoto--branches-cache)
            branches)
        (user-error nil)))))

(defvar remoto--tags-cache (make-hash-table :test 'equal)
  "Cache for repository tags.  key -> (TIMESTAMP . TAGS-LIST).")

(defun remoto--fetch-tags (owner repo)
  "Fetch tag names for OWNER/REPO, cached per `remoto-search-cache-ttl'."
  (let* ((key (format "%s/%s" owner repo))
         (entry (gethash key remoto--tags-cache))
         (now (float-time)))
    (if (and entry
             (or (zerop remoto-search-cache-ttl)
                 (< (- now (car entry)) remoto-search-cache-ttl)))
        (cdr entry)
      (condition-case nil
          (let* ((endpoint (format "repos/%s/%s/tags" owner repo))
                 (data (remoto--paginated-api endpoint 100))
                 (tags (mapcar (lambda (item) (alist-get 'name item)) data)))
            (puthash key (cons now tags) remoto--tags-cache)
            tags)
        (user-error nil)))))

(defun remoto--forget-refs (repo-id)
  "Drop the cached branches and tags of REPO-ID, an OWNER/REPO."
  (remhash repo-id remoto--branches-cache)
  (remhash repo-id remoto--tags-cache))

(defvar remoto--issues-cache (make-hash-table :test 'equal)
  "Cache for issue listings.  key -> (TIMESTAMP . ISSUES-ALIST).")

(defun remoto--fetch-issues (owner repo)
  "Fetch open issues+PRs for OWNER/REPO, cached."
  (let* ((key (format "%s/%s" owner repo))
         (entry (gethash key remoto--issues-cache))
         (now (float-time)))
    (if (and entry
             (or (zerop remoto-search-cache-ttl)
                 (< (- now (car entry)) remoto-search-cache-ttl)))
        (cdr entry)
      (condition-case nil
          (let* ((endpoint (format "repos/%s/%s/issues?state=open&sort=updated&per_page=30"
                                   owner repo))
                 (data (remoto--api endpoint)))
            (puthash key (cons now data) remoto--issues-cache)
            data)
        (user-error nil)))))

(defun remoto--search-issues (owner repo query)
  "Search issues+PRs in OWNER/REPO matching QUERY."
  (condition-case nil
      (let* ((endpoint (format "search/issues?q=%s+repo:%s/%s&per_page=30"
                               (url-hexify-string query) owner repo))
             (data (remoto--api endpoint)))
        (alist-get 'items data))
    (user-error nil)))

(defun remoto--fetch-issue (owner repo number)
  "Fetch single issue NUMBER from OWNER/REPO."
  (condition-case nil
      (remoto--api (format "repos/%s/%s/issues/%s" owner repo number))
    (user-error nil)))

(defun remoto--fetch-issue-comments (owner repo number)
  "Fetch comments for issue NUMBER from OWNER/REPO.
Returns list of comment alists, or nil on error."
  (condition-case nil
      (remoto--api (format "repos/%s/%s/issues/%s/comments" owner repo number))
    (user-error nil)))

(defvar remoto--file-commits-cache (make-hash-table :test 'equal)
  "Cache for per-file last commit messages.
Key: \"owner/repo@ref:dir\", Value: (TIMESTAMP . ALIST).
ALIST maps filename -> first line of commit message.")

(defun remoto--fetch-file-commits (owner repo ref dir-path children)
  "Fetch last commit message for each file in CHILDREN.
DIR-PATH is the directory path within OWNER/REPO at REF.
CHILDREN is a list of filenames.  Returns alist of (name . msg).
Cached per `remoto-search-cache-ttl'.  Capped at 20 API calls."
  (let* ((key (format "%s/%s@%s:%s" owner repo ref dir-path))
         (entry (gethash key remoto--file-commits-cache))
         (now (float-time)))
    (if (and entry
             (or (zerop remoto-search-cache-ttl)
                 (< (- now (car entry)) remoto-search-cache-ttl)))
        (cdr entry)
      (condition-case nil
          (let ((result nil))
            (dolist (child (seq-take children 20))
              (let* ((bare-name (string-trim-right child "/"))
                     (file-path (if (string-empty-p dir-path)
                                    bare-name
                                  (concat dir-path "/" bare-name)))
                     (endpoint (format "repos/%s/%s/commits?sha=%s&path=%s&per_page=1"
                                       owner repo
                                       (url-hexify-string ref)
                                       (url-hexify-string file-path)))
                     (commits (remoto--api endpoint)))
                (when-let* ((first (car commits))
                            (c (alist-get 'commit first))
                            (raw (alist-get 'message c))
                            (msg (car (split-string raw "\n" t))))
                  (push (cons child msg) result))))
            (puthash key (cons now result) remoto--file-commits-cache)
            result)
        (error nil)))))

(defun remoto--fetch-user-orgs (_user)
  "Fetch organization memberships for the authenticated user.
Uses /user/orgs which includes private memberships.
Returns propertized login strings with type and description."
  (condition-case nil
      (let ((data (remoto--paginated-api "user/orgs" 100)))
        (mapcar (lambda (item)
                  (propertize (alist-get 'login item)
                              'remoto-acct-type "Organization"
                              'remoto-acct-desc
                              (or (alist-get 'description item) "")))
                data))
    (user-error nil)))

(defun remoto--remember-repo (prefix full-name item)
  "Remember the Dired line and default branch of the repository ITEM.
PREFIX is the prefix of its forge and FULL-NAME its OWNER/REPO; ITEM
comes from a list or a search endpoint."
  (when full-name
    (remoto--remember (concat prefix full-name)
                      (cdr (remoto--repo-entry item)))
    (when-let* ((branch (alist-get 'default_branch item)))
      (puthash full-name branch remoto--default-branch-cache))))

(defun remoto--account-entries (dir)
  "Return listing entries for the account of the token and its organizations.
DIR is the root being listed.  Signal a `user-error' without a token,
since no other request names them."
  (let ((user (or (remoto--get-authenticated-user)
                  (user-error "Remoto: %s lists your account and \
organizations, which needs a GitHub token" dir))))
    (mapcar (lambda (account)
              (let ((type (or (get-text-property 0 'remoto-acct-type account)
                              "User"))
                    (desc (get-text-property 0 'remoto-acct-desc account)))
                (cons (substring-no-properties account)
                      `((type . "tree")
                        (note . ,(if (and desc (not (string-empty-p desc)))
                                     (concat type "  " desc)
                                   type))))))
            (cons user (remoto--fetch-user-orgs user)))))

(defun remoto--owner-endpoint (prefix owner)
  "Return the endpoint that lists OWNER's repositories, newest push first.
The account of the token and its organizations have endpoints that list
private repositories too; any other account lists its public ones.
PREFIX names the root whose listing holds the organizations."
  (let ((user (remoto--get-authenticated-user)))
    (cond
     ((null user) (format "users/%s/repos?sort=pushed" owner))
     ((string-equal-ignore-case owner user)
      "user/repos?affiliation=owner&sort=pushed")
     ((seq-some (lambda (entry) (string-equal-ignore-case owner (car entry)))
                (cdr (remoto--listing-entries (remoto--listing prefix))))
      (format "orgs/%s/repos?sort=pushed" owner))
     (t (format "users/%s/repos?sort=pushed" owner)))))

(defun remoto--listing-page-endpoint (endpoint page)
  "Return ENDPOINT for its PAGE of `remoto--listing-page-size' items."
  (format "%s&per_page=%d&page=%d" endpoint remoto--listing-page-size page))

(defun remoto--repo-entry (item)
  "Return the listing entry for ITEM, a repository from a list endpoint.
Its last push is the date and its size counts bytes.  A private one is
drwx------, an archived one dr-xr-xr-x, and a fork says so in its note."
  (let ((time (or (alist-get 'pushed_at item) (alist-get 'created_at item))))
    (cons (alist-get 'name item)
          `((type . "tree")
            (size . ,(* 1024 (or (alist-get 'size item) 0)))
            (perms . ,(concat (if (alist-get 'archived item) "dr-x" "drwx")
                              (if (alist-get 'private item) "------" "r-xr-x")))
            (time . ,(and time (encode-time (iso8601-parse time))))
            (note . ,(string-trim
                      (concat (and (alist-get 'fork item) "fork  ")
                              (alist-get 'description item))))))))

(defun remoto--add-listing-page (listing dir owner items)
  "Add ITEMS, one page of OWNER's repositories, to LISTING, the one of DIR.
Each repository is remembered on the way, so opening a listed one asks
for nothing but its tree."
  (dolist (item items)
    (remoto--remember-repo (remoto--prefix (remoto--canonical-forge dir))
                           (format "%s/%s" owner (alist-get 'name item)) item))
  (let ((entries (append (remoto--listing-entries listing)
                         (mapcar #'remoto--repo-entry items))))
    (setf (remoto--listing-entries listing) (seq-take entries remoto-listing-cap)
          (remoto--listing-state listing)
          (cond ((< remoto-listing-cap (length entries)) 'capped)
                ((< (length items) remoto--listing-page-size) nil)
                ((< (length entries) remoto-listing-cap) 'fetching)
                (t 'capped)))))

(defun remoto--fetch-owner-listing (dir)
  "Fetch the first page of the owner listing DIR and cache the listing.
When more pages follow, they load in the background."
  (let* ((parsed (remoto--parse dir))
         (owner (remoto-path-owner parsed))
         (endpoint (remoto--owner-endpoint (remoto--path-prefix parsed) owner))
         (items (remoto--api (remoto--listing-page-endpoint endpoint 1)))
         (listing (puthash dir (remoto--listing-create) remoto--listing-cache)))
    (remoto--add-listing-page listing dir owner items)
    (when (eq (remoto--listing-state listing) 'fetching)
      (message "Remoto: listing the first %d repositories of %s, fetching the rest"
               (length items) owner)
      (remoto--fetch-listing-page dir listing owner endpoint 2))
    listing))

(defun remoto--fetch-listing-page (dir listing owner endpoint page)
  "Fetch PAGE of ENDPOINT into LISTING, the listing of DIR, in the background.
One page at a time, as GitHub asks of clients, until the last page, the
cap or a failure.  A LISTING no longer cached, as after `remoto-refresh',
ends it; OWNER names the account for the cache and the messages."
  (remoto--api-async
   (remoto--listing-page-endpoint endpoint page)
   (lambda (items)
     (when (eq listing (gethash dir remoto--listing-cache))
       (remoto--add-listing-page listing dir owner items)
       (if (eq (remoto--listing-state listing) 'fetching)
           (remoto--fetch-listing-page dir listing owner endpoint (1+ page))
         (remoto--listing-done dir listing owner))))
   (lambda ()
     (when (eq listing (gethash dir remoto--listing-cache))
       (setf (remoto--listing-state listing) 'failed)
       (remoto--listing-done dir listing owner)))))

(defun remoto--account-search (query)
  "Return the logins of the accounts in a search for QUERY.
Not from completion's cache: that may hold a shorter query's top 30
narrowed down, which can lack QUERY itself.  The search is cached apart,
and a failure signals instead of matching none."
  (let ((key (concat "\0users-search:" (downcase query))))
    (pcase-let ((`(,hit ,logins) (remoto--search-cache-get key)))
      (if hit
          logins
        (remoto--search-cache-put
         key (remoto--extract-search-users
              (remoto--api (format "search/users?q=%s&per_page=100"
                                   (url-hexify-string query)))))))))

(defun remoto--extract-search-users (data)
  "Return the logins in the user search DATA, each with its account type."
  (mapcar (lambda (item)
            (propertize (alist-get 'login item)
                        'remoto-acct-type (or (alist-get 'type item) "")))
          (alist-get 'items data)))

(defun remoto--search-users (prefix)
  "Search GitHub users/orgs matching PREFIX, never blocking.
Returns cached or locally-narrowed results immediately.  On cache
miss, schedules a debounced async fetch and returns nil; the
completion UI refreshes when results arrive.
Requires at least `remoto-min-search-chars' characters."
  (when-let* (((<= remoto-min-search-chars (length prefix)))
              (prefix-down (downcase prefix)))
    ;; Check exact cache hit
    (pcase-let ((`(,hit ,results) (remoto--search-cache-get
                                    (concat "\0users:" prefix-down))))
      (if hit results
        ;; Try narrowing from a shorter cached query
        (let ((narrowed
               (cl-loop for key being the hash-keys of remoto--users-cache
                        for entry = (gethash key remoto--users-cache)
                        when (and entry
                                  (string-prefix-p key prefix-down)
                                  (< (length key) (length prefix-down))
                                  (or (zerop remoto-search-cache-ttl)
                                      (< (- (float-time) (car entry))
                                         remoto-search-cache-ttl)))
                        return (seq-filter
                                (lambda (u)
                                  (string-prefix-p prefix-down (downcase u)))
                                (cdr entry)))))
          (if narrowed
              (progn
                (puthash (concat "\0users:" prefix-down)
                         (cons (float-time) narrowed)
                         remoto--search-cache)
                narrowed)
            ;; Schedule async fetch instead of blocking
            (remoto--debounce
             (concat "\0users:" prefix-down)
             (lambda ()
               (remoto--api-async
                (format "search/users?q=%s&per_page=30"
                        (url-hexify-string prefix))
                (lambda (data)
                  (let ((results (remoto--extract-search-users data)))
                    (puthash prefix-down (cons (float-time) results)
                             remoto--users-cache)
                    (puthash (concat "\0users:" prefix-down)
                             (cons (float-time) results)
                             remoto--search-cache)
                    (remoto--refresh-minibuffer-completions))))))
            nil))))))

(defvar remoto--prefetch-timer nil
  "Idle timer for speculative repo pre-fetching.")

(defun remoto--prefetch-owner-repos (owner)
  "Pre-fetch recent repos for OWNER asynchronously.
Cancels any previously scheduled pre-fetch.  Uses the async API
so it never blocks typing."
  (when remoto--prefetch-timer
    (cancel-timer remoto--prefetch-timer))
  (let ((cache-key (format "\0repos-recent:%s" (downcase owner))))
    (setq remoto--prefetch-timer
          (run-with-idle-timer
           0.001 nil
           (lambda ()
             (setq remoto--prefetch-timer nil)
             (let ((q (url-hexify-string (format "user:%s" owner))))
               (remoto--api-async
                (format "search/repositories?q=%s&sort=updated&per_page=30" q)
                (lambda (data)
                  (let ((repos (mapcar
                                (lambda (item)
                                  (propertize (alist-get 'name item)
                                              'remoto-repo-desc
                                              (or (alist-get 'description item) "")))
                                (alist-get 'items data))))
                    (remoto--search-cache-put cache-key repos))))))))))

(defun remoto--recent-owner-repos (owner)
  "Return cached recent repos for OWNER, scheduling async refresh.
Uses `remoto-repo-cache-ttl' for longer caching.  Returns cached
results immediately (may be nil on first access); an async fetch
updates the cache and refreshes the completion UI."
  (let* ((cache-key (format "\0repos-recent:%s" (downcase owner))))
    (pcase-let ((`(,hit ,results) (remoto--search-cache-get
                                    cache-key remoto-repo-cache-ttl)))
      (if hit
          ;; Cache hit - return immediately, schedule background refresh
          ;; if cache is older than the short TTL (stale but usable)
          (let ((entry (gethash cache-key remoto--search-cache)))
            (when (and entry
                       (< remoto-search-cache-ttl (- (float-time) (car entry))))
              (remoto--async-refresh-recent-repos owner cache-key))
            results)
        ;; Cache miss - schedule async fetch, return nil
        (remoto--async-refresh-recent-repos owner cache-key)
        nil))))

(defun remoto--extract-search-repos (data &optional name-key)
  "Extract propertized repo names from GitHub search DATA.
NAME-KEY selects the JSON field for the repo name (default `name').
Each repository is remembered on the way, so that a search match gets a
Dired line and opens like a line of a listing."
  (mapcar (lambda (item)
            (remoto--remember-repo (remoto--prefix remoto--github)
                                   (alist-get 'full_name item) item)
            (propertize (alist-get (or name-key 'name) item)
                        'remoto-repo-desc
                        (or (alist-get 'description item) "")))
          (alist-get 'items data)))

(defun remoto--async-refresh-recent-repos (owner cache-key)
  "Fire async fetch of OWNER's recent repos, updating CACHE-KEY."
  (remoto--debounce
   cache-key
   (lambda ()
     (let ((q (url-hexify-string (format "user:%s" owner))))
       (remoto--api-async
        (format "search/repositories?q=%s&sort=updated&per_page=30" q)
        (lambda (data)
          (let ((repos (remoto--extract-search-repos data)))
            (remoto--search-cache-put cache-key repos)
            (remoto--refresh-minibuffer-completions))))))))

(defun remoto--search-owner-repos (owner query)
  "Search OWNER's repos matching QUERY, never blocking.
Returns cached or locally-narrowed results immediately.  On cache
miss, schedules a debounced async fetch and returns nil.
Requires at least `remoto-min-search-chars' characters in QUERY.
Also narrows from the recent-repos cache when available."
  (if (< (length query) remoto-min-search-chars)
      ;; Below threshold: try narrowing from the recent-repos cache
      (when-let* ((recent-key (format "\0repos-recent:%s" (downcase owner)))
                  (entry (gethash recent-key remoto--search-cache))
                  ((or (zerop remoto-repo-cache-ttl)
                       (< (- (float-time) (car entry)) remoto-repo-cache-ttl))))
        (seq-filter (lambda (r) (string-search (downcase query) (downcase r)))
                    (cdr entry)))
    (let* ((owner-down (downcase owner))
         (query-down (downcase query))
         (cache-key (format "\0repos:%s/%s" owner-down query-down)))
    (pcase-let ((`(,hit ,results) (remoto--search-cache-get cache-key)))
      (if hit results
        ;; Try narrowing from a shorter search query cache (reliable)
        (let ((search-narrowed
               (cl-loop for len from (1- (length query-down)) downto 1
                        for prefix = (substring query-down 0 len)
                        for pk = (format "\0repos:%s/%s" owner-down prefix)
                        for entry = (gethash pk remoto--search-cache)
                        when (and entry
                                  (or (zerop remoto-search-cache-ttl)
                                      (< (- (float-time) (car entry))
                                         remoto-search-cache-ttl)))
                        return (seq-filter
                                (lambda (r)
                                  (string-search query-down (downcase r)))
                                (cdr entry)))))
          (if search-narrowed
              ;; Narrowed from a real search result - reliable, cache it
              (remoto--search-cache-put cache-key search-narrowed)
            ;; No search cache to narrow from. Show preview from
            ;; recent-repos (if any) but always schedule the real
            ;; search since recent-repos is only 30 items.
            (let ((preview
                   (when-let* ((recent-key (format "\0repos-recent:%s" owner-down))
                               (entry (gethash recent-key remoto--search-cache))
                               ((or (zerop remoto-repo-cache-ttl)
                                    (< (- (float-time) (car entry))
                                       remoto-repo-cache-ttl))))
                     (seq-filter (lambda (r)
                                   (string-search query-down (downcase r)))
                                 (cdr entry)))))
              ;; Always schedule async search for full results
              (remoto--debounce
               cache-key
               (lambda ()
                 (let ((q (url-hexify-string
                           (format "%s in:name user:%s" query owner))))
                   (remoto--api-async
                    (format "search/repositories?q=%s&per_page=100" q)
                    (lambda (data)
                      (let ((repos (remoto--extract-search-repos data)))
                        (remoto--search-cache-put cache-key repos)
                        (remoto--refresh-minibuffer-completions)))))))
              ;; Return preview immediately (may be nil)
              preview))))))))

(defun remoto--recent-owner-repos-sync (owner)
  "Synchronously fetch recent repos for OWNER, caching the result.
Intended for use inside `while-no-input' as a fallback when the
async path returned nil on a cold cache."
  (condition-case nil
      (let* ((cache-key (format "\0repos-recent:%s" (downcase owner)))
             (q (url-hexify-string (format "user:%s" owner)))
             (data (remoto--api
                    (format "search/repositories?q=%s&sort=updated&per_page=30"
                            q))))
        (when data
          (let ((repos (remoto--extract-search-repos data)))
            (remoto--search-cache-put cache-key repos)
            repos)))
    (error nil)))

(defun remoto--fetch-owner-search (owner query)
  "Search OWNER's repos for QUERY in their names and cache the names."
  (when-let* ((data (remoto--api
                     (format "search/repositories?q=%s&per_page=100"
                             (url-hexify-string
                              (format "%s in:name user:%s" query owner))))))
    (remoto--search-cache-put
     (format "\0repos:%s/%s" (downcase owner) (downcase query))
     (remoto--extract-search-repos data))))

(defun remoto--owner-search (owner query)
  "Return the names of OWNER's repositories that match QUERY in a search.
The search that completion at /github:OWNER/ ran answers from its cache.
Without one it runs here, where a failure signals instead of matching none."
  (pcase-let ((`(,hit ,names) (remoto--search-cache-get
                               (format "\0repos:%s/%s" (downcase owner)
                                       (downcase query)))))
    (if hit names (remoto--fetch-owner-search owner query))))

(defun remoto--complete-branches (query at-pos)
  "Complete branch names for QUERY with @ at AT-POS.
Returns owner/repo@branch candidates matching the prefix after @."
  (let* ((repo-part (substring query 0 at-pos))
         (branch-prefix (substring query (1+ at-pos))))
    (when (string-match
           (rx bos (group (+ (not "/"))) "/" (group (+ nonl)) eos)
           repo-part)
      (when-let* ((branches (remoto--fetch-branches
                             (match-string 1 repo-part)
                             (match-string 2 repo-part))))
        (thread-last branches
          (seq-filter (lambda (b)
                        (or (string-empty-p branch-prefix)
                            (string-prefix-p branch-prefix b))))
          (mapcar (lambda (b) (format "%s@%s" repo-part b))))))))

(defun remoto--qualify-repos (owner names)
  "Prefix each bare repo NAME in NAMES with OWNER/, preserving properties.
The shared owner-repo search returns bare repo names; `remoto-browse'
presents them as OWNER/REPO while keeping the `remoto-repo-desc' text
property used for annotations."
  (mapcar (lambda (name)
            (apply #'propertize (concat owner "/" name)
                   (text-properties-at 0 name)))
          names))

(defun remoto--search-repos-by-name (query)
  "Search repositories by name for a plain, ownerless QUERY.
Returns owner/repo strings.  On cache miss schedules a debounced
async fetch and returns nil; the UI refreshes when results arrive.
Requires at least `remoto-min-search-chars' characters."
  (when (<= remoto-min-search-chars (length query))
    (pcase-let ((`(,hit ,results) (remoto--search-cache-get query)))
      (if hit
          results
        (remoto--debounce
         (concat "\0browse:" query)
         (lambda ()
           (remoto--api-async
            (format "search/repositories?q=%s&per_page=100"
                    (url-hexify-string (remoto--search-query query)))
            (lambda (data)
              (let ((results (remoto--extract-search-repos data 'full_name)))
                (remoto--search-cache-put query results)
                (remoto--refresh-minibuffer-completions))))))
        nil))))

(defun remoto--search-repos-fetch (query)
  "Return repo candidates for QUERY as owner/repo strings, never blocking.
An OWNER/REPO-prefix query is delegated to the shared
`remoto--search-owner-repos' engine (the same code path the
`/github:' file-name completion uses), so results stay correct and
consistent across both entry points; its bare repo names are
reformatted to OWNER/REPO.  An OWNER/ query (no repo part) lists the
owner's recent repos.  A plain query searches repositories by name."
  (let ((slash-pos (string-search "/" query)))
    (cond
     ((null slash-pos) (remoto--search-repos-by-name query))
     ((zerop slash-pos) nil)
     (t (let ((owner (substring query 0 slash-pos))
              (repo-q (substring query (1+ slash-pos))))
          (remoto--qualify-repos
           owner
           (if (string-empty-p repo-q)
               (remoto--recent-owner-repos owner)
             (remoto--search-owner-repos owner repo-q))))))))

(defun remoto--search-repos (query &optional callback)
  "Search GitHub repositories matching QUERY.
Returns a list of owner/repo strings.  Requires at least 3 characters.
When QUERY contains `@', completes branch names for the specified repo.

When CALLBACK is non-nil, passes results to it instead of returning
them directly.  This supports consult's async dynamic collection
protocol."
  (let* ((at-pos (string-search "@" query))
         (results (if at-pos
                      (remoto--complete-branches query at-pos)
                    (remoto--search-repos-fetch query))))
    (if callback
        (funcall callback results)
      results)))

(defvar remoto--browse-history nil
  "Minibuffer history for `remoto-browse'.")

(defun remoto--browse-parse-input (string)
  "Parse STRING from `remoto-browse' into (MODE OWNER REPO QUERY).
MODE is one of `search', `branches', `issues'.
OWNER+REPO are non-nil for @ and # modes.
QUERY is the text after the delimiter."
  (cond
   ;; owner/repo#query - issues mode
   ((string-match (rx bos (group (+ (not (in "/@#"))))
                      "/" (group (+ (not (in "/@#"))))
                      "#" (group (* anything)) eos)
                  string)
    (list 'issues (match-string 1 string)
          (match-string 2 string) (match-string 3 string)))
   ;; owner/repo@query - branches mode
   ((string-match (rx bos (group (+ (not (in "/@#"))))
                      "/" (group (+ (not (in "/@#"))))
                      "@" (group (* anything)) eos)
                  string)
    (list 'branches (match-string 1 string)
          (match-string 2 string) (match-string 3 string)))
   ;; owner/repo/[subpath] - files mode
   ((string-match (rx bos (group (+ (not (in "/@#"))))
                      "/" (group (+ (not (in "/@#"))))
                      "/" (group (* anything)) eos)
                  string)
    (list 'files (match-string 1 string)
          (match-string 2 string) (match-string 3 string)))
   ;; plain search
   (t (list 'search nil nil string))))

(defun remoto--browse-completions (string)
  "Return completion candidates for STRING in `remoto-browse'.
Handles search, branch, and issue modes."
  (pcase-let ((`(,mode ,owner ,repo ,query) (remoto--browse-parse-input string))
              (root (remoto--prefix remoto--github)))
    (pcase mode
      ('issues
       (let* ((prefix (format "%s/%s#" owner repo))
              (issues
               (cond
                ((string-empty-p query)
                 (while-no-input (remoto--fetch-issues owner repo)))
                ((string-match-p (rx bos (+ digit) eos) query)
                 (let* ((cached (while-no-input
                                  (remoto--fetch-issues owner repo)))
                        (direct (while-no-input
                                  (remoto--fetch-issue owner repo query)))
                        (results (if (listp cached) cached nil)))
                   (if (consp direct)
                       (cl-remove-duplicates
                        (cons direct results)
                        :key (lambda (i) (alist-get 'number i)))
                     results)))
                (t (while-no-input
                     (remoto--search-issues owner repo query))))))
         (when (listp issues)
           (let ((candidates
                  (mapcar (lambda (i)
                            (let* ((num (number-to-string (alist-get 'number i)))
                                   (is-pr (and (alist-get 'pull_request i) t))
                                   (title (or (alist-get 'title i) ""))
                                   (state (or (alist-get 'state i) "")))
                              (propertize (concat prefix num)
                                          'remoto-topic-pr is-pr
                                          'remoto-topic-title title
                                          'remoto-topic-state state
                                          'remoto-target
                                          (format "%s%s/%s#%s"
                                                  root owner repo num))))
                          issues)))
             (sort candidates
                   (lambda (a b)
                     (let ((a-pr (get-text-property 0 'remoto-topic-pr a))
                           (b-pr (get-text-property 0 'remoto-topic-pr b)))
                       (cond
                        ((and a-pr (not b-pr)) t)
                        ((and (not a-pr) b-pr) nil)
                        (t (> (string-to-number (replace-regexp-in-string ".*#" "" a))
                              (string-to-number (replace-regexp-in-string ".*#" "" b))))))))))))
      ('branches
       (let* ((prefix (format "%s/%s@" owner repo))
              (branches (while-no-input
                          (remoto--fetch-branches owner repo)))
              (tags (while-no-input
                      (remoto--fetch-tags owner repo))))
         (when (or (listp branches) (listp tags))
           (let ((branch-set (when (listp branches)
                               (mapcar (lambda (b)
                                         (propertize (concat prefix b)
                                                     'remoto-ref-type "branch"
                                                     'remoto-target
                                                     (format "%s%s/%s@%s:/"
                                                             root owner repo b)))
                                       branches)))
                 (tag-set (when (listp tags)
                            (mapcar (lambda (tg)
                                      (propertize (concat prefix tg)
                                                  'remoto-ref-type "tag"
                                                  'remoto-target
                                                  (format "%s%s/%s@%s:/"
                                                          root owner repo tg)))
                                    tags))))
             (seq-filter (lambda (r)
                           (or (string-empty-p query)
                               (string-prefix-p query
                                                (replace-regexp-in-string ".*@" "" r))))
                         (append branch-set tag-set))))))
      ('files
       (let* ((prefix (format "%s/%s/" owner repo))
              (branch (while-no-input
                        (remoto--default-branch owner repo))))
         (when (and (stringp branch) (not (equal branch t)))
           (let* ((subpath (if (string-search "/" query)
                               (file-name-directory query)
                             ""))
                  (file-part (if (string-search "/" query)
                                 (file-name-nondirectory query)
                               query))
                  (children (while-no-input
                              (remoto--fetch-dir-children-light
                               owner repo branch subpath)))
                  (names (when (listp children)
                           (mapcar (lambda (child)
                                     (let* ((name (car child))
                                            (dir? (equal "tree"
                                                         (alist-get 'type (cdr child))))
                                            (display (if dir? (concat name "/") name)))
                                       (propertize (concat prefix subpath display)
                                                   'remoto-target
                                                   (format "%s%s/%s@%s:/%s%s"
                                                           root owner repo branch
                                                           subpath display))))
                                   children))))
             (if (string-empty-p file-part)
                 names
               (seq-filter (lambda (n) (string-search file-part n)) names))))))
      ('search
       (mapcar (lambda (cand)
                 (let ((c (copy-sequence cand)))
                   (put-text-property 0 (length c) 'remoto-target
                                      (format "%s%s:/" root
                                              (substring-no-properties c))
                                      c)
                   c))
               (remoto--search-repos query))))))

(defun remoto--browse-metadata (string)
  "Return completion metadata alist for STRING in `remoto-browse'."
  (pcase (car (remoto--browse-parse-input string))
    ('issues
     (let ((group-fn (lambda (candidate transform)
                       (if transform candidate
                         (if (get-text-property 0 'remoto-topic-pr candidate)
                             "Pull Request"
                           "Issue"))))
           (affix-fn (lambda (candidates)
                       (remoto--affixate
                        (mapcar (lambda (c)
                                  (let ((title (or (get-text-property 0 'remoto-topic-title c) ""))
                                        (state (or (get-text-property 0 'remoto-topic-state c) ""))
                                        (is-pr (get-text-property 0 'remoto-topic-pr c)))
                                    (list c
                                          (if is-pr "PR " "   ")
                                          (format "%s [%s]" title state))))
                                candidates)))))
       `(metadata (category . remoto-browse)
                  (group-function . ,group-fn)
                  (affixation-function . ,affix-fn))))
    ('branches
     (let ((group-fn (lambda (candidate transform)
                       (if transform candidate
                         (if (equal "tag" (get-text-property 0 'remoto-ref-type candidate))
                             "Tag"
                           "Branch")))))
       `(metadata (category . remoto-browse)
                  (group-function . ,group-fn))))
    ('files
     '(metadata (category . remoto-browse)))
    ('search
     (let ((affix-fn (lambda (candidates)
                       (remoto--affixate
                        (mapcar (lambda (c)
                                  (let ((desc (or (get-text-property 0 'remoto-repo-desc c) "")))
                                    (list c "" desc)))
                                candidates)))))
       `(metadata (category . remoto-browse)
                  (affixation-function . ,affix-fn))))))

(defun remoto--repo-completion-table (string pred action)
  "Programmed completion table for GitHub repos, branches, and issues.
STRING is the current minibuffer input, PRED a filter predicate,
ACTION the completion action dispatched by `completing-read'.
Detects @ and # delimiters to switch between modes.
Styles that filter by `completion-regexp-list' pass an empty STRING (the
table has no boundaries); the minibuffer then supplies the query, and
`complete-with-action' applies the regexps to the resulting list."
  (cond
   ((eq action 'metadata) (remoto--browse-metadata string))
   ((eq (car-safe action) 'boundaries) nil)
   (t (let ((input (if (string-empty-p string)
                       (or (remoto--minibuffer-input) string)
                     string)))
        (complete-with-action action (remoto--browse-completions input)
                              string pred)))))

(defun remoto--read-repo ()
  "Read a GitHub repo from the minibuffer with search completion.
Type 3+ characters to trigger GitHub search.  Tab completes.
Append @ to complete branches/tags, # to browse issues/PRs.
URLs and owner/repo shorthand can be typed directly."
  (completing-read "GitHub repo: "
                   #'remoto--repo-completion-table
                   nil nil nil
                   'remoto--browse-history))

;;;###autoload
(defun remoto-browse (input)
  "Browse a GitHub repository without cloning.
INPUT can be any GitHub URL, git remote URL, or owner/repo shorthand.
Supports owner/repo#NUM to view issues/PRs and owner/repo@ref for
specific branches/tags.
With interactive use, provides search completion - type 3+ characters
to search GitHub repositories.
Turns on `global-remoto-mode' when it is off: the buffers this command
opens need the file-name handler for as long as they live."
  (interactive (progn (remoto--ensure-global-mode)
                      (list (remoto--read-repo))))
  (remoto--ensure-global-mode)
  ;; A pull request or issue web URL is the topic, not the repository root
  ;; the URL parser would make of it.
  (when-let* ((topic (remoto--parse-topic-url input)))
    (setq input (apply #'format "%s/%s#%s" topic)))
  (remoto--with-fetch-indicator
    (cond
     ;; Issue/PR mode: owner/repo#NUM
     ((string-match (rx bos (group (+ (not (in "/@#"))))
                        "/" (group (+ (not (in "/@#"))))
                        "#" (group (+ digit)) eos)
                    input)
      (let ((owner (match-string 1 input))
            (repo (match-string 2 input))
            (number (match-string 3 input)))
        (remoto--require-topic)
        (remoto-topic-display number (format "%s%s/%s" (remoto--prefix remoto--github)
                                             owner repo))))
     ;; Files mode: owner/repo/[subpath]
     ((string-match (rx bos (group (+ (not (in "/@#"))))
                        "/" (group (+ (not (in "/@#"))))
                        "/" (group (* anything)) eos)
                    input)
      (let* ((owner (match-string 1 input))
             (repo (match-string 2 input))
             (subpath (match-string 3 input))
             (canonical (remoto--maybe-rewrite
                         (format "%s%s/%s/%s" (remoto--prefix remoto--github)
                                 owner repo subpath))))
        (if (and (remoto--parse-path canonical)
                 (equal "tree"
                        (alist-get 'type
                                   (remoto--tree-entry
                                    (remoto--parse-path canonical)))))
            (dired canonical)
          (find-file canonical))))
     ;; Branch mode or plain repo
     (t
      (let* ((clean (if (string-match (rx bos (group (+ (not (in "/@#")))
                                                     "/" (+ (not (in "/@#"))))
                                          "@" (group (+ nonl)) eos)
                                      input)
                        (format "%s@%s" (match-string 1 input)
                                (match-string 2 input))
                      input))
             (parsed (remoto--parse-input clean))
             (resolved (remoto--resolve-ref parsed))
             (canonical (remoto--canonical-path resolved)))
        (if (equal "tree"
                   (alist-get 'type (remoto--tree-entry resolved)))
            (dired canonical)
          (find-file canonical)))))))

(defun remoto--github-input-p (input)
  "Return non-nil if INPUT can look like a GitHub URL or shorthand."
  (and (stringp input)
       (string-match-p
        (rx bos
            (or "https://github.com/"
                "git@github.com:"
                (or "github.com/" "/github.com/")))
        input)))


(defun remoto--fetch-tree (owner repo ref)
  "Fetch full tree for OWNER/REPO at REF from GitHub API.
Returns a hash table of path -> alist with keys type, size, sha, mode."
  (let* ((endpoint (format "repos/%s/%s/git/trees/%s?recursive=1" owner repo ref))
         (data (remoto--api endpoint))
         (entries (alist-get 'tree data))
         (truncated (alist-get 'truncated data))
         (table (make-hash-table :test 'equal :size (length entries))))
    (when (eq truncated t)
      (puthash "\0truncated" t table)
      (message "Remoto: tree truncated for %s/%s@%s, fetching dirs on demand"
               owner repo ref))
    ;; Root entry
    (puthash "" remoto--dir-entry table)
    (puthash "/" remoto--dir-entry table)
    ;; All entries from API
    (dolist (entry entries)
      (let ((path (alist-get 'path entry))
            (plist (list (cons 'type (alist-get 'type entry))
                         (cons 'size (or (alist-get 'size entry) 0))
                         (cons 'sha  (alist-get 'sha entry))
                         (cons 'mode (alist-get 'mode entry)))))
        (puthash path plist table)
        ;; Synthesize intermediate directories
        (let ((parts (split-string path "/" t)))
          (when (< 1 (length parts))
            (cl-loop for i from 1 below (length parts)
                     for dir = (mapconcat #'identity (seq-take parts i) "/")
                     unless (gethash dir table)
                     do (puthash dir remoto--dir-entry table))))))
    table))

(defun remoto--contents-entry (item)
  "Return the tree entry of ITEM, one object of the Contents API."
  (let ((type (if (equal (alist-get 'type item) "dir") "tree" "blob")))
    (list (cons 'type type)
          (cons 'size (or (alist-get 'size item) 0))
          (cons 'sha (or (alist-get 'sha item) ""))
          (cons 'mode (if (equal type "tree") "040000" "100644")))))

(defun remoto--fetch-directory-entries (owner repo ref dir)
  "Fetch DIR of OWNER/REPO at REF via the Contents API, as (PATH . ENTRY)."
  (let* ((endpoint (if (string-empty-p dir)
                       (format "repos/%s/%s/contents?ref=%s" owner repo ref)
                     (format "repos/%s/%s/contents/%s?ref=%s"
                             owner repo (url-hexify-string dir) ref)))
         (data (remoto--api endpoint)))
    ;; The Contents API answers a list of objects for a directory
    (when (and (consp data) (consp (caar data)))
      (mapcar (lambda (item)
                (cons (alist-get 'path item) (remoto--contents-entry item)))
              data))))

(defvar remoto--dir-contents-cache (make-hash-table :test 'equal)
  "Cache: \"owner/repo@ref:dir\" -> (TIMESTAMP . CHILDREN-LIST).
Stores lightweight directory listings from Contents API.")

(defun remoto--fetch-dir-children-light (owner repo ref dir-path)
  "Fetch direct children of DIR-PATH in OWNER/REPO@REF via Contents API.
Returns a list of (NAME . PLIST) pairs, capped at 20 entries.
Uses cache when available.  Much faster than recursive tree fetch."
  (let* ((key (format "%s/%s@%s:%s" owner repo ref (or dir-path "")))
         (entry (gethash key remoto--dir-contents-cache))
         (now (float-time)))
    (if (and entry
             (or (zerop remoto-search-cache-ttl)
                 (< (- now (car entry)) remoto-search-cache-ttl)))
        (cdr entry)
      (condition-case nil
          (let* ((endpoint (if (or (null dir-path) (string-empty-p dir-path))
                               (format "repos/%s/%s/contents?ref=%s"
                                       owner repo ref)
                             (format "repos/%s/%s/contents/%s?ref=%s"
                                     owner repo (url-hexify-string dir-path) ref)))
                 (data (remoto--api endpoint))
                 (children
                  (when (and (consp data) (consp (caar data)))
                    (mapcar (lambda (item)
                              (cons (alist-get 'name item)
                                    (remoto--contents-entry item)))
                            (seq-take data 20)))))
            (puthash key (cons now children) remoto--dir-contents-cache)
            children)
        (error nil)))))

(defun remoto--resolve-commit-sha (owner repo ref)
  "Resolve REF in OWNER/REPO to a commit SHA via the forge API.
Used for permalinks so the link survives the ref moving on."
  (let* ((data (remoto--api (format "repos/%s/%s/commits/%s" owner repo ref)))
         (sha (alist-get 'sha data)))
    (or sha
        (user-error "Remoto: could not resolve commit SHA for %s/%s@%s"
                    owner repo ref))))

(defun remoto--fetch-pull-request (owner repo number)
  "Fetch full PR data for NUMBER in OWNER/REPO.
Returns PR alist with merge status, diff stats, review state."
  (condition-case nil
      (remoto--api (format "repos/%s/%s/pulls/%s" owner repo number))
    (user-error nil)))

(defun remoto--fetch-reviews (owner repo number)
  "Fetch reviews for PR NUMBER in OWNER/REPO."
  (condition-case nil
      (remoto--api (format "repos/%s/%s/pulls/%s/reviews" owner repo number))
    (user-error nil)))

;;;; The contract

(cl-defmethod remoto-forge-default-ref ((_forge remoto-github) owner repo)
  "GitHub's `default-ref' for OWNER and REPO, see `remoto-forge-default-ref'."
  (remoto--default-branch owner repo))

(cl-defmethod remoto-forge-tree ((_forge remoto-github) owner repo ref)
  "GitHub's `tree' for OWNER, REPO and REF, see `remoto-forge-tree'."
  (remoto--fetch-tree owner repo ref))

(cl-defmethod remoto-forge-directory-contents ((_forge remoto-github) owner repo ref dir)
  "GitHub's `directory-contents' for OWNER, REPO, REF and DIR.
See `remoto-forge-directory-contents'."
  (remoto--fetch-directory-entries owner repo ref dir))

(cl-defmethod remoto-forge-children ((_forge remoto-github) owner repo ref dir)
  "GitHub's `children' for OWNER, REPO, REF and DIR.
See `remoto-forge-children'."
  (remoto--fetch-dir-children-light owner repo ref dir))

(cl-defmethod remoto-forge-content ((_forge remoto-github) owner repo ref path)
  "GitHub's `content' for OWNER, REPO, REF and PATH.
See `remoto-forge-content'."
  (remoto--fetch-file-content owner repo path ref))

(cl-defmethod remoto-forge-commit-sha ((_forge remoto-github) owner repo ref)
  "GitHub's `commit-sha' for OWNER, REPO and REF.
See `remoto-forge-commit-sha'."
  (remoto--resolve-commit-sha owner repo ref))

(cl-defmethod remoto-forge-branches ((_forge remoto-github) owner repo)
  "GitHub's `branches' for OWNER and REPO, see `remoto-forge-branches'."
  (remoto--fetch-branches owner repo))

(cl-defmethod remoto-forge-tags ((_forge remoto-github) owner repo)
  "GitHub's `tags' for OWNER and REPO, see `remoto-forge-tags'."
  (remoto--fetch-tags owner repo))

(cl-defmethod remoto-forge-forget-refs ((_forge remoto-github) owner repo)
  "GitHub's `forget-refs' for OWNER and REPO, see `remoto-forge-forget-refs'."
  (remoto--forget-refs (format "%s/%s" owner repo)))

(cl-defmethod remoto-forge-topics ((_forge remoto-github) owner repo)
  "GitHub's `topics' for OWNER and REPO, see `remoto-forge-topics'."
  (remoto--fetch-issues owner repo))

(cl-defmethod remoto-forge-search-topics ((_forge remoto-github) owner repo query)
  "GitHub's `search-topics' for OWNER, REPO and QUERY.
See `remoto-forge-search-topics'."
  (remoto--search-issues owner repo query))

(cl-defmethod remoto-forge-topic ((_forge remoto-github) owner repo number)
  "GitHub's `topic' for OWNER, REPO and NUMBER, see `remoto-forge-topic'."
  (remoto--fetch-issue owner repo number))

(cl-defmethod remoto-forge-topic-comments ((_forge remoto-github) owner repo number)
  "GitHub's `topic-comments' for OWNER, REPO and NUMBER.
See `remoto-forge-topic-comments'."
  (remoto--fetch-issue-comments owner repo number))

(cl-defmethod remoto-forge-pull-request ((_forge remoto-github) owner repo number)
  "GitHub's `pull-request' for OWNER, REPO and NUMBER.
See `remoto-forge-pull-request'."
  (remoto--fetch-pull-request owner repo number))

(cl-defmethod remoto-forge-reviews ((_forge remoto-github) owner repo number)
  "GitHub's `reviews' for OWNER, REPO and NUMBER, see `remoto-forge-reviews'."
  (remoto--fetch-reviews owner repo number))

(cl-defmethod remoto-forge-file-commits ((_forge remoto-github) owner repo ref dir names)
  "GitHub's `file-commits' for OWNER, REPO, REF, DIR and NAMES.
See `remoto-forge-file-commits'."
  (remoto--fetch-file-commits owner repo ref dir names))

(cl-defmethod remoto-forge-user ((_forge remoto-github))
  "GitHub's `user', see `remoto-forge-user'."
  (remoto--get-authenticated-user))

(cl-defmethod remoto-forge-user-orgs ((_forge remoto-github) user)
  "GitHub's `user-orgs' for USER, see `remoto-forge-user-orgs'."
  (remoto--fetch-user-orgs user))

(cl-defmethod remoto-forge-search-accounts ((_forge remoto-github) query wait)
  "GitHub's `search-accounts' for QUERY and WAIT.
See `remoto-forge-search-accounts'."
  (if wait
      (remoto--account-search query)
    (remoto--search-users query)))

(cl-defmethod remoto-forge-recent-repos ((_forge remoto-github) owner wait)
  "GitHub's `recent-repos' for OWNER and WAIT, see `remoto-forge-recent-repos'."
  (if wait
      (remoto--recent-owner-repos-sync owner)
    (remoto--recent-owner-repos owner)))

(cl-defmethod remoto-forge-search-repos ((_forge remoto-github) owner query wait)
  "GitHub's `search-repos' for OWNER, QUERY and WAIT.
See `remoto-forge-search-repos'."
  (if wait
      (remoto--owner-search owner query)
    (remoto--search-owner-repos owner query)))

(cl-defmethod remoto-forge-prefetch-repos ((_forge remoto-github) owner)
  "GitHub's `prefetch-repos' for OWNER, see `remoto-forge-prefetch-repos'."
  (remoto--prefetch-owner-repos owner))

(cl-defmethod remoto-forge-account-entries ((_forge remoto-github) dir)
  "GitHub's `account-entries' for DIR, see `remoto-forge-account-entries'."
  (remoto--account-entries dir))

(cl-defmethod remoto-forge-owner-listing ((_forge remoto-github) dir)
  "GitHub's `owner-listing' for DIR, see `remoto-forge-owner-listing'."
  (remoto--fetch-owner-listing dir))

(cl-defmethod remoto-forge-forget-all ((_forge remoto-github))
  "GitHub's `forget-all', see `remoto-forge-forget-all'."
  (dolist (cache (list remoto--branches-cache remoto--users-cache
                       remoto--content-cache remoto--tags-cache
                       remoto--issues-cache remoto--file-commits-cache
                       remoto--dir-contents-cache))
    (clrhash cache)))

(cl-defmethod remoto-forge-url-input-p ((_forge remoto-github) input)
  "GitHub's `url-input-p' for INPUT, see `remoto-forge-url-input-p'."
  (remoto--github-input-p input))

(cl-defmethod remoto-forge-parse-url ((_forge remoto-github) input)
  "GitHub's `parse-url' for INPUT, see `remoto-forge-parse-url'."
  (let* ((clean (replace-regexp-in-string "\\`/?" "" input))
         (clean (if (string-match-p "\\`github\\.com/" clean)
                    (concat "https://" clean)
                  clean)))
    (condition-case nil
        (remoto--parse-input clean)
      (error nil))))

(cl-defmethod remoto-forge-parse-topic-url ((_forge remoto-github) input)
  "GitHub's `parse-topic-url' for INPUT, see `remoto-forge-parse-topic-url'."
  (remoto--parse-topic-url input))

(provide 'remoto-github)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-github.el ends here
