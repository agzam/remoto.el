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
            :to-equal '((key "F12") (text "remoto.el") (key "Enter") (pause)))))

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
    (it "fails raw HTTP text, too many requests, and a runner's note"
      (expect (remoto-keys--checks "ff /gh:" `(:raw ("HTTP/1.1 502 Bad Gateway")
                                               :requests ,(make-list 21 "r"))
                                   nil "still busy after 60s")
              :to-equal '("still busy after 60s"
                          "raw HTTP text in the messages: HTTP/1.1 502 Bad Gateway"
                          "21 requests, more than 20")))))

(describe "remoto-keys--expected-state"
  (it "takes vanilla's golden state for a profile without its own, evil's for ex"
    (expect (remoto-keys--expected-state "ido" "ff /gh:agzam/remoto.el")
            :to-equal (remoto-keys--expected-state "vanilla" "ff /gh:agzam/remoto.el"))
    (expect (remoto-keys--expected-state "full" "ex /gh:agzam/remoto.el")
            :to-equal (remoto-keys--expected-state "evil" "ex /gh:agzam/remoto.el"))
    (expect (plist-get (remoto-keys--expected-state "vanilla" "ff /gh:agzam/remoto.el") :dired)
            :to-equal "/github:agzam/remoto.el@main:/")))

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
  :var (answer)
  (before-each
    ;; url.el hands the buffer over with point past the headers.
    (spy-on 'url-retrieve-synchronously
            :and-call-fake (lambda (&rest _)
                             (with-current-buffer (generate-new-buffer " *http test*")
                               (insert "HTTP/1.1 200 OK\nContent-Type: application/json\n\n" answer)
                               (current-buffer)))))
  (it "reads the account of a token, wherever url.el leaves point"
    (setq answer "{\"login\":\"someone\",\"id\":1}")
    (expect (remoto-keys--login "https://example.org/user" "not-a-token") :to-equal "someone"))
  (it "reads GitHub's search requests left"
    (setq answer "{\"resources\":{\"search\":{\"remaining\":5,\"reset\":100}}}")
    (expect (remoto-keys--search-left) :to-equal '(5 . 100)))
  (it "answers nil for an answer without the field"
    (setq answer "{\"message\":\"Bad credentials\"}")
    (expect (remoto-keys--login "https://example.org/user" "not-a-token") :to-be nil)
    (expect (remoto-keys--search-left) :to-be nil)
    (setq answer "[1, 2]")
    (expect (remoto-keys--login "https://example.org/user" "not-a-token") :to-be nil)))

(describe "remoto-keys--skip"
  (it "says which token a scenario lacks"
    (let ((remoto-keys--token nil) (remoto-keys--codeberg-token nil))
      (expect (remoto-keys--skip '(:token t)) :to-equal "needs REMOTO_E2E_TOKEN")
      (expect (remoto-keys--skip '(:codeberg t)) :to-equal "needs REMOTO_E2E_CODEBERG_TOKEN")
      (expect (remoto-keys--skip '(:gitconfig "")) :to-be nil)))
  (it "skips the Codeberg scenario when Codeberg names no account for the token"
    (let ((remoto-keys--codeberg-token "not-a-codeberg-token") (remoto-keys--codeberg-login nil))
      (expect (remoto-keys--skip '(:codeberg t))
              :to-equal "Codeberg names no account for REMOTO_E2E_CODEBERG_TOKEN"))
    (let ((remoto-keys--codeberg-token "not-a-codeberg-token") (remoto-keys--codeberg-login "x"))
      (expect (remoto-keys--skip '(:codeberg t)) :to-be nil))))

(describe "remoto-keys--scenarios"
  (let ((scenarios (remoto-keys--scenarios 8899)))
    (it "holds steps of the known kinds; lit needs GitHub's token, cbtoken Codeberg's"
      (expect (mapcar #'car scenarios)
              :to-equal '("none" "cbbad" "lit" "cbtoken" "mock" "instances"))
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
    (it "points the mock instance at the port, over plain HTTP"
      (expect (format "%S" (plist-get (cadr (assoc "mock" scenarios)) :init))
              :to-match "\"127\\.0\\.0\\.1:8899/api/v1\".*(\"mock\" \"127\\.0\\.0\\.1:8899\")"))
    (it "types a setopt form at eval-expression"
      (expect (remoto-keys--steps (cddr (car (remoto-keys--setopt '(("gitea" "gitea.com")))))
                                  "vanilla")
              :to-equal '((key "M-:")
                          (text "(setopt remoto-forgejo-instances '((\"gitea\" \"gitea.com\")))")
                          (key "Enter"))))))

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
        (delete-process server)))))

(describe "remoto-e2e--diff"
  (it "lists the keys whose values differ, both ways"
    (expect (remoto-e2e--diff '(:mode dired-mode :count 2) '(:mode dired-mode :count 3 :error "x"))
            :to-equal '((:count :expected 2 :actual 3) (:error :expected nil :actual "x"))))
  (it "returns nil for equal states"
    (expect (remoto-e2e--diff '(:mode dired-mode) '(:mode dired-mode)) :to-be nil)))

;;; remoto-keys-tests.el ends here
