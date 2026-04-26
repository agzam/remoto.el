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

4. File-name handler - the central dispatch function registered in `file-name-handler-alist`. Receives (OPERATION . ARGS), constructs a handler name via `(intern-soft (format "remoto--handle-%s" operation))` and calls it if bound, otherwise falls through to default Emacs handling.

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

Public repos work without any token - `remoto--api` automatically falls back to unauthenticated requests (60 req/hr) when no auth-source entry is found.

For private repos (or higher rate limits at 5000 req/hr), tokens are resolved via `auth-source`. The `remoto-github-auth` defcustom controls which token is used:

- `nil` (default) - tries the standard `ghub` token (`USERNAME^ghub` in auth-source), falls back to unauthenticated
- `'none` - always unauthenticated
- A symbol like `'forge` - uses that package's token
- A string - literal token value

Auth-source entry format:
```
machine api.github.com login USERNAME^ghub password ghp_TOKEN
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
| `file-exists-p` | Lookup in tree cache |
| `file-directory-p` | Check `:type` = `"tree"` in cache |
| `file-regular-p` | Check `:type` = `"blob"` in cache |
| `file-readable-p` | Delegates to `file-exists-p` |
| `file-writable-p` | Always nil |
| `file-attributes` | Synthesize from cache entry (size, type, mode, epoch-0 timestamps) |
| `directory-files` | List tree cache children for parent path, prepend `.` and `..` |
| `directory-files-and-attributes` | Same, with attributes |
| `file-name-all-completions` | Filter tree cache entries by prefix, append `/` to dirs |
| `file-name-completion` | Delegate to `try-completion` on completions list |
| `insert-file-contents` | Fetch file content via API, insert into buffer |
| `insert-directory` | Format dired-compatible listing from tree cache |
| `expand-file-name` | Normalize path components, handle relative paths under remoto dirs |
| `file-truename` | Return the path as-is (no symlink resolution) |
| `file-remote-p` | Return the `/github:owner/repo@ref:` prefix (or method/host on request) |
| `file-local-copy` | Download to temp file, return temp path |
| `make-nearby-temp-file` | Create temp file in system temp dir |
| `file-name-directory` | Return directory part of remoto path |
| `file-name-nondirectory` | Return non-directory part of remoto path |
| `file-name-as-directory` | Append `/` if not present |
| `directory-file-name` | Strip trailing `/` (preserving `:/` after prefix) |
| `file-name-case-insensitive-p` | Always nil (GitHub is case-sensitive) |
| `vc-registered` | Always nil (not under local vc) |
| `abbreviate-file-name` | Return as-is |
| `unhandled-file-name-directory` | Return nil |

### Write operations (all read-only)

`write-region`, `delete-file`, `delete-directory`, `rename-file`, `copy-file`, `set-file-modes`, `set-file-times` - all signal `(user-error "Remoto: repository is read-only")`.

`make-directory` succeeds silently for directories that already exist (required by dired), signals read-only error for new directories.

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

## TRAMP Coexistence

TRAMP's `tramp-file-name-regexp` matches `/method:...` patterns, which would intercept `/github:...` paths. The remoto handler is pushed to the front of `file-name-handler-alist` so it's checked first. First match wins.

## Error Handling

ghub signals typed conditions for HTTP errors. `remoto--api` catches these and re-signals as `user-error`:

- `ghub-404` - not found (repo missing, private without access)
- `ghub-403` - forbidden (rate limit, permissions)
- `ghub-401` - authentication failed (missing or invalid token in auth-source)
- `ghub-http-error` - catch-all for other HTTP errors
- `ghub-error` - catch-all for transport/connection failures
- Truncated tree: log a message, fall back to per-directory fetching.

## Interactive Commands

- `remoto-browse` - prompt for a repo using standard `completing-read` with a programmed completion table (`remoto--repo-completion-table`), open dired at root or find-file for blob paths. Type 3+ characters to trigger GitHub search via the search API. Tab completes repo names. Append `@` to complete branch names - fetches branches via the GitHub Branches API and offers `owner/repo@branch` candidates, with prefix filtering. Works with any completion frontend (vertico, ivy, helm, vanilla Emacs). Search results are cached for `remoto-search-cache-ttl` seconds (default 300). Branch results are cached in `remoto--branches-cache` with the same TTL as search results.
- `remoto-refresh` - invalidate tree and branch caches for current repo, re-fetch. Reverts dired buffer if in one.
- `remoto-copy-github-url` - for the current file/line, produce the corresponding `github.com` URL and copy to kill ring. Includes `#L<n>` suffix for files.

## Unloading

`remoto-unload-function` removes the `file-name-handler-alist` entry and all advice, ensuring clean `unload-feature` support.

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

Switching from `gh` CLI to `ghub` opens up support for other forges. ghub already handles auth and transport for GitHub, GitLab, Gitea/Forgejo, Gogs, and Bitbucket via its `:forge` and `:host` keyword arguments.

### Forge API compatibility

Gitea (and by extension Codeberg, Forgejo) cloned GitHub's REST API almost exactly:

| Operation | GitHub | Gitea/Codeberg |
|---|---|---|
| Repo info | `GET /repos/:owner/:repo` | `GET /repos/:owner/:repo` |
| Tree | `GET /repos/:owner/:repo/git/trees/:sha?recursive=1` | `GET /repos/:owner/:repo/git/trees/:sha?recursive=1` |
| Contents | `GET /repos/:owner/:repo/contents/:path?ref=REF` | `GET /repos/:owner/:repo/contents/:path?ref=REF` |
| Blob | `GET /repos/:owner/:repo/git/blobs/:sha` | `GET /repos/:owner/:repo/git/blobs/:sha` |
| Search | `GET /search/repositories?q=QUERY` | `GET /repos/search?q=QUERY` |

Response shapes are nearly identical. Gitea/Codeberg support could be added with minimal per-forge logic - mostly just different `:host` / `:forge` kwargs to ghub and a different search endpoint.

GitLab's API is structurally different:

| Operation | GitLab |
|---|---|
| Repo info | `GET /projects/:id` (uses URL-encoded `owner/repo` as `:id`) |
| Tree | `GET /projects/:id/repository/tree?path=PATH&ref=REF&recursive=true` |
| File | `GET /projects/:id/repository/files/:path?ref=REF` (base64 in `.content`) |
| Blob | `GET /projects/:id/repository/blobs/:sha` |
| Search | `GET /projects?search=QUERY` |

GitLab requires a forge-specific API adapter but the overall structure (fetch tree, cache it, fetch files on demand) maps 1:1.

### Path syntax for multi-forge

The path prefix determines the forge:

```
/github:owner/repo@ref:/path      (existing)
/gitlab:owner/repo@ref:/path      (future)
/codeberg:owner/repo@ref:/path    (future)
```

Each prefix would have its own entry in `file-name-handler-alist`, dispatching to the same handler with forge context derived from the prefix. The handler, tree cache, and content cache are forge-agnostic - only the API adapter layer differs.

### Implementation approach

1. Extract a forge-agnostic protocol (API adapter) with methods: `fetch-repo-info`, `fetch-tree`, `fetch-contents`, `fetch-blob`, `search-repos`.
2. Implement the GitHub adapter (current code, essentially unchanged).
3. Add a Gitea adapter (near-copy of GitHub, different `:forge`/`:host` in ghub calls, different search endpoint).
4. Add a GitLab adapter (different endpoint construction and response parsing).
5. Register multiple handler-alist entries, one per forge prefix.

## Dependencies

- Emacs 29.1+
- `ghub` 4.0+ (token configured in auth-source; see ghub docs)
- No optional dependencies - completion works with any frontend (vertico, ivy, helm, vanilla Emacs)

## File Structure

```
remoto.el/
  remoto.el          ;; the package - single file
  SPEC.md            ;; this spec
  README.org         ;; user-facing documentation
  CHANGELOG.org      ;; release history
  Makefile           ;; test runner
  LICENSE
  test/
    remoto-tests.el  ;; buttercup tests
```
