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

(cl-defmethod remoto--page-params ((_forge remoto-forgejo) count &optional page)
  "Forgejo's query for COUNT items, those of PAGE: it spells the size `limit'."
  (concat (format "limit=%d" count)
          (and page (format "&page=%d" page))))

(cl-defmethod remoto--page-size ((_forge remoto-forgejo))
  "Forgejo answers 50 items a page at most, by default."
  50)

;;;; Searches

(cl-defmethod remoto--search-items ((_forge remoto-forgejo) data)
  "Forgejo's search endpoints answer DATA with the items under `data'."
  (alist-get 'data data))

(cl-defmethod remoto--account-search-endpoint ((forge remoto-forgejo) query count)
  "Forgejo's endpoint for QUERY among users, COUNT results at most.
The search is at users/search on FORGE."
  (format "users/search?q=%s&%s" (url-hexify-string query)
          (remoto--page-params forge count)))

(defvar remoto-forgejo--uids (make-hash-table :test 'equal)
  "Cache: forge prefix and owner -> the numeric id of the account.
Forgejo's repository search filters by the id of the owner, not its name.")

(defun remoto-forgejo--uid (forge owner)
  "Return the id of the account OWNER on FORGE, asking once."
  (let ((key (concat (remoto--prefix forge) owner)))
    (or (gethash key remoto-forgejo--uids)
        (puthash key (alist-get 'id (remoto--api forge (concat "users/" owner)))
                 remoto-forgejo--uids))))

(cl-defmethod remoto--repo-search-endpoint ((forge remoto-forgejo) owner query count)
  "Forgejo's endpoint for QUERY among OWNER's repositories, COUNT at most.
The search is at repos/search on FORGE, filtered by the id of OWNER."
  (format "repos/search?%suid=%s&exclusive=true%s&%s"
          (if (string-empty-p query) "" (format "q=%s&" (url-hexify-string query)))
          (remoto-forgejo--uid forge owner)
          (if (string-empty-p query) "&sort=updated&order=desc" "")
          (remoto--page-params forge count)))

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
  "Return the endpoint of PAGE of the recursive tree of OWNER/REPO at REF."
  (format "repos/%s/%s/git/trees/%s?recursive=1&per_page=1000&page=%d"
          owner repo ref page))

(cl-defmethod remoto-forge-tree ((forge remoto-forgejo) owner repo ref)
  "Forgejo's `tree' for OWNER, REPO and REF on FORGE, 1000 entries a page.
The first page tells how many follow; those are asked for at once and
awaited together.  A page that fails leaves the table partial."
  (let* ((first (remoto--api forge (remoto-forgejo--tree-page owner repo ref 1)))
         (pages (ceiling (or (alist-get 'total_count first) 0) 1000))
         (wanted (min pages remoto-forgejo--tree-pages))
         (answers (make-vector (max wanted 1) nil))
         (pending (max 0 (1- wanted)))
         (failed nil))
    (aset answers 0 (alist-get 'tree first))
    (cl-loop for page from 2 to wanted
             do (let ((slot (1- page)))
                  (remoto--api-async
                   forge (remoto-forgejo--tree-page owner repo ref page)
                   (lambda (data)
                     (aset answers slot (alist-get 'tree data))
                     (cl-decf pending))
                   (lambda ()
                     (setq failed t)
                     (cl-decf pending)))))
    (while (< 0 pending)
      (accept-process-output nil 0.1))
    (remoto--tree-table (apply #'append (append answers nil))
                        (or failed (< wanted pages))
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
                                                 owner repo ref)))
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
  "Forgejo's `forget-all' on FORGE drops the account ids too."
  (clrhash remoto-forgejo--uids)
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

(defun remoto-forgejo--register-instances (instances)
  "Register one forge per (PREFIX HOST) of INSTANCES, and drop the rest.
A PREFIX that another forge owns is refused with a warning."
  (dolist (entry remoto-forgejo--instances)
    (remoto-unregister-forge (cdr entry)))
  (setq remoto-forgejo--instances nil)
  (pcase-dolist (`(,prefix ,host) instances)
    (if (assoc prefix remoto--forges)
        (display-warning 'remoto (format "the prefix %s belongs to another forge; \
remove it from `remoto-forgejo-instances'" prefix))
      (push (cons prefix (remoto-forgejo-register (intern prefix) (list prefix) host))
            remoto-forgejo--instances))))

(defcustom remoto-forgejo-instances nil
  "Forgejo and Gitea servers to browse besides Codeberg, as (PREFIX HOST) pairs.
PREFIX is the path prefix without slash or colon, so (\"gitea\"
\"gitea.com\") makes /gitea:OWNER/REPO paths work; HOST is the web host
of the server, whose API answers at HOST/api/v1 and whose token
auth-source holds under that host.  The forges exist once this file is
loaded: turn `global-remoto-mode' on in the init file to use them from
the first path on."
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
