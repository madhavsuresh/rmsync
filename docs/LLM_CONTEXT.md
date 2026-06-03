# rmsync — single-file context for LLM chats

Drop this file into a chat and ask questions like "my tablet isn't
pulling new writing, what do I check?" or "how do I move my sync
folder to iCloud?" This document is self-contained. It assumes the
user has `rmsync` installed and working at some point.

If the user is asking **how to use** the tool, answer from the
"Commands" / "How sync works" / "Recipes" sections. If they're asking
**why something broke**, walk them through "Troubleshooting" — it's
ordered from cheapest to most invasive. Only invoke the "Invariants"
section when a deep issue surfaces (e.g. ghost pages on the tablet).

---

## What rmsync is

An explicit sync tool between one configured reMarkable cloud folder
and a local Markdown tree. New installs use `/sync/notes`; existing
`/Writing` configs remain supported. Runs on macOS (via launchd, with
a menubar app) and on Linux (via Docker, headless).

- **Local to tablet:** edit a `.md` file, then run `rmsync push
  [path ...]`. The CLI packs Markdown into a reMarkable v6 `.rmdoc`
  archive and pushes it through `rmapi`.
- **Tablet to local:** write on the tablet and let the tablet sync to
  the reMarkable cloud, then run `rmsync pull`, review with
  `rmsync diff`, and apply selected changes with `rmsync accept`.
  Pull stages cloud content first and never overwrites local files
  until an accept command runs.
- **Optional git-backed sync:** inside a git repository, run
  `rmsync git init`, then use `rmsync git pull` and `rmsync git push`
  (or the `rmsync-git` wrapper) to make all cloud exchanges pass
  through git branches, commits, and merge conflict handling. This is
  an additional mode, not a replacement for the normal explicit
  pull/diff/accept/push workflow.

No handwriting OCR. Pen strokes come through as empty markdown. Only
typed-text notebooks round-trip.

The daemon is a Swift 6 binary. In current explicit-sync releases it
is status-only: it keeps IPC, dashboard, menu bar state, and periodic
status refreshes online, but it does not start a local watcher, cloud
poller, startup reconcile pass, or background worker pool. Sync
mutations happen through CLI commands.

Platform differences are confined to:

- **macOS:** launchd-managed daemon (label `com.user.rmsync`); menubar
  app (label `com.user.rmsync.menubar`); Spotlight metadata + Finder
  folder icon on accepted pulled files.
- **Linux:** Docker-supervised daemon (no launchd / systemd
  interaction); no menubar; no Finder/Spotlight integration.

Both platforms talk to the daemon over a Unix-domain socket
(`ipc.sock` under the state dir) for status and lifecycle-adjacent
actions. `sync-now` is deprecated and returns an explicit-sync error;
use `pull`, `diff`, `accept`, and `push`.

---

## Canonical file locations

Use these exact paths when helping the user. macOS first; Linux
(Docker) second.

### macOS

```
# binaries
~/.local/bin/rmsync                                 # CLI symlink → swift/.build/release/rmsync
~/.local/bin/rmsync-git                             # wrapper → rmsync git "$@"
~/code/rmsync/swift/.build/release/rmsync               # daemon + CLI binary
~/code/rmsync/swift/.build/release/rmsync-menubar      # menu bar app
/opt/homebrew/bin/rmsync-git                        # Homebrew wrapper → rmsync git "$@"

# launchd agents
~/Library/LaunchAgents/com.user.rmsync.plist
~/Library/LaunchAgents/com.user.rmsync.menubar.plist

# daemon-owned data
~/.config/rmsync/config.toml                       # config (TOML)
~/Library/Application Support/rmsync/state.db      # SQLite state
~/Library/Application Support/rmsync/ipc.sock      # live IPC socket
~/Library/Application Support/rmsync/status.json   # fallback status snapshot
~/Library/Application Support/rmsync/backups/      # snapshot history (per doc-id; v0.2.20+)

# logs
~/Library/Logs/rmsync/stderr.log                   # structured JSON, one event per line
~/Library/Logs/rmsync/stdout.log                   # usually empty under the Swift daemon
~/Library/Logs/rmsync/menubar.log

# rmapi (separate tool the daemon shells out to)
~/.config/rmapi/rmapi.conf                          # cloud auth

# default sync dir (user may have moved it)
~/rmsync-notes/
~/rmsync-notes/.rmsync-trash/                       # soft-delete buffer (v0.2.19+)
```

### Linux (Docker container layout)

```
# inside the container
/usr/local/bin/rmsync                              # daemon + CLI binary
/usr/local/bin/rmapi                               # rmapi (Go binary, bundled)
/usr/local/bin/rmsync-entrypoint.sh                # PID-1 init wrapper

# volume mounts (host paths come from docker-compose.yml; defaults below)
/config/config.toml                                # config (TOML)
/config/rmapi/rmapi.conf                           # cloud auth
/state/state.db                                    # SQLite state
/state/ipc.sock                                    # live IPC socket
/state/backups/                                    # snapshot history (per doc-id; v0.2.20+)
/sync/                                             # your reMarkable Markdown tree
/sync/.rmsync-trash/                               # soft-delete buffer (v0.2.19+)
```

No menubar. No launchd plists. Logs go to stdout/stderr (the
daemon's structured-JSON sink), captured via `docker logs`.

The sync dir is configurable via `rmsync relocate` on macOS; on
Linux/Docker, edit `/config/config.toml`'s `sync_dir` and
`docker compose restart`.

---

## Install

Three supported paths: macOS (Homebrew or source) and Linux (Docker).

### Homebrew (recommended for most users)

```sh
brew install madhavsuresh/rmsync/rmsync
rmapi                            # interactive auth: paste 8-char code
rmsync-install-agents            # seeds config + boots daemon + menu bar
rmsync doctor                    # all ✓
```

The brew formula declares `madhavsuresh/rmsync/rmapi` as a dependency,
so rmapi is installed transitively. The post-install helper
`rmsync-install-agents` writes a default `~/.config/rmsync/config.toml`,
mkdir's `~/rmsync-notes`, renders both launchd plists with
brew-relative paths, and bootstraps both agents.

Updates: `brew upgrade rmsync`. The formula's `post_install` kicks
both running agents so they reload the new binary without a separate
restart command.

### From source

```sh
git clone https://github.com/madhavsuresh/rmsync.git ~/code/rmsync
cd ~/code/rmsync
./install.sh
```

The installer:

1. Verifies Swift 6.0+ is available (Xcode command-line tools).
2. Offers to install `rmapi` via Homebrew.
3. Walks the user through `rmapi` cloud authentication — open
   `https://my.remarkable.com/device/desktop/connect`, sign in, paste
   the 8-character code.
4. Builds `rmsync` + `rmsync-menubar` in release mode.
5. Installs + loads both launchd plists, sets `~/.local/bin` on PATH.

Re-run `./install.sh` to pick up local code changes. The launchd
agents are kicked on every run.

### Docker (Linux mini-PC / NAS / homelab)

For users without a Mac. Headless service; no menubar. Multi-arch
image (amd64 + arm64) published on every release tag to
`ghcr.io/madhavsuresh/rmsync`.

```sh
mkdir -p data/{config,state,sync}
curl -fsSL -o docker-compose.yml \
    https://raw.githubusercontent.com/madhavsuresh/rmsync/main/docker-compose.yml
docker compose up -d
docker exec -it rmsync rmapi   # one-time auth
docker exec rmsync rmsync doctor
```

Volume layout: `/config` (rmapi.conf + config.toml), `/state`
(state.db, ipc.sock), `/sync` (your `.md` tree).

Operational commands run via `docker exec rmsync rmsync <command>`
(uses the IPC socket on the volume). Lifecycle commands
(`start/stop/restart`, `relocate`) error on Linux because the
container runtime owns those — use `docker compose restart` etc.

The Linux container uses the same explicit-sync command flow as macOS.
Legacy inotify watcher settings remain in config for compatibility,
but the current daemon does not start an automatic watcher.

### Either way: rmapi auth is required

If `rmapi` isn't authenticated, the daemon runs but every sync
operation fails. `rmsync doctor`'s "rmapi authenticated" check catches
this. The brew install path doesn't run an interactive auth flow —
the user must invoke `rmapi` themselves and paste the code. Same
on Docker (`docker exec -it rmsync rmapi`).

---

## Commands

Core subcommands. All are idempotent unless they explicitly apply a
push, accept, delete, restore, or force-push.

| Command | Talks to | What it does | Linux/Docker |
|---|---|---|---|
| `rmsync status` | IPC | Live state: tracked docs, last pull/push, conflicts, queue | ✓ |
| `rmsync pause` | IPC | Sets paused flag. Survives daemon restart. | ✓ |
| `rmsync resume` | IPC | Clears paused flag. | ✓ |
| `rmsync pull` | rmapi + staging | Fetch cloud changes into staging without touching local files. | ✓ |
| `rmsync diff [path]` | staging | Show staged cloud changes, or one file diff. | ✓ |
| `rmsync accept <path>` | filesystem + state DB | Apply selected staged cloud changes locally. | ✓ |
| `rmsync accept --all` | filesystem + state DB | Apply all staged non-delete changes. | ✓ |
| `rmsync accept --include-deletes <path>` | filesystem + state DB | Accept staged cloud deletes and move local files to trash. | ✓ |
| `rmsync push [path ...]` | rmapi + state DB | Push local Markdown changes to the cloud. | ✓ |
| `rmsync push --include-deletes` | rmapi + state DB | Also propagate tracked local files missing on disk. | ✓ |
| `rmsync force-push` | rmapi + staging | Preview replacing the cloud folder with the local tree. | ✓ |
| `rmsync force-push --apply` | rmapi + state DB | Apply the local-tree overwrite/delete plan. | ✓ |
| `rmsync init` | filesystem + rmapi | Create the local sync dir and configured cloud folder. | ✓ |
| `rmsync git init` | git + rmapi | Initialize `/sync/git/<name>` for an optional git-backed workflow. | requires git |
| `rmsync git pull` / `rmsync-git pull` | git + rmapi | Render cloud state into a new git branch. | requires git |
| `rmsync git push` / `rmsync-git push` | git + rmapi | Merge cloud with `HEAD`, then upload the verified git tree. | requires git |
| `rmsync sync-now` | IPC | Deprecated; automatic polling is disabled. | ✓ |
| `rmsync conflicts` | state DB | Lists unresolved `.md.conflict` files. | ✓ |
| `rmsync doctor` | direct | Runs 10 health checks; exits 1 on any ✗. | ✓ |
| `rmsync logs -f` | file tail | Tails the active daemon log, usually `stderr.log`. Ctrl+C to stop. | use `docker logs -f rmsync` |
| `rmsync start` | launchctl | Bootstraps the agent. | ✗ — `docker compose up -d` |
| `rmsync stop` | launchctl | Boots out the agent. | ✗ — `docker compose stop rmsync` |
| `rmsync restart` | launchctl | `kickstart -k`. Use after config edits or rebuilds. | ✗ — `docker compose restart rmsync` |
| `rmsync relocate <path>` | composite | Move sync dir + rewrite state + update config + restart. | ✗ — edit `/config/config.toml` and `docker compose restart` |
| `rmsync uninstall` | script | Remove launchd agent. Keeps config/state. `--purge` wipes all. | ✗ — `docker compose down` |
| `rmsync trash list` | filesystem | List soft-deleted files under `<sync_dir>/.rmsync-trash/`. | ✓ |
| `rmsync trash restore <rel>` | filesystem | Move a trashed file back; push explicitly if cloud should change. `--all` for bulk. | ✓ |
| `rmsync trash prune` | filesystem | Drop trash entries past `trash_retention_days`. | ✓ |
| `rmsync history list <path>` | state DB + filesystem | Per-doc snapshot history (newest first). Pushes and accepted pull overwrites are captured. | ✓ |
| `rmsync history diff <path> [--against <ts>]` | filesystem | Unified `diff -u` vs a snapshot (default: most recent). | ✓ |
| `rmsync history restore <path> --to <ts>` | filesystem | Revert to a snapshot; current -> trash; push explicitly when ready. | ✓ |

Internal-only subcommands: `daemon` (invoked by launchd), `init`
(legacy pointer to `install.sh`).

When the daemon is stopped, `rmsync status` falls back to reading
`state.db` directly — it'll report `daemon: not running` but still
show tracked docs.

---

## How sync actually works

### Local to cloud (`rmsync push`)

1. User edits a Markdown file under `sync_dir`.
2. User runs `rmsync push [path ...]` (or no paths to scan all
   pushable Markdown files).
3. The CLI hashes the local file. If it is tracked and unchanged from
   `last_synced_md_hash`, it skips.
4. Unless `--force` is passed, it checks that the tracked cloud doc is
   still at the last accepted/pushed remote baseline.
5. It refuses dataless File Provider placeholders and suspicious empty
   reads that would overwrite a previously non-empty doc.
6. It packs Markdown into a v6 `.rmdoc` archive:
   - Splits on `<!-- rmsync:page-break -->` for multi-page.
   - Each page is rendered by `PageCodec.renderPage()` with a stable
     `author_uuid`.
   - Existing page IDs are reused when available.
7. It shells `rmapi put --force` for updates, records the new remote
   metadata, and updates `last_push_at`, `last_synced_md_hash`, and
   `page_ids`.

Local deletes are ignored unless the user passes
`rmsync push --include-deletes`, in which case tracked missing files
are moved to cloud trash after the baseline check.

### Cloud to local (`rmsync pull`, `diff`, `accept`)

1. User runs `rmsync pull`.
2. The CLI lists the configured cloud folder, downloads current cloud docs into a
   staging directory under the rmsync state dir, decodes `.rmdoc`
   pages into Markdown, and writes a manifest.
3. The manifest classifies each entry as `added`, `modified`,
   `deleted`, `conflict`, `local_modified`, `unchanged`, or `error`
   by comparing staged cloud content, local content, and the stored
   baseline.
4. User reviews with `rmsync diff`.
5. User applies selected changes with `rmsync accept <path>` or all
   non-delete changes with `rmsync accept --all`.
6. Staged cloud deletes require
   `rmsync accept --include-deletes <path>` and move local files into
   `.rmsync-trash` before removing state.

`rmsync pull` never changes local files directly.

### Force push

`rmsync force-push` first stages the current cloud tree, then prints a
plan comparing cloud paths to the local Markdown tree:
`create_remote`, `overwrite_remote`, `delete_remote`, `unchanged`, or
`error`. `rmsync force-push --apply` applies that local-tree plan,
including remote-only deletes. It refuses any remote doc that failed
to stage, because the staged snapshot is the recovery point.

### Git-backed sync (`rmsync git`)

This mode is optional and only makes sense inside an existing git
repository. It uses a separate reMarkable cloud folder under
`/sync/git/<name>` and stores repo-local metadata under `.git/rmsync-git/`.
The old explicit sync flow remains available and continues to use the
configured `remote_folder`.

1. User runs `rmsync git init --name <name>`.
   - Fails if `/sync/git/<name>` already exists or overlaps the ordinary sync folder.
   - Creates `.git/rmsync-git/config.json`.
   - Records the empty initial cloud snapshot in
     `refs/rmsync-git/<name>/cloud`.
2. User runs `rmsync git pull`.
   - Renders current cloud state into a git commit.
   - Creates a random branch like
     `rmsync/cloud/<name>/20260603T041500Z-a1b2c3d4`.
   - The user merges, rebases, diffs, or cherry-picks with normal git
     tools.
3. User runs `rmsync git push`.
   - Requires a clean worktree by default.
   - Renders current cloud state, then runs a git three-way merge with
     `refs/rmsync-git/<name>/cloud` as the base, local `HEAD` as local,
     and current cloud as remote.
   - If git reports conflicts, no cloud documents are changed. The user
     resolves via git and retries.
   - If the merge is clean, rmsync materializes the resolved git tree,
     uploads through the explicit force-push planner, verifies the cloud
     matches, then advances `refs/rmsync-git/<name>/cloud`.

`rmsync-git` is a wrapper for `rmsync git`; both command shapes are
equivalent.

### Conflict handling

A staged `conflict` means both local and cloud content differ from the
stored baseline, or a cloud doc collides with a different tracked local
path. `rmsync accept` refuses conflicts unless `--force` is passed.
The conflict listing command reports unresolved `.md.conflict` files
from older flows and clears stale state when markers are removed.

---

## Configuration

`~/.config/rmsync/config.toml`. Edit, then `rmsync restart` — the
daemon does not watch the file.

| Key | Default | Effect |
|---|---|---|
| `sync_dir` | `~/rmsync-notes` | Where local `.md` files live. **Change with `rmsync relocate`, not by hand.** |
| `remote_folder` | `sync/notes` | Cloud folder to mirror. `/Writing` is legacy-compatible for existing configs. |
| `worker_pool_size` | `3` | Legacy daemon worker setting; explicit CLI sync does not use background workers |
| `poll_interval_seconds` | `30` | Legacy poll cadence; automatic polling is disabled |
| `poll_active_interval_seconds` | `15` | Legacy active poll cadence |
| `poll_idle_interval_seconds` | `120` | Legacy idle poll cadence |
| `debounce_seconds` | `2.0` | Legacy watcher debounce; automatic local watching is disabled |
| `echo_fence_seconds` | `5.0` | Legacy watcher echo-fence window |
| `retry_max_attempts` | `3` | Per-op retry budget |
| `push_strategy` | `native_plain` | Also: `native_formatted` (stub), `pdf` (stub) |
| `dry_run` | `false` | Log intent, don't touch cloud or disk |
| `[log].level` | `INFO` | `DEBUG`, `INFO`, `WARNING`, `ERROR` |
| `[inbox].local_dir` | unset | Legacy PDF/EPUB drop folder. Current explicit-sync daemon does not watch it. |
| `[inbox].remote_folder` | `Inbox` | Legacy cloud folder for PDF/EPUB sends. |
| `[inbox].delete_after_push` | `true` | Legacy inbox drain setting. |
| `[web].enabled` | `false` | Embedded HTTP dashboard. Token-authed. |
| `[web].bind_addr` | `127.0.0.1` | `0.0.0.0` to expose to LAN. |
| `[web].port` | `7878` | TCP port. |
| `[web].auth_token` | unset | Empty → daemon generates one in `$STATE_DIR/web-token`. |
| `[deletion].enable_propagation` | `true` | Legacy daemon switch. Deletes now require explicit `accept --include-deletes` or `push --include-deletes`. |
| `[deletion].trash_retention_days` | `30` | Retention used by `rmsync trash prune`; `0` keeps forever. |
| `[deletion].bulk_delete_threshold` | `0.5` | Legacy daemon bulk-delete brake threshold. |
| `[deletion].bulk_delete_window_seconds` | `30` | Legacy daemon bulk-delete brake window. |

### `relocate` vs editing `sync_dir`

Prefer `rmsync relocate` over editing `sync_dir` in `config.toml` by
hand. The state DB stores absolute `local_path` for every tracked doc;
editing the config alone leaves rows pointing at the old location, so
status, history, trash, and future explicit sync operations can reason
about the wrong files.

`rmsync relocate <new-path>`:
1. Stops the daemon.
2. Moves every file from old `sync_dir` to new.
3. Rewrites `local_path` for every row in `state.db`'s `documents`.
4. Updates `sync_dir` in `config.toml`.
5. Restarts the daemon.

All atomic. Pass `--force` to merge into a target that already has
`.md` files. Pass `--keep-stopped` to leave the agent down.

---

## Recipes

### Move sync folder to Dropbox

```sh
rmsync relocate ~/Library/CloudStorage/Dropbox/reMarkable
```

Or any path. If Dropbox has smart-sync on, set the folder to "Always
Keep on This Device". Explicit push refuses macOS dataless placeholders
and suspicious empty reads, but keeping the tree materialized avoids
workflow surprises.

### Set or clear paused status

```sh
rmsync pause
# ... do whatever ...
rmsync resume
```

Paused state survives daemon restarts. In explicit-sync mode there is
no background sync loop to pause, but the status flag is still shown by
the daemon and menu bar.

### Kick the daemon after a code change

```sh
cd ~/code/rmsync/swift
swift build -c release --product rmsync
rmsync restart
```

Menu bar is a separate target; if you changed it too:

```sh
swift build -c release --product rmsync-menubar
launchctl kickstart -k "gui/$(id -u)/com.user.rmsync.menubar"
```

Or just run `./install.sh` — it's idempotent.

### Delete a doc from the cloud

Delete propagation is explicit:

- Local delete -> cloud trash only after `rmsync push --include-deletes`.
- Tablet/cloud delete -> local trash only after `rmsync pull`,
  `rmsync diff`, and `rmsync accept --include-deletes <path>`.
- Recover local trash via `rmsync trash list` /
  `rmsync trash restore <rel-path>`. Cloud trash is recoverable via
  the reMarkable web UI within reMarkable's retention window.

The old propagation flag remains in config for compatibility:

```toml
[deletion]
enable_propagation = false
```

Current explicit-sync releases do not automatically act on that flag.

### Organize docs in folders

Subdirectories under `sync_dir` are reflected by explicit commands:

- Pushing `<sync_dir>/foo/note.md` creates or uses `/sync/notes/foo/`
  on the cloud and stores the doc at `/sync/notes/foo/note`.
- Cloud folder structure appears in the staged tree after
  `rmsync pull`; accepting selected staged files creates matching
  local directories.
- Empty-folder-only mirroring is legacy watcher/poller behavior and is
  not automatic in explicit-sync mode.

Hidden dirs (`.git`, `.obsidian`, dot-anything) are filtered.

### Revert a doc to an earlier version

Snapshot history is always on for tracked docs. Explicit pushes and
accepted pull overwrites park snapshots under
`<stateDir>/backups/<doc-id>/<utc-stamp>.{md,json}`.
Retention via `backup_snapshots_to_keep` (default 30).

```sh
rmsync history list ~/rmsync-notes/Chapter-3.md
# Newest first; columns: ts | cause (push|pull_overwrite) | words | delta | bytes

rmsync history diff ~/rmsync-notes/Chapter-3.md
# Unified diff vs most recent snapshot. --against <ts> to pick another.

rmsync history restore ~/rmsync-notes/Chapter-3.md \
    --to 2026-04-29T22:14:08Z
# Current -> trash; snapshot bytes written to local.
# Run `rmsync push <path>` after inspecting the restored content.
```

Storage is keyed on doc UUID, not local path, so `rmsync
relocate` doesn't orphan history. `history restore` is itself
recoverable via `rmsync trash restore` (the pre-restore content
is parked there).

### Change log level for debugging

Edit `config.toml`:

```toml
[log]
level = "DEBUG"
```

Then `rmsync restart`. Tail:

```sh
rmsync logs -f
```

### Resolve a conflict

```sh
rmsync conflicts
# shows e.g. /path/to/foo.md.conflict

$EDITOR /path/to/foo.md.conflict
# Delete the <<<<<<<, =======, >>>>>>> markers. Keep what you want.

mv /path/to/foo.md.conflict /path/to/foo.md
rmsync push foo.md
```

---

## Menu bar

Click the icon (top-right).

| Icon state | Meaning |
|---|---|
| ✓ | Synced, idle |
| tablet + ⟳ | Syncing |
| tablet + ⚠ | Unresolved conflicts |
| tablet + ⏸ | Paused |
| tablet + ✗ | Error or daemon down |

Menu items: Synced (N docs), Last pull/push (relative time), Open
Sync Folder, Show Conflicts (N) — hidden when 0, Pause/Resume, Manual
sync mode, Restart Daemon, Open Logs, Edit Config…, Quit Menu Bar.

"Quit Menu Bar" only stops the menu bar. The daemon/status IPC keeps
running.

---

## Troubleshooting

Run in this order. Stop at the first problem.

### 1. Is the daemon even running?

```sh
launchctl print "gui/$(id -u)/com.user.rmsync" | grep -E '(state|last exit)'
ps auxww | grep 'rmsync daemon' | grep -v grep
```

If `state = not running`:

```sh
rmsync start
```

If launchd keeps exit-code-looping it: check `~/Library/Logs/rmsync/stderr.log`.

### 2. Can the daemon reach the cloud?

```sh
rmapi account
```

Should print your email. If it prompts for a code, rmapi auth is gone
— redo it:

```sh
rmapi
# paste code from https://my.remarkable.com/device/desktop/connect
```

### 3. Does doctor pass?

```sh
rmsync doctor
```

10 checks:
1. rmapi on PATH
2. rmapi version (warn if old)
3. rmapi authenticated
4. configured cloud folder reachable
5. local `sync_dir` writable
6. state DB openable
7. launchd plist loaded
8. disk space >1GB
9. log dir writable
10. clock within 60s of NTP

Any ✗ → fix the check it names. Any ! → probably fine but surface to user.

### 4. Is it paused?

```sh
rmsync status
```

Look for `paused: true`. If yes:

```sh
rmsync resume
```

### 5. Do explicit sync commands work?

```sh
echo "content" > ~/rmsync-notes/test.md
rmsync push test.md
rmsync status
```

If push fails, read the refusal. Common causes are missing rmapi auth,
a changed cloud baseline, a dataless File Provider placeholder, or an
empty local read that would overwrite previously non-empty content.

### 6. Are tablet changes visible in staging?

```sh
rmsync pull
rmsync diff
```

If the tablet has obviously changed docs and nothing is staged, the
tablet probably has not synced them to the cloud yet. Swipe down from
the top on the tablet home screen, then run `rmsync pull` again.

### 7. Conflicts

```sh
rmsync conflicts
```

Walk the user through the "Resolve a conflict" recipe above. Don't
delete the `.md.conflict` file without preserving what the user
wants.

### 8. Fresh-install reset

When everything looks broken and bisection isn't finding it:

```sh
./uninstall.sh --purge
./install.sh
```

`--purge` wipes state + config + logs. Local `.md` files are not
touched. After reinstall, run `rmsync pull`, review with `rmsync diff`,
accept the staged cloud files you want, and run `rmsync push` for any
local Markdown files you want on the cloud.

---

## Inspecting state directly

```sh
# SQLite browser
sqlite3 "$HOME/Library/Application Support/rmsync/state.db"

.tables
# documents  jobs  settings  schema_version

# All tracked docs, most recently pushed first
SELECT doc_id, substr(local_path, -40) AS path,
       last_pull_at, last_push_at, error_state
FROM documents ORDER BY last_push_at DESC;

# Daemon-wide settings
SELECT * FROM settings;
# -> paused (bool), author_uuid (UUID)

# Schema version — 5 as of v0.2.19 (added `pending_op` column on
# documents to mark in-flight rename/delete operations across
# daemon restarts; older DBs migrate forward in place).
SELECT version FROM schema_version;

# Any rows currently mid-rename/delete (Reconcile resumes these
# at startup):
SELECT doc_id, local_path, remote_path, pending_op
FROM documents
WHERE pending_op IS NOT NULL;
```

### Xattrs

Every accepted pulled `.md` gets xattrs:

```sh
xattr -l ~/rmsync-notes/foo.md
# rmsync.doc_id               UUID of the cloud doc
# rmsync.remote_path          /sync/notes/foo
# rmsync.remote_modified      ISO8601 timestamp
# rmsync.page_ids             JSON array
# com.apple.metadata:kMDItemWhereFroms   Finder "Where from"
# _kMDItemUserTags             Finder color tag
```

Losing these (e.g. copying the file through a non-xattr-preserving
tool) removes Finder/Spotlight metadata and can make debugging harder.

---

## Rough edges (things that surprise people)

- **Deletes do not propagate automatically.** Local deletes require
  `rmsync push --include-deletes`; cloud deletes require `rmsync pull`
  plus `rmsync accept --include-deletes`.
- **Handwriting pages pull as empty.** Only typed text extracts. A
  notebook mixing typed text and handwriting keeps only typed text.
- **Never hand-invoke `rmapi put --content-only`.** That flag is
  PDF-only and will fail. The daemon uses `rmapi put --force`.
- **Prefer `rmsync relocate` over editing `sync_dir` in
  `config.toml`.** See the dedicated section.
- **Dropbox "conflicted copy" files are ignored.** Filename pattern
  `* (conflicted copy *).md` never gets pushed.
- **Dropbox smart-sync online-only files are refused by explicit push**
  when macOS reports them as dataless placeholders. Keep the sync
  folder set to "Always Keep on This Device" for a smoother workflow.
- **There is no automatic cloud poll.** Run `rmsync pull` when you
  want to review tablet/cloud changes.
- **Pulled formatting is lost on next push under `native_plain`.**
  Tablet gets literal `# Heading` text. Switch to `native_formatted`
  (experimental) if you need round-trip formatting.

---

## Architecture (brief)

```
┌──────────────┐   IPC socket   ┌─────────────────┐
│  menubar app │◄──────────────►│  rmsync daemon  │
└──────────────┘                │   (launchd)     │
                                │                 │
┌──────────────┐   IPC socket   │  status / IPC   │
│  rmsync CLI  │◄──────────────►│  dashboard      │
└──────────────┘                │  state.db       │
                                └─────────────────┘
        │ explicit pull / push via rmapi
        ▼
 reMarkable cloud ◄──────────────► sync_dir/*.md
```

Swift 6 strict concurrency. The daemon is status-only in explicit
sync mode; `ExplicitSync.swift` owns staged pull / accept / push.
`GitSync.swift` owns the optional repository-local `rmsync git`
workflow and shells out to git only when those commands are invoked.
Three SPM targets: `rmsync` (executable), `rmsync-menubar`
(executable), `RMScene` (library, Swift port of the v6 CRDT codec from
[ricklupton/rmscene](https://github.com/ricklupton/rmscene), MIT).

---

## Six invariants (for deep debugging only)

If the user is seeing wildly broken cloud-side behavior — ghost
pages, interleaved character-by-character text, blank cover pages —
one of these is being violated. They should never hit this.

1. **Page UUIDs are reused across pushes of the same doc.** Tracked
   in `state.db`'s `page_ids` JSON column on `documents`. If a push
   generates fresh `page_id`s, the CRDT grows a ghost entry per push.
2. **`author_uuid` is stable across this install.** One UUID per
   install, stored in `settings` table. Different UUIDs cause the
   tablet's CRDT engine to interleave text at the character level.
3. **`coverPageNumber` in `.content` is `-1`, not `0`.** `0` makes
   the tablet prepend a blank cover.
4. **`.content` is packed in sync15 `cPages` shape**, not legacy
   flat `pages: [id, ...]`. Legacy shape triggers a blank-template
   page insertion on first tablet sync.
5. **`rmapi put --force` for updates, plain `rmapi put` for new
   docs.** `--force` on a non-existent doc fails; plain `put` on an
   existing one errors with `entry already exists`.
6. **Local data-loss guards remain active on explicit push.** Dataless
   File Provider placeholders and suspicious empty reads must be
   refused before packing and uploading.

---

## FAQ

**Q: Do I need a reMarkable Connect subscription?**
No. Free tier works. Cloud sync is all we use.

**Q: Does this work with reMarkable 2 and Paper Pro?**
Yes. Both use v6 `.rm` format.

**Q: Will it sync PDFs or drawings?**
No. Only typed-text notebooks. PDFs and drawings stay tablet-side.

**Q: Can I edit a doc on both Mac and tablet at the same time?**
Yes, but review it explicitly. `rmsync pull` classifies the staged
entry as a conflict when both sides differ from the stored baseline;
`rmsync accept` refuses it unless you pass `--force`.

**Q: Does this work offline?**
The daemon keeps running for status, but explicit commands that need
the cloud fail until the network/rmapi access returns. Re-run
`rmsync pull` or `rmsync push` once online.

**Q: How do I back up my notes?**
The `.md` files in `sync_dir` are the backup. Accepted deletes park
local files under `.rmsync-trash/`, and snapshot history lives under
the state dir for tracked docs.

**Q: What happens when I uninstall?**
`./uninstall.sh` removes the launchd agents only. Your `.md` files,
config, state, and logs stay. `./uninstall.sh --purge` also removes
config, state, and logs. `.md` files are never touched.

**Q: Why Swift, not Python?**
v0.1 was Python. v0.2 ported to Swift for: (a) no runtime
dependency, (b) in-process v6 codec instead of Python subprocess
bridge, (c) native launchd integration, (d) single-binary distribution.
Python archive is at `python-legacy.tar.gz` in the repo root.

**Q: Where do I report bugs?**
GitHub issues on the repo the user cloned from. Include:
- `rmsync status` output
- `rmsync doctor` output
- Last 50 lines of `~/Library/Logs/rmsync/stderr.log`
- Whether it's push, pull, or both that's failing

---

## What this doc does NOT cover

- Internal code organization beyond the three targets.
- The v6 `.rm` CRDT format details (see ricklupton/rmscene upstream).
- Port history (see `docs/SWIFT_PORT_PHASE1.md`).
- Deviations from the original Python spec (see
  `CHANGES_FROM_SPEC.md`).

These live in separate docs in the repo. If the user asks about them,
point at those files — don't invent answers.
