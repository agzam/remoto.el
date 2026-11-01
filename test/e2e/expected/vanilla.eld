;; -*- mode: lisp-data -*-
;; Written by make test-e2e-update.

("ff /gh:" :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests ("/user/orgs?per_page=100&page=1"))

("ff /github:" :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests ("/user/orgs?per_page=100&page=1"))

("ff /gh:agzam" :mode dired-mode :dired "/github:" :matches t :names
 ("agzam" "Agzam-Ar" "agzam-asadullaev" "agzam-dev" "agzam-juraev786"
  "Agzam-lev" "agzam-zham" "agzam009" "Agzam020" "agzam05")
 :count 94 :point "agzam" :requests
 ("/search/users?q=agzam&per_page=100"))

("ff /gh:qlik" :mode dired-mode :dired "/github:" :matches t :names
 ("qlik" "andre-ferreira-qlik" "CodeQlik" "qlik-all" "Qlik-Branch"
  "Qlik-BT" "Qlik-Data-Integration-Team" "qlik-download" "qlik-hhe"
  "qlik-ktg")
 :count 31 :point "qlik" :requests
 ("/search/users?q=qlik&per_page=100"))

("ff /gh:agzam/" :mode dired-mode :dired "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("ff /gh:agzam/remoto.el" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto" :mode dired-mode :dired "/github:agzam/"
 :matches t :names ("remoto.el") :count 1 :point "remoto.el" :requests
 ("/repos/agzam/remoto"
  "/search/repositories?q=remoto%20in%3Aname%20user%3Aagzam&per_page=100"))

("ff /gh:agzam/remoto.el/" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto.el/README.org" :mode org-mode :file
 "/github:agzam/remoto.el@main:/README.org" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"
  "/repos/agzam/remoto.el/contents/README.org?ref=main"))

("ff /gh:agzam/remoto.el/READ" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :matches t :names ("README.org")
 :count 1 :point "README.org" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto.el/nope.txt" :mode text-mode :file
 "/github:agzam/remoto.el@main:/nope.txt" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto.el@" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names
 ("1.0.0" "1.0.1" "1.0.2" "1.0.3" "1.1.0" "1.2.0" "1.3.0" "1.4.0"
  "1.5.0" "1.6.0")
 :count 19 :point "1.0.0" :requests
 ("/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("ff /gh:agzam/remoto.el@ma" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names ("main") :count 1 :point
 "main" :requests
 ("/repos/agzam/remoto.el/git/trees/ma?recursive=1"
  "/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("ff /gh:agzam/remoto.el@main" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto.el@main:" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto.el@main:/test/" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :names
 ("." ".." "demo.gif" "el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 7 :point "demo.gif" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto.el@main:/test" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :names
 ("." ".." "demo.gif" "el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 7 :point "demo.gif" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto.el@main:/test/remo" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :matches t :names
 ("el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 4 :point "el-remoto-logo.png" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto.el@2.2.0:/" :mode dired-mode :dired
 "/github:agzam/remoto.el@2.2.0:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/2.2.0?recursive=1"))

("ff /gh:agzam/remoto.el@2.2" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names ("2.2.0") :count 1
 :point "2.2.0" :requests
 ("/repos/agzam/remoto.el/git/trees/2.2?recursive=1"
  "/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("ff /gh:agzam/remoto.el@ceaf310:/" :mode dired-mode :dired
 "/github:agzam/remoto.el@ceaf310:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/ceaf310?recursive=1"))

("ff /gh:agzam/remoto.el#47" :buffer
 "*remoto: /github:agzam/remoto.el#47*" :mode remoto-topic-mode
 :requests
 ("/repos/agzam/remoto.el/issues/47" "/repos/agzam/remoto.el/pulls/47"
  "/repos/agzam/remoto.el/pulls/47/reviews"
  "/repos/agzam/remoto.el/issues/47/comments"))

("ff /gh:agzam/.." :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests ("/user/orgs?per_page=100&page=1"))

("ff /gh:agzam/remoto.el/.." :mode dired-mode :dired "/github:agzam/"
 :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("ff /gh:agzam/remoto.el@main:/test/.." :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/.emacs.d" :mode dired-mode :dired
 "/github:agzam/.emacs.d@main:/" :names
 ("." ".." ".github" ".gitignore" ".rgignore" "AGENTS.md" "bb.edn"
  "config.el" "early-init.el" "init.el")
 :count 16 :point ".github" :requests
 ("/repos/agzam/.emacs.d"
  "/repos/agzam/.emacs.d/git/trees/main?recursive=1"))

("ff /gh:agzam/.doom" :mode dired-mode :dired "/github:agzam/"
 :matches t :names (".doom.d") :count 1 :point ".doom.d" :requests
 ("/repos/agzam/.doom"
  "/search/repositories?q=.doom%20in%3Aname%20user%3Aagzam&per_page=100"))

("ff /gh:Agzam/Remoto.el" :mode dired-mode :dired
 "/github:Agzam/Remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/Agzam/Remoto.el"
  "/repos/Agzam/Remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto el" :mode dired-mode :dired "/github:agzam/"
 :matches t :names ("remoto.el") :count 1 :point "remoto.el" :requests
 ("/search/repositories?q=remoto%20el%20in%3Aname%20user%3Aagzam&per_page=100"))

("ff /gh:no-such-owner-zz9q/" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: not found: users/no-such-owner-zz9q/repos?sort=pushed&per_page=100&page=1"
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/no-such-owner-zz9q/repos?sort=pushed&per_page=100&page=1"))

("ff /gh:no-such-owner-zz9q" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: no account matches no-such-owner-zz9q" :requests
 ("/search/users?q=no-such-owner-zz9q&per_page=100"))

("ff /gh:no-such-owner-zz9q/repo" :buffer "*scratch*" :mode
 lisp-interaction-mode :error "Remoto: no account no-such-owner-zz9q"
 :requests
 ("/repos/no-such-owner-zz9q/repo"
  "/search/repositories?q=repo%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"))

("ff /gh:agzam/zzqqxx" :buffer "*scratch*" :mode lisp-interaction-mode
 :error "Remoto: no repository of agzam matches zzqqxx" :requests
 ("/repos/agzam/zzqqxx"
  "/search/repositories?q=zzqqxx%20in%3Aname%20user%3Aagzam&per_page=100"))

("ff /gh:agzam/remoto.el@zzqq" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: no branch or tag of agzam/remoto.el matches zzqq" :requests
 ("/repos/agzam/remoto.el/git/trees/zzqq?recursive=1"
  "/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("ff https://github.com/agzam/remoto.el" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:" :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests ("/user/orgs?per_page=100&page=1"))

("dired /github:" :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests ("/user/orgs?per_page=100&page=1"))

("dired /gh:agzam" :mode dired-mode :dired "/github:" :matches t
 :names
 ("agzam" "Agzam-Ar" "agzam-asadullaev" "agzam-dev" "agzam-juraev786"
  "Agzam-lev" "agzam-zham" "agzam009" "Agzam020" "agzam05")
 :count 94 :point "agzam" :requests
 ("/search/users?q=agzam&per_page=100"))

("dired /gh:qlik" :mode dired-mode :dired "/github:" :matches t :names
 ("qlik" "andre-ferreira-qlik" "CodeQlik" "qlik-all" "Qlik-Branch"
  "Qlik-BT" "Qlik-Data-Integration-Team" "qlik-download" "qlik-hhe"
  "qlik-ktg")
 :count 31 :point "qlik" :requests
 ("/search/users?q=qlik&per_page=100"))

("dired /gh:agzam/" :mode dired-mode :dired "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired /gh:agzam/remoto.el" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto" :mode dired-mode :dired "/github:agzam/"
 :matches t :names ("remoto.el") :count 1 :point "remoto.el" :requests
 ("/repos/agzam/remoto"
  "/search/repositories?q=remoto%20in%3Aname%20user%3Aagzam&per_page=100"))

("dired /gh:agzam/remoto.el/" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el/README.org" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/README.org" :names ("README.org")
 :count 1 :point "README.org" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el/READ" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :matches t :names ("README.org")
 :count 1 :point "README.org" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el/nope.txt" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/nope.txt" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el@" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names
 ("1.0.0" "1.0.1" "1.0.2" "1.0.3" "1.1.0" "1.2.0" "1.3.0" "1.4.0"
  "1.5.0" "1.6.0")
 :count 19 :point "1.0.0" :requests
 ("/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("dired /gh:agzam/remoto.el@ma" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names ("main") :count 1 :point
 "main" :requests
 ("/repos/agzam/remoto.el/git/trees/ma?recursive=1"
  "/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("dired /gh:agzam/remoto.el@main" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el@main:" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el@main:/test/" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :names
 ("." ".." "demo.gif" "el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 7 :point "demo.gif" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el@main:/test" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :names
 ("." ".." "demo.gif" "el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 7 :point "demo.gif" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el@main:/test/remo" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :matches t :names
 ("el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 4 :point "el-remoto-logo.png" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el@2.2.0:/" :mode dired-mode :dired
 "/github:agzam/remoto.el@2.2.0:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/2.2.0?recursive=1"))

("dired /gh:agzam/remoto.el@2.2" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names ("2.2.0") :count 1
 :point "2.2.0" :requests
 ("/repos/agzam/remoto.el/git/trees/2.2?recursive=1"
  "/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("dired /gh:agzam/remoto.el@ceaf310:/" :mode dired-mode :dired
 "/github:agzam/remoto.el@ceaf310:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/ceaf310?recursive=1"))

("dired /gh:agzam/remoto.el#47" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Directory /github:agzam/remoto.el#47 inaccessible or nonexistent")

("dired /gh:agzam/.." :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests ("/user/orgs?per_page=100&page=1"))

("dired /gh:agzam/remoto.el/.." :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired /gh:agzam/remoto.el@main:/test/.." :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/.emacs.d" :mode dired-mode :dired
 "/github:agzam/.emacs.d@main:/" :names
 ("." ".." ".github" ".gitignore" ".rgignore" "AGENTS.md" "bb.edn"
  "config.el" "early-init.el" "init.el")
 :count 16 :point ".github" :requests
 ("/repos/agzam/.emacs.d"
  "/repos/agzam/.emacs.d/git/trees/main?recursive=1"))

("dired /gh:agzam/.doom" :mode dired-mode :dired "/github:agzam/"
 :matches t :names (".doom.d") :count 1 :point ".doom.d" :requests
 ("/repos/agzam/.doom"
  "/search/repositories?q=.doom%20in%3Aname%20user%3Aagzam&per_page=100"))

("dired /gh:Agzam/Remoto.el" :mode dired-mode :dired
 "/github:Agzam/Remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/Agzam/Remoto.el"
  "/repos/Agzam/Remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto el" :mode dired-mode :dired "/github:agzam/"
 :matches t :names ("remoto.el") :count 1 :point "remoto.el" :requests
 ("/search/repositories?q=remoto%20el%20in%3Aname%20user%3Aagzam&per_page=100"))

("dired /gh:no-such-owner-zz9q/" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: not found: users/no-such-owner-zz9q/repos?sort=pushed&per_page=100&page=1"
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/no-such-owner-zz9q/repos?sort=pushed&per_page=100&page=1"))

("dired /gh:no-such-owner-zz9q" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: no account matches no-such-owner-zz9q" :requests
 ("/search/users?q=no-such-owner-zz9q&per_page=100"))

("dired /gh:no-such-owner-zz9q/repo" :buffer "*scratch*" :mode
 lisp-interaction-mode :error "Remoto: no account no-such-owner-zz9q"
 :requests
 ("/repos/no-such-owner-zz9q/repo"
  "/search/repositories?q=repo%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"))

("dired /gh:agzam/zzqqxx" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: no repository of agzam matches zzqqxx" :requests
 ("/repos/agzam/zzqqxx"
  "/search/repositories?q=zzqqxx%20in%3Aname%20user%3Aagzam&per_page=100"))

("dired /gh:agzam/remoto.el@zzqq" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: no branch or tag of agzam/remoto.el matches zzqq" :requests
 ("/repos/agzam/remoto.el/git/trees/zzqq?recursive=1"
  "/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("dired https://github.com/agzam/remoto.el" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("tab /gh:" :buffer "*scratch*" :mode lisp-interaction-mode
 :minibuffer "/tmp//gh:" :requests ("/user/orgs?per_page=100&page=1"))

("tab /gh:agz" :buffer "*scratch*" :mode lisp-interaction-mode
 :minibuffer "/tmp//gh:agz")

("tab /gh:agzam/" :buffer "*scratch*" :mode lisp-interaction-mode
 :minibuffer "/tmp//gh:agzam//" :requests
 ("async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"))

("tab /gh:agzam/rem" :buffer "*scratch*" :mode lisp-interaction-mode
 :minibuffer "/tmp//gh:agzam/remoto.el/" :requests
 ("async /search/repositories?q=rem%20in%3Aname%20user%3Aagzam&per_page=100"))

("tab /gh:agzam/remoto.el/" :buffer "*scratch*" :mode
 lisp-interaction-mode :minibuffer "/tmp//gh:agzam/remoto.el/"
 :requests
 ("async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"
  "async /repos/agzam/remoto.el"))

("tab /gh:agzam/remoto.el/RE" :buffer "*scratch*" :mode
 lisp-interaction-mode :minibuffer
 "/tmp//gh:agzam/remoto.el/README.org" :requests
 ("async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"))

("tab /gh:agzam/remoto.el@" :buffer "*scratch*" :mode
 lisp-interaction-mode :minibuffer "/tmp//gh:agzam/remoto.el@:"
 :requests
 ("async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"))

("tab /gh:agzam/remoto.el@ma" :buffer "*scratch*" :mode
 lisp-interaction-mode :minibuffer "/tmp//gh:agzam/remoto.el@main:"
 :requests
 ("async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"))

("tab /gh:agzam/remoto.el@main:/te" :buffer "*scratch*" :mode
 lisp-interaction-mode :minibuffer
 "/tmp//gh:agzam/remoto.el@main:/test/" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"
  "/repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"))

("tab /gh:agzam/remoto.el#" :buffer "*scratch*" :mode
 lisp-interaction-mode :minibuffer "/tmp//gh:agzam/remoto.el#"
 :completions ("47" "49" "48" "46" "45" "44" "43" "42" "41" "40")
 :requests
 ("async /repos/agzam/remoto.el/issues?state=open&sort=updated&per_page=30"))

("dired RET on a repository line" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired RET on an account line" :mode dired-mode :dired
 "/github:emacs-mirror/" :names ("." ".." "emacs") :count 3 :point
 "emacs" :requests
 ("/user/orgs?per_page=100&page=1"
  "/orgs/emacs-mirror/repos?sort=pushed&per_page=100&page=1"))

("dired RET on a ref line" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired RET on a file line" :mode org-mode :file
 "/github:agzam/remoto.el@main:/README.org" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"
  "/repos/agzam/remoto.el/contents/README.org?ref=main"))

("dired RET on a match line" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto"
  "/search/repositories?q=remoto%20in%3Aname%20user%3Aagzam&per_page=100"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired RET on .. at a repository root" :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"
  "/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired ^ in an owner listing" :mode dired-mode :dired "/github:"
 :names ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point
 "emacs-mirror" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired ^ at a repository root" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "changelog.org" "LICENSE" "Makefile"
  "plan.md" "README.org" "remoto-embark.el")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired g in an owner listing" :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired s in an owner listing" :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." "remoto.el" ".emacs.d" "go-jira.el" "eca-emacs"
  ".spacehammer" "mw-thesaurus.el" "wiktionary-bro.el"
  "google-translate")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired ( in an owner listing" :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired i on a repository line" :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 159 :point ".github" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired + in an owner listing" :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 145 :point ".doom.d" :error "Remoto: repository is read-only"
 :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired D on a repository line" :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 145 :point "remoto.el" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired R on a repository line" :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 145 :point "remoto.el" :error
 "Remoto: repository is read-only" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired remoto-refresh in an owner listing" :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: cache cleared for /github:agzam/"
  "Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired remoto-refresh in a Dired of refs" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names
 ("1.0.0" "1.0.1" "1.0.2" "1.0.3" "1.1.0" "1.2.0" "1.3.0" "1.4.0"
  "1.5.0" "1.6.0")
 :count 19 :point "1.0.0" :messages
 ("Remoto: cache cleared for agzam/remoto.el") :requests
 ("/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("dired owner listing whose pages outlast its cache" :mode dired-mode
 :dired "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "aero" "ag-themes.el")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))
