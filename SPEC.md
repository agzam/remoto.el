# remoto.el - Specification

Browse any GitHub repository in Emacs as if it were cloned locally - without cloning it.

## Overview

remoto.el registers a virtual filesystem via `file-name-handler-alist` that intercepts Emacs file operations on paths with a `/github:` prefix and translates them into GitHub REST API calls via the `ghub` library. The result: `find-file`, dired, completion, xref - all standard Emacs file tooling works against a remote GitHub repo. Read-only.

## Path Syntax

### Internal (canonical) form

The filesystem handler operates on paths in this canonical format:

```
/github:OWNER/REPO@REF:/PATH
```

- `OWNER` - GitHub user or organization (e.g., `torvalds`)
- `REPO` - repository name (e.g., `linux`)
- `REF` - branch, tag, or commit SHA (e.g., `master`, `v6.5`, `a1b2c3d`). Optional - when omitted, uses the repo's default branch.
- `PATH` - path within the repo. `/` for root.

### User-facing input

Users should never have to type the canonical form manually. `remoto-browse` (and any other entry point) accepts whatever the user would naturally copy-paste:

| Input | Resolved to |
|---|---|
| `https://github.com/torvalds/linux` | `/github:torvalds/linux:/` |
| `https://github.com/torvalds/linux/tree/master/kernel` | `/github:torvalds/linux@master:/kernel/` |
| `https://github.com/torvalds/linux/blob/master/README` | `/github:torvalds/linux@master:/README` |
| `https://github.com/torvalds/linux/blob/v6.5/Makefile#L10-L20` | `/github:torvalds/linux@v6.5:/Makefile` (line numbers noted, not used in path) |
| `git@github.com:torvalds/linux.git` | `/github:torvalds/linux:/` |
| `git@github.com:torvalds/linux` | `/github:torvalds/linux:/` |
| `torvalds/linux` | `/github:torvalds/linux:/` |
| `torvalds/linux@v6.5` | `/github:torvalds/linux@v6.5:/` |

The parser is a single function `remoto--parse-input` that normalizes any of the above into `(owner repo ref path)`. The rules:

1. Strip `https://github.com/` prefix if present.
2. Strip `git@github.com:` prefix if present.
3. Strip trailing `.git` if present.
4. From the remaining string, extract `owner/repo`. Everything after that is path context.
5. For web URLs: `/tree/REF/PATH` means directory, `/blob/REF/PATH` means file. Fragment (`#L10-L20`) is stripped.
6. `@REF` suffix on the repo portion sets the ref explicitly.
7. Missing ref -> nil (resolved lazily to default branch on first API call).

When `@REF` is omitted, the first access resolves the default branch via the repos API and caches it.

### URL rewriting

GitHub URLs are also detected and rewritten automatically in `dired` and `find-file-noselect` via `:around` advice. The function `remoto--github-input-p` detects GitHub-like inputs (https URLs, git SSH URLs, `/github.com/...` paths), and `remoto--maybe-rewrite` converts them to canonical remoto paths. This lets users do:

```
C-x d /github.com/torvalds/linux RET
C-x C-f https://github.com/torvalds/linux/blob/master/README RET
```

## Architecture

```
 User: C-x d /github:torvalds/linux@master:/
           |
           v
 file-name-handler-alist  (regexp: \`/github:)
           |
           v
 remoto-file-name-handler (dispatch on operation)
           |
     +-----+------+--------- - - -
     |            |              |
 directory    file-exists-p    insert-file-
   files          |            contents
     |            v              |
     v       tree cache          v
  tree cache  (hash table)    ghub-get (fetch file)
  (hash table)
     ^
     |
  ghub-get /repos/OWNER/REPO/git/trees/SHA?recursive=1
  (single call, cached per repo@ref)
```

### Core components

1. Path parser - extract owner, repo, ref, path from a remoto path string.

2. `ghub` API wrapper - call `ghub-get` on the REST endpoint, parse JSON response. All network I/O goes through this single function (`remoto--api`).

3. Tree cache - on first access to any path in a repo@ref, fetch the full tree via the Git Trees API. Store as a hash table keyed by path, values being plists with keys `:type`, `:size`, `:sha`, `:mode`. Cache is keyed by `owner/repo@ref`.

4. File-name handler - the central dispatch function registered in `file-name-handler-alist`. Receives (OPERATION . ARGS), constructs a handler name via `(intern-soft (format "remoto--handle-%s" operation))` and calls it if bound, otherwise falls through to default Emacs handling. It saves and restores the caller's match data around the call, as TRAMP's handler does: file primitives leave the match data alone for local names, and callers rely on that.

## ghub Transport

All forge API access goes through the `ghub` Emacs library:

```elisp
(defun remoto--api (endpoint)
  "Call GitHub REST API ENDPOINT via ghub. Returns parsed JSON."
  ...)
```

Internally: `(ghub-get (concat "/" endpoint) nil :auth remoto-github-auth :reader #'remoto--json-reader)`. Errors are caught via `condition-case` on ghub's typed conditions (`ghub-404`, `ghub-403`, `ghub-401`, etc.) and re-signaled as `user-error` with contextual messages.

Why `ghub`:
- Pure Emacs Lisp - no external binary dependency
- Handles auth via standard `auth-source` (authinfo, GPG-encrypted, OS keychain, etc.)
- Supports GitHub, GitLab, Gitea/Forgejo, Gogs, Bitbucket - same API, different `:forge` / `:host`
- Users of Magit/Forge already have tokens configured - zero setup
- No telemetry (the `gh` CLI collects usage analytics unless opted out)
- Synchronous by default, async available via `:callback` if needed later

A custom `:reader` function (`remoto--json-reader`) is used instead of ghub's default to ensure JSON arrays are parsed as lists (ghub defaults to vectors), matching what the rest of the codebase expects.

### Authentication

Public repos work without any token. When remoto finds none for a forge, it reads that forge anonymously (GitHub allows 60 requests an hour) until `remoto-reset-auth` or `remoto-login`.

`M-x remoto-login` asks for a token, checks it with `/user` and stores it as `ACCOUNT^remoto` under the forge's web host, in the first `.gpg` file of `auth-sources`; without one, or when the file cannot be written, the token lasts the session. The file is written as `auth-source-netrc-saver` writes it: with `auth-source-gpg-encrypt-to` non-nil, `epa-file-encrypt-to` is buffer-local, so a new file gets a passphrase and no list of keys to pick. The token page's address goes to `*Messages*`, and into the prompt when `browse-url` fails; a pasted token is taken out of the kill ring. The lookup reads every row under the API host or the web host and ranks them: `^remoto`, `^forge`, `^ghub`, untagged, with the account git config names first within a tag; a macOS keychain is read only when no other source holds a token. It needs no git config: remoto hands ghub the row's account as `:username`, so ghub never asks git for one.

A token the forge refuses stays refused for the session: the lookup skips it, `remoto-github-auth`'s included, and the next token auth-source holds takes its place before remoto asks to log in again. A login kept by an older remoto, whose struct has fewer slots, is forgotten when remoto loads again.

The `remoto-github-auth` defcustom:

- `nil` (default) - look the token up in auth-source
- `'none` - never send a token
- A string - the token itself

Auth-source entry formats remoto reads, for example:
```
machine github.com login USERNAME^remoto password ghp_TOKEN
machine api.github.com login USERNAME^forge password ghp_TOKEN
machine codeberg.org login USERNAME password TOKEN
```

Requests are synchronous (`ghub-get` without `:callback`). No sentinels, no async complexity. Browsing is inherently interactive and sequential - the user waits for the dired buffer or file to appear.

## Tree Cache

On first access to any path in a `owner/repo@ref`:

```
ghub-get /repos/OWNER/REPO/git/trees/REF?recursive=1
```

Returns every file and directory in the repo (path, type, size, sha, mode). Stored in:

```elisp
(defvar remoto--tree-cache (make-hash-table :test 'equal)
  "Hash table: \"owner/repo@ref\" -> hash table of path -> entry.")
```

Inner hash table: `"kernel/main.c"` -> `(:type "blob" :size 12345 :sha "abc..." :mode "100644")`

Directories are synthesized from the tree (the API returns blobs and sub-trees, but intermediate directories may need to be inferred from paths). A constant `remoto--dir-entry` holds the plist used for synthesized directory entries (root, intermediates, dired `.`/`..`).

Path lookup is normalized via `remoto--tree-lookup-key`, which strips leading/trailing slashes and collapses runs of slashes.

Cache invalidation: manual only. A command `remoto-refresh` clears the cache for a given repo@ref, forcing re-fetch on next access.

A repository without a commit has no tree: GitHub answers 409 "Git Repository is empty.", Forgejo 404. `remoto--forge-tree` gives it a tree of the root alone and says the repository is empty. After a 404 it asks the repository for `empty`, and only when the ref is the cached default branch, the one ref an empty repository names, so a missing ref costs no extra request.

### Large repos

The Trees API truncates at 100,000 entries / 7 MB response. When `truncated` is true in the response, fall back to per-directory fetching via the Contents API:

```
ghub-get /repos/OWNER/REPO/contents/PATH?ref=REF
```

This returns one directory level at a time. The tree cache stores what it has and fetches missing subdirectories on demand.

## File Operations

### Read operations

| Operation | Implementation |
|---|---|
| `file-exists-p` | Lookup in tree cache; returns t for partial paths (`/github:`, `/github:OWNER/`), and for a bare `/github:OWNER`, `/github:OWNER/REPO` or `/github:OWNER/REPO@REF` once a cached listing holds it or a search found it (`remoto--entry-cache`) |
| `file-directory-p` | Check `:type` = `"tree"` in cache; returns t for partial paths and for a ref that a Dired of matches shows |
| `file-regular-p` | Check `:type` = `"blob"` in cache |
| `file-readable-p` | `file-exists-p`, else `file-directory-p`: Dired asks this of `/github:OWNER` and `/github:OWNER/REPO@`, which `file-exists-p` denies, before it lists matches there |
| `file-writable-p` | Always nil |
| `file-attributes` | Synthesize from cache entry (size, type, mode, epoch-0 timestamps) |
| `directory-files` | List tree cache children for parent path, prepend `.` and `..` |
| `directory-files-and-attributes` | Same, with attributes |
| `file-name-all-completions` | Filter tree cache entries by prefix, append `/` to dirs; at pre-repo levels, searches users or lists repos |
| `file-name-completion` | Delegate to `try-completion` on completions list |
| `insert-file-contents` | Fetch file content via API, insert into buffer |
| `insert-directory` | Format dired-compatible listing from tree cache; `-F` indicators when the switches ask; at `/github:` and `/github:OWNER/` the accounts and repositories (see Listings above the repository). Without FULL-DIRECTORY-P a name gets its one line, a directory too, as with ls-lisp: Dired asks so for each name of a list of names |
| `expand-file-name` | Resolve `.` and `..` in absolute and relative remoto names, handle relative paths under remoto dirs; for partial paths (e.g. `/github:owner/`) concatenates directly. `..` above a repository root names the owner, `/github:OWNER/`, and above that `/github:` |
| `file-accessible-directory-p` | Delegates to `file-directory-p` - remote dirs are always readable |
| `file-truename` | Return the path as-is (no symlink resolution) |
| `file-remote-p` | Return the `/github:owner/repo@ref:` prefix (or method/host on request); handles partial paths. `localname` is the prefix as well, so no caller hands a local program a remoto path, except for the argument of a running Evil ex command, which gets the path after the prefix with each bare `#` and `%` escaped: Evil rebuilds that argument from the two answers and would replace those with file names |
| `file-local-copy` | Download to temp file, return temp path |
| `make-nearby-temp-file` | Create temp file in system temp dir |
| `file-name-directory` | Return directory part of remoto path; handles partial paths for pre-repo completion |
| `file-name-nondirectory` | Return non-directory part of remoto path; handles partial paths for pre-repo completion. Empty for a canonical directory name: Dired lists a name with a nondirectory part as a wildcard, and completion matches that part against the children |
| `file-name-as-directory` | Append `/` if not present; `/github:` and `/github:OWNER/REPO@` stay as they are, so their Dired names `/github:OWNER` and `/github:OWNER/REPO@REF` |
| `directory-file-name` | Strip trailing `/` (preserving `:/` after prefix) |
| `file-name-case-insensitive-p` | Always nil (GitHub is case-sensitive) |
| `vc-registered` | Always nil (not under local vc) |
| `abbreviate-file-name` | Return as-is |
| `unhandled-file-name-directory` | Return nil |

### Programs

A program started in a remoto directory, through `process-file`, `start-file-process`, `make-process` with `:file-handler` or `shell-command`, runs in `~`: `unhandled-file-name-directory` is nil. A search there would report the files of `~` as the repository's, so the handlers of those four operations refuse one with `(user-error "Remoto: grep needs a clone; a repository has no local files")`. A search is a program in `remoto--search-programs` (grep, egrep, fgrep, rg, ugrep, ag, ack, find, fd, fdfind), `git` with its `grep` subcommand, or a shell whose command line after `-c` names one of those in any word, as xref's `xargs -0 grep` does. Every other program passes on unchanged (`remoto--pass-on`), git for Magit and vc included.

### Write operations (all read-only)

`write-region`, `delete-file`, `delete-directory`, `rename-file`, `copy-file`, `set-file-modes`, `set-file-times` - all signal `(user-error "Remoto: repository is read-only")`.

`make-directory` succeeds silently for directories that already exist (required by dired), signals read-only error for new directories. A name below an owner is a directory by its shape, so it must also exist, as a listed repository does; otherwise Dired's `+` would add a line for a repository it never made.

### Delegated to defaults

Operations not listed above fall through to default Emacs handling via the standard `inhibit-file-name-handlers` / `inhibit-file-name-operation` mechanism.

## Fetching File Contents

For files under 1 MB, the Contents API returns base64-encoded content:

```
ghub-get /repos/OWNER/REPO/contents/PATH?ref=REF
```

For larger files, fall back to the Blobs API:

```
ghub-get /repos/OWNER/REPO/git/blobs/SHA
```

The blob response contains base64-encoded content regardless of file size.

Fetched file contents are cached in memory keyed by SHA. Since SHA is a content hash, this cache never goes stale - the same file across branches/refs is only fetched once.

## Dired Integration

`insert-directory` produces output matching dired's expected format:

```
drwxr-xr-x  1 github github     0 Jan  1  2000 kernel
drwxr-xr-x  1 github github     0 Jan  1  2000 drivers
-rw-r--r--  1 github github   727 Jan  1  2000 README
-rwxr-xr-x  1 github github 18693 Jan  1  2000 Makefile
```

No leading spaces - dired and dired-subtree add their own. Timestamps are synthetic (the Trees API does not return timestamps). Permissions are derived from the mode field (100644 -> `-rw-r--r--`, 100755 -> `-rwxr-xr-x`, 120000 -> `lrwxrwxrwx`, 040000 -> `drwxr-xr-x`).

Each name carries the `dired-filename` text property, as `ls --dired` output does, so dired reads it exactly whatever `dired-listing-switches` holds. Without it, dired guesses where a name ends: under `-F` it strips one character after every directory and executable name, and on a symlink line it looks for ` -> TARGET`, which the listing does not print. When the switches ask for `-F` or `--classify`, the listing appends `/` to directories, `*` to executables and `@` to symlinks, after the property.

### Listings above the repository

`/github:` lists the account of the token and its organizations (`remoto--fetch-user-orgs`); without a token it signals a `user-error`, and Dired kills the buffer it made. `/github:OWNER/` lists OWNER's repositories, newest push first from the API:

| OWNER | Endpoint | Sees |
|---|---|---|
| the token's own account | `user/repos?affiliation=owner&sort=pushed` | private repositories too |
| an organization of the token | `orgs/OWNER/repos?sort=pushed` | private repositories too |
| any other account, or no token | `users/OWNER/repos?sort=pushed` | public repositories |

```
drwxr-xr-x  1 github github  2670592 Oct 20 13:23 .emacs.d     My Emacs config
drwx------  1 github github    10240 Oct 19 17:24 notes        fork  Private notes
dr-xr-xr-x  1 github github    20480 Mar  3  2021 old-thing
```

- The size is the API's `size` in bytes, the date the last push (`ls -l` format, local time, English month names), the mode `drwx------` for a private repository and `dr-x` in front for an archived one. An account line has the fixed size and date of tree entries.
- A note follows each name: the description, `fork` in front for a fork; at `/github:` the account type and description. Notes start 4 columns past the longest name, so `dired-hide-details-mode` hides them with symlink targets (dired.el hides a line from 4 columns past its name under `dired-hide-details-link`).
- Names sort with `string<`; `-t` in the switches sorts by the last push, newest first.
- The first page of 100 is a blocking `remoto--api` call. When it is full, `remoto--fetch-listing-page` fetches the next page through `remoto--api-async`, one at a time, until a short page or `remoto-listing-cap` (1000); then every Dired buffer of the listing reverts once. The `.` line's note tells a partial listing: fetching, capped, or failed. Not the `total` line: Dired deletes that under the default `dired-free-space`. The end of the pages, failed or not, renews the listing's time, because the revert that shows the end would otherwise find a listing older than `remoto-repo-cache-ttl` stale and fetch it all again, and again; `remoto-refresh` retries a failed one.
- Each repository's `default_branch` goes into `remoto--default-branch-cache`, so `RET` on a line costs one tree request.
- A Dired line names `/github:OWNER/REPO` or `/github:OWNER`, bare names that `file-exists-p` denies to keep the `[Confirm]` of a half-typed name. `remoto--listed-p` lets them through once a cached listing holds them, whatever its age, so a buffer that still shows a name can open it.
- A bare `/github:OWNER/NAME` that names no repository opens a Dired of OWNER's repositories that match NAME (`remoto--repo-matches`, called by the `find-file-noselect` and `dired-noselect` advice). The repository check stays first: `remoto--repository-p` asks for the default branch, and only a 404 (a `user-error` starting with `remoto--not-found`) means no; a NAME with a character no repository name has (a space from orderless, say) is not asked about. The matches come from the search completion ran at `/github:OWNER/` (`\0repos:OWNER/NAME` in `remoto--search-cache`), or from that search run then, whose failure signals. They open as Dired on a list of names, `(DIR . NAMES)`, so they take the place of an open `/github:OWNER/` listing until `C-x d /github:OWNER/` brings it back. Dired asks `insert-directory` for each name without FULL-DIRECTORY-P and checks `file-readable-p` of `/github:OWNER` first. Each line comes from `remoto--entry-cache`, which listing pages and every repository search fill (`remoto--remember-repo`, with the default branch); the names in `dired-directory` line the notes up, from widths counted once per reading (`remoto--entry-widths`), since a count per line made a long list quadratic.
- The other levels work the same way (`remoto--query-matches`, `remoto--file-matches`, both behind `remoto--name-or-matches`), each word of the query matching case-insensitively (`remoto--words-match-p`):
  - `/github:NAME`, typed without the slash, lists the accounts whose login holds NAME, from a search for NAME itself, cached apart (`remoto--account-search`): completion's `\0users:NAME` can be a shorter query's top 30 narrowed down, which may lack NAME. An exact account is no exception: GitHub has a user named qlik, and `/gh:qlik` must list the qlik organizations; it comes first, as does any name equal to the one typed. A line of the current Dired buffer (`remoto--dired-line-p`, by `dired-goto-file`) opens its account, since Dired opens a line by its bare name; `/github:NAME/` opens it too.
  - `/github:OWNER/REPO@REF` lists the branches and tags that hold REF, with `branch` or `tag` as the note, unless the tree at REF loads (`remoto--ref-p`, so a commit opens as well); a bare `@` lists them all. A ref with a slash does not parse in a path and stays out. The Dired directory is `/github:OWNER/REPO@`, which `file-name-as-directory` keeps without a slash.
  - A canonical file name that its directory lacks lists the entries of the directory that hold it; a directory among them shows as one line. A name with a trailing slash or a wildcard is no query, and one that nothing matches visits a new file, as a local name does.
- A name that matches nothing signals a `user-error` at the account, repository and ref levels, where the name used to fail with a 404, and leaves no buffer.
- `..` at a repository root expands to `/github:OWNER/` (`remoto--normalize-name`), and at an owner to `/github:`. `remoto--maybe-rewrite` resolves dots before it reads a short form, which would take `/github:OWNER/..` for a repository named `..`. `^` keeps its behavior: `file-name-directory` of a root is the root, since completion right after `@REF:` relies on it.

## TRAMP Coexistence

TRAMP's `tramp-file-name-regexp` matches `/method:...` patterns, which would intercept `/github:...` paths. The remoto handler is pushed to the front of `file-name-handler-alist` so it's checked first. First match wins.

## Error Handling

Two policies:

1. During completion (typing/TAB): all errors swallowed, empty list returned. Every `remoto--fetch-*` uses `(condition-case nil ... (user-error nil))`.
2. During open (RET): errors surface as `user-error` ("Remoto: not found: ...").

ghub signals typed conditions for HTTP errors. `remoto--api` catches these and re-signals as `user-error`:

- `ghub-404` - not found (repo missing, private without access)
- `ghub-403` - forbidden (rate limit, permissions)
- `ghub-401` - authentication failed (missing or invalid token in auth-source)
- `ghub-http-error` - catch-all for other HTTP errors
- `ghub-error` - catch-all for transport/connection failures
- Truncated tree: log a message, fall back to per-directory fetching.

## Interactive Commands

- `remoto-browse` - prompt for a repo using standard `completing-read` with a programmed completion table (`remoto--repo-completion-table`), open dired at root or find-file for blob paths. Type 3+ characters to trigger GitHub search via the search API. Tab completes repo names. Append `@` to complete branch names - fetches branches via the GitHub Branches API and offers `owner/repo@branch` candidates, with prefix filtering. Works with any completion frontend (vertico, ivy, helm, vanilla Emacs). Search results are cached for `remoto-search-cache-ttl` seconds (default 300). Branch results are cached in `remoto--branches-cache` with the same TTL as search results. Owner-scoped repo search shares the `remoto--search-owner-repos` engine with `/github:` completion (results are reformatted from bare repo names to `owner/repo`), and the ⟳ indicator shows while searching and during the post-selection fetch (see Fetch indicator).
- `remoto-refresh` - invalidate tree and branch caches for current repo, re-fetch. Reverts dired buffer if in one. In a listing of `/github:` or `/github:OWNER/` it drops that listing and fetches it again; in a Dired of branches and tags it forgets the repository's branches and tags.
- URL commands - `remoto-copy-url`, `remoto-copy-blame-url`, `remoto-copy-permalink`, `remoto-copy-raw-url`, `remoto-copy-history-url`, `remoto-browse-url` - and the `remoto-mode` minor mode. See "Forge-agnostic URL Layer" below. `remoto-copy-github-url` remains as an obsolete alias of `remoto-copy-url`.

### find-file completion

The `/github:` prefix enables multi-level completion directly in `find-file` (`C-x C-f`). Standard Emacs file completion machinery drives the entire flow.

#### Delimiter rules

The first delimiter character after `OWNER/REPO` determines the completion mode:

| Delimiter | Mode | Example |
|---|---|---|
| `/` | files-default (browse on default branch) | `/github:owner/repo/src/` |
| `@` | repo (pick branch or tag) | `/github:owner/repo@v1.0:` |
| `#` | issues (browse issues/PRs) | `/github:owner/repo#42` |

Once consumed, other delimiters become literal (e.g. `/github:foo/bar/@` - the `@` is a filename character).

#### Completion levels

| Level | Directory | Query | Action |
|---|---|---|---|
| `root` | `/github:` | empty | Show authenticated user + org memberships (via `/user/orgs`) |
| `root` | `/github:` | 2+ chars | Search users/orgs via `search/users` |
| `owner` | `/github:OWNER/` | empty | 30 most recently updated repos |
| `owner` | `/github:OWNER/` | 2+ chars | Search repos by name |
| `repo` | `/github:OWNER/REPO@` | any | Branches + tags merged, `:` suffix on selection |
| `files-default` | `/github:OWNER/REPO/[subdir/]` | any | Tree listing on default branch |
| `issues` | `/github:OWNER/REPO#` | empty | Top 30 open issues+PRs |
| `issues` | `/github:OWNER/REPO#` | numeric | Direct fetch + cache filter |
| `issues` | `/github:OWNER/REPO#` | text | Search via `search/issues` |
| canonical | `/github:OWNER/REPO@REF:/path/` | any | Tree listing at path |

#### Annotations (affixation-function)

Each level provides annotations via completion metadata `affixation-function`. Alignment uses `(space :align-to N)` display property. All annotations get `remoto-annotation` face.

| Level | Annotation |
|---|---|
| root | User/Organization type + org description |
| owner | Repository description |
| repo | group-function: "Branch" vs "Tag" |
| files-default, canonical | Last commit message per file (up to 20 API calls, cached) |
| issues | PR/Issue prefix + title + state; group-function: "Pull Request" vs "Issue" |

PRs are sorted before issues. Completion category is set to a `remoto-*` category so Marginalia does not override the annotations. remoto sets no completion style for those categories: the file-name handler honors `completion-regexp-list` (as the built-in primitive and TRAMP do) and reads the typed query from the minibuffer when a style such as orderless passes an empty FILE, so the user's own `completion-styles` apply.

#### Path normalization on RET

| Short form | Normalized to |
|---|---|
| `/github:owner/repo/` | `/github:owner/repo@DEFAULTBRANCH:/` |
| `/github:owner/repo/src/main.el` | `/github:owner/repo@DEFAULTBRANCH:/src/main.el` |
| `/github:owner/repo#42` | Routed to `remoto-topic-display` (no file operation) |

The `#NUM` interception happens in `remoto--find-file-around-a` BEFORE `remoto--maybe-rewrite` (rewrite would mangle the `#` delimiter).

#### file-exists-p RET guard

Returns nil for incomplete paths (triggers `[Confirm]` prompt):

| Returns t | Returns nil |
|---|---|
| `/github:`, `/github:owner/`, `/github:owner/repo/`, `/github:owner/repo#42`, canonical paths in tree, a bare `/github:owner`, `/github:owner/repo` or `/github:owner/repo@ref` that a cached listing holds or a search found | `/github:owner/repo` (bare, not listed), `/github:owner/repo#`, `/github:owner/repo@`, `/github:owner#` |

#### API functions

- `remoto--search-users` - `search/users`. Cached, client-side narrowing from parent queries. Min 2 chars.
- `remoto--recent-owner-repos` - `search/repositories?q=user:OWNER&sort=updated`. Cached.
- `remoto--search-owner-repos` - `search/repositories?q=QUERY+in:name+user:OWNER`. Cached, client-side narrowing.
- `remoto--fetch-branches` - `repos/OWNER/REPO/branches`. TTL-cached in `remoto--branches-cache`.
- `remoto--fetch-tags` - `repos/OWNER/REPO/tags`. TTL-cached in `remoto--tags-cache`.
- `remoto--fetch-issues` - `repos/OWNER/REPO/issues?state=open&sort=updated`. TTL-cached in `remoto--issues-cache`.
- `remoto--search-issues` - `search/issues?q=QUERY+repo:OWNER/REPO`. Not cached (ephemeral).
- `remoto--fetch-issue` - `repos/OWNER/REPO/issues/NUMBER`. Not cached.
- `remoto--fetch-user-orgs` - `/user/orgs` (authenticated endpoint, includes private memberships).
- `remoto--fetch-file-commits` - `repos/OWNER/REPO/commits?sha=REF&path=FILE&per_page=1` per file (capped at 20). TTL-cached in `remoto--file-commits-cache`.

#### Caches

| Variable | Key | Value | TTL |
|---|---|---|---|
| `remoto--tree-cache` | `"owner/repo@ref"` | hash-table (path -> entry) | Manual |
| `remoto--default-branch-cache` | `"owner/repo"` | branch name string | Manual |
| `remoto--branches-cache` | `"owner/repo"` | `(TIMESTAMP . LIST)` | `remoto-search-cache-ttl` |
| `remoto--tags-cache` | `"owner/repo"` | `(TIMESTAMP . LIST)` | `remoto-search-cache-ttl` |
| `remoto--issues-cache` | `"owner/repo"` | `(TIMESTAMP . ALIST)` | `remoto-search-cache-ttl` |
| `remoto--users-cache` | query string | `(TIMESTAMP . NAMES)` | `remoto-search-cache-ttl` |
| `remoto--search-cache` | typed key | `(TIMESTAMP . RESULTS)` | `remoto-search-cache-ttl` |
| `remoto--content-cache` | SHA | decoded string | Never (content-addressable) |
| `remoto--file-commits-cache` | `"owner/repo@ref:dir"` | `(TIMESTAMP . ALIST)` | `remoto-search-cache-ttl` |
| `remoto--listing-cache` | `"/github:"`, `"/github:OWNER/"` | `remoto--listing` (time, entries, state) | `remoto-repo-cache-ttl` |
| `remoto--entry-cache` | `"/github:ACCOUNT"`, `"/github:OWNER/REPO"`, `"/github:OWNER/REPO@REF"`, downcased | attributes of its Dired line | Manual |

#### Partial path handling

The handler recognizes partial paths (`/github:`, `/github:OWNER/`) that don't match `remoto--path-regexp`. For these: `file-exists-p` and `file-directory-p` return t, `file-name-directory`/`nondirectory` split correctly, `file-remote-p` returns `/github:` prefix. `remoto--parse-partial-canonical` handles `/github:OWNER/REPO[@REF]` (excludes `#` from repo name character class).

### Fetch indicator

While completion data loads asynchronously - user/repo search under `/github:`, or repo search in `remoto-browse` - a `⟳` appears between the prompt and the input (an overlay `before-string` at `minibuffer-prompt-end`). It is plain minibuffer text, so it works with any completion UI. It sits in front of the input, not after it, because Emacs draws the cursor after any string that follows point, and Vertico's candidates overlay claims the `cursor` property for its own leading space, which a `cursor` property on the indicator cannot win back. The slot stays for the rest of the prompt, blank between requests (`remoto--fetch-indicator-blank`), so the input does not shift as requests come and go; `remoto--hide-status` blanks it, `remoto--clear-status` removes it when the minibuffer exits. An in-flight counter (`remoto--inflight-count`), incremented and decremented around each `remoto--api-async` call, drives it; the overlay clears when the count returns to zero. `remoto--show-status` gates rendering to remoto completions: a `/github:` path, or the `remoto--repo-completion-table` collection. `remoto-browse` additionally shows a `Remoto ⟳` echo-area message during the synchronous resolve/open that runs after a repo is selected. Controlled by `remoto-show-fetch-indicator` (default t).

## Topic Display (remoto-topic.el)

Opening `/github:owner/repo#NUM` via `find-file` routes to `remoto-topic-display` instead of file operations. Detects whether the number is an issue or PR and renders accordingly.

For PRs: fetches full PR data (`repos/OWNER/REPO/pulls/NUM`) for diff stats, branch info, merge state, and review summary (`repos/OWNER/REPO/pulls/NUM/reviews`).

For both: fetches comments (`repos/OWNER/REPO/issues/NUM/comments`).

Buffer name: `*remoto: /PREFIX:owner/repo#NUM*`, the canonical prefix of the forge (`/github:`, `/codeberg:`). Mode: `remoto-topic-mode` (derived from `special-mode`). Keybindings: `b` (browse URL), `g` (refresh). Carriage returns stripped from body/comments.

Faces: `remoto-topic-title`, `remoto-topic-state-open`, `remoto-topic-state-closed`, `remoto-topic-state-merged`, `remoto-topic-meta`, `remoto-topic-comment-header`, `remoto-topic-additions`, `remoto-topic-deletions`.

## Forge-agnostic URL Layer

The web-URL features sit on a small forge-agnostic core, so adding a forge (GitLab, Codeberg, ...) is a data change, not new command code. Two pieces:

1. `remoto-forge-url-templates` - an alist keyed by forge symbol. Each value maps a URL KIND to a `format-spec` template. Path-level kinds: `blob`, `tree`, `blame`, `history`, `raw`. Repository-level kinds: `repo` (web root), `ssh` and `https` (clone URLs). Account-level kinds: `owner` (profile page), `owner-repos` (repositories tab). Issue/PR kinds: `issue`, `pr-diff`; branch kinds: `compare`, `new-pr`. Plus the `line`/`region` fragment builders. Specs: `%o` owner, `%r` repo, `%R` ref, `%p` repo-relative path, `%N` issue/PR number, `%L` line fragment.

2. A context plist - the currency every command and Embark action consumes, built by `remoto--path-context PATH &optional LINE-START LINE-END`:

| Key | Meaning |
|---|---|
| `:forge` | forge symbol, from the path prefix via `remoto--forge-type` |
| `:owner` `:repo` `:ref` | repository coordinates |
| `:path` | repo-relative path (`""` for root) |
| `:kind` | `tree` or `blob` |
| `:type` | target type: `remoto-repo`, `remoto-dir`, or `remoto-file` |
| `:line-start` `:line-end` | file line/region (file targets only) |

A repo root is classified `remoto-repo` without resolving the ref or fetching the tree, so it works offline and on bare `owner/repo` targets. `remoto--buffer-file-context` derives PATH plus line/region from the current buffer (file or Dired) and delegates to `remoto--path-context`. `remoto--context-url CTX KIND` and `remoto--context-web-url CTX` (which picks the web KIND from `:type`) turn a context into a URL.

### URL commands and `remoto-mode`

`remoto-copy-url` (obsoletes `remoto-copy-github-url`), `remoto-copy-blame-url`, `remoto-copy-permalink` (resolves ref -> commit SHA), `remoto-copy-raw-url`, `remoto-copy-history-url`, `remoto-browse-url`. All work in file buffers (current line / active region) and in Dired (entry at point, falling back to the directory). `remoto-mode` is a buffer-local minor mode auto-enabled in remoto buffers via `find-file-hook` / `dired-mode-hook`; its keymap is empty by default to avoid the user-reserved `C-c LETTER` space. The commands are grouped in the prefix keymap `remoto-command-map`, which users bind to a prefix of their choosing.

## Embark Integration (remoto-embark.el)

Optional, soft integration. Loaded only when Embark is present; remoto works identically without it.

### Non-breaking mechanism

- `embark` is NOT in `Package-Requires` - no hard dependency.
- `remoto-embark.el` does not `(require 'embark)`; it `defvar`s the few Embark variables it touches and registers itself inside `(with-eval-after-load 'embark ...)`. It byte-compiles and loads cleanly with Embark absent (verified with `byte-compile-error-on-warn`).
- `remoto.el` carries no reference to Embark at all, so the main file stays package-lint clean. Activation is automatic: an autoloaded `(with-eval-after-load 'embark (remoto-embark-register))` (the cookie is copied into the generated autoloads) registers the integration the moment Embark loads, with no manual `require` and load order irrelevant. Going through the autoloaded public `remoto-embark-register` rather than `(require 'remoto-embark)` avoids a load recursion when the file is itself loaded with Embark already present. Eager/manual setup via `(require 'remoto-embark)` still works. The lone `with-eval-after-load` package-lint caution is confined to this dedicated integration file, where it is the correct mechanism.

### Target types (forge-agnostic, stable public API)

`remoto-owner`, `remoto-repo`, `remoto-branch`, `remoto-issue`, `remoto-dir`, `remoto-file`, plus Embark's built-in `url` for forge web links at point. Two sources produce them:

- Buffers / Dired: a target finder (`remoto--embark-target-finder`, via `remoto--embark-target-at-point`) parses the remoto path's shape (root -> repo, tree -> dir, blob -> file) and returns `(TYPE FULLPATH)`. A line of a Dired of branches and tags is that ref (`remoto-branch`).
- Minibuffer completion: the completion category. remoto detects the level (owner/repo/branch/issue/file) and reports a per-level category (`remoto-owner`, `remoto-repo`, `remoto-branch`, `remoto-issue`, `remoto-file`, plus the single `remoto-browse` category used by `remoto-browse`) that Embark maps to a keymap.

Embark actions always receive a full canonical remoto path; a transformer expands minibuffer candidates (e.g. `remoto.el/`) to the full path before the action runs.

### Action catalog (tiered)

Shipped actions are marked; the rest are documented follow-ups.

- owner: browse profile, copy URL, open repositories tab. (Shipped.)
- repo: copy web URL, browse, clone, copy SSH URL, copy HTTPS URL, copy history URL. (Shipped.) Later: `gh repo clone`, open issues/PRs, fork/star, copy `owner/repo` shorthand, package recipe.
- branch: browse, copy URL, compare view, new-PR page. (Shipped.) Later: copy checkout command, tip SHA.
- issue/PR: open in remoto-topic, browse, copy URL, PR files-diff page, copy `owner/repo#N`. (Shipped.) Later: head branch.
- dir: copy URL, browse, copy history URL. (Shipped.) Later: copy repo-relative path.
- file: copy URL, browse, blame, permalink, raw, history. (Shipped.) Later: save a local copy, insert contents, copy `curl` command.

Descoped (read-only model mismatch): `gh pr checkout` and export-subdir-to-local both bridge into a local working copy, raising contention against a separately cloned repo - out of scope for a read-only browse integration.

### Keymaps

`remoto-embark-owner-map`, `remoto-embark-repo-map`, `remoto-embark-branch-map`, `remoto-embark-dir-map`, `remoto-embark-file-map`, `remoto-embark-issue-map` (defined with `defvar-keymap`), registered in `embark-keymap-alist` by target type, plus a generic `remoto` fallback entry mapped to the repo keymap. The `remoto-branch` entry lists the branch keymap and then the repo keymap, which Embark composes, so a branch or tag keeps clone, the clone URLs and history, and its own `y` and `b` give the ref's tree URL. Action commands take the target path and reuse the forge-agnostic context layer, so they are forge-agnostic too. The generic copy/browse actions (`remoto-embark-copy-url`/`-browse-url`) resolve a web URL for any target kind via `remoto--embark-web-url` - issue/PR, repository, directory, file, or owner - so an owner or issue candidate that reaches the repo or generic `remoto` keymap still works instead of failing with a forge-lookup error; the repository- and file-specific actions go through `remoto--embark-context`, which raises a clear "not a repository, directory, or file target" message on a non-repo target. A per-category transformer expands a bare minibuffer/collect candidate to its full path and classifies it by shape (`remoto--embark-classify`): `remoto-owner`/`remoto-branch`/`remoto-issue` keep their type, while `remoto-repo`/`remoto-file` and the generic `remoto`/`remoto-browse` categories re-derive it from the resolved path - so an owner target routes to `remoto-embark-owner-map` rather than the repo keymap. The built-in `url` target also gains `R` (`remoto-embark-open-in-remoto`).

### Implementation status

- Done: forge-agnostic core (templates including `repo`/`ssh`/`https`/`owner`/`owner-repos`/`issue`/`pr-diff`/`compare`/`new-pr`, `remoto--path-context` with `:type`, `remoto--context-web-url`), the URL commands, `remoto-mode`.
- Done: `remoto-embark.el` end to end - buffer/Dired target finder; per-level minibuffer completion categories (`remoto-owner`/`-repo`/`-branch`/`-issue`/`-file`) plus the `remoto-browse` category; candidate-to-path transformers; the `embark-collect` round-trip (verified against real Embark); owner/repo/branch/dir/file/issue keymaps and a generic `remoto` fallback; the `url`-at-point "open in remoto" bridge; clone governed by `remoto-clone-url-type`. CI exercises the integration against real Embark (`make test-embark`); the runtime stays embark-free.
- Remaining: `embark-export` refinement (a remoto Dired exporter via `embark-exporters-alist`, if feasible - `embark-collect` already works); the follow-up action tier (repo copy-shorthand, file save-local / insert-contents / copy-curl, dir copy-repo-relative-path).
- Descoped: `gh pr checkout` and export-subdir-to-local (read-only model mismatch).

## Inhibited functions

A remoto file buffer visits a real file name, so the major mode hooks, `after-change-major-mode-hook` and `find-file-hook` all run. Language-server clients started there cannot work: no server reads a remoto path. lsp-mode sees a non-nil `file-remote-p`, treats the buffer as TRAMP and offers only `-tramp` clients; Eglot finds no server executable "on the remote" and warns.

`remoto-inhibited-functions` (default `(lsp eglot-ensure)`) lists functions that do nothing in remoto buffers. While `global-remoto-mode` is on, each carries the `:around` advice `remoto--inhibit-a`, which skips the call when `buffer-file-name`, or `default-directory` in a buffer without one, matches `remoto--handler-regexp`. `lsp` covers every lsp-mode entry point, since `lsp-deferred`, restarts and installs all end in it; `eglot-ensure` covers Eglot's hook path. This is the pattern of Magit's `magit--inhibit-in-blob-buffers`, minus the load-time `advice-add`.

`remoto--inhibited` records which functions carry the advice, so turning the mode off removes exactly those even after a plain `setq` of the option. The option's `:set` moves the advice at once. Advice on a function that is not defined yet, or is still an autoload, waits for the definition and does not make the symbol `fboundp`, so remoto requires neither lsp-mode nor Eglot.

## project.el

A directory in a repository tree is a project: `(remoto . ROOT)`, ROOT the canonical `/PREFIX:OWNER/REPO@REF:/` of the tree (`remoto--project`). The levels above a tree (`/github:`, `/github:OWNER/`, `@`, `#`) have none, and neither has the short form `/github:OWNER/REPO/`, whose default branch would cost a request.

| Method | Answer |
|---|---|
| `project-root` | ROOT |
| `project-name` | `OWNER/REPO@REF`: ROOT after its prefix, without `:/` |
| `project-files` | the blobs under each of DIRS, from the tree (`remoto--tree-files`): full names, sorted; relative to the one directory asked for when `project-files-relative-names` allows it. A truncated tree lists what it holds and says so |
| `project-buffers` | project.el's default: the buffers whose `default-directory` is under ROOT |

project.el's own `project-files` runs `find` through `process-file`, and a repository has no local directory to run it in (see Programs). The commands that search with a program stop with remoto's message: `project-find-regexp`, `project-find-file` with a prefix argument, consult-ripgrep, consult-find, `grep`. `project-shell` and `project-compile` run in `~`.

`remoto-project-try` finds the project. It lives in `remoto-project.el`, apart from remoto.el, because project.el calls it for every directory: it answers only a directory whose file-name handler is remoto's or the bootstrap handler of the autoloads, and only then requires remoto. The package autoloads add it to `project-find-functions` at depth -90 once project.el loads, ahead of `project-try-vc`, whose search for marker files costs a request per name in a tree. So a remoto project in `project-list-file` resolves in a session that has not loaded remoto yet, and `remoto--project` turns the mode on, as other first uses do. Left to `project-try-vc`, such a project is not found: project.el drops it from its list and lists the files of a transient project with `find` in `~`.

project.el asks `file-remote-p` of every root it reads, writes and prunes, and recentf of every file it keeps, in sessions that may never browse a repository. So the autoloads hold the definition of `remoto-autoload-file-name-handler` itself, not an autoload of it: a `;;;###autoload` on a `progn` copies the `defun`. Before remoto loads, the handler answers `file-remote-p` of a canonical `/github:` or `/codeberg:` name with the prefix `remoto--handle-file-remote-p` gives, and nil for a CONNECTED that asks for a reached repository, since none is. Any other operation or identification, and a shorthand name, loads remoto and goes to `remoto--take-over`.

## Unloading

`remoto-unload-function` removes the handler-alist entry and all advice, clears all caches (tree, default-branch, branches, tags, issues, users, search, content, file-commits).

## Known Technical Debt

- `remoto-browse` and `find-file` completion still have parallel dispatch/formatting code. The fetch logic is shared (`remoto--fetch-dir-children-light`, `remoto--fetch-branches`, `remoto--fetch-issues`, etc.) and, as of 1.6.0, so is the owner repo search: `remoto-browse` delegates to `remoto--search-owner-repos` / `remoto--recent-owner-repos` and reformats the bare repo names to `owner/repo`, instead of keeping its own copy (the divergent `remoto--search-repos-from-parent` narrowing was removed). What still differs is the mode parsing (`remoto--browse-parse-input` vs `remoto--parse-partial-github-path`) and candidate formatting (full `owner/repo` strings vs bare path segments). A shared dispatcher returning raw candidates per mode, with each UI layer applying its prefix, would eliminate the rest. Non-trivial because `file-name-all-completions` splits input into `(file directory)` while `completing-read` uses a single string.

## Limitations

- Read-only. No commits, no pushes, no file modifications.
- No git operations (log, blame, diff). These would require either `libgit2` or many API calls.
- Timestamps in dired are synthetic (the tree API has no timestamps).
- Very large repos (100k+ files) use slower per-directory fetching.
- Binary files are base64-decoded as UTF-8 and may not display usefully.
- No process execution against the repo (no compile, no grep via subprocess). In-buffer search (isearch, occur) works on opened files.
- Symlinks are not resolved (shown as regular files).
- Rate limit: 5,000 requests/hour. Normal browsing stays well within this.
- Submodules appear as entries in the tree but are not traversable.

## Multi-forge Direction

The core speaks to a forge through the generic functions of the forge contract (`remoto-forge-*`), dispatching on a `cl-defstruct` type per forge; a forge registers its path prefixes with `remoto-register-forge`. Two forges ship: GitHub in `remoto-github.el` and Forgejo in `remoto-forgejo.el`, which registers Codeberg under `/codeberg:` and `/cb:`.

### Forgejo: GitHub's API against another host

Forgejo (and Gitea, and Codeberg, which runs Forgejo) cloned GitHub's REST API, so `remoto-forgejo` includes `remoto-github` and inherits its methods. Every GitHub function takes the forge it speaks for, and the transport asks the forge for its API host (`remoto--api-host`, `codeberg.org/api/v1`) and its kind for ghub (`remoto--ghub-forge`, `forgejo`). Forgejo overrides only what differs:

| Difference | GitHub | Forgejo |
|---|---|---|
| Page size and its name | `per_page=100&page=N`, 100 max, one page after another | `limit=50&page=N`, 50 max; the pages after the first are asked for at once, as many as its `X-Total-Count` says |
| Recursive tree | one answer, `truncated` past 100k entries | 1000 entries a page, `total_count`; the pages after the first are asked for at once |
| Tree of an empty repository | 409 `Git Repository is empty.` | 404; `repos/O/R` says `empty: true` |
| The token's own repositories | `user/repos?affiliation=owner` | `user/repos` ignores `affiliation` and adds its organizations' repositories; a listing keeps those whose owner is OWNER |
| Account search | `search/users?q=` -> `items` | `users/search?q=` -> `data` |
| Repository search | `search/repositories?q=Q in:name user:O` | `repos/search?q=Q&uid=ID&exclusive=true`, the owner's id from the account search that found O, or from `users/O` once |
| Topic search | `search/issues?q=Q repo:O/R` | `repos/O/R/issues?q=Q&state=all&type=all` |
| Refs under a prefix | `git/matching-refs/KIND/PREFIX` | `git/refs/KIND/PREFIX` |
| A ref's commit | `commits/REF` | `git/commits/REF` |
| Review states | `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED` | `APPROVED`, `REQUEST_CHANGES`, `COMMENT`, `REQUEST_REVIEW`; spelled GitHub's way, requests dropped |
| An organization's name | `login` | `username` |
| Web URLs | `blob/REF/PATH`, `tree/REF/PATH` | `src/branch/REF/PATH`, `src/tag/REF/PATH`, `src/commit/SHA/PATH`; `%k` in the templates is the kind, from the cached refs |

Other Forgejo and Gitea servers come from `remoto-forgejo-instances`, `(PREFIX HOST)` pairs; each registers a `remoto-forgejo` whose API is at `HOST/api/v1`, with URL templates for `HOST` under the prefix's name. Setting the option keeps the servers that stay as they are. A server that goes is unregistered, and its URL templates and its login go too, unless another forge shares its API host. `remoto-unregister-forge` kills the buffers of the forge first, file, Dired and topic buffers alike: a buffer whose name no handler serves makes `uniquify` fail to kill any buffer of the same name.

### Login per host

The login state (`remoto--login`: failed, token, user, account, hinted, declined) is kept per API host in `remoto--logins`, so a GitHub token and a Codeberg token live apart and a failure on one host leaves the other alone. The token lookup (see Authentication) needs no git config; a forge with no token is read anonymously from its first request. A request that needs a token offers `remoto-login` when a command of the user's runs a remoto entry point (`remoto--may-ask`, bound by the `find-file-noselect` and `dired-noselect` advice and by `remoto-browse`): an anonymous rate limit, a refused token, the root listing. During completion, from timers and from process filters it only says so; after a "no" too, for the session. `remoto-reset-auth` forgets every host, or one with a prefix argument, and auth-source's cache. The token's account heads the root listing and the completion at a forge's root: GitHub's idle warm-up learns it once the mode is on, and the root completion of any forge learns it after `remoto-debounce-delay` of idle time and refreshes, asking `/user` only with a token.

### Caches per forge

Every cache key starts with the canonical prefix of the forge (`remoto--repo-id`, `remoto--repo-key`): the tree cache, the default branches, the refs, issues, directory contents and searches. An `OWNER/REPO` that exists on two forges is two repositories.

### Path syntax

```
/github:owner/repo@ref:/path
/codeberg:owner/repo@ref:/path
/PREFIX:owner/repo@ref:/path       (an instance from remoto-forgejo-instances)
```

Each forge file carries an autoload cookie that registers `remoto-autoload-file-name-handler` for its prefixes, so the first path of a session loads remoto, `file-remote-p` aside (see project.el); the mode then installs the real handler under `remoto--handler-regexp`, every registered prefix. An instance's prefix exists once remoto is loaded.

### Next

GitLab (`/gitlab:`) and gists (`/gist:`) follow, after the contract is reshaped around the sources they need (nested groups, flat files, no refs).

## Dependencies

- Emacs 29.1+
- `ghub` 5.3+ (token configured in auth-source; see ghub docs; Forgejo since 5.0, `FORGE.user` for the domain of the web host since 5.3)
- No optional dependencies - completion works with any frontend (vertico, ivy, helm, vanilla Emacs)

## File Structure

```
remoto.el/
  remoto.el          ;; core: file-name-handler, completion, transport, caching, the forge contract
  remoto-github.el   ;; GitHub: the REST endpoints behind the contract, URL parsers, remoto-browse
  remoto-forgejo.el  ;; Forgejo and Gitea on GitHub's shape; registers Codeberg, remoto-forgejo-instances
  remoto-topic.el    ;; issue/PR display buffers
  remoto-embark.el   ;; optional Embark integration (loaded only when embark is present)
  remoto-project.el  ;; remoto-project-try for project.el, apart so remoto loads only for its own directories
  SPEC.md            ;; this spec
  README.org         ;; user-facing documentation
  changelog.org      ;; release history
  Makefile           ;; test runner
  LICENSE
  test/
    remoto-tests.el             ;; buttercup tests (embark-free path), the grammar and conformance suites
    remoto-embark-tests.el      ;; Embark integration tests (real embark; make test-embark)
    remoto-integration-tests.el ;; end-to-end integration tests
    remoto-e2e.el               ;; typed cases under six completion setups, replayed from recorded answers
    remoto-e2e-cases.el         ;; the cases, shared by the replay suite and the keystroke runner
    remoto-keys.el              ;; the keystroke runner: emacs -nw -q under tmux, or the running Emacs
    remoto-keys-init.el         ;; the init of each profile the runner starts
    remoto-keys-tests.el        ;; buttercup tests of the runner (make test)
    record-codeberg-fixtures.el ;; records test/fixtures/codeberg.jsonl for the Codeberg conformance kit
```
