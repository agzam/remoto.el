# remoto.el - Specification

Browse any GitHub repository in Emacs as if it were cloned locally - without cloning it.

## Overview

remoto.el registers a virtual filesystem via `file-name-handler-alist` that intercepts Emacs file operations on paths with a `/github:` prefix and translates them into GitHub API calls via the `gh` CLI. The result: `find-file`, dired, completion, xref - all standard Emacs file tooling works against a remote GitHub repo. Read-only.

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

When `@REF` is omitted, the first access resolves the default branch via `gh api repos/OWNER/REPO --jq .default_branch` and caches it.

## Architecture

```
 User: C-x d /github:torvalds/linux@master:/
           |
           v
 file-name-handler-alist  (regexp: \\`/github:)
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
  tree cache  (hash table)    gh api (fetch file)
  (hash table)
     ^
     |
  gh api repos/OWNER/REPO/git/trees/SHA?recursive=1
  (single call, cached per repo@ref)
```

### Core components

1. Path parser - extract owner, repo, ref, path from a remoto path string.

2. `gh` API wrapper - call `gh api ENDPOINT`, parse JSON response. All network I/O goes through this single function.

3. Tree cache - on first access to any path in a repo@ref, fetch the full tree via the Git Trees API. Store as a hash table keyed by path, values being alists of (type, size, sha, mode). Cache is keyed by `owner/repo@ref`.

4. File-name handler - the central dispatch function registered in `file-name-handler-alist`. Receives (OPERATION . ARGS), delegates to operation-specific functions.

## gh CLI Delegation

All GitHub API access goes through `gh` CLI:

```elisp
(defun remoto--api (endpoint &optional jq-filter)
  "Call GitHub API via gh CLI. Returns parsed JSON."
  ...)
```

Internally: `gh api ENDPOINT` (or `gh api ENDPOINT --jq FILTER` when a filter is provided).

Why `gh` and not `url-retrieve`:
- Handles all auth: personal tokens, OAuth, SSO/SAML, GitHub Enterprise
- Private repos behind SSO work with zero extra configuration
- Token refresh, credential storage - all handled
- One less thing to implement and maintain

Process calls use `call-process` (synchronous). No sentinels, no async complexity. Browsing is inherently interactive and sequential - the user waits for the dired buffer or file to appear.

## Tree Cache

On first access to any path in a `owner/repo@ref`:

```
gh api repos/OWNER/REPO/git/trees/REF?recursive=1
```

Returns every file and directory in the repo (path, type, size, sha, mode). Stored in:

```elisp
(defvar remoto--tree-cache (make-hash-table :test 'equal)
  "Hash table: \"owner/repo@ref\" -> hash table of path -> entry.")
```

Inner hash table: `"kernel/main.c"` -> `(:type "blob" :size 12345 :sha "abc..." :mode "100644")`

Directories are synthesized from the tree (the API returns blobs and sub-trees, but intermediate directories may need to be inferred from paths).

Cache invalidation: manual only. A command `remoto-refresh` clears the cache for a given repo@ref, forcing re-fetch on next access.

### Large repos

The Trees API truncates at 100,000 entries / 7 MB response. When `truncated` is true in the response, fall back to per-directory fetching via the Contents API:

```
gh api repos/OWNER/REPO/contents/PATH?ref=REF
```

This returns one directory level at a time. The tree cache stores what it has and fetches missing subdirectories on demand.

## File Operations

### Must implement (read operations)

| Operation | Implementation |
|---|---|
| `file-exists-p` | Lookup in tree cache |
| `file-directory-p` | Check type = "tree" in cache |
| `file-regular-p` | Check type = "blob" in cache |
| `file-readable-p` | Always t if exists |
| `file-writable-p` | Always nil |
| `file-attributes` | Synthesize from cache entry (size, type, fake timestamps) |
| `directory-files` | Filter tree cache by parent path |
| `directory-files-and-attributes` | Same, with attributes |
| `file-name-all-completions` | Filter tree cache entries for completion |
| `insert-file-contents` | Fetch file content via API, insert into buffer |
| `insert-directory` | Format dired-compatible listing from tree cache |
| `expand-file-name` | Normalize path components |
| `file-truename` | Return the path as-is (no symlink resolution) |
| `file-remote-p` | Return the `/github:owner/repo@ref:` prefix |
| `file-local-copy` | Download to temp file, return temp path |
| `make-nearby-temp-file` | Create temp file in system temp dir |

### Write operations (all error)

`write-region`, `delete-file`, `delete-directory`, `rename-file`, `copy-file`, `make-directory`, `set-file-modes`, `set-file-times` - all signal `(user-error "remoto: repository is read-only")`.

### Delegated to defaults

Operations not listed above fall through to default Emacs handling via the standard `inhibit-file-name-handlers` / `inhibit-file-name-operation` mechanism.

## Fetching File Contents

For files under 1 MB, the Contents API returns base64-encoded content:

```
gh api repos/OWNER/REPO/contents/PATH?ref=REF
```

For files over 1 MB (or as an optimization), use the raw download:

```
gh api repos/OWNER/REPO/git/blobs/SHA
```

The blob response contains base64-encoded content regardless of file size. Decode with `base64-decode-region`.

Fetched file contents could be cached in memory (keyed by sha) to avoid re-fetching the same file. Since sha is a content hash, this cache never goes stale.

## Dired Integration

`insert-directory` must produce output matching dired's expected format:

```
  drwxr-xr-x  1 github github     0 2024-01-01 00:00 kernel
  drwxr-xr-x  1 github github     0 2024-01-01 00:00 drivers
  -rw-r--r--  1 github github   727 2024-01-01 00:00 README
  -rw-r--r--  1 github github 18693 2024-01-01 00:00 Makefile
```

Timestamps are synthetic (the Trees API does not return timestamps). Permissions are derived from the mode field (100644 -> `-rw-r--r--`, 100755 -> `-rwxr-xr-x`, 040000 -> `drwxr-xr-x`).

## TRAMP Coexistence

TRAMP's `tramp-file-name-regexp` matches `/method:...` patterns, which would intercept `/github:...` paths. Two strategies:

1. Push our handler to the front of `file-name-handler-alist` so it's checked first. First match wins.
2. Also register via `tramp-register-foreign-file-name-handler` as a safety net, so if TRAMP somehow sees the path, it delegates to us.

Primary strategy is (1). The handler regexp is more specific than TRAMP's general pattern, and `push` ensures it's checked first.

## Error Handling

- `gh` not found: signal error with install instructions on first API call.
- `gh` not authenticated: detect from exit code / stderr, suggest `gh auth login`.
- 404 (repo not found / private without access): clear error message naming the repo.
- 403 (rate limited): report remaining reset time from response headers.
- Network errors: report the `gh` stderr output.
- Truncated tree: log a message, switch to per-directory mode.

## Interactive Commands

- `remoto-browse` - prompt for `owner/repo` (with completion via `gh api search/repositories?q=QUERY` for discovery), optionally ref, open dired at repo root.
- `remoto-refresh` - invalidate tree cache for current repo, re-fetch.
- `remoto-copy-github-url` - for the current file/line, produce the corresponding `github.com` URL. Inverse of the path mapping.

## Limitations

- Read-only. No commits, no pushes, no file modifications.
- No git operations (log, blame, diff). These would require either `libgit2` or many API calls.
- Timestamps in dired are fake (the tree API has no timestamps).
- Very large repos (100k+ files) use slower per-directory fetching.
- Binary files are base64-decoded but may not display usefully.
- No process execution against the repo (no compile, no grep via subprocess). In-buffer search (isearch, occur) works on opened files.
- Symlinks are not resolved (shown as regular files).
- Rate limit: 5,000 requests/hour. Normal browsing stays well within this.
- Submodules appear as entries in the tree but are not traversable.

## Dependencies

- Emacs 29+
- `gh` CLI (authenticated via `gh auth login`)
- No other packages required

## File Structure

```
remoto.el/
  remoto.el          ;; the package - single file
  SPEC.md            ;; this spec
  README.md          ;; user-facing documentation
  LICENSE
```
