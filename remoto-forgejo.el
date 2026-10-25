;;; remoto-forgejo.el --- Forgejo and Gitea behind remoto's forge contract  -*- lexical-binding: t; -*-
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

;; Forgejo's REST API copies GitHub's, so a `remoto-forgejo' forge is a
;; `remoto-github' with its own host and a few methods of its own: the
;; paged tree, the search endpoints, the refs lookup and its web URLs.
;; Codeberg is registered here; `remoto-forgejo-instances' adds servers.

;;; Code:

(require 'remoto)
(require 'remoto-github)

(defvar tramp-methods)

(cl-defstruct (remoto-forgejo (:include remoto-github)
                              (:constructor remoto-forgejo-create)
                              (:copier nil))
  "A Forgejo or Gitea forge.  GitHub's methods serve it, against its host.")

;;;; Transport

(cl-defmethod remoto--api-host ((forge remoto-forgejo))
  "The API of a Forgejo FORGE sits under /api/v1 of its host."
  (concat (remoto-forge-host forge) "/api/v1"))

(cl-defmethod remoto--ghub-forge ((_forge remoto-forgejo))
  "Forgejo and Gitea are `forgejo' to ghub."
  'forgejo)

(cl-defmethod remoto--literal-token ((_forge remoto-forgejo))
  "A Forgejo server has no token option: `remoto-github-auth' is GitHub's."
  nil)

(cl-defmethod remoto--page-params ((_forge remoto-forgejo) count &optional page)
  "Forgejo's query for COUNT items, those of PAGE: it spells the size `limit'."
  (concat (format "limit=%d" count)
          (and page (format "&page=%d" page))))

(cl-defmethod remoto--page-size ((_forge remoto-forgejo))
  "Forgejo answers 50 items a page at most, by default."
  50)

(defun remoto-forgejo--at-once (forge endpoints)
  "Ask FORGE for all ENDPOINTS at once; return their answers in that order.
The answer of a request that fails is the symbol `failed'."
  (let ((answers (make-vector (length endpoints) nil))
        (pending (length endpoints)))
    (seq-do-indexed (lambda (endpoint slot)
                      (remoto--api-async forge endpoint
                                         (lambda (data)
                                           (aset answers slot data)
                                           (cl-decf pending))
                                         (lambda ()
                                           (aset answers slot 'failed)
                                           (cl-decf pending))))
                    endpoints)
    (while (< 0 pending)
      (accept-process-output nil 0.1))
    (append answers nil)))

(cl-defmethod remoto--paginated-api ((forge remoto-forgejo) endpoint &optional max-pages)
  "Forgejo's pages of ENDPOINT on FORGE: the first, then the rest at once.
X-Total-Count of the first answer tells how many follow, MAX-PAGES (10)
at most.  An answer without it pages one after another, from the first."
  (let* ((remoto--response-headers nil)
         (size (remoto--page-size forge))
         (page (lambda (n)
                 (concat endpoint (if (cl-search "?" endpoint) "&" "?")
                         (remoto--page-params forge size n))))
         (first (remoto--api forge (funcall page 1)))
         (total (cdr (assoc-string "x-total-count" remoto--response-headers t))))
    (cond
     ((< (length first) size) first)
     ((null total) (cl-call-next-method))
     (t (let ((pages (min (or max-pages 10) (ceiling (string-to-number total) size))))
          (apply #'append first
                 (seq-remove (lambda (answer) (eq answer 'failed))
                             (remoto-forgejo--at-once
                              forge (mapcar page (number-sequence 2 pages))))))))))

;;;; Searches

(cl-defmethod remoto--search-items ((_forge remoto-forgejo) data)
  "Forgejo's search endpoints answer DATA with the items under `data'."
  (alist-get 'data data))

(cl-defmethod remoto--account-search-endpoint ((forge remoto-forgejo) query count)
  "Forgejo's endpoint for QUERY among users, COUNT results at most.
The search is at users/search on FORGE."
  (format "users/search?q=%s&%s" (url-hexify-string query)
          (remoto--page-params forge count)))

(defvar remoto-forgejo--accounts (make-hash-table :test 'equal)
  "Cache: forge prefix and lowercase name -> the account users/NAME answers.
`none' marks a name of no account.  users/NAME answers for organizations,
which users/search leaves out, and gives the id repos/search filters by.")

(defvar remoto-forgejo--account-timer nil
  "Idle timer of the account lookup that completion waits for, or nil.")

(defun remoto-forgejo--account-key (forge name)
  "Return the key of the account NAME of FORGE in `remoto-forgejo--accounts'."
  (concat (remoto--prefix forge) (downcase name)))

(defun remoto-forgejo--account (forge name)
  "Return the account NAME of FORGE as users/NAME answers it, nil for none.
It is asked for once, a name of no account included."
  (let* ((key (remoto-forgejo--account-key forge name))
         (known (gethash key remoto-forgejo--accounts)))
    (if known
        (unless (eq known 'none) known)
      (let ((data (remoto--if-found #'remoto--api forge
                                    (concat "users/" (url-hexify-string name)))))
        (puthash key (or data 'none) remoto-forgejo--accounts)
        data))))

(defun remoto-forgejo--account-soon (forge name)
  "Return the account NAME of FORGE if known, else ask for it in the background.
The request waits for `remoto-debounce-delay' of idle time, as the search
does, and the completions refresh when it answers."
  (let* ((key (remoto-forgejo--account-key forge name))
         (known (gethash key remoto-forgejo--accounts)))
    (if known
        (unless (eq known 'none) known)
      (when (timerp remoto-forgejo--account-timer)
        (cancel-timer remoto-forgejo--account-timer))
      (setq remoto-forgejo--account-timer
            (run-with-idle-timer
             remoto-debounce-delay nil
             (lambda ()
               (setq remoto-forgejo--account-timer nil)
               (remoto--api-async forge (concat "users/" (url-hexify-string name))
                                  (lambda (data)
                                    (puthash key data remoto-forgejo--accounts)
                                    (remoto--refresh-minibuffer-completions))))))
      nil)))

(cl-defmethod remoto-forge-search-accounts ((forge remoto-forgejo) query wait)
  "Forgejo's `search-accounts' for QUERY and WAIT on FORGE.
The account QUERY names comes first: users/search finds no organization,
users/QUERY answers for one."
  (let* ((found (cl-call-next-method))
         (account (cond (wait (remoto-forgejo--account forge query))
                        ((<= remoto-min-search-chars (length query))
                         (remoto-forgejo--account-soon forge query))))
         (login (alist-get 'login account)))
    (if login
        (cons (propertize login 'remoto-acct-type "")
              (seq-remove (lambda (name) (string-equal-ignore-case name login))
                          found))
      found)))

(defun remoto-forgejo--uid (forge owner)
  "Return the id of the account OWNER on FORGE, nil when there is none."
  (alist-get 'id (remoto-forgejo--account forge owner)))

(cl-defmethod remoto--repo-search-endpoint ((forge remoto-forgejo) owner query count)
  "Forgejo's endpoint for QUERY among OWNER's repositories, COUNT at most.
The search is at repos/search on FORGE, filtered by the id of OWNER.  For
an OWNER of no account it is OWNER's own listing, which answers 404:
repos/search without an id searches every account."
  (if-let* ((uid (remoto-forgejo--uid forge owner)))
      (format "repos/search?%suid=%s&exclusive=true%s&%s"
              (if (string-empty-p query) "" (format "q=%s&" (url-hexify-string query)))
              uid
              (if (string-empty-p query) "&sort=updated&order=desc" "")
              (remoto--page-params forge count))
    (format "users/%s/repos?%s" owner (remoto--page-params forge count))))

(cl-defmethod remoto-forge-search-topics ((forge remoto-forgejo) owner repo query)
  "Forgejo's `search-topics' for OWNER, REPO and QUERY on FORGE.
The issues endpoint of the repository searches in place."
  (condition-case nil
      (remoto--api forge (format "repos/%s/%s/issues?q=%s&state=all&type=all&%s"
                                 owner repo (url-hexify-string query)
                                 (remoto--page-params forge 30)))
    (user-error nil)))

;;;; Data where Forgejo differs

(defconst remoto-forgejo--tree-pages 20
  "Most pages of 1000 entries a recursive tree is read in.
The tree of a larger repository stays partial, and the Contents API
fills its directories on demand, as for a truncated GitHub tree.")

(defun remoto-forgejo--tree-page (owner repo ref page)
  "Return the endpoint of PAGE of the recursive tree of OWNER/REPO at REF.
Forgejo answers 404 to a slash of the ref in the path, so it is escaped."
  (format "repos/%s/%s/git/trees/%s?recursive=1&per_page=1000&page=%d"
          owner repo (url-hexify-string ref) page))

(cl-defmethod remoto-forge-tree ((forge remoto-forgejo) owner repo ref)
  "Forgejo's `tree' for OWNER, REPO and REF on FORGE, 1000 entries a page.
The first page tells how many follow; those are asked for at once and
awaited together.  A page that fails leaves the table partial."
  (let* ((first (remoto--api forge (remoto-forgejo--tree-page owner repo ref 1)))
         (pages (ceiling (or (alist-get 'total_count first) 0) 1000))
         (wanted (min pages remoto-forgejo--tree-pages))
         (rest (remoto-forgejo--at-once
                forge (mapcar (lambda (page)
                                (remoto-forgejo--tree-page owner repo ref page))
                              (number-sequence 2 wanted)))))
    (remoto--tree-table (apply #'append (alist-get 'tree first)
                               (mapcar (lambda (answer)
                                         (unless (eq answer 'failed)
                                           (alist-get 'tree answer)))
                                       rest))
                        (or (memq 'failed rest) (< wanted pages))
                        owner repo ref)))

(cl-defmethod remoto--matching-refs ((forge remoto-forgejo) owner repo kind prefix)
  "Forgejo's KIND refs of OWNER/REPO on FORGE that start with PREFIX.
They are listed at git/refs."
  (condition-case nil
      (mapcar (lambda (item)
                (string-remove-prefix (format "refs/%s/" kind)
                                      (alist-get 'ref item)))
              (remoto--api forge (format "repos/%s/%s/git/refs/%s/%s"
                                         owner repo kind (url-hexify-string prefix))))
    (error nil)))

(cl-defmethod remoto-forge-commit-sha ((forge remoto-forgejo) owner repo ref)
  "Forgejo's `commit-sha' for OWNER, REPO and REF on FORGE, from git/commits."
  (or (alist-get 'sha (remoto--api forge (format "repos/%s/%s/git/commits/%s"
                                                 owner repo (url-hexify-string ref))))
      (user-error "Remoto: could not resolve commit SHA for %s/%s@%s"
                  owner repo ref)))

(cl-defmethod remoto-forge-reviews ((forge remoto-forgejo) owner repo number)
  "Forgejo's `reviews' for OWNER, REPO and NUMBER on FORGE.
The states come in GitHub's spelling, review requests left out."
  (seq-keep (lambda (review)
              (pcase (alist-get 'state review)
                ("APPROVED" review)
                ("REQUEST_CHANGES"
                 (cons '(state . "CHANGES_REQUESTED")
                       (assq-delete-all 'state (copy-sequence review))))
                ("COMMENT"
                 (cons '(state . "COMMENTED")
                       (assq-delete-all 'state (copy-sequence review))))))
            (cl-call-next-method forge owner repo number)))

(cl-defmethod remoto-forge-user-orgs ((forge remoto-forgejo) _user)
  "Forgejo's `user-orgs' for USER on FORGE, which names them by `username'."
  (condition-case nil
      (mapcar (lambda (item)
                (propertize (alist-get 'username item)
                            'remoto-acct-type "Organization"
                            'remoto-acct-desc (or (alist-get 'description item) "")))
              (remoto--paginated-api forge "user/orgs"))
    (user-error nil)))

(cl-defmethod remoto-forge-forget-all ((forge remoto-forgejo))
  "Forgejo's `forget-all' on FORGE drops the accounts too."
  (clrhash remoto-forgejo--accounts)
  (cl-call-next-method forge))

;;;; Web URLs

(defun remoto-forgejo--url-templates (host)
  "Return the `remoto-forge-url-templates' entry of the Forgejo server HOST.
Forgejo spells the kind of a ref in its paths: src/branch/main, src/tag/v1."
  (let ((repo (concat "https://" host "/%o/%r")))
    `((blob    . ,(concat repo "/src/%k/%R/%p%L"))
      (tree    . ,(concat repo "/src/%k/%R/%p%L"))
      (blame   . ,(concat repo "/blame/%k/%R/%p%L"))
      (history . ,(concat repo "/commits/%k/%R/%p"))
      (raw     . ,(concat repo "/raw/%k/%R/%p"))
      (repo    . ,repo)
      (ssh     . ,(concat "git@" host ":%o/%r.git"))
      (https   . ,(concat repo ".git"))
      (compare . ,(concat repo "/compare/%R"))
      (new-pr  . ,(concat repo "/compare/%R"))
      (issue   . ,(concat repo "/issues/%N"))
      (pr      . ,(concat repo "/pulls/%N"))
      (pr-diff . ,(concat repo "/pulls/%N/files"))
      (owner       . ,(concat "https://" host "/%o"))
      (owner-repos . ,(concat "https://" host "/%o"))
      (line    . "#L%s")
      (region  . "#L%s-L%e"))))

(cl-defmethod remoto--ref-kind ((forge remoto-forgejo) owner repo ref)
  "The kind of REF of OWNER/REPO on FORGE, from the cached refs.
A hex name that is no branch is a commit."
  (cond ((null ref) "branch")
        ((member ref (remoto-forge-branches forge owner repo)) "branch")
        ((member ref (remoto-forge-tags forge owner repo)) "tag")
        ((string-match-p (rx bos (+ hex) eos) ref) "commit")
        (t "branch")))

(defun remoto-forgejo--host-regexp (forge)
  "Return the regexp of the heads a URL or remote of FORGE can have."
  (let ((host (regexp-quote (remoto-forge-host forge))))
    (concat "\\`\\(?:https://" host "/\\|git@" host ":\\|/?" host "/\\)")))

(cl-defmethod remoto-forge-url-input-p ((forge remoto-forgejo) input)
  "Non-nil when INPUT is a URL of the host of FORGE, or its ssh remote."
  (and (stringp input)
       (string-match-p (remoto-forgejo--host-regexp forge) input)))

(cl-defmethod remoto-forge-parse-url ((forge remoto-forgejo) input)
  "The repository, tree or file that INPUT, a web URL or remote of FORGE, names.
The path after src, raw or blame carries the kind of the ref, or not;
either way the ref may hold a slash, which `remoto--url-ref' settles."
  (let ((rest (string-trim input)))
    (when (string-match (remoto-forgejo--host-regexp forge) rest)
      (setq rest (substring rest (match-end 0)))
      (when (string-match
             (rx bos
                 (group (+ (not "/")))
                 "/"
                 (group (+ (not (in "/#?"))))
                 (? "/" (or "src" "raw" "blame") "/"
                    (? (or "branch" "tag" "commit") "/")
                    (group (+ (not (in "/?#"))))
                    (? "/" (group (+ (not (in "?#"))))))
                 (* nonl)
                 eos)
             rest)
        (let* ((owner (match-string 1 rest))
               (repo (string-remove-suffix ".git" (match-string 2 rest)))
               (ref (remoto--url-unescape (match-string 3 rest)))
               (path (remoto--url-unescape (match-string 4 rest)))
               (split (and ref (remoto--url-ref forge owner repo ref path))))
          (remoto-path-create :forge forge :owner owner :repo repo
                              :ref (car split)
                              :path (if split (cdr split) "/")))))))

(cl-defmethod remoto-forge-parse-topic-url ((forge remoto-forgejo) input)
  "The (OWNER REPO NUMBER) of INPUT, an issue or pull request web URL of FORGE."
  (when (string-match (rx-to-string
                       `(seq bos (? "/") (? "https://") ,(remoto-forge-host forge) "/"
                             (group (+ (not (in "/#?")))) "/"
                             (group (+ (not (in "/#?")))) "/"
                             (or "issues" "pulls") "/"
                             (group (+ digit))
                             (or eos (in "/#?"))))
                      input)
    (list (match-string 1 input) (match-string 2 input) (match-string 3 input))))

;;;; Codeberg and the other servers

(defun remoto-forgejo-register (name prefixes host)
  "Register the Forgejo server HOST as the forge NAME under PREFIXES.
PREFIXES are the path prefixes without slash or colon, the first one
canonical.  The web URL templates of HOST go under NAME."
  (let ((forge (remoto-forgejo-create :name name :prefixes prefixes :host host
                                      :delimiters '(?@ ?#))))
    (setf (alist-get name remoto-forge-url-templates)
          (remoto-forgejo--url-templates host))
    (remoto-register-forge forge)
    forge))

(defvar remoto--codeberg (remoto-forgejo-register 'codeberg '("codeberg" "cb")
                                                   "codeberg.org")
  "The Codeberg forge, a Forgejo server.")

(defvar remoto-forgejo--instances nil
  "The forges that `remoto-forgejo-instances' registered, by prefix.")

(defun remoto-forgejo--drop (forge)
  "Unregister the server FORGE, and forget its web URL templates and login.
The login stays while another forge asks the same API host."
  (remoto-unregister-forge forge)
  (setq remoto-forge-url-templates
        (assq-delete-all (remoto-forge-name forge) remoto-forge-url-templates))
  (let ((host (remoto--api-host forge)))
    (unless (seq-some (lambda (entry)
                        (and (remoto-github-p (cdr entry))
                             (equal host (remoto--api-host (cdr entry)))))
                      remoto--forges)
      (remhash host remoto--logins))))

(defun remoto-forgejo--register-instances (instances)
  "Register one forge per (PREFIX HOST) of INSTANCES, and drop the rest.
A server that stays keeps its forge and its buffers.  A PREFIX that
another forge owns, that names a TRAMP method or that holds a colon or a
slash, and a HOST with a scheme or a path, are refused with a warning."
  (let ((kept nil))
    (pcase-dolist (`(,prefix . ,forge) remoto-forgejo--instances)
      (if (member (list prefix (remoto-forge-host forge)) instances)
          (push (cons prefix forge) kept)
        (remoto-forgejo--drop forge)))
    (setq remoto-forgejo--instances (nreverse kept)))
  (pcase-dolist (`(,prefix ,host) instances)
    (cond
     ((when-let* ((kept (cdr (assoc prefix remoto-forgejo--instances))))
        (equal host (remoto-forge-host kept))))
     ((not (and (stringp prefix) (string-match-p "\\`[^:/]+\\'" prefix)))
      (display-warning 'remoto (format "the prefix %S of `remoto-forgejo-instances' \
holds a colon or a slash; give it bare, as \"gitea\"" prefix)))
     ((not (and (stringp host) (string-match-p "\\`[^/]+\\'" host)))
      (display-warning 'remoto (format "the host %S of `remoto-forgejo-instances' \
holds a scheme or a path; give the host alone, as \"gitea.com\"" host)))
     ((assoc prefix remoto--forges)
      (display-warning 'remoto (format "the prefix %s belongs to another forge; \
remove it from `remoto-forgejo-instances'" prefix)))
     ;; remoto's handler goes first: the prefix would take the method from TRAMP.
     ((and (require 'tramp nil t) (assoc prefix tramp-methods))
      (display-warning 'remoto (format "the prefix %s is a TRAMP method; \
remove it from `remoto-forgejo-instances'" prefix)))
     (t
      (push (cons prefix (remoto-forgejo-register (intern prefix) (list prefix) host))
            remoto-forgejo--instances)))))

(defcustom remoto-forgejo-instances nil
  "Forgejo and Gitea servers to browse besides Codeberg, as (PREFIX HOST) pairs.
PREFIX is the path prefix without slash or colon, and no TRAMP method
such as ssh, so (\"gitea\" \"gitea.com\") makes /gitea:OWNER/REPO paths
work; HOST is the web host of the server, whose API answers at
HOST/api/v1 and whose token auth-source holds under that host.  The
forges exist once this file is loaded: turn `global-remoto-mode' on in
the init file to use them from the first path on."
  :type '(repeat (list (string :tag "Prefix") (string :tag "Host")))
  :set (lambda (symbol value)
         (set-default symbol value)
         (remoto-forgejo--register-instances value))
  :group 'remoto)

;; A /codeberg: or /cb: path at a file prompt loads remoto before the mode
;; is on, as a remote path loads TRAMP.
;;;###autoload (add-to-list 'file-name-handler-alist '("\\`/\\(?:codeberg\\|cb\\):" . remoto-autoload-file-name-handler))

(provide 'remoto-forgejo)

;; Local Variables:
;; package-lint-main-file: "remoto.el"
;; End:
;;; remoto-forgejo.el ends here
