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
;; function of the forge contract and the URL parsers.
;; Every function takes the forge it speaks for, so a forge whose API
;; copies GitHub's (remoto-forgejo.el) inherits them against its own host.

;;; Code:

(require 'remoto)

;;;; Where GitHub's REST dialect differs from its copies

(cl-defgeneric remoto--search-items (_forge data)
  "Return the items of DATA, the answer of a search endpoint of FORGE."
  (alist-get 'items data))

(cl-defgeneric remoto--account-search-endpoint (forge query count)
  "Return the account search endpoint of FORGE for QUERY, COUNT results at most."
  (format "search/users?q=%s&%s" (url-hexify-string query)
          (remoto--page-params forge count)))

(cl-defgeneric remoto--repo-search-endpoint (forge owner query count)
  "Return the search endpoint of FORGE for QUERY among OWNER's repositories.
An empty QUERY asks for the COUNT most recently updated ones."
  (if (string-empty-p query)
      (format "search/repositories?q=%s&sort=updated&%s"
              (url-hexify-string (format "user:%s" owner))
              (remoto--page-params forge count))
    (format "search/repositories?q=%s&%s"
            (url-hexify-string (format "%s in:name user:%s" query owner))
            (remoto--page-params forge count))))

;;;; Repository data

(defvar remoto--branches-cache (make-hash-table :test 'equal)
  "Cache: `remoto--repo-id' -> (TIMESTAMP . BRANCH-NAMES).")

(defvar remoto--users-cache (make-hash-table :test 'equal)
  "Cache: forge prefix and query string -> (TIMESTAMP . USER-NAMES).
Entries expire after `remoto-search-cache-ttl' seconds.")

(defvar remoto--content-cache (make-hash-table :test 'equal)
  "Cache: sha -> raw file bytes as a unibyte string.
A sha names its content on every forge, so the table is shared.")

(defun remoto--fetch-blob (forge owner repo sha)
  "Fetch a git blob by SHA from OWNER/REPO on FORGE.  Return its raw bytes."
  (let* ((endpoint (format "repos/%s/%s/git/blobs/%s" owner repo sha))
         (data (remoto--api forge endpoint))
         (raw (alist-get 'content data)))
    (base64-decode-string (string-replace "\n" "" raw))))

(cl-defgeneric remoto--matching-refs (forge owner repo kind prefix)
  "Return the names of the KIND refs of OWNER/REPO on FORGE that start with PREFIX.
KIND is \"heads\" or \"tags\".  A lookup that fails answers nil, so the
URL keeps its first segment as the ref."
  (condition-case nil
      (mapcar (lambda (item)
                (string-remove-prefix (format "refs/%s/" kind)
                                      (alist-get 'ref item)))
              (remoto--api forge
                           (format "repos/%s/%s/git/matching-refs/%s/%s"
                                   owner repo kind (url-hexify-string prefix))))
    (error nil)))

(defun remoto--url-ref (forge owner repo ref rest)
  "Return (REF . PATH) for REF/REST, the tail of a URL into OWNER/REPO on FORGE.
The URL does not mark where a ref with a slash ends: the longest branch,
or else tag, that starts REF/REST is the ref.  A full commit SHA, a
branch named REF or a nil `remoto--url-ref-lookup' needs no lookup past it."
  (let ((full (if rest (concat ref "/" rest) ref))
        (best ref))
    (when (and rest remoto--url-ref-lookup
               (not (string-match-p (rx bos (= 40 hex) eos) ref)))
      (catch 'done
        (dolist (kind '("heads" "tags"))
          (dolist (name (remoto--matching-refs forge owner repo kind ref))
            (when (equal name ref) (throw 'done nil))
            (when (and (< (length best) (length name))
                       (or (equal name full)
                           (string-prefix-p (concat name "/") full)))
              (setq best name)))
          (unless (equal best ref) (throw 'done nil)))))
    (cons best (concat "/" (substring full (min (length full)
                                                (1+ (length best))))))))

(defun remoto--url-unescape (string)
  "Decode the percent escapes of STRING, a part of a URL, as UTF-8."
  (and string (decode-coding-string (url-unhex-string string) 'utf-8)))

(defun remoto--parse-github-url (input)
  "Parse GitHub web INPUT into a `remoto-path' struct.
A query string, such as ?plain=1 or ?tab=readme-ov-file, and a fragment
name no part of the path."
  (cond
   ((string-match
     (rx bos "https://github.com/"
         (group (+ (not "/")))
         "/"
         (group (+ (not (in "/#?"))))
         (? "/" (or "tree" "blob") "/"
            (group (+ (not (in "/?#"))))
            (? "/" (group (+ (not (in "?#"))))))
         (* nonl)
         eos)
     input)
    (let* ((owner (match-string 1 input))
           (repo (let ((repo (match-string 2 input)))
                   (if (string-suffix-p ".git" repo) (substring repo 0 -4) repo)))
           ;; Read both groups first: decoding runs `string-match'.
           (raw-ref (match-string 3 input))
           (raw-rest (match-string 4 input))
           (ref (remoto--url-unescape raw-ref))
           (rest (remoto--url-unescape raw-rest))
           (split (and ref (remoto--url-ref remoto--github owner repo ref rest))))
      (remoto-path-create
       :owner owner :repo repo :level 'tree
       :ref (car split)
       :path (if split (cdr split) "/"))))
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
     :ref nil :level 'tree
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

(defun remoto--parse-repo-shorthand (input)
  "Parse owner/repo INPUT into a `remoto-path' struct."
  (when (string-match remoto--shorthand-regexp input)
    (remoto-path-create
     :owner (match-string 1 input)
     :repo (match-string 2 input)
     :ref (match-string 3 input) :level 'tree
     :path "/")))

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

(defun remoto--fetch-branches (forge owner repo)
  "Fetch branch names for OWNER/REPO on FORGE.
Cached per `remoto-search-cache-ttl'."
  (let* ((key (remoto--repo-id forge owner repo))
         (entry (gethash key remoto--branches-cache))
         (now (float-time)))
    (if (and entry
             (or (zerop remoto-search-cache-ttl)
                 (< (- now (car entry)) remoto-search-cache-ttl)))
        (cdr entry)
      (condition-case nil
          (let* ((endpoint (format "repos/%s/%s/branches" owner repo))
                 (data (remoto--paginated-api forge endpoint))
                 (branches (mapcar (lambda (item) (alist-get 'name item)) data)))
            (puthash key (cons now branches) remoto--branches-cache)
            branches)
        (user-error nil)))))

(defvar remoto--tags-cache (make-hash-table :test 'equal)
  "Cache for repository tags.  `remoto--repo-id' -> (TIMESTAMP . TAGS-LIST).")

(defun remoto--fetch-tags (forge owner repo)
  "Fetch tag names for OWNER/REPO on FORGE.
Cached per `remoto-search-cache-ttl'."
  (let* ((key (remoto--repo-id forge owner repo))
         (entry (gethash key remoto--tags-cache))
         (now (float-time)))
    (if (and entry
             (or (zerop remoto-search-cache-ttl)
                 (< (- now (car entry)) remoto-search-cache-ttl)))
        (cdr entry)
      (condition-case nil
          (let* ((endpoint (format "repos/%s/%s/tags" owner repo))
                 (data (remoto--paginated-api forge endpoint))
                 (tags (mapcar (lambda (item) (alist-get 'name item)) data)))
            (puthash key (cons now tags) remoto--tags-cache)
            tags)
        (user-error nil)))))

(defvar remoto--issues-cache (make-hash-table :test 'equal)
  "Cache for issue listings.  `remoto--repo-id' -> (TIMESTAMP . ISSUES-ALIST).")

(defvar remoto--file-commits-cache (make-hash-table :test 'equal)
  "Cache for per-file last commit messages.
Key: `remoto--repo-key' and \":dir\", Value: (TIMESTAMP . ALIST).
ALIST maps filename -> first line of commit message.")

(cl-defgeneric remoto--fetch-user-orgs (forge)
  "Return the organizations of the account of the token on FORGE.
Each is a login with its type and description as text properties;
GitHub's /user/orgs includes the private memberships."
  (condition-case nil
      (let ((data (remoto--paginated-api forge "user/orgs")))
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
      (puthash (concat prefix full-name) branch remoto--default-branch-cache))))

(defun remoto--account-entries (forge dir)
  "Return listing entries for the token's account on FORGE and its organizations.
DIR is the root being listed; each entry has `account-type' and
`description' fields.  Without a token no request names them: offer a
login when remoto may ask, and signal a `user-error' otherwise."
  (let* ((title (remoto-forge-title forge))
         (user (or (remoto--get-authenticated-user forge)
                   (and (remoto--offer-login
                         forge (format "%s needs a %s token. Log in now? " dir title))
                        (remoto--get-authenticated-user forge))
                   (user-error "Remoto: %s needs a %s token%s"
                               dir title (remoto--login-tail)))))
    (mapcar (lambda (account)
              (let ((type (or (get-text-property 0 'remoto-acct-type account)
                              "User"))
                    (desc (or (get-text-property 0 'remoto-acct-desc account) "")))
                (cons (substring-no-properties account)
                      `((type . "tree")
                        (account-type . ,type)
                        (description . ,desc)
                        (note . ,(if (string-empty-p desc)
                                     type
                                   (concat type "  " desc)))))))
            (cons user (remoto--fetch-user-orgs forge)))))

(defun remoto--owner-endpoint (forge prefix owner)
  "Return the endpoint of FORGE that lists OWNER's repositories, newest push first.
The account of the token and its organizations have endpoints that list
private repositories too; any other account lists its public ones.
PREFIX names the root whose listing holds the organizations."
  (let ((user (remoto--get-authenticated-user forge)))
    (cond
     ((null user) (format "users/%s/repos?sort=pushed" owner))
     ((string-equal-ignore-case owner user)
      "user/repos?affiliation=owner&sort=pushed")
     ((seq-some (lambda (entry) (string-equal-ignore-case owner (car entry)))
                (cdr (remoto--listing-entries (remoto--listing prefix))))
      (format "orgs/%s/repos?sort=pushed" owner))
     (t (format "users/%s/repos?sort=pushed" owner)))))

(defun remoto--listing-page-endpoint (forge endpoint page)
  "Return ENDPOINT of FORGE for its PAGE of `remoto--page-size' items."
  (concat endpoint "&" (remoto--page-params forge (remoto--page-size forge) page)))

(defun remoto--repo-entry (item)
  "Return the listing entry for ITEM, a repository from a list endpoint.
Its last push is the date and its size counts bytes.  A private one is
drwx------, an archived one dr-xr-xr-x, and a fork says so in its note."
  (let ((time (or (alist-get 'pushed_at item)
                  (alist-get 'updated_at item)
                  (alist-get 'created_at item))))
    (cons (alist-get 'name item)
          `((type . "tree")
            (size . ,(* 1024 (or (alist-get 'size item) 0)))
            (perms . ,(concat (if (alist-get 'archived item) "dr-x" "drwx")
                              (if (alist-get 'private item) "------" "r-xr-x")))
            (time . ,(and time (encode-time (iso8601-parse time))))
            (note . ,(string-trim
                      (concat (and (alist-get 'fork item) "fork  ")
                              (alist-get 'description item))))))))

(defun remoto--owner-page-entries (forge owner endpoint page items)
  "Return (ENTRIES . NEXT) of ITEMS, PAGE of OWNER's repositories at ENDPOINT.
Each repository of OWNER on FORGE is remembered on the way, so opening a
listed one asks for nothing but its tree.  A short page is the last."
  (let ((owned (seq-filter
                (lambda (item)
                  ;; Forgejo's user/repos ignores affiliation=owner and lists
                  ;; the repositories of the token's organizations too.
                  (let ((login (alist-get 'login (alist-get 'owner item))))
                    (or (null login) (string-equal-ignore-case login owner))))
                items)))
    (mapc (lambda (item)
            (remoto--remember-repo (remoto--prefix forge)
                                   (format "%s/%s" owner (alist-get 'name item)) item))
          owned)
    (cons (mapcar #'remoto--repo-entry owned)
          (unless (< (length items) (remoto--page-size forge))
            (cons endpoint (1+ page))))))

(defun remoto--owner-page (forge path continuation callback)
  "Return a page of the owner listing at PATH on FORGE.
CONTINUATION is (ENDPOINT . PAGE), the first page of the endpoint that
`remoto--owner-endpoint' picks without it.  With CALLBACK, ask in the
background and return nil, as `remoto-forge-entries' allows."
  (pcase-let* ((owner (remoto-path-owner path))
               (`(,endpoint . ,page)
                (or continuation
                    (cons (remoto--owner-endpoint forge (remoto--path-prefix path) owner)
                          1)))
               (resource (remoto--listing-page-endpoint forge endpoint page)))
    (if callback
        (ignore
         (remoto--api-async
          forge resource
          (lambda (items)
            (funcall callback
                     (remoto--owner-page-entries forge owner endpoint page items)))
          (lambda () (funcall callback 'failed))))
      (remoto--owner-page-entries forge owner endpoint page
                                  (remoto--api forge resource)))))

(defun remoto--account-search (forge query)
  "Return the logins of the accounts on FORGE in a search for QUERY.
Not from completion's cache: that may hold a shorter query's top 30
narrowed down, which can lack QUERY itself.  The search is cached apart,
and a failure signals instead of matching none."
  (let ((key (concat "\0users-search:" (remoto--prefix forge) (downcase query))))
    (pcase-let ((`(,hit ,logins) (remoto--search-cache-get key)))
      (if hit
          logins
        (remoto--search-cache-put
         key (remoto--extract-search-users
              forge
              (remoto--api forge (remoto--account-search-endpoint
                                  forge query (remoto--page-size forge)))))))))

(cl-defgeneric remoto--extract-search-users (forge data)
  "Return the logins in the user search DATA of FORGE, each with its account type."
  (mapcar (lambda (item)
            (propertize (alist-get 'login item)
                        'remoto-acct-type (or (alist-get 'type item) "")))
          (remoto--search-items forge data)))

(defun remoto--search-users (forge prefix)
  "Search the users and organizations of FORGE matching PREFIX, never blocking.
Returns cached or locally-narrowed results immediately.  On cache
miss, schedules a debounced async fetch and returns nil; the
completion UI refreshes when results arrive.
Requires at least `remoto-min-search-chars' characters."
  (when-let* (((<= remoto-min-search-chars (length prefix)))
              (prefix-down (concat (remoto--prefix forge) (downcase prefix))))
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
                                  (string-prefix-p (downcase prefix) (downcase u)))
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
                forge
                (remoto--account-search-endpoint forge prefix 30)
                (lambda (data)
                  (let ((results (remoto--extract-search-users forge data)))
                    (puthash prefix-down (cons (float-time) results)
                             remoto--users-cache)
                    (puthash (concat "\0users:" prefix-down)
                             (cons (float-time) results)
                             remoto--search-cache)
                    (remoto--refresh-minibuffer-completions))))))
            nil))))))

(defvar remoto--prefetch-timer nil
  "Idle timer for speculative repo pre-fetching.")

(defun remoto--recent-key (forge owner)
  "Return the search cache key of the recent repositories of OWNER on FORGE."
  (format "\0repos-recent:%s%s" (remoto--prefix forge) (downcase owner)))

(defun remoto--owner-search-key (forge owner query)
  "Return the search cache key of QUERY among OWNER's repositories on FORGE."
  (format "\0repos:%s%s/%s" (remoto--prefix forge) (downcase owner) (downcase query)))

(defun remoto--prefetch-owner-repos (forge owner)
  "Pre-fetch recent repos for OWNER on FORGE asynchronously.
Cancels any previously scheduled pre-fetch.  Uses the async API
so it never blocks typing."
  (when remoto--prefetch-timer
    (cancel-timer remoto--prefetch-timer))
  (let ((cache-key (remoto--recent-key forge owner)))
    (setq remoto--prefetch-timer
          (run-with-idle-timer
           0.001 nil
           (lambda ()
             (setq remoto--prefetch-timer nil)
             (remoto--api-async
              forge
              (remoto--repo-search-endpoint forge owner "" 30)
              (lambda (data)
                (let ((repos (mapcar
                              (lambda (item)
                                (propertize (alist-get 'name item)
                                            'remoto-repo-desc
                                            (or (alist-get 'description item) "")))
                              (remoto--search-items forge data))))
                  (remoto--search-cache-put cache-key repos)))))))))

(defun remoto--recent-owner-repos (forge owner)
  "Return cached recent repos for OWNER on FORGE, scheduling async refresh.
Uses `remoto-repo-cache-ttl' for longer caching.  Returns cached
results immediately (may be nil on first access); an async fetch
updates the cache and refreshes the completion UI."
  (let* ((cache-key (remoto--recent-key forge owner)))
    (pcase-let ((`(,hit ,results) (remoto--search-cache-get
                                    cache-key remoto-repo-cache-ttl)))
      (if hit
          ;; Cache hit - return immediately, schedule background refresh
          ;; if cache is older than the short TTL (stale but usable)
          (let ((entry (gethash cache-key remoto--search-cache)))
            (when (and entry
                       (< remoto-search-cache-ttl (- (float-time) (car entry))))
              (remoto--async-refresh-recent-repos forge owner cache-key))
            results)
        ;; Cache miss - schedule async fetch, return nil
        (remoto--async-refresh-recent-repos forge owner cache-key)
        nil))))

(defun remoto--extract-search-repos (forge data &optional name-key)
  "Extract propertized repo names from the repository search DATA of FORGE.
NAME-KEY selects the JSON field for the repo name (default `name').
Each repository is remembered on the way, so that a search match gets a
Dired line and opens like a line of a listing."
  (mapcar (lambda (item)
            (remoto--remember-repo (remoto--prefix forge)
                                   (alist-get 'full_name item) item)
            (propertize (alist-get (or name-key 'name) item)
                        'remoto-repo-desc
                        (or (alist-get 'description item) "")))
          (remoto--search-items forge data)))

(defun remoto--async-refresh-recent-repos (forge owner cache-key)
  "Fire async fetch of OWNER's recent repos on FORGE, updating CACHE-KEY."
  (remoto--debounce
   cache-key
   (lambda ()
     (remoto--api-async
      forge
      (remoto--repo-search-endpoint forge owner "" 30)
      (lambda (data)
        (let ((repos (remoto--extract-search-repos forge data)))
          (remoto--search-cache-put cache-key repos)
          (remoto--refresh-minibuffer-completions)))))))

(defun remoto--search-owner-repos (forge owner query)
  "Search OWNER's repos on FORGE matching QUERY, never blocking.
Returns cached or locally-narrowed results immediately.  On cache
miss, schedules a debounced async fetch and returns nil.
Requires at least `remoto-min-search-chars' characters in QUERY.
Also narrows from the recent-repos cache when available."
  (if (< (length query) remoto-min-search-chars)
      ;; Below threshold: try narrowing from the recent-repos cache
      (when-let* ((recent-key (remoto--recent-key forge owner))
                  (entry (gethash recent-key remoto--search-cache))
                  ((or (zerop remoto-repo-cache-ttl)
                       (< (- (float-time) (car entry)) remoto-repo-cache-ttl))))
        (seq-filter (lambda (r) (string-search (downcase query) (downcase r)))
                    (cdr entry)))
    (let* ((query-down (downcase query))
           (cache-key (remoto--owner-search-key forge owner query)))
    (pcase-let ((`(,hit ,results) (remoto--search-cache-get cache-key)))
      (if hit results
        ;; Try narrowing from a shorter search query cache (reliable)
        (let ((search-narrowed
               (cl-loop for len from (1- (length query-down)) downto 1
                        for prefix = (substring query-down 0 len)
                        for pk = (remoto--owner-search-key forge owner prefix)
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
                   (when-let* ((recent-key (remoto--recent-key forge owner))
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
                 (remoto--api-async
                  forge
                  (remoto--repo-search-endpoint forge owner query
                                                (remoto--page-size forge))
                  (lambda (data)
                    (let ((repos (remoto--extract-search-repos forge data)))
                      (remoto--search-cache-put cache-key repos)
                      (remoto--refresh-minibuffer-completions))))))
              ;; Return preview immediately (may be nil)
              preview))))))))

(defun remoto--recent-owner-repos-sync (forge owner)
  "Synchronously fetch recent repos for OWNER on FORGE, caching the result.
Intended for use inside `while-no-input' as a fallback when the
async path returned nil on a cold cache."
  (condition-case nil
      (let* ((cache-key (remoto--recent-key forge owner))
             (data (remoto--api forge (remoto--repo-search-endpoint
                                       forge owner "" 30))))
        (when data
          (let ((repos (remoto--extract-search-repos forge data)))
            (remoto--search-cache-put cache-key repos)
            repos)))
    (error nil)))

(defun remoto--fetch-owner-search (forge owner query)
  "Search OWNER's repos on FORGE for QUERY in their names and cache the names."
  (when-let* ((data (remoto--api forge (remoto--repo-search-endpoint
                                        forge owner query
                                        (remoto--page-size forge)))))
    (remoto--search-cache-put
     (remoto--owner-search-key forge owner query)
     (remoto--extract-search-repos forge data))))

(defun remoto--owner-search (forge owner query)
  "Return the names of OWNER's repositories on FORGE that match QUERY in a search.
The search that completion at /PREFIX:OWNER/ ran answers from its cache.
Without one it runs here, where a failure signals instead of matching none."
  (pcase-let ((`(,hit ,names) (remoto--search-cache-get
                               (remoto--owner-search-key forge owner query))))
    (if hit names (remoto--fetch-owner-search forge owner query))))

(defun remoto--complete-branches (query at-pos)
  "Complete branch names for QUERY with @ at AT-POS.
Returns owner/repo@branch candidates matching the prefix after @."
  (let* ((repo-part (substring query 0 at-pos))
         (branch-prefix (substring query (1+ at-pos))))
    (when (string-match
           (rx bos (group (+ (not "/"))) "/" (group (+ nonl)) eos)
           repo-part)
      (when-let* ((branches (remoto--fetch-branches
                             remoto--github
                             (match-string 1 repo-part)
                             (match-string 2 repo-part))))
        (thread-last branches
          (seq-filter (lambda (b)
                        (or (string-empty-p branch-prefix)
                            (string-prefix-p branch-prefix b))))
          (mapcar (lambda (b) (format "%s@%s" repo-part b))))))))

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
            remoto--github
            (format "search/repositories?q=%s&per_page=100"
                    (url-hexify-string (remoto--search-query query)))
            (lambda (data)
              (let ((results (remoto--extract-search-repos
                              remoto--github data 'full_name)))
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
               (remoto--recent-owner-repos remoto--github owner)
             (remoto--search-owner-repos remoto--github owner repo-q))))))))

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

(cl-defmethod remoto--browse-repos ((forge remoto-github) query)
  "GitHub's candidates for QUERY on FORGE, from its repository search.
The copies of GitHub's API list theirs through the forge contract."
  (if (eq forge remoto--github)
      (remoto--search-repos query)
    (cl-call-next-method)))

;; A /github: or /gh: path at a file prompt loads remoto before the mode
;; is on, as a remote path loads TRAMP.
;;;###autoload (add-to-list 'file-name-handler-alist '("\\`/\\(?:github\\|gh\\):" . remoto-autoload-file-name-handler))

(defun remoto--tree-table (entries truncated owner repo ref)
  "Return the tree table of ENTRIES, the items of a recursive tree answer.
TRUNCATED marks the table partial, so directories are fetched on demand;
OWNER, REPO and REF name the tree in the message about that."
  (let ((table (make-hash-table :test 'equal :size (length entries))))
    (when truncated
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

(defvar remoto--dir-contents-cache (make-hash-table :test 'equal)
  "Cache: `remoto--repo-key' and \":dir\" -> (TIMESTAMP . CHILDREN-LIST).
Stores lightweight directory listings from Contents API.")

;;;; The contract

(defun remoto--fresh-entry (table key)
  "Return the (TIMESTAMP . VALUE) of KEY in TABLE, nil once it is stale.
An entry goes stale `remoto-search-cache-ttl' seconds after it is stored;
a TTL of 0 keeps it for good."
  (when-let* ((entry (gethash key table))
              ((or (zerop remoto-search-cache-ttl)
                   (< (- (float-time) (car entry)) remoto-search-cache-ttl))))
    entry))

(cl-defmethod remoto-forge-default-ref ((forge remoto-github) owner repo)
  "GitHub's `default-ref' for OWNER and REPO on FORGE.
See `remoto-forge-default-ref'.  The answer is the whole repository, so
its Dired line is remembered too, for the owner listing to land on."
  (let ((item (remoto--api forge (format "repos/%s/%s" owner repo))))
    (when item
      (remoto--remember-repo (remoto--prefix forge) (format "%s/%s" owner repo) item))
    (alist-get 'default_branch item)))

(cl-defmethod remoto-forge-tree ((forge remoto-github) owner repo ref)
  "GitHub's `tree' for OWNER, REPO and REF on FORGE, see `remoto-forge-tree'."
  (let ((data (remoto--api forge (format "repos/%s/%s/git/trees/%s?recursive=1"
                                         owner repo ref))))
    (remoto--tree-table (alist-get 'tree data) (eq (alist-get 'truncated data) t)
                        owner repo ref)))

(defun remoto--contents-endpoint (owner repo ref dir)
  "Return the Contents API endpoint of DIR of OWNER/REPO at REF."
  (if (or (null dir) (string-empty-p dir))
      (format "repos/%s/%s/contents?ref=%s" owner repo ref)
    (format "repos/%s/%s/contents/%s?ref=%s" owner repo (url-hexify-string dir) ref)))

(defun remoto--contents-list-p (data)
  "Return non-nil when DATA, a Contents API answer, lists a directory."
  (and (consp data) (consp (caar data))))

(cl-defmethod remoto-forge-directory-contents ((forge remoto-github) owner repo ref dir)
  "GitHub's `directory-contents' for OWNER, REPO, REF and DIR on FORGE.
See `remoto-forge-directory-contents'."
  (let ((data (remoto--api forge (remoto--contents-endpoint owner repo ref dir))))
    (when (remoto--contents-list-p data)
      (mapcar (lambda (item)
                (cons (alist-get 'path item) (remoto--contents-entry item)))
              data))))

(cl-defmethod remoto-forge-children ((forge remoto-github) owner repo ref dir)
  "GitHub's `children' for OWNER, REPO, REF and DIR on FORGE, 20 at most.
They come from the Contents API, cached.  See `remoto-forge-children'."
  (let ((key (format "%s@%s:%s" (remoto--repo-id forge owner repo) ref (or dir ""))))
    (if-let* ((entry (remoto--fresh-entry remoto--dir-contents-cache key)))
        (cdr entry)
      (condition-case nil
          (let* ((data (remoto--api forge (remoto--contents-endpoint owner repo ref dir)))
                 (children
                  (when (remoto--contents-list-p data)
                    (mapcar (lambda (item)
                              (cons (alist-get 'name item) (remoto--contents-entry item)))
                            (seq-take data 20)))))
            (puthash key (cons (float-time) children) remoto--dir-contents-cache)
            children)
        (error nil)))))

(cl-defmethod remoto-forge-content ((forge remoto-github) owner repo ref path)
  "GitHub's `content' for OWNER, REPO, REF and PATH on FORGE.
The Contents API answers a file under 1MB, the Blobs API a larger one.
See `remoto-forge-content'."
  (let* ((data (remoto--api forge (format "repos/%s/%s/contents/%s?ref=%s"
                                          owner repo (url-hexify-string path) ref)))
         (sha (alist-get 'sha data)))
    (or (gethash sha remoto--content-cache)
        (puthash sha
                 (if (equal (alist-get 'encoding data) "base64")
                     (base64-decode-string
                      (string-replace "\n" "" (alist-get 'content data)))
                   (remoto--fetch-blob forge owner repo sha))
                 remoto--content-cache))))

(cl-defmethod remoto-forge-resolve-ref ((forge remoto-github) owner repo ref)
  "GitHub's `resolve-ref' for OWNER, REPO and REF on FORGE: the commit SHA.
See `remoto-forge-resolve-ref'."
  (or (alist-get 'sha (remoto--api forge (format "repos/%s/%s/commits/%s"
                                                 owner repo ref)))
      (user-error "Remoto: could not resolve commit SHA for %s/%s@%s"
                  owner repo ref)))

(cl-defmethod remoto-forge-refs ((forge remoto-github) owner repo)
  "GitHub's `refs' for OWNER and REPO on FORGE: its branches, then its tags.
See `remoto-forge-refs'."
  `(("branch" . ,(remoto--fetch-branches forge owner repo))
    ("tag" . ,(remoto--fetch-tags forge owner repo))))

(cl-defmethod remoto-forge-forget ((forge remoto-github) &optional owner repo)
  "GitHub's `forget' on FORGE: the branches and tags of OWNER/REPO, or every cache.
See `remoto-forge-forget'."
  (if owner
      (let ((key (remoto--repo-id forge owner repo)))
        (remhash key remoto--branches-cache)
        (remhash key remoto--tags-cache))
    (dolist (cache (list remoto--branches-cache remoto--users-cache
                         remoto--content-cache remoto--tags-cache
                         remoto--issues-cache remoto--file-commits-cache
                         remoto--dir-contents-cache))
      (clrhash cache))))

(defun remoto--topic-item (issue)
  "Return ISSUE, an issue or pull request alist, with its `key' and `kind'."
  (when issue
    `((key . ,(format "%s" (alist-get 'number issue)))
      (kind . ,(if (alist-get 'pull_request issue) "pr" "issue"))
      ,@issue)))

(cl-defgeneric remoto--search-topics (forge owner repo query)
  "Return the issues and pull requests of OWNER/REPO on FORGE matching QUERY."
  (condition-case nil
      (alist-get 'items
                 (remoto--api forge (format "search/issues?q=%s+repo:%s/%s&per_page=30"
                                            (url-hexify-string query) owner repo)))
    (user-error nil)))

(cl-defmethod remoto-forge-topics ((forge remoto-github) owner repo query)
  "GitHub's `topics' for OWNER, REPO and QUERY on FORGE.
The open ones, cached, for a nil or empty QUERY.  See `remoto-forge-topics'."
  (mapcar
   #'remoto--topic-item
   (if (and query (not (string-empty-p query)))
       (remoto--search-topics forge owner repo query)
     (let ((key (remoto--repo-id forge owner repo)))
       (if-let* ((entry (remoto--fresh-entry remoto--issues-cache key)))
           (cdr entry)
         (condition-case nil
             (let ((data (remoto--api
                          forge (format "repos/%s/%s/issues?state=open&sort=updated&%s"
                                        owner repo (remoto--page-params forge 30)))))
               (cdr (puthash key (cons (float-time) data) remoto--issues-cache)))
           (user-error nil)))))))

(cl-defmethod remoto-forge-topic ((forge remoto-github) owner repo key)
  "GitHub's `topic' for OWNER, REPO and KEY on FORGE, see `remoto-forge-topic'."
  (when (remoto--topic-key-p forge key)
    (remoto--topic-item
     (condition-case nil
         (remoto--api forge (format "repos/%s/%s/issues/%s" owner repo key))
       (user-error nil)))))

(cl-defmethod remoto-forge-topic-comments ((forge remoto-github) owner repo key)
  "GitHub's `topic-comments' for OWNER, REPO and KEY on FORGE.
See `remoto-forge-topic-comments'."
  (condition-case nil
      (remoto--api forge (format "repos/%s/%s/issues/%s/comments" owner repo key))
    (user-error nil)))

(cl-defgeneric remoto--reviews (forge owner repo key)
  "Return the reviews of pull request KEY of OWNER/REPO on FORGE."
  (condition-case nil
      (remoto--api forge (format "repos/%s/%s/pulls/%s/reviews" owner repo key))
    (user-error nil)))

(cl-defmethod remoto-forge-topic-extra ((forge remoto-github) owner repo key)
  "GitHub's `topic-extra' for OWNER, REPO and KEY on FORGE: a pull request's.
The pull request and its reviews; nil for an issue.  See
`remoto-forge-topic-extra'."
  (when-let* ((pr (condition-case nil
                      (remoto--api forge (format "repos/%s/%s/pulls/%s" owner repo key))
                    (user-error nil))))
    `((pull-request . ,pr)
      (reviews . ,(remoto--reviews forge owner repo key)))))

(cl-defmethod remoto-forge-entry-notes ((forge remoto-github) owner repo ref dir names)
  "GitHub's `entry-notes' for OWNER, REPO, REF, DIR and NAMES on FORGE.
Each note is the subject of the last commit that touched the name, for the
first 20 NAMES, cached; see `remoto-forge-entry-notes'."
  (let ((key (format "%s@%s:%s" (remoto--repo-id forge owner repo) ref dir)))
    (if-let* ((entry (remoto--fresh-entry remoto--file-commits-cache key)))
        (cdr entry)
      (condition-case nil
          (let ((notes
                 (seq-keep
                  (lambda (name)
                    (let ((bare (string-trim-right name "/")))
                      (when-let* ((commits
                                   (remoto--api
                                    forge
                                    (format "repos/%s/%s/commits?sha=%s&path=%s&%s"
                                            owner repo (url-hexify-string ref)
                                            (url-hexify-string
                                             (if (string-empty-p dir)
                                                 bare
                                               (concat dir "/" bare)))
                                            (remoto--page-params forge 1))))
                                  (raw (alist-get 'message
                                                  (alist-get 'commit (car commits))))
                                  (subject (car (split-string raw "\n" t))))
                        (cons name subject))))
                  (seq-take names 20))))
            (cdr (puthash key (cons (float-time) notes) remoto--file-commits-cache)))
        (error nil)))))

(cl-defmethod remoto-forge-complete ((forge remoto-github) path query wait)
  "GitHub's `complete' for PATH, QUERY and WAIT on FORGE.
The root's accounts come from the generic method; see
`remoto-forge-complete'."
  (let ((owner (remoto-path-owner path)))
    (cond
     ((eq (remoto-path-level path) 'root)
      (cond ((equal query "") (cl-call-next-method))
            ((null query) nil)
            (wait (remoto--account-search forge query))
            (t (remoto--search-users forge query))))
     ((null query) (ignore (remoto--prefetch-owner-repos forge owner)))
     ((string-empty-p query)
      (if wait
          (remoto--recent-owner-repos-sync forge owner)
        (remoto--recent-owner-repos forge owner)))
     (wait (remoto--owner-search forge owner query))
     (t (remoto--search-owner-repos forge owner query)))))

(cl-defmethod remoto-forge-entries ((forge remoto-github) path
                                    &optional continuation callback)
  "GitHub's `entries' for PATH, CONTINUATION and CALLBACK on FORGE.
The root is one page: the account of the token and its organizations.
See `remoto-forge-entries'."
  (if (eq (remoto-path-level path) 'root)
      (list (remoto--account-entries forge (remoto--path-prefix path)))
    (remoto--owner-page forge path continuation callback)))

(cl-defmethod remoto-forge-parse-url ((forge remoto-github) input)
  "GitHub's `parse-url' for INPUT on FORGE, see `remoto-forge-parse-url'."
  (let* ((input (string-trim input))
         (web (replace-regexp-in-string "\\`/?github\\.com/" "https://github.com/"
                                        input)))
    (or (when-let* ((topic (remoto--parse-topic-url input)))
          (apply #'remoto--path-at forge 'topics topic))
        (remoto--remote-path forge input)
        (remoto--parse-github-url web)
        (when (string-match (rx bos "https://github.com"
                                (? "/" (? (group (+ (not (in "/?#")))) (? "/")))
                                (? (in "?#") (* nonl)) eos)
                            web)
          (if-let* ((owner (match-string 1 web)))
              (remoto--path-at forge 'owner owner)
            (remoto--path-at forge 'root)))
        (remoto--parse-repo-shorthand input))))

(provide 'remoto-github)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-github.el ends here
