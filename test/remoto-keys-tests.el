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

(describe "remoto-e2e--diff"
  (it "lists the keys whose values differ, both ways"
    (expect (remoto-e2e--diff '(:mode dired-mode :count 2) '(:mode dired-mode :count 3 :error "x"))
            :to-equal '((:count :expected 2 :actual 3) (:error :expected nil :actual "x"))))
  (it "returns nil for equal states"
    (expect (remoto-e2e--diff '(:mode dired-mode) '(:mode dired-mode)) :to-be nil)))

;;; remoto-keys-tests.el ends here
