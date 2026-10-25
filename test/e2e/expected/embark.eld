;; -*- mode: lisp-data -*-
;; Written by make test-e2e-update.

("ff /gh:" :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "/user/orgs?per_page=100&page=1"))

("ff /github:" :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "/user/orgs?per_page=100&page=1"))

("ff /gh:agzam" :mode dired-mode :dired "/github:" :matches t :names
 ("agzam" "AGZAMOVVVS21" "AGZamu" "AGzamDev" "AgZaMhOdJ" "AgZaMiC"
  "Agzam-Ar" "Agzam-lev" "Agzam020" "Agzam06")
 :count 94 :point "agzam" :requests
 ("async /user/orgs?per_page=100&page=1"
  "/search/users?q=agzam&per_page=100"))

("ff /gh:qlik" :mode dired-mode :dired "/github:" :matches t :names
 ("qlik" "CodeQlik" "Qlik-BT" "Qlik-Branch"
  "Qlik-Data-Integration-Team" "Qlik-PE" "Qlik-Sense-Extensions"
  "QlikDeploymentFramework" "QlikFrancePlatform" "QlikFreak")
 :count 31 :point "qlik" :requests
 ("async /user/orgs?per_page=100&page=1"
  "/search/users?q=qlik&per_page=100"))

("ff /gh:agzam/" :mode dired-mode :dired "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "FTPSearchAndReplace" "Fennel")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("ff /gh:agzam/remoto.el" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto" :mode dired-mode :dired "/github:agzam/"
 :matches t :names ("remoto.el") :count 1 :point "remoto.el" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/repos/agzam/remoto"
  "/search/repositories?q=remoto%20in%3Aname%20user%3Aagzam&per_page=100"))

("ff /gh:agzam/remoto.el/" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto.el/README.org" :mode org-mode :file
 "/github:agzam/remoto.el@main:/README.org" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"
  "/repos/agzam/remoto.el/contents/README.org?ref=main"))

("ff /gh:agzam/remoto.el/READ" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :matches t :names ("README.org")
 :count 1 :point "README.org" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto.el/nope.txt" :mode text-mode :file
 "/github:agzam/remoto.el@main:/nope.txt" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto.el@" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names
 ("1.0.0" "1.0.1" "1.0.2" "1.0.3" "1.1.0" "1.2.0" "1.3.0" "1.4.0"
  "1.5.0" "1.6.0")
 :count 19 :point "1.0.0" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"))

("ff /gh:agzam/remoto.el@ma" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names ("main") :count 1 :point
 "main" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "/repos/agzam/remoto.el/git/trees/ma?recursive=1"))

("ff /gh:agzam/remoto.el@main" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto.el@main:" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"))

("ff /gh:agzam/remoto.el@main:/test/" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :names
 ("." ".." "demo.gif" "el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 7 :point "demo.gif" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fdemo.gif&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fel-remoto-logo.png&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-embark-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-integration-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-tests.el&per_page=1"))

("ff /gh:agzam/remoto.el@main:/test" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :names
 ("." ".." "demo.gif" "el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 7 :point "demo.gif" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"))

("ff /gh:agzam/remoto.el@main:/test/remo" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :matches t :names
 ("el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 4 :point "el-remoto-logo.png" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fdemo.gif&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fel-remoto-logo.png&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-embark-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-integration-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-tests.el&per_page=1"))

("ff /gh:agzam/remoto.el@2.2.0:/" :mode dired-mode :dired
 "/github:agzam/remoto.el@2.2.0:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/2.2.0?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=test&per_page=1"))

("ff /gh:agzam/remoto.el@2.2" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names ("2.2.0") :count 1
 :point "2.2.0" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "/repos/agzam/remoto.el/git/trees/2.2?recursive=1"))

("ff /gh:agzam/remoto.el@ceaf310:/" :mode dired-mode :dired
 "/github:agzam/remoto.el@ceaf310:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/ceaf310?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=test&per_page=1"))

("ff /gh:agzam/remoto.el#47" :buffer
 "*remoto: /github:agzam/remoto.el#47*" :mode remoto-topic-mode
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/issues?state=open&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/issues/4"
  "async /repos/agzam/remoto.el/issues/47"
  "/repos/agzam/remoto.el/issues/47" "/repos/agzam/remoto.el/pulls/47"
  "/repos/agzam/remoto.el/pulls/47/reviews"
  "/repos/agzam/remoto.el/issues/47/comments"))

("ff /gh:agzam/.." :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/user/orgs?per_page=100&page=1"))

("ff /gh:agzam/remoto.el/.." :mode dired-mode :dired "/github:agzam/"
 :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "FTPSearchAndReplace" "Fennel")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("ff /gh:agzam/remoto.el@main:/test/.." :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fdemo.gif&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fel-remoto-logo.png&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-embark-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-integration-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-tests.el&per_page=1"))

("ff /gh:agzam/.emacs.d" :mode dired-mode :dired
 "/github:agzam/.emacs.d@main:/" :names
 ("." ".." ".github" ".gitignore" ".rgignore" "AGENTS.md" "README.md"
  "bb.edn" "config.el" "early-init.el")
 :count 16 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/repos/agzam/.emacs.d/git/trees/main?recursive=1"))

("ff /gh:agzam/.doom" :mode dired-mode :dired "/github:agzam/"
 :matches t :names (".doom.d") :count 1 :point ".doom.d" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/repos/agzam/.doom"
  "/search/repositories?q=.doom%20in%3Aname%20user%3Aagzam&per_page=100"))

("ff /gh:Agzam/Remoto.el" :mode dired-mode :dired
 "/github:Agzam/Remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3AAgzam&sort=updated&per_page=30"
  "/repos/Agzam/Remoto.el"
  "/repos/Agzam/Remoto.el/git/trees/main?recursive=1"))

("ff /gh:agzam/remoto el" :mode dired-mode :dired "/github:agzam/"
 :matches t :names ("remoto.el") :count 1 :point "remoto.el" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /search/repositories?q=remoto%20%20in%3Aname%20user%3Aagzam&per_page=100"
  "async /search/repositories?q=remoto%20e%20in%3Aname%20user%3Aagzam&per_page=100"
  "async /search/repositories?q=remoto%20el%20in%3Aname%20user%3Aagzam&per_page=100"))

("ff /gh:no-such-owner-zz9q/" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: not found: users/no-such-owner-zz9q/repos?sort=pushed&per_page=100&page=1"
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Ano-such-owner-zz9q&sort=updated&per_page=30"
  "async /search/repositories?q=user%3Ano-such-owner-zz9q&sort=updated&per_page=30"
  "/user/orgs?per_page=100&page=1"
  "/users/no-such-owner-zz9q/repos?sort=pushed&per_page=100&page=1"))

("ff /gh:no-such-owner-zz9q" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: no account matches no-such-owner-zz9q" :requests
 ("async /user/orgs?per_page=100&page=1"
  "/search/users?q=no-such-owner-zz9q&per_page=100"))

("ff /gh:no-such-owner-zz9q/repo" :buffer "*scratch*" :mode
 lisp-interaction-mode :error "Remoto: no account no-such-owner-zz9q"
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Ano-such-owner-zz9q&sort=updated&per_page=30"
  "async /search/repositories?q=user%3Ano-such-owner-zz9q&sort=updated&per_page=30"
  "async /search/repositories?q=rep%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"
  "async /search/repositories?q=rep%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"
  "async /search/repositories?q=repo%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"
  "async /search/repositories?q=repo%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"
  "/repos/no-such-owner-zz9q/repo"
  "/search/repositories?q=repo%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"))

("ff /gh:agzam/zzqqxx" :buffer "*scratch*" :mode lisp-interaction-mode
 :error "Remoto: no repository of agzam matches zzqqxx" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /search/repositories?q=zzq%20in%3Aname%20user%3Aagzam&per_page=100"
  "async /search/repositories?q=zzqq%20in%3Aname%20user%3Aagzam&per_page=100"
  "async /search/repositories?q=zzqqx%20in%3Aname%20user%3Aagzam&per_page=100"
  "async /search/repositories?q=zzqqxx%20in%3Aname%20user%3Aagzam&per_page=100"
  "/repos/agzam/zzqqxx"))

("ff /gh:agzam/remoto.el@zzqq" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: no branch or tag of agzam/remoto.el matches zzqq" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "/repos/agzam/remoto.el/git/trees/zzqq?recursive=1"))

("ff https://github.com/agzam/remoto.el" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:" :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "/user/orgs?per_page=100&page=1"))

("dired /github:" :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "/user/orgs?per_page=100&page=1"))

("dired /gh:agzam" :mode dired-mode :dired "/github:" :matches t
 :names
 ("agzam" "AGZAMOVVVS21" "AGZamu" "AGzamDev" "AgZaMhOdJ" "AgZaMiC"
  "Agzam-Ar" "Agzam-lev" "Agzam020" "Agzam06")
 :count 94 :point "agzam" :requests
 ("async /user/orgs?per_page=100&page=1"
  "/search/users?q=agzam&per_page=100"))

("dired /gh:qlik" :mode dired-mode :dired "/github:" :matches t :names
 ("qlik" "CodeQlik" "Qlik-BT" "Qlik-Branch"
  "Qlik-Data-Integration-Team" "Qlik-PE" "Qlik-Sense-Extensions"
  "QlikDeploymentFramework" "QlikFrancePlatform" "QlikFreak")
 :count 31 :point "qlik" :requests
 ("async /user/orgs?per_page=100&page=1"
  "/search/users?q=qlik&per_page=100"))

("dired /gh:agzam/" :mode dired-mode :dired "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "FTPSearchAndReplace" "Fennel")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired /gh:agzam/remoto.el" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto" :mode dired-mode :dired "/github:agzam/"
 :matches t :names ("remoto.el") :count 1 :point "remoto.el" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/repos/agzam/remoto"
  "/search/repositories?q=remoto%20in%3Aname%20user%3Aagzam&per_page=100"))

("dired /gh:agzam/remoto.el/" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el/README.org" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/README.org" :names ("README.org")
 :count 1 :point "README.org" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el/READ" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :matches t :names ("README.org")
 :count 1 :point "README.org" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el/nope.txt" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/nope.txt" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el@" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names
 ("1.0.0" "1.0.1" "1.0.2" "1.0.3" "1.1.0" "1.2.0" "1.3.0" "1.4.0"
  "1.5.0" "1.6.0")
 :count 19 :point "1.0.0" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"))

("dired /gh:agzam/remoto.el@ma" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names ("main") :count 1 :point
 "main" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "/repos/agzam/remoto.el/git/trees/ma?recursive=1"))

("dired /gh:agzam/remoto.el@main" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto.el@main:" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"))

("dired /gh:agzam/remoto.el@main:/test/" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :names
 ("." ".." "demo.gif" "el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 7 :point "demo.gif" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fdemo.gif&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fel-remoto-logo.png&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-embark-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-integration-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-tests.el&per_page=1"))

("dired /gh:agzam/remoto.el@main:/test" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :names
 ("." ".." "demo.gif" "el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 7 :point "demo.gif" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"))

("dired /gh:agzam/remoto.el@main:/test/remo" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/test/" :matches t :names
 ("el-remoto-logo.png" "remoto-embark-tests.el"
  "remoto-integration-tests.el" "remoto-tests.el")
 :count 4 :point "el-remoto-logo.png" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fdemo.gif&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fel-remoto-logo.png&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-embark-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-integration-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-tests.el&per_page=1"))

("dired /gh:agzam/remoto.el@2.2.0:/" :mode dired-mode :dired
 "/github:agzam/remoto.el@2.2.0:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/2.2.0?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=2.2.0&path=test&per_page=1"))

("dired /gh:agzam/remoto.el@2.2" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names ("2.2.0") :count 1
 :point "2.2.0" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "/repos/agzam/remoto.el/git/trees/2.2?recursive=1"))

("dired /gh:agzam/remoto.el@ceaf310:/" :mode dired-mode :dired
 "/github:agzam/remoto.el@ceaf310:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/ceaf310?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=ceaf310&path=test&per_page=1"))

("dired /gh:agzam/remoto.el#47" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Directory /github:agzam/remoto.el#47 inaccessible or nonexistent"
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/issues?state=open&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/issues/4"
  "async /repos/agzam/remoto.el/issues/47"))

("dired /gh:agzam/.." :mode dired-mode :dired "/github:" :names
 ("." ".." "emacs-mirror" "remoto-e2e") :count 4 :point "emacs-mirror"
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/user/orgs?per_page=100&page=1"))

("dired /gh:agzam/remoto.el/.." :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "FTPSearchAndReplace" "Fennel")
 :count 145 :point ".doom.d" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"
  "async /repos/agzam/remoto.el" "async /repos/agzam/remoto.el"
  "/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("dired /gh:agzam/remoto.el@main:/test/.." :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fdemo.gif&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fel-remoto-logo.png&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-embark-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-integration-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-tests.el&per_page=1"))

("dired /gh:agzam/.emacs.d" :mode dired-mode :dired
 "/github:agzam/.emacs.d@main:/" :names
 ("." ".." ".github" ".gitignore" ".rgignore" "AGENTS.md" "README.md"
  "bb.edn" "config.el" "early-init.el")
 :count 16 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/repos/agzam/.emacs.d/git/trees/main?recursive=1"))

("dired /gh:agzam/.doom" :mode dired-mode :dired "/github:agzam/"
 :matches t :names (".doom.d") :count 1 :point ".doom.d" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/repos/agzam/.doom"
  "/search/repositories?q=.doom%20in%3Aname%20user%3Aagzam&per_page=100"))

("dired /gh:Agzam/Remoto.el" :mode dired-mode :dired
 "/github:Agzam/Remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3AAgzam&sort=updated&per_page=30"
  "/repos/Agzam/Remoto.el"
  "/repos/Agzam/Remoto.el/git/trees/main?recursive=1"))

("dired /gh:agzam/remoto el" :mode dired-mode :dired "/github:agzam/"
 :matches t :names ("remoto.el") :count 1 :point "remoto.el" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /search/repositories?q=remoto%20%20in%3Aname%20user%3Aagzam&per_page=100"
  "async /search/repositories?q=remoto%20e%20in%3Aname%20user%3Aagzam&per_page=100"
  "async /search/repositories?q=remoto%20el%20in%3Aname%20user%3Aagzam&per_page=100"))

("dired /gh:no-such-owner-zz9q/" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: not found: users/no-such-owner-zz9q/repos?sort=pushed&per_page=100&page=1"
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Ano-such-owner-zz9q&sort=updated&per_page=30"
  "async /search/repositories?q=user%3Ano-such-owner-zz9q&sort=updated&per_page=30"
  "/user/orgs?per_page=100&page=1"
  "/users/no-such-owner-zz9q/repos?sort=pushed&per_page=100&page=1"))

("dired /gh:no-such-owner-zz9q" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: no account matches no-such-owner-zz9q" :requests
 ("async /user/orgs?per_page=100&page=1"
  "/search/users?q=no-such-owner-zz9q&per_page=100"))

("dired /gh:no-such-owner-zz9q/repo" :buffer "*scratch*" :mode
 lisp-interaction-mode :error "Remoto: no account no-such-owner-zz9q"
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Ano-such-owner-zz9q&sort=updated&per_page=30"
  "async /search/repositories?q=user%3Ano-such-owner-zz9q&sort=updated&per_page=30"
  "async /search/repositories?q=rep%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"
  "async /search/repositories?q=rep%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"
  "async /search/repositories?q=repo%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"
  "async /search/repositories?q=repo%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"
  "/repos/no-such-owner-zz9q/repo"
  "/search/repositories?q=repo%20in%3Aname%20user%3Ano-such-owner-zz9q&per_page=100"))

("dired /gh:agzam/zzqqxx" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: no repository of agzam matches zzqqxx" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /search/repositories?q=zzq%20in%3Aname%20user%3Aagzam&per_page=100"
  "async /search/repositories?q=zzqq%20in%3Aname%20user%3Aagzam&per_page=100"
  "async /search/repositories?q=zzqqx%20in%3Aname%20user%3Aagzam&per_page=100"
  "async /search/repositories?q=zzqqxx%20in%3Aname%20user%3Aagzam&per_page=100"
  "/repos/agzam/zzqqxx"))

("dired /gh:agzam/remoto.el@zzqq" :buffer "*scratch*" :mode
 lisp-interaction-mode :error
 "Remoto: no branch or tag of agzam/remoto.el matches zzqq" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "/repos/agzam/remoto.el/git/trees/zzqq?recursive=1"))

("dired https://github.com/agzam/remoto.el" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point ".github" :requests
 ("/repos/agzam/remoto.el"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("embark y on a repository line" :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "FTPSearchAndReplace" "Fennel")
 :count 145 :point "remoto.el" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :kill "https://github.com/agzam/remoto.el" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("embark b on a repository line" :mode dired-mode :dired
 "/github:agzam/" :names
 ("." ".." ".doom.d" ".emacs.d" ".spacehammer" ".spacemacs.d"
  ".stumpwm.d" "Adv360-Pro-ZMK" "FTPSearchAndReplace" "Fennel")
 :count 145 :point "remoto.el" :messages
 ("Remoto: listing the first 100 repositories of agzam, fetching the rest"
  "Remoto: listed all 143 repositories of agzam")
 :browsed ("https://github.com/agzam/remoto.el") :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "/user/orgs?per_page=100&page=1"
  "/users/agzam/repos?sort=pushed&per_page=100&page=1"
  "async /users/agzam/repos?sort=pushed&per_page=100&page=2"))

("embark y on an account line" :mode dired-mode :dired "/github:"
 :matches t :names
 ("agzam" "AGZAMOVVVS21" "AGZamu" "AGzamDev" "AgZaMhOdJ" "AgZaMiC"
  "Agzam-Ar" "Agzam-lev" "Agzam020" "Agzam06")
 :count 94 :point "agzam" :kill "https://github.com/agzam" :requests
 ("async /user/orgs?per_page=100&page=1"
  "/search/users?q=agzam&per_page=100"))

("embark y on a ref line" :mode dired-mode :dired
 "/github:agzam/remoto.el@" :matches t :names
 ("1.0.0" "1.0.1" "1.0.2" "1.0.3" "1.1.0" "1.2.0" "1.3.0" "1.4.0"
  "1.5.0" "1.6.0")
 :count 19 :point "main" :kill
 "https://github.com/agzam/remoto.el/tree/main/" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"))

("embark y on a file line" :mode dired-mode :dired
 "/github:agzam/remoto.el@main:/" :names
 ("." ".." ".github" ".gitignore" "LICENSE" "Makefile" "README.org"
  "SPEC.md" "changelog.org" "plan.md")
 :count 14 :point "README.org" :kill
 "https://github.com/agzam/remoto.el/blob/main/README.org" :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el"
  "async /repos/agzam/remoto.el/contents?ref=main"
  "/repos/agzam/remoto.el/git/trees/main?recursive=1"))

("embark y on a file candidate" :buffer "*scratch*" :mode
 lisp-interaction-mode :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fdemo.gif&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fel-remoto-logo.png&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-embark-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-integration-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-tests.el&per_page=1"))

("embark y on an issue candidate" :buffer "*scratch*" :mode
 lisp-interaction-mode :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/issues?state=open&sort=updated&per_page=30"))

("embark collect at /gh:agzam/" :buffer
 "*Embark Collect: find-file - /tmp//gh:agzam/*" :mode
 embark-collect-mode :names
 ("mxp/" "tecla/" "resume/" ".doom.d/" ".emacs.d/" "pdf-text/"
  "occult.el/" "prisma.el/" "remoto.el/" "slacko.el/")
 :count 25 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"))

("embark export at /gh:agzam/" :buffer
 "*Embark Collect: find-file - /tmp//gh:agzam/*" :mode
 embark-collect-mode :names
 ("mxp/" "tecla/" "resume/" ".doom.d/" ".emacs.d/" "pdf-text/"
  "occult.el/" "prisma.el/" "remoto.el/" "slacko.el/")
 :count 25 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"))

("embark collect at /gh:agzam/remoto.el#" :buffer
 "*Embark Collect: find-file - /tmp//gh:agzam/remoto.el#*" :mode
 embark-collect-mode :names
 ("47" "49" "48" "46" "45" "44" "43" "42" "41" "40") :count 11
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/issues?state=open&sort=updated&per_page=30"
  "async /search/repositories?q=remoto.el%20in%3Aname%20user%3Aagzam&per_page=100"))

("embark export at /gh:agzam/remoto.el#" :buffer
 "*Embark Collect: find-file - /tmp//gh:agzam/remoto.el#*" :mode
 embark-collect-mode :names
 ("47" "49" "48" "46" "45" "44" "43" "42" "41" "40") :count 11
 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/issues?state=open&sort=updated&per_page=30"
  "async /search/repositories?q=remoto.el%20in%3Aname%20user%3Aagzam&per_page=100"))

("embark collect at /gh:agzam/remoto.el@main:/test/" :buffer
 "*Embark Collect: find-file - /tmp//gh:agzam/remoto.el@main:/test/*"
 :mode embark-collect-mode :names
 ("demo.gif" "remoto-tests.el" "el-remoto-logo.png"
  "remoto-embark-tests.el" "remoto-integration-tests.el")
 :count 5 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fdemo.gif&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fel-remoto-logo.png&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-embark-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-integration-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-tests.el&per_page=1"
  "async /search/repositories?q=remoto.el%20in%3Aname%20user%3Aagzam&per_page=100"))

("embark export at /gh:agzam/remoto.el@main:/test/" :buffer
 "*Embark Collect: find-file - /tmp//gh:agzam/remoto.el@main:/test/*"
 :mode embark-collect-mode :names
 ("demo.gif" "remoto-tests.el" "el-remoto-logo.png"
  "remoto-embark-tests.el" "remoto-integration-tests.el")
 :count 5 :requests
 ("async /user/orgs?per_page=100&page=1"
  "async /search/repositories?q=user%3Aagzam&sort=updated&per_page=30"
  "async /repos/agzam/remoto.el/branches?per_page=100&page=1"
  "async /repos/agzam/remoto.el/tags?per_page=100&page=1"
  "async /repos/agzam/remoto.el/git/trees/main?recursive=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.github&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=.gitignore&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=LICENSE&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=Makefile&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=README.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=SPEC.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=changelog.org&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=plan.md&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-embark.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto-topic.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=remoto.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fdemo.gif&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fel-remoto-logo.png&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-embark-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-integration-tests.el&per_page=1"
  "async /repos/agzam/remoto.el/commits?sha=main&path=test%2F%2Fremoto-tests.el&per_page=1"
  "async /search/repositories?q=remoto.el%20in%3Aname%20user%3Aagzam&per_page=100"))
