;;; remoto-issue.el --- Issue and PR display for remoto -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Ag Ibragimov
;; Author: Ag Ibragimov

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Dedicated buffers for viewing GitHub issues and pull requests.
;; Provides `remoto-issue-display' for issues and `remoto-pr-display'
;; for pull requests, with rich rendering including comments, diff
;; stats, review state, and merge status.

;;; Code:

(require 'remoto)

(declare-function remoto--api "remoto" (endpoint &rest args))
(declare-function remoto--fetch-issue "remoto" (owner repo number))
(declare-function remoto--fetch-issue-comments "remoto" (owner repo number))

;;;; Customization

(defgroup remoto-issue nil
  "GitHub issue and PR display for remoto."
  :group 'remoto
  :prefix "remoto-issue-")

(defface remoto-issue-title
  '((t :weight bold :height 1.2))
  "Face for issue/PR title.")

(defface remoto-issue-state-open
  '((t :foreground "green"))
  "Face for open state.")

(defface remoto-issue-state-closed
  '((t :foreground "red"))
  "Face for closed state.")

(defface remoto-issue-state-merged
  '((t :foreground "purple"))
  "Face for merged state.")

(defface remoto-issue-meta
  '((t :foreground "gray"))
  "Face for metadata (author, date, labels).")

(defface remoto-issue-separator
  '((t :foreground "gray" :strike-through t))
  "Face for horizontal separators.")

(defface remoto-issue-comment-header
  '((t :weight bold))
  "Face for comment author/date header.")

(defface remoto-issue-additions
  '((t :foreground "green"))
  "Face for addition count in PR stats.")

(defface remoto-issue-deletions
  '((t :foreground "red"))
  "Face for deletion count in PR stats.")

;;;; Buffer-local state

(defvar-local remoto-issue--number nil
  "Issue/PR number displayed in this buffer.")

(defvar-local remoto-issue--repo-path nil
  "Repo path (e.g. \"/github:owner/repo\") for this buffer.")

(defvar-local remoto-issue--is-pr nil
  "Non-nil if this buffer displays a pull request.")

(defvar-local remoto-issue--data nil
  "Raw issue/PR alist for the current buffer.")

;;;; Mode

(defvar remoto-issue-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "b" #'remoto-issue-browse)
    (define-key map "g" #'remoto-issue-refresh)
    map)
  "Keymap for `remoto-issue-mode'.")

(define-derived-mode remoto-issue-mode special-mode "Remoto-Issue"
  "Major mode for viewing GitHub issues and pull requests.

\\{remoto-issue-mode-map}"
  :group 'remoto-issue)

;;;; Commands

(defun remoto-issue-browse ()
  "Open the current issue/PR in a web browser."
  (interactive)
  (when-let* ((number remoto-issue--number)
              (path remoto-issue--repo-path)
              (_ (string-match (rx "/github:" (group (+ nonl))) path))
              (slug (match-string 1 path))
              (type (if remoto-issue--is-pr "pull" "issues")))
    (browse-url (format "https://github.com/%s/%s/%s" slug type number))))

(defun remoto-issue-refresh ()
  "Re-fetch and redisplay the current issue/PR."
  (interactive)
  (when (and remoto-issue--number remoto-issue--repo-path)
    (remoto-issue-display remoto-issue--number remoto-issue--repo-path)))

;;;; Formatting helpers

(defun remoto-issue--format-date (date-str)
  "Format DATE-STR (ISO 8601) to YYYY-MM-DD."
  (if (and date-str
           (string-match (rx bos (group (= 4 digit) "-" (= 2 digit) "-" (= 2 digit)))
                         date-str))
      (match-string 1 date-str)
    (or date-str "")))

(defun remoto-issue--state-face (state merged)
  "Return face for STATE, accounting for MERGED status."
  (cond
   (merged 'remoto-issue-state-merged)
   ((equal state "open") 'remoto-issue-state-open)
   (t 'remoto-issue-state-closed)))

(defun remoto-issue--separator ()
  "Insert a visual separator line."
  (insert (propertize (make-string 60 ?-) 'face 'remoto-issue-separator) "\n"))

;;;; PR-specific data fetching

(defun remoto-issue--fetch-pr (owner repo number)
  "Fetch full PR data for NUMBER in OWNER/REPO.
Returns PR alist with merge status, diff stats, review state."
  (condition-case nil
      (remoto--api (format "repos/%s/%s/pulls/%s" owner repo number))
    (user-error nil)))

(defun remoto-issue--fetch-reviews (owner repo number)
  "Fetch reviews for PR NUMBER in OWNER/REPO."
  (condition-case nil
      (remoto--api (format "repos/%s/%s/pulls/%s/reviews" owner repo number))
    (user-error nil)))

;;;; Rendering

(defun remoto-issue--render-header (data is-pr)
  "Render the header section for DATA. IS-PR if pull request."
  (let* ((number (alist-get 'number data))
         (title (or (alist-get 'title data) ""))
         (state (or (alist-get 'state data) "unknown"))
         (merged (and is-pr (alist-get 'merged data)))
         (draft (and is-pr (alist-get 'draft data)))
         (user (alist-get 'user data))
         (author (or (and user (alist-get 'login user)) "unknown"))
         (labels (alist-get 'labels data))
         (label-names (mapcar (lambda (l) (alist-get 'name l)) labels))
         (created (remoto-issue--format-date (alist-get 'created_at data)))
         (state-str (cond (merged "merged")
                          (draft "draft")
                          (t state)))
         (state-face (remoto-issue--state-face state merged)))
    ;; Title line
    (insert (propertize (format "#%s %s" number title) 'face 'remoto-issue-title))
    (insert "  ")
    (insert (propertize (format "[%s]" state-str) 'face state-face))
    (insert "\n")
    ;; Meta line
    (insert (propertize
             (concat "Author: " author
                     (when label-names
                       (concat " | Labels: " (string-join label-names ", ")))
                     " | " created)
             'face 'remoto-issue-meta))
    (insert "\n")))

(defun remoto-issue--render-pr-stats (pr-data)
  "Render PR-specific stats from PR-DATA."
  (let* ((additions (or (alist-get 'additions pr-data) 0))
         (deletions (or (alist-get 'deletions pr-data) 0))
         (changed (or (alist-get 'changed_files pr-data) 0))
         (head-ref (or (alist-get 'ref (alist-get 'head pr-data)) "?"))
         (base-ref (or (alist-get 'ref (alist-get 'base pr-data)) "?"))
         (mergeable (alist-get 'mergeable_state pr-data)))
    (insert (propertize (format "%s -> %s" head-ref base-ref) 'face 'remoto-issue-meta))
    (insert "  ")
    (insert (propertize (format "+%d" additions) 'face 'remoto-issue-additions))
    (insert " ")
    (insert (propertize (format "-%d" deletions) 'face 'remoto-issue-deletions))
    (insert (propertize (format "  %d files" changed) 'face 'remoto-issue-meta))
    (when mergeable
      (insert (propertize (format "  [%s]" mergeable) 'face 'remoto-issue-meta)))
    (insert "\n")))

(defun remoto-issue--render-reviews (reviews)
  "Render review summary from REVIEWS list."
  (when reviews
    ;; Deduplicate: keep only the latest review per author
    (let ((latest (make-hash-table :test 'equal)))
      (dolist (r reviews)
        (let* ((user (alist-get 'user r))
               (login (and user (alist-get 'login user)))
               (state (alist-get 'state r)))
          (when (and login (not (equal state "COMMENTED")))
            (puthash login state latest))))
      (when (< 0 (hash-table-count latest))
        (insert (propertize "Reviews: " 'face 'remoto-issue-meta))
        (let ((first t))
          (maphash (lambda (login state)
                     (unless first (insert ", "))
                     (setq first nil)
                     (insert (format "%s " login))
                     (insert (propertize
                              (pcase state
                                ("APPROVED" "approved")
                                ("CHANGES_REQUESTED" "changes requested")
                                (_ (downcase state)))
                              'face (pcase state
                                      ("APPROVED" 'remoto-issue-state-open)
                                      ("CHANGES_REQUESTED" 'remoto-issue-state-closed)
                                      (_ 'remoto-issue-meta)))))
                   latest))
        (insert "\n")))))

(defun remoto-issue--render-body (data)
  "Render the body section from DATA."
  (let ((body (or (alist-get 'body data) "")))
    (insert "\n")
    (remoto-issue--separator)
    (insert "\n")
    (insert body)
    (insert "\n")))

(defun remoto-issue--render-comments (comments)
  "Render COMMENTS section."
  (when comments
    (insert "\n")
    (remoto-issue--separator)
    (insert "\n")
    (insert (propertize "Comments" 'face 'remoto-issue-title))
    (insert "\n\n")
    (dolist (comment comments)
      (let* ((user (alist-get 'user comment))
             (author (or (and user (alist-get 'login user)) "unknown"))
             (date (remoto-issue--format-date (alist-get 'created_at comment)))
             (body (or (alist-get 'body comment) "")))
        (insert (propertize (format "%s - %s" author date)
                            'face 'remoto-issue-comment-header))
        (insert "\n")
        (insert body)
        (insert "\n\n")))))

;;;; Entry points

(defun remoto-issue--parse-repo-path (repo-path)
  "Extract owner and repo from REPO-PATH.
Returns (OWNER . REPO) or nil."
  (when (string-match (rx "/github:" (group (+ (not (any "/@#"))))
                          "/" (group (+ (not (any "/@#")))))
                      repo-path)
    (cons (match-string 1 repo-path)
          (match-string 2 repo-path))))

(defun remoto-issue-display (number repo-path)
  "Fetch and display issue/PR NUMBER for the repo at REPO-PATH.
REPO-PATH is like \"/github:owner/repo\".
Detects whether NUMBER is a PR and renders accordingly."
  (let ((parsed (remoto-issue--parse-repo-path repo-path)))
    (unless parsed
      (user-error "Remoto: invalid repo path: %s" repo-path))
    (let* ((owner (car parsed))
           (repo (cdr parsed))
           (issue (remoto--fetch-issue owner repo number)))
      (unless issue
        (user-error "Remoto: not found: %s/%s#%s" owner repo number))
      (let* ((is-pr (not (null (alist-get 'pull_request issue))))
             (pr-data (when is-pr
                        (remoto-issue--fetch-pr owner repo number)))
             (reviews (when is-pr
                        (remoto-issue--fetch-reviews owner repo number)))
             (comments (remoto--fetch-issue-comments owner repo number))
             (display-data (or pr-data issue))
             (buf-name (format "*remoto: %s/%s#%s*" owner repo number))
             (buf (get-buffer-create buf-name)))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (remoto-issue--render-header display-data is-pr)
            (when (and is-pr pr-data)
              (remoto-issue--render-pr-stats pr-data)
              (remoto-issue--render-reviews reviews))
            (remoto-issue--render-body display-data)
            (remoto-issue--render-comments comments))
          (goto-char (point-min))
          (remoto-issue-mode)
          (setq remoto-issue--number number
                remoto-issue--repo-path repo-path
                remoto-issue--is-pr is-pr
                remoto-issue--data display-data))
        (pop-to-buffer buf)
        buf))))

(provide 'remoto-issue)
;;; remoto-issue.el ends here
