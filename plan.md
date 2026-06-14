# Embark Integration Plan - remoto.el

Living plan for completing the optional Embark integration. Written to survive
context compaction: a fresh/compacted session should be able to continue from
here without prior chat history. Update this file as work proceeds.

## 1. Current state

- Branch: `embark-integration`, PR #30 (base `main`). CI green.
- Commits on branch:
  - `5a213da` Add optional Embark integration on a forge-agnostic URL layer (Stage 1 + forge core).
  - `c158704` Bind plist-get results in let* for buttercup on Emacs 29 (test fix).
  - Stages A-D plus owner-level and the generic fallback have since landed on the
    branch (see `git log main..HEAD`); the lists below are reconciled to that.
- `main` (`ad0b42c`, PR #29) already has the forge-agnostic URL commands + `remoto-mode`.

Done (Stage 1):
- Forge-agnostic URL core in `remoto.el`: `remoto-forge-url-templates` (path kinds
  blob/tree/blame/history/raw + repo kinds repo/ssh/https + line/region), and a
  context plist built by `remoto--path-context` with a `:type`
  (`remoto-repo`/`remoto-dir`/`remoto-file`). `remoto--context-web-url` picks the
  web kind by `:type`. `remoto--buffer-file-context` delegates to it.
- `remoto-embark.el`: buffer/Dired target finder, `remoto-embark-{repo,dir,file}-map`,
  copy/browse/clone-URL actions. Opt-in; no embark dependency; byte-compiles and
  loads with embark absent.
- `SPEC.md` documents the design ("Forge-agnostic URL Layer" + "Embark Integration").

Done since: CI embark test strategy; minibuffer / embark-collect targets; the
url-at-point bridge; clone command; per-type actions (repo/branch/dir/file/issue);
the remoto-browse surface; owner-level target + actions; a generic `remoto`
fallback keymap; README docs.

Remaining: `embark-export` refinement (a remoto Dired exporter, if feasible -
`embark-collect` already works) and the follow-up action tier (repo copy-shorthand,
file save-local / insert-contents / copy-curl, dir copy-repo-relative-path).

## 2. Goal

Complete, forge-agnostic Embark integration, no half-measures, with CI that
exercises the integration's programmatic layer (not left untested). Runtime stays
embark-free (optional, opt-in). Adding a forge later must remain a data change.

## 3. CI testing strategy (DO THIS FIRST - unblocks everything)

Key decision: embark is pure elisp and MELPA-installable, so add it as a
TEST-ONLY dependency (exactly like buttercup). The package stays embark-free at
runtime: `embark` is NOT in `Package-Requires`, and `remoto-embark.el` never
`(require 'embark)`. A test-time dependency is independent of runtime deps.

This exercises the REAL embark programmatic API - registration, target finders,
transformers, keymaps, actions, `embark--targets` - with no embark mocking. Only
true interactive keypress dispatch (live minibuffer + vertico) stays manual.

Concrete changes:
1. `Makefile` `$(ELPA_DIR)` target: add `--eval "(package-install 'embark)"`.
   CI caches `.elpa` keyed by `hashFiles('Makefile')`, so editing the Makefile
   busts the cache and installs embark.
2. New `test/remoto-embark-tests.el`: `(require 'embark)` then `(require 'remoto-embark)`.
   Cover:
   - Registration: `embark-keymap-alist` contains `(remoto-repo remoto-embark-repo-map)`,
     `(remoto-dir ...)`, `(remoto-file ...)` (and owner/branch/issue once added);
     `remoto--embark-target-finder` in `embark-target-finders`; transformer in
     `embark-transformer-alist` (once added).
   - Buffer/Dired finder via real embark (set up buffer; call finder / `embark--targets`;
     assert TYPE + full path).
   - Minibuffer category + transformer: build a propertized candidate, run the
     transformer, assert the full canonical path; assert embark resolves the
     per-level keymap from the category.
   - Actions: call each with a target path; assert kill-ring / mocked `browse-url` /
     mocked clone command.
   - embark-collect: assert candidates retain the full-path text property so the
     transformer still works with no live minibuffer.
3. Keep `test/remoto-tests.el` EMBARK-FREE. Never `(require 'embark)` there - once
   loaded, `(featurep 'embark)` stays t for the whole buttercup process, defeating
   the no-embark assertions. This file keeps verifying the no-embark path
   (`remoto-embark` loads with `(featurep 'embark)` nil) plus all pure logic.
4. `Makefile`: add `test-embark` target (loads `test/remoto-embark-tests.el`,
   `--funcall buttercup-run`); add it to `test-all`.
5. `.github/workflows/run-tests.yml` unit-tests job: add a step
   `- name: Run embark tests / run: make test-embark` (runs on push + PR).
6. Optional but recommended: extend `check-compile` to also
   `(byte-compile-file "remoto-embark.el")` with `byte-compile-error-on-warn t`.
   embark is not loaded while compiling it (it does not require embark), so this
   keeps verifying the no-embark compile path stays warning-clean.

Still mock (buttercup `spy-on`): `browse-url`, `git`/process launches, `remoto--api`.

Run locally:
- `make test` (no embark), `make test-embark` (with embark), `make check-compile`.
- Filter buttercup noise: `make test 2>&1 | rg '^Ran [0-9]+ specs'`.

## 4. Architecture (forge-agnostic) - recap

Context plist is the currency between "where the target came from" and "what an
action does". Built by `remoto--path-context PATH &optional LINE-START LINE-END`:

| Key | Meaning |
|---|---|
| `:forge` | forge symbol from path prefix (`remoto--forge-type`) |
| `:owner` `:repo` `:ref` | repo coordinates |
| `:path` | repo-relative path (`""` for root) |
| `:kind` | `tree` or `blob` |
| `:type` | target type: `remoto-repo` / `remoto-dir` / `remoto-file` |
| `:line-start` `:line-end` | file line/region (file targets only) |

- A repo root is classified without resolving the ref or fetching the tree
  (offline-safe, works on bare `owner/repo`).
- `remoto-forge-url-templates` (defvar) holds per-forge `format-spec` templates;
  specs `%o %r %R %p %L`. Add a forge by adding an entry (+ teaching
  `remoto--parse-path` the prefix). No code change for URL building.
- `remoto--context-url CTX KIND &optional REF` and `remoto--context-web-url CTX`
  turn a context into a URL.

## 5. Target types (stable public API)

| Type | Where | Example target |
|---|---|---|
| `remoto-owner` | minibuffer (root level), text | `/github:agzam` |
| `remoto-repo` | minibuffer (owner level), Dired root, text, collect | `/github:agzam/remoto.el` |
| `remoto-branch` | minibuffer (`@` level), text | `/github:agzam/remoto.el@main` |
| `remoto-issue` | minibuffer (`#` level), remoto-topic buffer, text | `/github:agzam/remoto.el#42` |
| `remoto-dir` | minibuffer (tree), Dired, text | `/github:agzam/remoto.el/test` |
| `remoto-file` | minibuffer (blob), file buffer, text | `/github:agzam/remoto.el/remoto.el` |
| `url` (built-in) | any buffer text | `https://github.com/agzam/...` |

## 6. Action catalog (tiered) per type

Shipped actions are marked; only genuine follow-ups remain TODO.

- owner: browse profile (done), copy URL (done), open repositories tab (done).
- repo: copy web URL (done), browse (done), clone (done), copy SSH (done), copy
  HTTPS (done), copy history (done); TODO `gh repo clone`, open issues/PRs page,
  copy `owner/repo` shorthand, insert org/markdown link, fork/star.
- branch: browse (done), copy URL (done), compare view (done, `/compare/REF`),
  new-PR page (done, `/pull/new/REF`); TODO copy checkout command, tip SHA.
- issue/PR: open in `remoto-topic` (done), browse (done), copy URL (done), copy
  `owner/repo#N` (done), open diff (done, `/pull/N/files`); TODO head branch.
  DESCOPED `gh pr checkout`.
- dir: browse (done), copy tree URL (done), copy history (done); TODO copy
  repo-relative path. DESCOPED export-subdir-to-local.
- file: copy URL/blame/permalink/raw/history/browse (done); TODO save local copy,
  insert contents at point, copy `curl` command.
- url (bridge): `remoto-embark-open-in-remoto` (done) - parse via
  `remoto--parse-input` and open (dired/find-file the canonical path).

## 7. Integration surfaces

1. Buffer / Dired (DONE) - `remoto--embark-target-finder` returns `(TYPE PATH)`.
2. Minibuffer completion (`C-x C-f /github:...`) - per-level categories + candidate
   full-path property + transformer (Stage C).
3. `remoto-browse` completion (currently category `remoto-browse`) - give per-level
   targets too (Stage D).
4. url-at-point bridge (Stage B) - add action to `embark-url-map`.

## 8. Key technical problems and decisions

### Non-breaking (keep)
- No `embark` in `Package-Requires`. `remoto-embark.el` uses `defvar`/`declare-function`
  for embark symbols and registers in `(with-eval-after-load 'embark ...)`.
- Opt-in: users `(require 'remoto-embark)`. `remoto.el` carries no embark reference
  (keeps main file package-lint clean; the lone `with-eval-after-load` lint caution
  is confined to `remoto-embark.el`).

### Per-level completion categories (Stage C core)
- Injected today in `remoto--read-file-name-internal-a` at the `'metadata` action:
  it hardcodes `(category . remoto)`. Change to a per-level category.
- Mapping (level from `remoto--parse-partial-github-path`, plus the canonical
  `@REF:` check used by `remoto--completion-metadata`):
  - root (`/github:`) -> `remoto-owner`
  - owner (`/github:OWNER/`) -> `remoto-repo`
  - repo (`/github:OWNER/REPO@`) -> `remoto-branch`
  - issues (`/github:OWNER/REPO#`) -> `remoto-issue`
  - files-default + canonical (`@REF:/path`) -> `remoto-file`
  - fallback -> `remoto`
- Cleanest: have `remoto--completion-metadata` add `(category . remoto-LEVEL)` to
  each cond branch (it already branches per level), and drop the hardcoded
  `(category . remoto)` in the advice (append `extra` which now carries category).
- Add `completion-category-overrides` entries `(remoto-owner (styles partial-completion basic))`
  etc. for every new category (keep the existing `remoto` entry as fallback).
- Affected existing tests: `test/remoto-tests.el` "completion-category-overrides
  registration" (~L1814, asserts `remoto` entry - keep it) and "uses remoto category
  to avoid marginalia override" (~L2831, only checks metadata non-nil - still passes;
  consider strengthening to assert the per-level category). The `remoto--completion-metadata`
  level tests (~L2790-2840, ~L2939-2950) check group/affixation only - adding a
  `category` cons must not break them (they do not assert exact alist equality; verify).

### Candidate -> full canonical path (Stage C, the crux)
- A minibuffer candidate is bare (e.g. `remoto.el/`); actions need a full canonical
  path. In an embark-collect buffer the minibuffer base is gone.
- Decision: attach a text property (e.g. `remoto-target`) holding the full canonical
  path to each completion candidate at generation time (candidates are already
  propertized: `remoto-repo-desc`, `remoto-acct-type`, `remoto-topic-title`, etc.).
  The transformer reads that property -> `(TYPE . FULLPATH)`.
- VERIFIED (embark 1.2 / Emacs 30.2, and the CI .elpa embark): the property
  survives the whole collect path, so no fallback/reconstruction is needed.
  Proven two ways, both now tested:
  1. Collector link (embark-free, test/remoto-tests.el "completion candidates
     survive embark collection"): `completion-all-completions' on the remoto
     table keeps `remoto-target' for every category, including the
     default-style `remoto-browse' (orderless/partial-completion both copy
     candidates, never strip).
  2. Collect-buffer link (real embark, test/remoto-embark-tests.el
     "embark-collect candidate round-trip"): embark-collect stores the raw
     candidate as the tabulated-list-id (`embark-collect--format-entries' ->
     ``(,cand [...])``), `embark--maybe-transform-candidates' passes
     `:orig-candidates' through unstripped (non-file types), and
     `embark-target-collect-candidate' returns it with `remoto-target' intact.
  So a bare collected candidate (e.g. `remoto.el/`) still resolves to its full
  path with no live minibuffer, and the per-type transformer/keymap dispatch.
- Register transformers via `embark-transformer-alist`: `(remoto-repo . FN)` etc.

### buttercup on Emacs 29 - plist-in-expect quirk
- `(expect (plist-get ctx :key) ...)` mis-evaluates (returns nil) under buttercup on
  Emacs 29. ALWAYS bind plist values in a `let*` first and assert on plain locals.
  See the `remoto--path-context` describe block in `test/remoto-tests.el` for the
  pattern. This bit us once (commit `c158704`).

## 9. Staged implementation plan (each stage: test-first, CI green)

Stage A - CI test infrastructure - DONE (uncommitted on `embark-integration`):
- Makefile: embark added to `deps`; `test-embark` target; `test-all` includes it;
  `check-compile` now also byte-compiles `remoto-embark.el`.
- `test/remoto-embark-tests.el`: real-embark tests (registration of the three
  keymaps + target finder; finder shape; repo-level actions). Mock-free (repo-root
  targets need no API). `make test-embark` -> 8 specs, 0 failed.
- `test/remoto-tests.el` kept embark-free; `make test` -> 465 specs, 0 failed.
- `.github/workflows/run-tests.yml`: "Run embark integration tests" step in the
  unit-tests job (push + PR).
- Verified: `make test`, `make test-embark`, `make check-compile` all green/clean
  locally (Emacs 30.2; embark installed into .elpa). Not yet run in CI (needs push).

Stage B - isolated, fully CI-verifiable actions - DONE (uncommitted on `embark-integration`):
- url-at-point bridge: `remoto-embark-open-in-remoto`, bound to `R` in
  `embark-url-map`; opens any forge URL / `owner/repo` shorthand in remoto.
- repo clone action: `remoto-embark-clone` (bound `c` in the repo map) plus the
  `remoto-clone-url-type` defcustom (https/ssh, default https); async via
  `remoto--clone`.
- `make test` 472/0, `make test-embark` 9/0, `make check-compile` clean.
- Remaining Stage B follow-ups (not done): repo copy-shorthand, file save-local /
  insert-contents / copy-curl, dir copy-repo-relative-path.

Stage C - minibuffer / embark-collect - DONE (all five levels):
- Per-level categories injected via `remoto--completion-metadata` + the
  read-file-name advice: owner->remoto-repo, files/canonical->remoto-file,
  `@`->remoto-branch, `#`->remoto-issue. Overrides added for each.
- Candidates carry a `remoto-target' full canonical path (attached in the
  file-name-all-completions handler per level). `remoto--embark-transform'
  reads it and re-derives type (file vs dir vs repo); `remoto--embark-transform-ref'
  keeps the type for branch/issue. Registered in embark-transformer-alist.
- Keymaps: repo/dir/file (Stage 1) + remoto-embark-branch-map (copy-url/browse)
  + remoto-embark-issue-map (open via find-file -> topic, copy OWNER/REPO#N).
  Registered in embark-keymap-alist.
- `C-x C-f /github:OWNER` -> embark-collect of repos with working actions, and
  embark-act works at every completion level.  VERIFIED + tested end-to-end
  (see the "Candidate -> full canonical path" note); the collect round-trip is
  no longer an unproven assumption.

Stage C investigation findings (so it can be executed cold):
- Categories: add `(category . remoto-LEVEL)` to each cond branch of
  `remoto--completion-metadata` (issues->remoto-issue, branches `@`->remoto-branch,
  file [canonical `@ref:` + files-default]->remoto-file, owner `/github:O/`->remoto-repo,
  root `/github:`->remoto-owner), and simplify `remoto--read-file-name-internal-a` to
  append `extra` (now carrying the category) instead of hardcoding `(category . remoto)`.
- Add `completion-category-overrides` for each new category (keep `remoto` as
  fallback). Affected tests in test/remoto-tests.el: ~L1814 (override registration),
  ~L2831 (category). The `remoto--completion-metadata` level tests (~L2790-2840,
  ~L2939-2950) check group/affixation only - adding a `category` cons is additive,
  but confirm none assert an exact alist.
- ATOMICITY (important): categories must land together with the candidate-to-path
  transformer. `remoto-repo`/`remoto-file` keymaps are already registered (Stage 1),
  so once owner-level candidates get category `remoto-repo`, `embark-act` uses
  `remoto-embark-repo-map` and the actions need a full path - shipping categories
  alone makes those actions error on bare candidates (`remoto.el/`). Do not commit
  categories without the transformer.
- Candidate -> full path: attach a `remoto-target` (full canonical path) text
  property to candidates. Prefer two chokepoints over the ~7 generation sites: the
  `file-name-all-completions` handler (find-file path) and
  `remoto--repo-completion-table` / `remoto--browse-completions` (browse path).
  Per-level normalization needed: owner-level `/github:O/repo/` -> `/github:O/repo:/`
  (canonical dirs already carry `:`). The transformer reads `remoto-target`; this also
  makes it unit-testable (propertize a string -> transform -> assert) and works in
  embark-collect (no live minibuffer). Generation sites for reference: remoto.el
  ~759, ~802-807, ~885-887, ~926, ~2034-2154, ~2303, ~2428-2456.
- This is one atomic, hot-path change; best done with a fresh context budget.

Stage D - remoto-browse surface, richer actions, polish:
- remoto-browse surface - DONE: `remoto--browse-completions` candidates now carry
  a `remoto-target' full canonical path in every mode (search->repo `:/`,
  `@`->branch `@ref:/`, `#`->issue `#N`, `/`->file `@branch:/path`).  Kept the
  single `remoto-browse' category and registered one transformer
  `remoto--embark-browse-transform' that classifies per target (issue/branch by
  path marker, else dir/file/repo via the path context) and dispatches to the
  existing per-type keymaps.  No category churn, no new keymap/override.
- issue/PR web actions - DONE: browse (`w`), copy-url (`u`), and the PR
  files-diff page (`d`, `pr-diff' template -> /pull/N/files) via
  `remoto--forge-issue-url' (forge-agnostic, %N-based templates).
- DESCOPED (read-only model mismatch): `gh pr checkout' and
  export-subdir-to-local both bridge into a local working copy and raise
  contention/conflict-resolution questions against a locally cloned repo;
  out of scope for the read-only browse integration.
- embark-collect - DONE + tested (round-trip proven; see the crux note).
- owner-level target - DONE: root-level `/github:` candidates carry a `remoto-target`
  (`/github:OWNER`); the metadata reports category `remoto-owner`;
  `remoto-embark-owner-map` (browse profile / copy URL / repositories tab) dispatches
  via the owner URL templates (`owner`, `owner-repos`). A generic `remoto` fallback
  keymap (reusing the repo map) covers any candidate that falls back to the bare
  `remoto` category.
- README docs - DONE: an "Embark integration" section (how to enable, opt-in note,
  target-types + keymaps tables, the `R` url bridge, collect support).
- Remaining: `embark-export` refinement only (`embark-exporters-alist` -> a remoto
  Dired buffer, if feasible) - distinct from collect, which already works; plus the
  §6 follow-up action tier (repo copy-shorthand, file save-local / insert / curl,
  dir copy-repo-relative-path).

## 10. File and function pointers

`remoto.el`:
- URL core: `remoto-forge-url-templates`, `remoto--forge-type`, `remoto--forge-url`,
  `remoto--path-context`, `remoto--buffer-file-context`, `remoto--context-url`,
  `remoto--context-web-url`, `remoto--require-blob`, `remoto--kill-url`,
  `remoto--resolve-commit-sha`.
- Commands: `remoto-copy-url`, `-blame-url`, `-permalink`, `-raw-url`, `-history-url`,
  `remoto-browse-url`; obsolete alias `remoto-copy-github-url`.
- Mode: `remoto-mode`, `remoto-command-map`, `remoto--maybe-enable-mode`.
- Completion: `remoto--completion-metadata` (per-level group/affix),
  `remoto--parse-partial-github-path` (`:level`), `remoto--read-file-name-internal-a`
  (injects the per-level completion category at `'metadata`), the `completion-category-overrides`
  registration, `remoto--browse-metadata` / `remoto--repo-completion-table`
  (category `remoto-browse`).

`remoto-embark.el`:
- `remoto--embark-target-at-point`, `remoto--embark-target-finder`.
- Actions: repo/dir/file URL (`remoto-embark-copy-url`, `-browse-url`,
  `-copy-repo-url`, `-copy-ssh-url`, `-copy-https-url`, `-copy-history-url`,
  `-copy-blame-url`, `-copy-raw-url`, `-copy-permalink`); branch (`-copy-branch-url`,
  `-browse-branch`, `-browse-compare`, `-new-pr`); issue (`-open-issue`,
  `-browse-issue`, `-copy-issue-url`, `-browse-pr-diff`, `-copy-issue-ref`); owner
  (`-browse-owner`, `-copy-owner-url`, `-browse-owner-repos`); clone
  (`remoto-embark-clone`); url bridge (`remoto-embark-open-in-remoto`).
- Keymaps: `remoto-embark-owner-map`, `-repo-map`, `-branch-map`, `-dir-map`,
  `-file-map`, `-issue-map` (+ generic `remoto` fallback -> repo map).
- Transformers: `remoto--embark-transform` (repo/file), `-transform-ref`
  (owner/branch/issue), `-browse-transform` (`remoto-browse`).
- `(with-eval-after-load 'embark ...)` registration block.

`SPEC.md`: "Forge-agnostic URL Layer", "Embark Integration" (keep in sync).
`.github/workflows/run-tests.yml`: unit-tests (29.4/30.1) + integration-tests.

## 11. Conventions / gotchas checklist

- Tests-first: write failing test, confirm red, implement, confirm green.
- Buttercup: bind `plist-get` results in `let*`; never call `plist-get`/struct
  accessors directly inside `expect` (Emacs 29 quirk).
- Buttercup stacktraces are huge: always filter, e.g. `make test 2>&1 | rg '^Ran'`.
- Verify without embark: `byte-compile-error-on-warn t` byte-compile of `remoto.el`
  and `remoto-embark.el` must be clean; `remoto-tests.el` stays embark-free.
- Lint elisp: check-parens, checkdoc, package-lint (`package-lint-main-file: "remoto.el"`
  local var in secondary files). Pre-existing noise: `ghub not installable` (L11),
  8 "two spaces after a period" nits in `remoto.el`.
- Never call network-touching functions (e.g. `remoto--path-context` on a real path)
  outside the `remoto-test-with-cache` mock - it hits the GitHub API.
- Git: never commit/push/PR without the user's explicit instruction in the current
  message. No Co-Authored-By / AI attribution in commits.
- Keymaps avoid the user-reserved `C-c LETTER` space; commands live in prefix maps.
- After `make check-compile` locally, remove `*.elc test/*.elc` (and the generated
  `remoto-autoloads.el`) before re-running `make test`/`make test-embark`: a stale
  .elc is loaded over newer .el (`load-prefer-newer' is nil), masking edits. CI is
  unaffected (tests run before check-compile).
