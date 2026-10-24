;;; record-codeberg-fixtures.el --- Record Codeberg's answers for the conformance kit  -*- lexical-binding: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;
;;  Writes test/fixtures/codeberg.jsonl, the answers the Codeberg kit of
;;  test/remoto-tests.el replays at `remoto--api'.  Public resources of
;;  forgejo/docs and the forgejo organization, asked for anonymously:
;;
;;    make test-fixtures-codeberg
;;
;;; Code:

(require 'ghub)
(require 'json)

(defconst record-codeberg--file
  (expand-file-name "fixtures/codeberg.jsonl"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Where the answers go, one JSON object a line, sorted by resource.")

(defconst record-codeberg--resources
  '("/repos/forgejo/docs"
    "/repos/forgejo/docs/git/trees/next?recursive=1&per_page=1000&page=1"
    "/repos/forgejo/docs/branches?limit=50&page=1"
    "/repos/forgejo/docs/tags?limit=50&page=1"
    "/repos/forgejo/docs/issues?state=open&sort=updated&limit=30"
    "/repos/forgejo/docs/issues/2249"
    "/repos/forgejo/docs/issues/2249/comments"
    "/repos/forgejo/docs/pulls/2249"
    "/repos/forgejo/docs/pulls/2249/reviews"
    "/repos/forgejo/docs/contents/README.md?ref=next"
    "/repos/forgejo/docs/contents?ref=next"
    "/repos/forgejo/docs/contents/docs?ref=next"
    "/repos/forgejo/docs/git/commits/next"
    "/repos/forgejo/docs/git/refs/heads/next"
    "/users/forgejo"
    "/users/forgejo/repos?sort=pushed&limit=50&page=1"
    "/orgs/forgejo/repos?sort=pushed&limit=50&page=1"
    "/repos/search?uid=70422&exclusive=true&sort=updated&order=desc&limit=30"
    "/repos/search?q=doc&uid=70422&exclusive=true&limit=50")
  "The resources the conformance suite asks Codeberg for.")

(defconst record-codeberg--kept-keys
  '(additions archived base body changed_files commit content created_at data
    default_branch deletions description draft encoding fork full_name head id
    labels login mergeable merged message mode name number ok page path private
    pull_request pushed_at ref sha size state title total_count tree truncated
    type updated_at user username)
  "The keys of Forgejo's answers that remoto reads.  The rest is dropped.")

(defun record-codeberg--trim (value)
  "Return VALUE, parsed JSON, without the keys remoto never reads."
  (cond ((vectorp value) (vconcat (mapcar #'record-codeberg--trim value)))
        ((and (consp value) (consp (car value)) (symbolp (caar value)))
         (cl-loop for (key . val) in value
                  when (memq key record-codeberg--kept-keys)
                  collect (cons key (if (eq key 'pull_request)
                                        val
                                      (record-codeberg--trim val)))))
        (t value)))

(defun record-codeberg--read (_status)
  "Parse the JSON body in the current buffer, arrays as vectors."
  (goto-char (point-min))
  (when (re-search-forward "[{[]" nil t)
    (json-parse-string (decode-coding-string
                        (buffer-substring-no-properties (1- (point)) (point-max))
                        'utf-8)
                       :object-type 'alist :array-type 'array
                       :null-object :null :false-object :false)))

(defun record-codeberg--answer (resource)
  "Return (STATUS BODY) for RESOURCE, asked of codeberg.org anonymously."
  (condition-case err
      (list 200 (record-codeberg--trim
                 (ghub-get resource nil :auth 'none :forge 'forgejo
                           :host "codeberg.org/api/v1"
                           :reader #'record-codeberg--read)))
    (ghub-http-error (list (nth 1 err) (nth 4 err)))))

(defun record-codeberg-fixtures ()
  "Record every resource of `record-codeberg--resources' into the fixtures file."
  (let ((coding-system-for-write 'utf-8))
    (with-temp-file record-codeberg--file
      (dolist (resource (sort (copy-sequence record-codeberg--resources) #'string<))
        (pcase-let ((`(,status ,body) (record-codeberg--answer resource)))
          (princ (format "recorded %s %s\n" status resource)
                 #'external-debugging-output)
          ;; `json-serialize' answers UTF-8 bytes; the buffer holds text.
          (insert (decode-coding-string
                   (json-serialize `((resource . ,resource) (status . ,status)
                                     (body . ,body)))
                   'utf-8)
                  "\n"))))))

(provide 'record-codeberg-fixtures)
;;; record-codeberg-fixtures.el ends here
