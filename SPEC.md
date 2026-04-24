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

3. Tree cache - on first access to any path in a repo@ref, fetch the full tree via the Git Trees API. Store as a hash table keyed by path, values being plists with keys `:type`, `:size`, `:sha`, `:mode`. Cache is keyed by `owner/repo@ref`.

4. File-name handler - the central dispatch function registered in `file-name-handler-alist`. Receives (OPERATION . ARGS), constructs a handler name via `(intern-soft (format "remoto--handle-%s" operation))` and calls it if bound, otherwise falls through to default Emacs handling.

## gh CLI Delegation

All GitHub API access goes through `gh` CLI:

```elisp
(defun remoto--api (endpoint)
  "Call GitHub API via gh CLI. Returns parsed JSON."
  ...)
```

Internally: `gh api ENDPOINT`. The `gh` executable is looked up lazily via `executable-find` on each call, so installing `gh` after loading remoto works without reloading.

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

Directories are synthesized from the tree (the API returns blobs and sub-trees, but intermediate directories may need to be inferred from paths). A constant `remoto--dir-entry` holds the plist used for synthesized directory entries (root, intermediates, dired `.`/`..`).

Path lookup is normalized via `remoto--tree-lookup-key`, which strips leading/trailing slashes and collapses runs of slashes.

Cache invalidation: manual only. A command `remoto-refresh` clears the cache for a given repo@ref, forcing re-fetch on next access.

### Large repos

The Trees API truncates at 100,000 entries / 7 MB response. When `truncated` is true in the response, fall back to per-directory fetching via the Contents API:

```
gh api repos/OWNER/REPO/contents/PATH?ref=REF
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
gh api repos/OWNER/REPO/contents/PATH?ref=REF
```

For larger files, fall back to the Blobs API:

```
gh api repos/OWNER/REPO/git/blobs/SHA
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

- `gh` not found: signal error with install instructions on first API call.
- `gh` not authenticated: detect from stderr output, suggest `gh auth login`.
- 404 (repo not found / private without access): clear error message naming the endpoint.
- 403 (rate limited / permissions): report access denied with the endpoint.
- Network errors: report the `gh` stderr output with exit code.
- Truncated tree: log a message, fall back to per-directory fetching.

## Interactive Commands

- `remoto-browse` - prompt for a repo (with search completion via `gh api search/repositories` when `consult` is available, or `completion-table-dynamic` otherwise), open dired at root or find-file for blob paths.
- `remoto-refresh` - invalidate tree cache for current repo, re-fetch. Reverts dired buffer if in one.
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

## Dependencies

- Emacs 29.1+
- `gh` CLI (authenticated via `gh auth login`)
- Optional: `consult` for async search completion in `remoto-browse`

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
