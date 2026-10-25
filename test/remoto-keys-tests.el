;;; remoto-keys-tests.el --- Specs of the terminal runner's pure parts -*- lexical-binding: t; no-byte-compile: t; -*-
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;;; Commentary:
;;  How remoto-keys.el turns the parts of a case into what tmux types, and
;;  how the E2E suites compare two states.  Nothing here starts tmux.
;;
;;; Code:

(require 'buttercup)
(require 'remoto-keys (expand-file-name "remoto-keys"
                                        (file-name-directory
                                         (or load-file-name buffer-file-name))))

(describe "remoto-keys--tmux-key"
  (it "names modified and special keys as tmux does"
    (expect (mapcar #'remoto-keys--tmux-key
                    (list ?\C-x ?\C-g (aref (kbd "M-RET") 0) (aref (kbd "M-x") 0)
                          (aref (kbd "C-M-x") 0) ?\r ?\t ?\e ?\d 'f12 'up))
            :to-equal '("C-x" "C-g" "M-Enter" "M-x" "C-M-x" "Enter" "Tab"
                        "Escape" "BSpace" "F12" "Up")))
  (it "leaves plain characters, space among them, to be typed as text"
    (expect (mapcar #'remoto-keys--tmux-key '(?a ?: ?^ ?+ ?D ?\s))
            :to-equal '(nil nil nil nil nil nil)))
  (it "refuses a key tmux cannot send"
    (expect (remoto-keys--tmux-key 'f35) :to-throw 'error)))

(describe "remoto-keys--steps"
  (it "types a name and the profile's submit key"
    (expect (remoto-keys--steps '("/gh:agzam" submit) "vertico")
            :to-equal '((text "/gh:agzam") (key "M-Enter")))
    (expect (remoto-keys--steps '("/gh:agzam" submit) "fido")
            :to-equal '((text "/gh:agzam") (key "M-j")))
    (expect (remoto-keys--steps '("/gh:agzam" submit) "vanilla")
            :to-equal '((text "/gh:agzam") (key "Enter"))))
  (it "names the control characters of a kbd string and types the rest"
    (expect (remoto-keys--steps (list (kbd "C-x C-f") (kbd ": e SPC")) "evil")
            :to-equal '((key "C-x") (key "C-f") (text ":e ")))
    (expect (remoto-keys--steps (list (vconcat "ab" [f12] "c")) "vanilla")
            :to-equal '((text "ab") (key "F12") (text "c"))))
  (it "turns goto into F12 and keeps pauses"
    (expect (remoto-keys--steps (list 'goto "remoto.el" (kbd "RET") 'pause) "vanilla")
            :to-equal '((key "F12") (text "remoto.el") (key "Enter") (pause))))
  (it "waits after a submit that keys follow, and before Embark, once"
    (expect (remoto-keys--steps (list (kbd "C-x d") "/cb:forgejo/" 'submit 'goto "docs"
                                      (kbd "RET") (kbd "C-c a") "y")
                                "vertico")
            :to-equal '((key "C-x") (text "d") (text "/cb:forgejo/") (key "M-Enter") (pause)
                        (key "F12") (text "docs") (key "Enter") (pause) (key "C-c") (text "a")
                        (text "y")))
    (expect (remoto-keys--steps (list (kbd "C-x C-f") "/gh:agzam/" 'pause (kbd "C-c c")) "vertico")
            :to-equal '((key "C-x") (key "C-f") (text "/gh:agzam/") (pause) (key "C-c") (text "c")))))

(describe "remoto-keys--tmux-arg"
  (it "escapes a trailing semicolon, which tmux reads as a command separator"
    (expect (remoto-keys--tmux-arg "(foo);") :to-equal "(foo)\\;")
    (expect (remoto-keys--tmux-arg ";") :to-equal "\\;"))
  (it "leaves other arguments alone"
    (expect (remoto-keys--tmux-arg "a;b") :to-equal "a;b")
    (expect (remoto-keys--tmux-arg "") :to-equal "")))

(describe "remoto-keys--checks"
  (let ((dired '(:mode dired-mode :dired "/github:agzam/" :names ("a" "b") :requests ("x"))))
    (it "passes a case that ends where the replay ends"
      (expect (remoto-keys--checks "dired /gh:agzam/" dired dired nil) :to-be nil))
    (it "fails a case that ends somewhere else than the replay"
      (expect (remoto-keys--checks "dired /gh:agzam/" '(:mode lisp-interaction-mode) dired nil)
              :to-equal '("the replay ends in (:dired \"/github:agzam/\"), this run in nil")))
    (it "needs no replay state for the other checks"
      (expect (remoto-keys--checks "ff /cb:forgejo" '(:mode fundamental-mode) nil nil) :to-be nil))
    (it "leaves a typed name with two colons to no file name handler"
      (expect (remoto-keys--checks "ff /gitea::gitea/tea" '(:mode fundamental-mode) nil nil)
              :to-be nil)
      (expect (remoto-keys--checks "ff /gh:agzam/remoto.el@main:/test/"
                                   '(:dired "/github:agzam/remoto.el@main:/test/" :matches t
                                     :names ("x" "test"))
                                   nil nil)
              :to-equal '("the typed name test is not the first line")))
    (it "fails a Dired of matches whose first line is not the typed name"
      (expect (remoto-keys--checks "ff /gh:agzam/remoto.el"
                                   '(:dired "/github:agzam/" :matches t
                                     :names ("remoto-x" "remoto.el"))
                                   nil nil)
              :to-equal '("the typed name remoto.el is not the first line")))
    (it "fails the problems of a Dired or Embark buffer, naming the buffer"
      (expect (remoto-keys--checks "ff /cb:technomancy/"
                                   '(:dired "/codeberg:technomancy/"
                                     :problems ("not an entry:   https://itch.io"))
                                   nil nil)
              :to-equal '("Dired: not an entry:   https://itch.io"))
      (expect (remoto-keys--checks "embark collect at /cb:technomancy/"
                                   '(:buffer "*Embark Collect*" :mode embark-collect-mode
                                     :problems ("annotations start at columns (24 30)"))
                                   nil nil)
              :to-equal '("*Embark Collect*: annotations start at columns (24 30)")))
    (it "fails an Embark y case that copied nothing and a b case that browsed nothing"
      (expect (remoto-keys--checks "cb embark y on a file line" '(:mode dired-mode) nil nil)
              :to-equal '("Embark's y copied nothing"))
      (expect (remoto-keys--checks "embark b on a repository line" '(:mode dired-mode) nil nil)
              :to-equal '("Embark's b browsed nothing"))
      (expect (remoto-keys--checks "embark y on a ref line" '(:kill "https://x") nil nil)
              :to-be nil))
    (it "fails a copied or browsed URL that does not load"
      (expect (remoto-keys--checks "M-x remoto-copy-url"
                                   '(:dead (("https://codeberg.org/x" . 404) ("https://y" . nil)))
                                   nil nil)
              :to-equal '("https://codeberg.org/x answers 404" "https://y answers nothing")))
    (it "fails raw HTTP text, too many requests, and a runner's note"
      (expect (remoto-keys--checks "ff /gh:" `(:raw ("HTTP/1.1 502 Bad Gateway")
                                               :requests ,(mapcar (lambda (n) (format "r%d" n))
                                                                  (number-sequence 1 21)))
                                   nil "still busy after 60s")
              :to-equal '("still busy after 60s"
                          "raw HTTP text in the messages: HTTP/1.1 502 Bad Gateway"
                          "21 requests, more than 20")))
    (it "counts a request asked again, synchronously or not, once"
      ;; A keystroke that interrupts a Codeberg tree has its pages asked again (CB28).
      (let ((pages (mapcar (lambda (n) (format "/codeberg:repos/o/r/git/trees/x?page=%d" n))
                           (number-sequence 1 11))))
        (expect (remoto-keys--checks "ff /cb:forgejo/forgejo@v17.0.0:/"
                                     `(:requests ,(append pages
                                                          (mapcar (lambda (p) (concat "async " p))
                                                                  pages)))
                                     nil nil)
                :to-be nil)))
    (it "counts the commit annotations apart, with a cap of 20 for each directory"
      ;; remoto documents up to 20 of them, one per file of the directory it lists.
      (let ((annotations (lambda (prefix dir n)
                           (mapcar (lambda (i)
                                     (format "%srepos/o/r/commits?sha=main&path=%s&limit=1"
                                             prefix (url-hexify-string (format "%sf%d" dir i))))
                                   (number-sequence 1 n)))))
        (expect (remoto-keys--checks
                 "ff /cb:forgejo/forgejo@v17.0.0:/public/assets/img/emoji/gitea.png"
                 `(:requests ,(append (make-list 11 "/codeberg:repos/o/r/git/trees/x")
                                      (funcall annotations "/codeberg:" "" 20)
                                      (funcall annotations "/codeberg:" "public/" 11)))
                 nil nil)
                :to-be nil)
        (expect (remoto-keys--checks
                 "ff /gh:agzam/remoto.el@main:/test/"
                 `(:requests ,(cons "repos/o/r/git/trees/main"
                                    (funcall annotations "" "test/" 21)))
                 nil nil)
                :to-equal '("21 commit annotations in one directory, more than 20"))
        (expect (remoto-keys--annotation-p "async repos/o/r/commits/main") :to-be nil)))))

(describe "remoto-keys--expected-state"
  (it "takes vanilla's golden state for a profile without its own, evil's for ex"
    (expect (remoto-keys--expected-state "ido" "ff /gh:agzam/remoto.el")
            :to-equal (remoto-keys--expected-state "vanilla" "ff /gh:agzam/remoto.el"))
    (expect (remoto-keys--expected-state "full" "ex /gh:agzam/remoto.el")
            :to-equal (remoto-keys--expected-state "evil" "ex /gh:agzam/remoto.el"))
    (expect (plist-get (remoto-keys--expected-state "vanilla" "ff /gh:agzam/remoto.el") :dired)
            :to-equal "/github:agzam/remoto.el@main:/"))

  (it "takes ido's own landing where ido ends a case elsewhere, on main too"
    (expect (remoto-keys--landing (remoto-keys--expected-state "ido" "dired /gh:qlik"))
            :to-equal '(:dired "/github:qlik/"))
    (expect (remoto-keys--landing (remoto-keys--expected-state "vanilla" "dired /gh:qlik"))
            :to-equal '(:dired "/github:"))
    ;; ido's C-j ends this one in no Dired and no file: nothing to check.
    (expect (remoto-keys--expected-state "ido" "dired /gh:agzam/remoto") :to-be nil)
    (expect (remoto-keys--checks "dired /gh:qlik" '(:dired "/github:qlik/")
                                 (remoto-keys--expected-state "ido" "dired /gh:qlik") nil)
            :to-be nil))

  (it "opens the account line of the token's own account, as the replay opens its org"
    (expect (plist-get (remoto-keys--expected-state "vanilla" "dired RET on an account line")
                       :dired)
            :to-equal "/github:emacs-mirror/")
    (let ((remoto-e2e--root-account "someone"))
      (expect (plist-get (remoto-keys--expected-state "full" "dired RET on an account line")
                         :dired)
              :to-equal "/github:someone/")
      (expect (member "someone" (assoc "dired RET on an account line" (remoto-e2e--dired-cases)))
              :to-be-truthy))))

(describe "remoto-e2e--codeberg-cases"
  (it "opens each Codeberg name with the profile's commands, ex lines ending in RET"
    (let ((cases (remoto-e2e--codeberg-cases "evil-vertico")))
      (expect (length cases) :to-equal (* 3 (length remoto-e2e--codeberg-names)))
      (expect (car (assoc "ex /cb:forgejo/docs" cases)) :to-equal "ex /cb:forgejo/docs")
      (expect (car (last (assoc "ex /cb:forgejo/docs" cases))) :to-equal (kbd "RET"))
      (expect (car (last (assoc "ff /cb:forgejo/docs" cases))) :to-equal 'submit))))

(describe "remoto-e2e--buffer-problems"
  (it "finds a Dired line that is no entry and a control character"
    (with-temp-buffer
      (insert "  /codeberg:technomancy/:\n"
              "  drwxr-xr-x  1 github github 0 Jan  1  2000 "
              (propertize "sokobelt" 'dired-filename t) "    Jam 2022\r\n"
              "  https://itch.io\n")
      (dired-mode)
      (expect (remoto-e2e--buffer-problems)
              :to-equal '("line 2 holds U+000D" "not an entry:   https://itch.io"))))
  (it "reads Dired's \\015 as the carriage return it stands for, and its \\\\ as a backslash"
    (dolist (case '(("Jam 2022\\015" . ("line 2 holds U+000D"))
                    ("C:\\\\015 is a path" . nil)
                    ("C:\\\\\\015 is a path and a return" . ("line 2 holds U+000D"))))
      (with-temp-buffer
        (insert "  /x:\n  drwxr-xr-x  1 github github 0 Jan  1  2000 "
                (propertize "a" 'dired-filename t) "    " (car case) "\n")
        (dired-mode)
        (expect (remoto-e2e--buffer-problems) :to-equal (cdr case)))))
  (it "passes clean Dired lines and skips invisible text"
    (with-temp-buffer
      (insert "  /x:\n  drwxr-xr-x  1 github github 0 Jan  1  2000 "
              (propertize "a" 'dired-filename t) (propertize "\t" 'invisible t) "    note\n")
      (dired-mode)
      (expect (remoto-e2e--buffer-problems) :to-be nil)))
  (it "finds an Embark entry over two lines, and a raw byte"
    (require 'embark)
    (with-temp-buffer
      (embark-collect-mode)
      (setq tabulated-list-format [("Candidate" 10 t) ("Annotation" 0 t)]
            tabulated-list-entries
            `(("a" ["a" "one line"]) ("b" ["b" ,(concat "two\nlines " (string #x3fffc3))])))
      (tabulated-list-print)
      (expect (remoto-e2e--buffer-problems)
              :to-equal '("line 3 holds U+3FFFC3" "3 lines for 2 entries"))
      (expect (remoto-e2e--buffer-names) :to-equal '("a" "b"))))
  (it "finds where the annotation of an Embark entry starts, past its alignment space"
    (require 'embark)
    (with-temp-buffer
      (embark-collect-mode)
      (setq tabulated-list-format [("Candidate" 10 t) ("Annotation" 0 t)]
            tabulated-list-entries
            `(("a" ["a" ,(concat (propertize " " 'display '(space :align-to 20)) "desc")])
              ("b" ["b" ""])))
      (tabulated-list-print)
      (goto-char (point-min))
      (expect (buffer-substring (remoto-e2e--annotation-start) (line-end-position))
              :to-equal "desc")
      (forward-line 1)
      (expect (remoto-e2e--annotation-start) :to-be nil)))
  (it "has nothing to say about other buffers"
    (with-temp-buffer
      (insert "a\rb")
      (expect (remoto-e2e--buffer-problems) :to-be nil))))

(describe "remoto-e2e--selected"
  (it "matches the names of the cases with letter case counting"
    (let ((remoto-e2e--only "^ff /gh:agzam/remoto\\.el$"))
      (expect (mapcar #'car (remoto-e2e--selected '(("ff /gh:agzam/remoto.el")
                                                    ("ff /gh:Agzam/Remoto.el"))))
              :to-equal '("ff /gh:agzam/remoto.el"))))
  (it "keeps every case without REMOTO_E2E_ONLY"
    (let ((remoto-e2e--only nil))
      (expect (length (remoto-e2e--selected '(("a") ("b")))) :to-equal 2))))

(describe "remoto-keys--env"
  (it "gives a scenario its git config, authinfo and init, and no token unless asked"
    (let* ((remoto-keys--token "not-a-token")
           (remoto-keys--dir (file-name-as-directory (make-temp-file "remoto-keys" t)))
           (env (remoto-keys--env "sc-x" "vanilla" "/elpa/"
                                  '(:gitconfig "[forgejo]\n" :authinfo "machine x\n"
                                    :init (foo "a b")))))
      (unwind-protect
          (progn
            (expect (with-temp-buffer
                      (insert-file-contents (getenv-internal "GIT_CONFIG_GLOBAL" env))
                      (buffer-string))
                    :to-equal "[forgejo]\n")
            (expect (with-temp-buffer
                      (insert-file-contents (getenv-internal "REMOTO_KEYS_AUTHINFO" env))
                      (buffer-string))
                    :to-equal "machine x\n")
            (expect (getenv-internal "REMOTO_KEYS_INIT" env) :to-equal "(foo \"a b\")")
            (expect (getenv-internal "REMOTO_KEYS_TOKEN_FILE" env) :to-be nil))
        (delete-directory remoto-keys--dir t))))
  (it "gives a profile an empty git config, no authinfo, and the token"
    (let* ((remoto-keys--token "not-a-token")
           (remoto-keys--dir (file-name-as-directory (make-temp-file "remoto-keys" t)))
           (env (remoto-keys--env "vanilla" "vanilla" "/elpa/")))
      (unwind-protect
          (progn
            (expect (file-attribute-size
                     (file-attributes (getenv-internal "GIT_CONFIG_GLOBAL" env)))
                    :to-equal 0)
            (expect (getenv-internal "REMOTO_KEYS_AUTHINFO" env) :to-be nil)
            (expect (file-modes (getenv-internal "REMOTO_KEYS_TOKEN_FILE" env))
                    :to-equal #o600))
        (delete-directory remoto-keys--dir t))))
  (it "names the account of the token in the git config, since ghub needs one"
    (let* ((remoto-keys--token "not-a-token")
           (remoto-keys--github-login "someone")
           (remoto-keys--dir (file-name-as-directory (make-temp-file "remoto-keys" t)))
           (env (remoto-keys--env "vanilla" "vanilla" "/elpa/")))
      (unwind-protect
          (expect (with-temp-buffer
                    (insert-file-contents (getenv-internal "GIT_CONFIG_GLOBAL" env))
                    (buffer-string))
                  :to-equal "[github]\n\tuser = someone\n")
        (delete-directory remoto-keys--dir t))))
  (it "gives the Codeberg scenario the Codeberg token and its account, not GitHub's token"
    (let* ((remoto-keys--token "not-a-token")
           (remoto-keys--codeberg-token "not-a-codeberg-token")
           (remoto-keys--codeberg-login "someone")
           (remoto-keys--dir (file-name-as-directory (make-temp-file "remoto-keys" t)))
           (env (remoto-keys--env "sc-cbtoken" "vanilla" "/elpa/" '(:gitconfig "" :codeberg t)))
           (authinfo (getenv-internal "REMOTO_KEYS_AUTHINFO" env)))
      (unwind-protect
          (progn
            (expect (with-temp-buffer
                      (insert-file-contents (getenv-internal "GIT_CONFIG_GLOBAL" env))
                      (buffer-string))
                    :to-equal "[forgejo]\n\tuser = someone\n")
            (expect (with-temp-buffer (insert-file-contents authinfo) (buffer-string))
                    :to-equal (concat "machine codeberg.org/api/v1 login someone^ghub"
                                      " password not-a-codeberg-token\n"))
            (expect (file-modes authinfo) :to-equal #o600)
            (expect (getenv-internal "REMOTO_KEYS_TOKEN_FILE" env) :to-be nil)
            (remoto-keys--stop "sc-cbtoken")
            (expect (file-exists-p authinfo) :to-be nil))
        (delete-directory remoto-keys--dir t))))
  (it "passes the run's REMOTO_KEYS_INIT to a profile whose setup has no init"
    (let* ((process-environment (cons "REMOTO_KEYS_INIT=(plant)" process-environment))
           (remoto-keys--dir (file-name-as-directory (make-temp-file "remoto-keys" t))))
      (unwind-protect
          (progn
            (expect (getenv-internal "REMOTO_KEYS_INIT" (remoto-keys--env "vanilla" "vanilla" "/e/"))
                    :to-equal "(plant)")
            (expect (getenv-internal "REMOTO_KEYS_INIT"
                                     (remoto-keys--env "sc-x" "vanilla" "/e/" '(:init (own))))
                    :to-equal "(own)"))
        (delete-directory remoto-keys--dir t))))
  (it "leaves out a variable the run does not have, so no empty TMPDIR"
    (let* ((process-environment (cons "TMPDIR" process-environment))
           (remoto-keys--dir (file-name-as-directory (make-temp-file "remoto-keys" t)))
           (env (remoto-keys--env "vanilla" "vanilla" "/elpa/")))
      (unwind-protect
          (expect (seq-find (lambda (entry) (string-prefix-p "TMPDIR" entry)) env) :to-be nil)
        (delete-directory remoto-keys--dir t)))))

(describe "remoto-keys--json"
  :var (answer exit curl-args curl-input)
  (before-each
    (setq exit 0 curl-args nil curl-input nil)
    (spy-on 'executable-find :and-return-value "/usr/bin/curl")
    (spy-on 'url-retrieve-synchronously)
    ;; curl writes the body, then the status that -w asks for on a line of its own.
    (spy-on 'call-process-region
            :and-call-fake (lambda (start _end _program _delete _buffer _display &rest args)
                             (setq curl-input start curl-args args)
                             (insert answer)
                             exit)))
  (it "reads the account of a token"
    (setq answer "{\"login\":\"someone\",\"id\":1}\n200")
    (expect (remoto-keys--account "GitHub" "https://example.org/user" "not-a-token")
            :to-equal "someone"))
  (it "gives curl the token on its standard input, never as an argument"
    (setq answer "{\"login\":\"someone\"}\n200")
    (remoto-keys--json "https://example.org/user" "not-a-token")
    (expect curl-input :to-equal "Authorization: token not-a-token\n")
    (expect (seq-find (lambda (arg) (string-search "not-a-token" arg)) curl-args) :to-be nil)
    (expect (last curl-args) :to-equal '("https://example.org/user")))
  (it "reads GitHub's search requests left"
    (setq answer "{\"resources\":{\"search\":{\"remaining\":5,\"reset\":100}}}\n200")
    (expect (remoto-keys--search-left) :to-equal '(5 . 100)))
  (it "answers nil for an answer without the field"
    (setq answer "{\"message\":\"Bad credentials\"}\n200")
    (expect (remoto-keys--search-left) :to-be nil))
  (it "answers nil, and runs no url.el, when no host answers"
    ;; A batch Emacs exits 255 on an error in url.el's process sentinel.
    (setq answer "curl: (6) Could not resolve host: api.github.com" exit 6)
    (expect (remoto-keys--search-left) :to-be nil)
    (expect 'url-retrieve-synchronously :not :to-have-been-called))
  (it "signals why on one line when an answer is no success"
    (setq answer "{\n  \"message\": \"Bad credentials\"\n}\n401")
    (expect (remoto-keys--ask "https://example.org/user" "not-a-token")
            :to-throw 'error '("HTTP 401: { \"message\": \"Bad credentials\" }"))
    (setq answer "curl: (6) Could not resolve host: example.org" exit 6)
    (expect (remoto-keys--ask "https://example.org/user" nil)
            :to-throw 'error '("curl: (6) Could not resolve host: example.org"))))

(describe "remoto-keys--dead-urls"
  (it "asks each web URL a case copied or browsed once, and keeps those that fail"
    (let ((asked nil))
      (spy-on 'remoto-keys--url-status
              :and-call-fake (lambda (url) (push url asked) (if (string-suffix-p "gone" url) 404 200)))
      (expect (remoto-keys--dead-urls '(:kill "https://x/ok"
                                        :browsed ("https://x/gone" "https://x/ok"
                                                  "git@codeberg.org:a/b.git")))
              :to-equal '(("https://x/gone" . 404)))
      (expect (sort asked #'string<) :to-equal '("https://x/gone" "https://x/ok"))))
  (it "checks no URL without curl, and says so once"
    ;; The remoto-linux image has no curl: every URL check failed "answers nothing".
    (let ((remoto-keys--no-curl-said nil)
          (printed nil))
      (spy-on 'executable-find :and-return-value nil)
      (spy-on 'remoto-keys--url-status)
      (let ((standard-output (lambda (char) (push char printed))))
        (expect (remoto-keys--dead-urls '(:kill "https://x/gone")) :to-be nil)
        (expect (remoto-keys--dead-urls '(:browsed ("https://x/other"))) :to-be nil)
        (expect (remoto-keys--dead-urls '(:kill "git@codeberg.org:a/b.git")) :to-be nil))
      (expect 'remoto-keys--url-status :not :to-have-been-called)
      (expect (concat (nreverse printed))
              :to-equal (concat "No curl: web URLs go unchecked, and the run asks no forge"
                                " for a token's account or for GitHub's search budget\n")))))

(describe "remoto-e2e--embark-action-cases"
  (it "keeps GitHub's labels and tags Codeberg's, with the same actions"
    (let ((github (remoto-e2e--embark-action-cases remoto-e2e--github-targets))
          (codeberg (remoto-e2e--embark-action-cases remoto-e2e--codeberg-targets "cb")))
      (expect (car (car github)) :to-equal "embark y on a repository line")
      (expect (mapcar #'car codeberg)
              :to-equal (mapcar (lambda (case) (concat "cb " (car case))) github))
      (expect (member "/cb:forgejo/docs@next:/docs/" (assoc "cb embark y on a file candidate" codeberg))
              :to-be-truthy))))

(describe "remoto-keys--skip"
  (it "says which token a scenario lacks"
    (let ((remoto-keys--token nil) (remoto-keys--codeberg-token nil))
      (expect (remoto-keys--skip '(:token t)) :to-equal "needs REMOTO_E2E_TOKEN")
      (expect (remoto-keys--skip '(:codeberg t)) :to-equal "needs REMOTO_E2E_CODEBERG_TOKEN")
      (expect (remoto-keys--skip '(:gitconfig "")) :to-be nil)))
  (it "runs the Codeberg scenario with Codeberg's token"
    (let ((remoto-keys--codeberg-token "not-a-codeberg-token"))
      (expect (remoto-keys--skip '(:codeberg t)) :to-be nil))))

(describe "remoto-keys--learn-logins"
  :var (answers)
  (before-each
    (spy-on 'sleep-for)
    ;; A string answer is the error that asking signals.
    (spy-on 'remoto-keys--ask
            :and-call-fake (lambda (&rest _)
                             (let ((answer (pop answers)))
                               (if (stringp answer) (error "%s" answer) answer)))))

  (it "asks again after a failure and takes the account a later answer names"
    (setq answers '("curl: (6) Could not resolve host: api.github.com" ((login . "someone"))))
    (let ((remoto-keys--token "not-a-token")
          (remoto-keys--github-login nil)
          (remoto-e2e--root-account "emacs-mirror"))
      (expect (with-output-to-string (remoto-keys--learn-logins))
              :to-equal "GitHub token of someone\n")
      (expect remoto-keys--github-login :to-equal "someone")
      (expect remoto-e2e--root-account :to-equal "someone")))

  (it "stops the run and says why when no answer names an account"
    ;; The profile went on anonymously, and its first cases failed for want of a token.
    (setq answers '("curl: (6) Could not resolve host: api.github.com"
                    [1 2]
                    "curl: (6) Could not resolve host: api.github.com"))
    (let ((remoto-keys--token "not-a-token")
          (remoto-keys--github-login nil))
      (expect (with-output-to-string (remoto-keys--learn-logins))
              :to-throw 'error '("GitHub names no account for its token: curl: (6) Could not resolve host: api.github.com"))
      (expect 'remoto-keys--ask :to-have-been-called-times 3)
      (expect remoto-keys--github-login :to-be nil)))

  (it "asks Codeberg only for a run that uses its account"
    (setq answers '(((login . "someone"))))
    (let ((remoto-keys--token "not-a-token")
          (remoto-keys--codeberg-token "not-a-codeberg-token")
          (remoto-keys--github-login nil)
          (remoto-keys--codeberg-login nil))
      (with-output-to-string (remoto-keys--learn-logins))
      (expect 'remoto-keys--ask :to-have-been-called-times 1)
      (expect remoto-keys--codeberg-login :to-be nil)))

  (it "stops the scenarios when Codeberg names no account for its token"
    (setq answers '("HTTP 401: {\"message\":\"token is required\"}"
                    "HTTP 401: {\"message\":\"token is required\"}"
                    "HTTP 401: {\"message\":\"token is required\"}"))
    (let ((remoto-keys--token nil)
          (remoto-keys--codeberg-token "not-a-codeberg-token")
          (remoto-keys--codeberg-login nil))
      (expect (with-output-to-string (remoto-keys--learn-logins t))
              :to-throw 'error '("Codeberg names no account for its token: HTTP 401: {\"message\":\"token is required\"}")))))

(describe "remoto-keys--scenarios"
  (let ((scenarios (remoto-keys--scenarios 8899)))
    (it "holds steps of the known kinds; lit needs GitHub's token, cbtoken Codeberg's"
      (expect (mapcar #'car scenarios)
              :to-equal '("none" "cbbad" "lit" "cbtoken" "mock" "instances"
                          "boot-cb-forgejo-docs" "boot-cb-forgejo-docs-README-md"
                          "boot-cb-forgejo-forgejo-14989" "boot-gh-agzam-remoto-el"
                          "boot-gh-agzam-remoto-el-README-org" "boot-gh-agzam-remoto-el-51"))
      (dolist (scenario scenarios)
        (dolist (step (cddr scenario))
          (expect (memq (car step) '(case step probe fault)) :to-be-truthy)))
      (expect (seq-filter (lambda (scenario) (plist-get (cadr scenario) :token)) scenarios)
              :to-equal (list (assoc "lit" scenarios)))
      (expect (seq-filter (lambda (scenario) (plist-get (cadr scenario) :codeberg)) scenarios)
              :to-equal (list (assoc "cbtoken" scenarios))))
    (it "lists the Dired of the Codeberg token's own account"
      (let ((remoto-keys--codeberg-login "someone"))
        (expect (seq-find (lambda (step) (equal (cadr step) "dired /cb:someone/"))
                          (cddr (assoc "cbtoken" (remoto-keys--scenarios 8899))))
                :to-equal `(case "dired /cb:someone/" ,(kbd "C-x d") "/cb:someone/" submit))))
    (it "lists the token's organization and opens its private repository, when it has them"
      (let* ((labels (lambda ()
                       (mapcar #'cadr (cddr (assoc "cbtoken" (remoto-keys--scenarios 8899))))))
             (without (let ((remoto-keys--codeberg-login "someone")) (funcall labels)))
             (with (let ((remoto-keys--codeberg-login "someone")
                         (remoto-keys--codeberg-org "an-org")
                         (remoto-keys--codeberg-private "an-org/secret"))
                     (funcall labels))))
        (expect (seq-difference with without) :to-equal '("dired /cb:an-org/" "ff /cb:an-org/secret"))))
    (it "points the mock instance at the port, over plain HTTP"
      (expect (format "%S" (plist-get (cadr (assoc "mock" scenarios)) :init))
              :to-match "\"127\\.0\\.0\\.1:8899/api/v1\".*(\"mock\" \"127\\.0\\.0\\.1:8899\")"))
    (it "types a setopt form at eval-expression"
      (expect (remoto-keys--steps (cddr (car (remoto-keys--setopt '(("gitea" "gitea.com")))))
                                  "vanilla")
              :to-equal '((key "M-:")
                          (text "(setopt remoto-forgejo-instances '((\"gitea\" \"gitea.com\")))")
                          (key "Enter"))))))

(defun remoto-keys-tests--mock-get (path)
  "Return (STATUS . BODY) that a fresh mock Forgejo answers for PATH."
  (let* ((remoto-keys--fault "none")
         (standard-output #'ignore)
         ;; remoto-tests.el points url.el at a dead proxy; this server is local.
         (url-proxy-services nil)
         (server (remoto-keys--mock-start))
         (buffer (url-retrieve-synchronously
                  (format "http://127.0.0.1:%d%s" (process-contact server :service) path)
                  t t 10)))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (re-search-forward "\r?\n\r?\n")
          (cons url-http-response-status (buffer-substring (point) (point-max))))
      (kill-buffer buffer)
      (delete-process server))))

(describe "the mock Forgejo"
  (it "counts the bytes of an answer's body, not its characters"
    (expect (remoto-keys--answer 200 "text/plain" "é" '("X-A" . "1"))
            :to-equal (concat "HTTP/1.1 200 Mock\r\nContent-Type: text/plain\r\n"
                              "Content-Length: 2\r\nX-A: 1\r\nConnection: close\r\n\r\n"
                              "\303\251")))
  (it "passes on the status, the type, the body and the paging headers"
    (with-temp-buffer
      (insert "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n"
              "Link: <https://codeberg.org/x?page=2>; rel=\"next\"\r\nSet-Cookie: a=b\r\n\r\n[1]")
      (expect (remoto-keys--relay)
              :to-equal (remoto-keys--answer 404 "application/json" "[1]"
                                             '("Link" . "<https://codeberg.org/x?page=2>; rel=\"next\"")))))
  (it "answers a canned fault over HTTP"
    (let* ((remoto-keys--fault "502")
           (standard-output #'ignore)
           ;; remoto-tests.el points url.el at a dead proxy; this server is local.
           (url-proxy-services nil)
           (server (remoto-keys--mock-start))
           (buffer (url-retrieve-synchronously
                    (format "http://127.0.0.1:%d/api/v1/repos/forgejo/docs"
                            (process-contact server :service))
                    t t 10)))
      (unwind-protect
          (with-current-buffer buffer
            (expect url-http-response-status :to-equal 502)
            (goto-char (point-min))
            (expect (search-forward "<h1>502 Bad Gateway</h1>" nil t) :to-be-truthy))
        (kill-buffer buffer)
        (delete-process server))))
  (it "asks codeberg.org through curl and passes its answer on, whatever the header case"
    (spy-on 'remoto-keys--curl-p :and-return-value t)
    (spy-on 'remoto-keys--curl
            :and-return-value (cons 0 (concat "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n"
                                              "x-total-count: 3\r\n\r\n[1]")))
    (expect (remoto-keys--upstream "/api/v1/repos/forgejo/docs")
            :to-equal (remoto-keys--answer 200 "application/json" "[1]" '("X-Total-Count" . "3")))
    (expect (car (spy-calls-args-for 'remoto-keys--curl 0))
            :to-equal "https://codeberg.org/api/v1/repos/forgejo/docs"))
  (it "answers 502 when codeberg.org gives no answer"
    (spy-on 'remoto-keys--curl-p :and-return-value t)
    (spy-on 'remoto-keys--curl :and-return-value '(6 . "curl: (6) Could not resolve host\n"))
    (expect (remoto-keys-tests--mock-get "/api/v1/repos/forgejo/docs")
            :to-equal '(502 . "mock Forgejo upstream: curl: (6) Could not resolve host\n")))
  (it "answers 502 when the relay fails, and keeps the run alive"
    ;; An error that leaves a process filter ends a batch Emacs with 255.
    (spy-on 'remoto-keys--upstream :and-call-fake (lambda (_) (error "Relay broke")))
    (expect (remoto-keys-tests--mock-get "/api/v1/repos/forgejo/docs")
            :to-equal '(502 . "mock Forgejo: Relay broke\n"))))

(describe "remoto-keys--profile"
  :var (counts output written)
  (before-each
    (setq counts nil output nil written nil)
    (spy-on 'remoto-keys--start :and-return-value '(:lib "remoto"))
    (spy-on 'remoto-keys--stop)
    (spy-on 'remoto-keys--answers-p :and-return-value t)
    (spy-on 'remoto-keys--expected-state)
    (spy-on 'remoto-e2e--cases :and-return-value '(("ff /gh:a" nil "a") ("ff /gh:b" nil "b")))
    (spy-on 'remoto-e2e--codeberg-cases)
    (spy-on 'remoto-keys--write
            :and-call-fake (lambda (file results)
                             (push (cons (file-name-nondirectory file)
                                         (mapcar (lambda (r) (plist-get r :label)) results))
                                   written)))
    ;; The case ff /gh:a loses the Emacs it types into; ff /gh:b passes.
    (spy-on 'remoto-keys--run
            :and-call-fake (lambda (name case &rest _)
                             (if (equal (car case) "ff /gh:a")
                                 (signal 'file-error (list "make client process failed"
                                                           "Connection refused"))
                               (list :label (car case) :seconds 1 :line name
                                     :state '(:mode dired-mode))))))

  (it "fails a case whose Emacs gives no state, says why, and goes on"
    (setq output (with-output-to-string
                   (setq counts (remoto-keys--profile "vanilla" "/elpa/" nil))))
    (expect counts :to-equal '(:cases 2 :failed 1 :differ 0))
    (expect output :to-match (concat "^FAIL vanilla | ff /gh:a: no state: make client process"
                                     " failed: Connection refused$"))
    (expect written :to-equal '(("vanilla.eld" "ff /gh:a" "ff /gh:b")))
    (expect 'remoto-keys--start :to-have-been-called-times 1))

  (it "restarts an Emacs that gives no answer after the failed case"
    (spy-on 'remoto-keys--answers-p :and-return-value nil)
    (with-output-to-string
      (setq counts (remoto-keys--profile "vanilla" "/elpa/" nil)))
    (expect (plist-get counts :cases) :to-equal 2)
    (expect 'remoto-keys--start :to-have-been-called-times 2)
    (expect (spy-calls-args-for 'remoto-keys--start 1) :to-equal '("vanilla" "vanilla" "/elpa/")))

  (it "stops with why when the Emacs cannot start again, and writes the results so far"
    (spy-on 'remoto-keys--answers-p :and-return-value nil)
    (let ((starts 0))
      (spy-on 'remoto-keys--start
              :and-call-fake (lambda (&rest _)
                               (when (< 1 (cl-incf starts))
                                 (error "No answer from vanilla in 30s"))
                               '(:lib "remoto"))))
    (setq output (with-output-to-string
                   (setq counts (remoto-keys--profile "vanilla" "/elpa/" nil))))
    (expect counts :to-equal '(:cases 0 :failed 1 :differ 0))
    (expect output :to-match "^FAIL vanilla | stopped: No answer from vanilla in 30s$")
    (expect written :to-equal '(("vanilla.eld"))))

  (it "names a DIFF where origin/main's Emacs gives no state"
    (spy-on 'remoto-keys--run
            :and-call-fake (lambda (name case &rest _)
                             (if (string-suffix-p "-main" name)
                                 (error "No answer from vanilla-main in 30s")
                               (list :label (car case) :seconds 1 :line name
                                     :state '(:mode dired-mode)))))
    (setq output (with-output-to-string
                   (setq counts (remoto-keys--profile "vanilla" "/elpa/" "/elpa-main/"))))
    (expect counts :to-equal '(:cases 2 :failed 0 :differ 2))
    (expect output :to-match (concat "^DIFF vanilla | ff /gh:a: origin/main has no state:"
                                     " No answer from vanilla-main in 30s$"))
    (expect (spy-calls-args-for 'remoto-keys--answers-p 0) :to-equal '("vanilla-main" 60))))

(describe "remoto-keys--exit"
  (it "exits with the status the run returns"
    (spy-on 'kill-emacs)
    (remoto-keys--exit "vanilla" (lambda () 0))
    (expect 'kill-emacs :to-have-been-called-with 0))
  (it "exits 1, not 255, and says why when the run signals"
    (spy-on 'kill-emacs)
    (expect (with-output-to-string
              (remoto-keys--exit "vanilla" (lambda () (error "No answer from vanilla in 30s"))))
            :to-equal "remoto-keys vanilla: stopped: No answer from vanilla in 30s\n")
    (expect 'kill-emacs :to-have-been-called-with 1)))

(describe "remoto-keys--start"
  (it "kills the tmux server of the run whenever the run exits"
    ;; A server left behind keeps make's jobserver pipe open, so make -j never exits.
    (let ((remoto-keys--dir (file-name-as-directory (make-temp-file "remoto-keys" t)))
          (remoto-keys--keep nil)
          (kill-emacs-hook nil))
      (spy-on 'remoto-keys--tmux
              :and-call-fake (lambda (&rest args)
                               (when (equal (car args) "new-session")
                                 (with-temp-file (expand-file-name "sock/vanilla"
                                                                   remoto-keys--dir)))
                               ""))
      (spy-on 'remoto-keys--wait-idle)
      (spy-on 'remoto-keys--eval :and-return-value '(:lib "remoto"))
      (unwind-protect
          (progn
            (remoto-keys--start "vanilla" "vanilla" "/elpa/")
            (spy-calls-reset 'remoto-keys--tmux)
            (run-hooks 'kill-emacs-hook)
            (expect 'remoto-keys--tmux :to-have-been-called-with "kill-server"))
        (delete-directory remoto-keys--dir t)))))

(describe "remoto-e2e--diff"
  (it "lists the keys whose values differ, both ways"
    (expect (remoto-e2e--diff '(:mode dired-mode :count 2) '(:mode dired-mode :count 3 :error "x"))
            :to-equal '((:count :expected 2 :actual 3) (:error :expected nil :actual "x"))))
  (it "returns nil for equal states"
    (expect (remoto-e2e--diff '(:mode dired-mode) '(:mode dired-mode)) :to-be nil)))

;;; remoto-keys-tests.el ends here
