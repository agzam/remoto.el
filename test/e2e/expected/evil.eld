;; -*- mode: lisp-data -*-
;; Written by make test-e2e-update.

("ex /gh:" :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests ("/user/orgs?per_page=100&page=1"))

("ex /github:" :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests ("/user/orgs?per_page=100&page=1"))

("ex /gh:agzam" :mode dired-mode :dired "/github:" :matches t :names
 ("agzam" "AGZAMOVVVS21" "AGZamu" "AGzamDev" "AgZaMhOdJ" "AgZaMiC"
  "Agzam-Ar" "Agzam-lev" "Agzam020" "Agzam06")
 :count 94 :point "agzam" :requests
 ("/search/users?q=agzam&per_page=100"))

("ex /gh:qlik" :mode dired-mode :dired "/github:" :matches t :names
 ("qlik" "CodeQlik" "Qlik-BT" "Qlik-Branch"
  "Qlik-Data-Integration-Team" "Qlik-PE" "Qlik-Sense-Extensions"
  "QlikDeploymentFramework" "QlikFrancePlatform" "QlikFreak")
 :count 31 :point "qlik" :requests
 ("/search/users?q=qlik&per_page=100"))

("ex /gh:agzam/" :mode dired-mode :dired "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "FTPSearchAndReplace" "Fennel")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("ex /gh:agzam/remoto.el" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ex /gh:agzam/remoto" :mode dired-mode :dired "/github:agzam/"
 :matches t :names ("remoto.el") :count 1 :point "remoto.el" :requests
 ("/repos/agzam/remoto"
  "/search/repositories?q=remoto%20in%3Aname%20user%3Aagzam&per_page=100"))

("ex /gh:agzam/remoto.el/" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ex /gh:agzam/remoto.el/README.org" :mode org-mode :file
 "/github:agzam/remoto.el@main:/README.org" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"
  "/repos/agzam/remoto.el/contents/README.org?ref=main"))

("ex /gh:agzam/remoto.el/READ" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :matches t :names ("README.org")
 :count 1 :point "README.org" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ex /gh:agzam/remoto.el/nope.txt" :mode text-mode :file
 "/github:agzam/remoto.el@main:/nope.txt" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ex /gh:agzam/remoto.el@" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names
 ("1.0.0" "1.0.1" "1.0.2" "1.0.3" "1.1.0" "1.2.0" "1.3.0" "1.4.0"
  "1.5.0" "1.6.0")
 :count 19 :point "1.0.0" :requests
 ("/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("ex /gh:agzam/remoto.el@ma" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names ("main") :count 1 :point
 "main" :requests
 ("/repos/agzam/remoto.el/git/trees/ma?recursive=1"
  "/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("ex /gh:agzam/remoto.el@main" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ex /gh:agzam/remoto.el@main:" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ex /gh:agzam/remoto.el@main:/test/" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :names
 ("." ".." "demo.gif" "el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 7 :point "demo.gif" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ex /gh:agzam/remoto.el@main:/test" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :names
 ("." ".." "demo.gif" "el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 7 :point "demo.gif" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ex /gh:agzam/remoto.el@main:/test/remo" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :matches t :names
 ("el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 4 :point "el-remoto-logo.png" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ex /gh:agzam/remoto.el@2.2.0:/" :mode dired-mode :dired
 "/github:agzam/remoto.el@2.2.0:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/2.2.0?recursive=1"))

("ex /gh:agzam/remoto.el@2.2" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names ("2.2.0") :count 1
 :point "2.2.0" :requests
 ("/repos/agzam/remoto.el/git/trees/2.2?recursive=1"
  "/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("ex /gh:agzam/remoto.el@ceaf310:/" :mode dired-mode :dired
 "/github:agzam/remoto.el@ceaf310:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/ceaf310?recursive=1"))

("ex /gh:agzam/remoto.el#47" :buffer
 "*remoto: /github:agzam/remoto.el#47*" :mode remoto-topic-mode
 :requests
 ("/repos/agzam/remoto.el/issues/47" "/repos/agzam/remoto.el/pulls/47"
  "/repos/agzam/remoto.el/pulls/47/reviews"
  "/repos/agzam/remoto.el/issues/47/comments"))

("ex /gh:agzam/.." :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests ("/user/orgs?per_page=100&page=1"))

("ex /gh:agzam/remoto.el/.." :mode dired-mode :dired "/github:agzam/"
 :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "FTPSearchAndReplace" "Fennel")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("ex /gh:agzam/remoto.el@main:/test/.." :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ex /gh:agzam/.emacs.d" :mode dired-mode :dired
 "/github:agzam/.emacs.d@main:/" :names
 ("." ".." ".github" ".gitignore" ".rgignore" "AGENTS.md" "README.md"
  "bb.edn" "config.el" "early-init.el")
 :count 16 :point ".github" :requests
 ("/repos/agzam/.emacs.d"
  "/repos/agzam/.emacs.d/git/trees/main?recursive=1"))

("ex /gh:agzam/.doom" :mode dired-mode :dired "/github:agzam/"
 :matches t :names (".doom.d") :count 1 :point ".doom.d" :requests
 ("/repos/agzam/.doom"
  "/search/repositories?q=.doom%20in%3Aname%20user%3Aagzam&per_page=100"))

("ex /gh:Agzam/Remoto.el" :mode dired-mode :dired
 "/github:Agzam/Remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("/repos/Agzam/Remoto.el"
  "/repos/Agzam/Remoto.el/git/trees/main?recursive=1"))

("ex /gh:agzam/remoto el" :mode dired-mode :dired "/github:agzam/"
 :matches t :names ("remoto.el") :count 1 :point "remoto.el" :requests
 ("/search/repositories?q=remoto%20el%20in%3Aname%20user%3Aagzam&per_page=100"))

("ex /gh:no-such-owner-zz9q/" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: not found: users/no-such-owner-zz9q/repos?sort=pushed&per_page=100&page=1"
 :requests
 ("/user/orgs?per_page=100&page=1"
  "/users/no-such-owner-zz9q/repos?sort=pushed&per_page=100&page=1"))

("ex /gh:no-such-owner-zz9q" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: no account matches no-such-owner-zz9q" :requests
 ("/search/users?q=no-such-owner-zz9q&per_page=100"))

("ex /gh:no-such-owner-zz9q/repo" :buffer "*scratch*" :mode
 lisp-interaction-mode :error "Remoto: no account no-such-owner-zz9q"
 :requests
 ("/repos/no-such-owner-zz9q/repo"
  "/search/repositories?q=repo%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"))

("ex /gh:agzam/zzqqxx" :buffer "*scratch*" :mode lisp-interaction-mode
 :error "Remoto: no repository of agzam matches zzqqxx" :requests
 ("/repos/agzam/zzqqxx"
  "/search/repositories?q=zzqqxx%20in%3Aname%20user%3Aagzam&per_page=100"))

("ex /gh:agzam/remoto.el@zzqq" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: no branch or tag of agzam/remoto.el matches zzqq" :requests
 ("/repos/agzam/remoto.el/git/trees/zzqq?recursive=1"
  "/repos/agzam/remoto.el/branches?per_page=100&page=1"
  "/repos/agzam/remoto.el/tags?per_page=100&page=1"))

("ex https://github.com/agzam/remoto.el" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))
