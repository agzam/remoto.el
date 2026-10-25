;; -*- mode: lisp-data -*-
;; Written by make test-e2e-update.

("tab /gh:agzam/" :buffer "*scratch*" :mode lisp-interaction-mode
 :minibuffer "/tmp//gh:agzam/" :requests
 ("async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"))

("tab /gh:agzam/remoto.el@" :buffer "*scratch*" :mode
 lisp-interaction-mode :minibuffer "/tmp//gh:agzam/remoto.el@"
 :completions
 ("1.0.0:" "1.0.1:" "1.0.2:" "1.0.3:" "1.1.0:" "1.2.0:" "1.3.0:"
  "1.4.0:" "1.5.0:" "1.6.0:")
 :requests
 ("async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"))
