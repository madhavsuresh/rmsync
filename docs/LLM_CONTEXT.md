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

A bidirectional sync daemon between a reMarkable tablet's
`Writing/` cloud folder and a local Markdown tree. Runs on macOS
(via launchd, with a menubar app) and on Linux (via Docker, headless).

- **Local → tablet:** you save a `.md` file; within ~5 seconds it
  gets packed into a reMarkable v6 `.rmdoc` archive and pushed to the
  cloud via `rmapi`.
- **Tablet → local:** you type on the tablet; the daemon polls the
  cloud every 15–120s, notices the `ModifiedClient` timestamp moved,
  pulls the `.rmdoc`, decodes the v6 `.rm` pages with an in-process
  Swift port of `rmscene`, and writes Markdown locally (atomic
  rename).

No handwriting OCR. Pen strokes come through as empty markdown. Only
typed-text notebooks round-trip.

The daemon is a Swift 6 binary, identical core code on both
platforms. Platform differences are confined to:

- **macOS:** FSEventStream watcher; launchd-managed daemon (label
  `com.user.rmsync`); menubar app (label `com.user.rmsync.menubar`);
  Spotlight metadata + Finder folder icon on pulled files.
- **Linux:** inotify watcher; Docker-supervised daemon (no
  launchd / systemd interaction); no menubar; no Finder/Spotlight
  integration. Same daemon binary just behind `#if os(Linux)` guards.

Both platforms talk to the daemon over a Unix-domain socket
(`ipc.sock` under the state dir). CLI commands (`rmsync status`,
`sync-now`, `pause`, `doctor`, etc.) work identically.

---

## Canonical file locations

Use these exact paths when helping the user. macOS first; Linux
(Docker) second.

### macOS

```
# binaries
~/.local/bin/rmsync                                 # CLI symlink → swift/.build/release/rmsync
~/code/rmsync/swift/.build/release/rmsync               # daemon + CLI binary
~/code/rmsync/swift/.build/release/rmsync-menubar      # menu bar app

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
~/Library/Logs/rmsync/stdout.log                   # structured JSON, one event per line
~/Library/Logs/rmsync/stderr.log
~/Library/Logs/rmsync/menubar.log

# rmapi (separate tool the daemon shells out to)
~/.config/rmapi/rmapi.conf                          # cloud auth

# default sync dir (user may have moved it)
~/rmsync-writing/
~/rmsync-writing/.rmsync-trash/                     # soft-delete buffer (v0.2.19+)
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

The brew formula declares `io41/tap/rmapi` as a dependency, so rmapi
is installed transitively. The post-install helper
`rmsync-install-agents` writes a default `~/.config/rmsync/config.toml`,
mkdir's `~/rmsync-writing`, renders both launchd plists with
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

Linux uses inotify instead of FSEventStream. Same daemon code path
otherwise. File watcher needs `fs.inotify.max_user_watches` ≥ tree
size on the host (default 8192; large trees need
`sudo sysctl fs.inotify.max_user_watches=524288`).

### Either way: rmapi auth is required

If `rmapi` isn't authenticated, the daemon runs but every sync
operation fails. `rmsync doctor`'s "rmapi authenticated" check catches
this. The brew install path doesn't run an interactive auth flow —
the user must invoke `rmapi` themselves and paste the code. Same
on Docker (`docker exec -it rmsync rmapi`).

---

## Commands

11 subcommands. All are idempotent.

| Command | Talks to | What it does | Linux/Docker |
|---|---|---|---|
| `rmsync status` | IPC | Live state: tracked docs, last pull/push, conflicts, queue | ✓ |
| `rmsync pause` | IPC | Sets paused flag. Survives daemon restart. | ✓ |
| `rmsync resume` | IPC | Clears paused flag. | ✓ |
| `rmsync sync-now` | IPC | Forces immediate poll. | ✓ |
| `rmsync conflicts` | state DB | Lists unresolved `.md.conflict` files. | ✓ |
| `rmsync doctor` | direct | Runs 10 health checks; exits 1 on any ✗. | ✓ |
| `rmsync logs -f` | file tail | Tails `stdout.log`. Ctrl+C to stop. | use `docker logs -f rmsync` |
| `rmsync start` | launchctl | Bootstraps the agent. | ✗ — `docker compose up -d` |
| `rmsync stop` | launchctl | Boots out the agent. | ✗ — `docker compose stop rmsync` |
| `rmsync restart` | launchctl | `kickstart -k`. Use after config edits or rebuilds. | ✗ — `docker compose restart rmsync` |
| `rmsync relocate <path>` | composite | Move sync dir + rewrite state + update config + restart. | ✗ — edit `/config/config.toml` and `docker compose restart` |
| `rmsync uninstall` | script | Remove launchd agent. Keeps config/state. `--purge` wipes all. | ✗ — `docker compose down` |
| `rmsync trash list` | filesystem | List soft-deleted files under `<sync_dir>/.rmsync-trash/`. | ✓ |
| `rmsync trash restore <rel>` | filesystem | Move a trashed file back; daemon re-pushes on next watcher tick. `--all` for bulk. | ✓ |
| `rmsync trash prune` | filesystem | Drop trash entries past `trash_retention_days`. Auto-runs at daemon startup. | ✓ |
| `rmsync history list <path>` | state DB + filesystem | Per-doc snapshot history (newest first). Each save / pull-overwrite is captured. | ✓ |
| `rmsync history diff <path> [--against <ts>]` | filesystem | Unified `diff -u` vs a snapshot (default: most recent). | ✓ |
| `rmsync history restore <path> --to <ts>` | filesystem + IPC | Revert to a snapshot; current → trash; daemon pushes immediately via `push_path` IPC. | ✓ |

Internal-only subcommands: `daemon` (invoked by launchd), `init`
(legacy pointer to `install.sh`).

When the daemon is stopped, `rmsync status` falls back to reading
`state.db` directly — it'll report `daemon: not running` but still
show tracked docs.

---

## How the sync cycle actually works

### Local → cloud (push path)

1. User writes `~/sync-dir/foo.md`.
2. `FSEventStream` fires within ~100ms.
3. Watcher debounces for **2s** (coalesces rapid saves from editors
   like VSCode or Obsidian).
4. Watcher enqueues a push job in the GRDB job queue.
5. A worker (pool size 3) picks it up:
   - Hashes the file. If hash matches `last_synced_md_hash`, skip.
   - Packs Markdown into a v6 `.rmdoc` archive:
     - Splits on `<!-- rmsync:page-break -->` for multi-page.
     - Each page rendered by in-process `PageCodec.renderPage()` with
       a stable `author_uuid`.
     - Packs as sync15 `cPages` shape with reused `page_ids` from
       `state.db`.
   - Shells `rmapi put --force <file>.rmdoc /Writing` to replace
     in-place (stable doc_id).
   - Updates `last_push_at`, `last_synced_md_hash`, `page_ids`.
6. Seeds the echo fence with the file's new mtime so the next
   `FSEventStream` event for our own write gets dropped.

Typical latency: **~5s** local save to cloud.

### Cloud → local (pull path)

1. Poller wakes on an adaptive interval:
   - **15s** if something changed in the last 5 minutes
   - **30s** default
   - **120s** when idle for 20+ minutes
2. Runs `rmapi find /Writing` and `rmapi stat` per entry.
3. For each doc: compare `ModifiedClient` timestamp to the one in
   `state.db`. If newer, enqueue a pull job.
4. Worker:
   - `rmapi get <doc>` → `.rmdoc` → unpack.
   - For each page, `PageCodec.parsePage()` → Markdown.
   - Join pages with `<!-- rmsync:page-break -->`.
   - `atomic_write` to local (`.tmp` then `rename`).
   - Tag with xattrs (`rmsync.doc_id`, `rmsync.page_ids`, Finder
     where-from).
   - Update `last_pull_at`, `last_synced_md_hash`.

Typical latency for a first change after idle: **up to 2 minutes**.
During active editing: **~15s**. `rmsync sync-now` kicks the poller
immediately.

### Conflict detection

A conflict exists when BOTH sides changed since the last sync:

```
L = sha256(local_file)          != last_synced_md_hash
R = doc.ModifiedClient           > last_remote_modified
L && R                           → conflict
```

Resolution: the daemon writes `<stem>.md.conflict` with git-style
markers:

```
<<<<<<< local
<your local content>
=======
<tablet content>
>>>>>>> remote
```

Neither side wins automatically. User edits `.md.conflict`, renames
it to `.md`, saves. Daemon picks up the edit and pushes as normal.

`rmsync conflicts` lists unresolved ones.

---

## Configuration

`~/.config/rmsync/config.toml`. Edit, then `rmsync restart` — the
daemon does not watch the file.

| Key | Default | Effect |
|---|---|---|
| `sync_dir` | `~/rmsync-writing` | Where local `.md` files live. **Change with `rmsync relocate`, not by hand.** |
| `remote_folder` | `Writing` | Cloud folder to mirror |
| `worker_pool_size` | `3` | Concurrent pull/push workers |
| `poll_interval_seconds` | `30` | Default poll cadence |
| `poll_active_interval_seconds` | `15` | After recent activity |
| `poll_idle_interval_seconds` | `120` | After 20+ min quiet |
| `debounce_seconds` | `2.0` | Local edit → push delay |
| `echo_fence_seconds` | `5.0` | Window to drop watcher events we caused |
| `retry_max_attempts` | `3` | Per-op retry budget |
| `push_strategy` | `native_plain` | Also: `native_formatted` (stub), `pdf` (stub) |
| `dry_run` | `false` | Log intent, don't touch cloud or disk |
| `[log].level` | `INFO` | `DEBUG`, `INFO`, `WARNING`, `ERROR` |
| `[inbox].local_dir` | unset | PDF/EPUB drop folder. Files pushed to cloud + (by default) removed locally. Block absent → feature off. |
| `[inbox].remote_folder` | `Inbox` | Cloud folder for pushed PDFs/EPUBs. |
| `[inbox].delete_after_push` | `true` | Drain the local inbox after successful push. |
| `[web].enabled` | `false` | Embedded HTTP dashboard. Token-authed. |
| `[web].bind_addr` | `127.0.0.1` | `0.0.0.0` to expose to LAN. |
| `[web].port` | `7878` | TCP port. |
| `[web].auth_token` | unset | Empty → daemon generates one in `$STATE_DIR/web-token`. |
| `[deletion].enable_propagation` | `true` | Master switch for rename/delete propagation. Default flipped on in v0.2.27 (was false in v0.2.19–v0.2.26). |
| `[deletion].trash_retention_days` | `30` | Reaped at daemon startup. `0` keeps forever. |
| `[deletion].bulk_delete_threshold` | `0.5` | Refuse if `> N%` of tracked docs would be deleted in window. |
| `[deletion].bulk_delete_window_seconds` | `30` | Rolling window for the brake. |

### `relocate` vs editing `sync_dir`

**Never edit `sync_dir` in `config.toml` by hand.** The state DB
stores absolute `local_path` for every tracked doc; editing the
config leaves every row pointing at a missing location and the daemon
reads that as "user deleted everything."

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
Keep on This Device" — the watcher doesn't know how to handle online-
only placeholders and will push empty files.

### Pause syncing while you edit a bunch of files

```sh
rmsync pause
# ... do whatever ...
rmsync resume
```

Paused state survives daemon restarts. Menu bar shows ⏸.

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

**Default since v0.2.27** — local delete and tablet-side delete
propagate automatically:

- `rm <sync_dir>/foo.md` → local file moves to
  `<sync_dir>/.rmsync-trash/<utc-stamp>/foo.md` and the cloud
  doc moves to the reMarkable cloud's trash via `rmapi rm`.
- Deleting `Writing/foo` on the tablet → next cloud poll moves
  the local file into `.rmsync-trash/`.
- Recover either side via `rmsync trash list` /
  `rmsync trash restore <rel-path>`. Cloud trash recoverable
  via the reMarkable web UI within reMarkable's retention
  window.

A bulk-delete brake refuses operations exceeding
`[deletion].bulk_delete_threshold` (default 0.5) of tracked
docs in `[deletion].bulk_delete_window_seconds` (default 30s) —
caps the blast radius of an accidental `rm -rf`.

**To opt out** (v0.2.18-style: local delete logs but doesn't
propagate), set:

```toml
[deletion]
enable_propagation = false
```

In that mode, manually delete from cloud via `rmapi rm /Writing/foo`.

### Organize docs in folders

Subdirectories under `sync_dir` propagate as cloud folders, in
both directions (v0.2.22+):

- `mkdir <sync_dir>/foo/` → cloud `mkdir /Writing/foo/`.
  Always-on; non-destructive.
- Save `<sync_dir>/foo/note.md` → doc lands at
  `/Writing/foo/note` on the cloud (NEW files derive
  `remoteParent` from local path; previously flattened).
- Tablet-side `mkdir foo/` → next cloud poll cycle creates
  empty `<sync_dir>/foo/` locally.
- `rmdir <sync_dir>/foo/` (when empty) → cloud rmdir.
  Gated on `[deletion] enable_propagation = true` AND
  cloud-side empty check (so a half-cascaded delete burst
  can't trash docs).
- Tablet-side rmdir → next poll cycle removes the local empty
  dir. Same propagation + empty checks.

Hidden dirs (`.git`, `.obsidian`, dot-anything) are filtered.

### Revert a doc to an earlier version

Snapshot history is always on (v0.2.20+). The daemon parks
a copy of every tracked `.md` at every push (about-to-go-up
bytes) and every cloud-pull-overwrite (about-to-be-clobbered
bytes) under `<stateDir>/backups/<doc-id>/<utc-stamp>.{md,json}`.
Retention via `backup_snapshots_to_keep` (default 30).

```sh
rmsync history list ~/rmsync-writing/Chapter-3.md
# Newest first; columns: ts | cause (push|pull_overwrite) | words | delta | bytes

rmsync history diff ~/rmsync-writing/Chapter-3.md
# Unified diff vs most recent snapshot. --against <ts> to pick another.

rmsync history restore ~/rmsync-writing/Chapter-3.md \
    --to 2026-04-29T22:14:08Z
# Current → trash; snapshot bytes written to local; daemon pushes
# immediately via the push_path IPC verb.
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
# Daemon picks this up, pushes normally.
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
Sync Folder, Show Conflicts (N) — hidden when 0, Pause/Resume, Sync
Now, Restart Daemon, Open Logs, Edit Config…, Quit Menu Bar.

"Quit Menu Bar" only stops the menu bar. The daemon keeps syncing.

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
4. remote `Writing/` folder reachable
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

### 5. Is the watcher seeing your saves?

```sh
rmsync logs -f
# in another shell, touch a file:
touch ~/rmsync-writing/test.md
echo "content" > ~/rmsync-writing/test.md
```

You should see a `local_change` event within 2s. If not, FSEvents is
wedged — `rmsync restart`.

### 6. Is the poller seeing tablet changes?

```sh
rmsync sync-now
rmsync logs -f | grep -E '(poll_start|remote_change|pull)'
```

If the tablet has obviously-changed docs and nothing shows up, the
tablet probably hasn't synced them to the cloud yet. Swipe down from
the top on the tablet home screen.

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
touched. After reinstall, the first sync pulls the full remote
`Writing/` tree and re-tracks existing local files by content hash.

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

Every pulled `.md` has xattrs:

```sh
xattr -l ~/rmsync-writing/foo.md
# rmsync.doc_id               UUID of the cloud doc
# rmsync.remote_path          /Writing/foo
# rmsync.remote_modified      ISO8601 timestamp
# rmsync.page_ids             JSON array
# com.apple.metadata:kMDItemWhereFroms   Finder "Where from"
# _kMDItemUserTags             Finder color tag
```

Losing these (e.g. copying the file through a non-xattr-preserving
tool) makes the daemon re-track it as a new doc on next edit.

---

## Rough edges (things that surprise people)

- **Local delete propagates by default** (v0.2.27+) — `rm`
  parks the file in `<sync_dir>/.rmsync-trash/` AND cloud-trashes
  the doc. Soft-delete + bulk-delete brake (50%-in-30s) make
  this safe. To opt out: `[deletion] enable_propagation = false`.
  v0.2.19–v0.2.26 had this opt-in; v0.2.27 flipped the default
  after enough field-test cycles.
- **Handwriting pages pull as empty.** Only typed text extracts. A
  notebook mixing typed text and handwriting keeps only typed text.
- **Never hand-invoke `rmapi put --content-only`.** That flag is
  PDF-only and will fail. The daemon uses `rmapi put --force`.
- **Never edit `sync_dir` in `config.toml`.** Use `rmsync relocate`.
  See the dedicated section.
- **Dropbox "conflicted copy" files are ignored.** Filename pattern
  `* (conflicted copy *).md` never gets pushed.
- **Dropbox smart-sync online-only files push as 0 bytes.** Keep the
  sync folder set to "Always Keep on This Device."
- **First poll after idle can take 2 minutes.** Adaptive interval.
  `rmsync sync-now` for immediate.
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
┌──────────────┐   IPC socket   │  workers × 3    │       rmapi
│  rmsync CLI  │◄──────────────►│  poller         │──────────────► reMarkable
└──────────────┘                │  watcher        │                cloud
                                │  state.db       │
                                └─────────────────┘
                                       ▲
                                       │ FSEvents
                                       │
                                 ┌─────┴──────┐
                                 │ sync_dir/  │
                                 │   *.md     │
                                 └────────────┘
```

Swift 6 strict concurrency. Actors for IPC, GRDB write queue. Three
SPM targets: `rmsync` (executable), `rmsync-menubar` (executable),
`RMScene` (library, Swift port of the v6 CRDT codec from
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
6. **Atomic write + echo fence seeded before watcher sees the mtime
   bump.** Missing this causes every local write to trigger a spurious
   push.

---

## FAQ

**Q: Do I need a reMarkable Connect subscription?**
No. Free tier works. Cloud sync is all we use.

**Q: Does this work with reMarkable 2 and Paper Pro?**
Yes. Both use v6 `.rm` format.

**Q: Will it sync PDFs or drawings?**
No. Only typed-text notebooks. PDFs and drawings stay tablet-side.

**Q: Can I edit a doc on both Mac and tablet at the same time?**
Yes. The daemon will detect the double-edit and write a `.md.conflict`
file. See "Resolve a conflict."

**Q: Does this work offline?**
The daemon keeps running and queuing. When the network returns,
pushes/pulls drain. `rmapi` itself handles the cloud connection.

**Q: How do I back up my notes?**
The `.md` files in `sync_dir` are the backup. The daemon also
preserves them under `.rmsync-trash/` on tablet-side deletion (the
folder is ignored by the watcher).

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
- Last 50 lines of `~/Library/Logs/rmsync/stdout.log`
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
