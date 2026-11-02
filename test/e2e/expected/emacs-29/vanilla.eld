;; -*- mode: lisp-data -*-
;; Written by make test-e2e-update.

("tab /gh:agzam/" :buffer "*scratch*" :mode lisp-interaction-mode
 :minibuffer "/tmp//gh:agzam/" :requests
 ("async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"))

("tab /gh:agzam/remoto.el@" :buffer "*scratch*" :mode
 lisp-interaction-mode :minibuffer "/tmp//gh:agzam/remoto.el@"
 :requests
 ("async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1")
 :completions
 ("1.0.0:" "1.0.1:" "1.0.2:" "1.0.3:" "1.1.0:" "1.2.0:" "1.3.0:"
  "1.4.0:" "1.5.0:" "1.6.0:"))

("dired + in an owner listing" :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "FTPSearchAndReplace" "Fennel")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))
