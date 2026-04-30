# Using rmsync

Everything you need to operate the daemon day-to-day. Read top to bottom
the first time; skip to whichever section matters after that.

---

## What's installed right now

Two launchd agents, both running under your user (no root, no login password):

| Label | What it is | Program |
|---|---|---|
| `com.user.rmsync` | The sync daemon | `~/.local/bin/rmsync daemon` |
| `com.user.rmsync.menubar` | The menu bar app | `~/code/rmsync/swift/.build/release/rmsync-menubar` |

Their plists live at:

```
~/Library/LaunchAgents/com.user.rmsync.plist
~/Library/LaunchAgents/com.user.rmsync.menubar.plist
```

The CLI binary is on your PATH as `rmsync` (symlinked from
`~/.local/bin/rmsync` to the release build under the repo).

Everything else the daemon needs:

```
~/.config/rmsync/config.toml                           # config
~/Library/Application Support/rmsync/state.db          # SQLite state
~/Library/Application Support/rmsync/ipc.sock          # live IPC socket
~/Library/Application Support/rmsync/status.json       # slow-cadence snapshot
~/Library/Logs/rmsync/stdout.log                       # structured daemon log
~/Library/Logs/rmsync/menubar.log                      # menu bar log
~/Library/CloudStorage/Dropbox/reMarkable/              # your sync dir (Dropbox today)
```

The agents start automatically at login and restart on crash.

### One prerequisite: rmapi must be authenticated

The daemon shells out to `rmapi` for all cloud access, so `rmapi`
itself needs a reMarkable cloud session stored in
`~/.config/rmapi/rmapi.conf`. You only do this once per Mac. If
`install.sh` didn't walk you through it already:

```sh
rmapi
# Opens an interactive prompt. In a browser, go to
#   https://my.remarkable.com/device/desktop/connect
# sign in, copy the 8-character code, and paste it into the rmapi prompt.
```

Verify:

```sh
rmapi account
# Should print your email. If it prompts for a code, auth hasn't stuck.
```

Without this, the daemon will run but `rmsync doctor` fails on the
"rmapi authenticated" check and nothing syncs.

---

## Daily commands

All 10 subcommands. Run any of them from anywhere.

| Command | What it does | Mechanism |
|---|---|---|
| `rmsync status` | Current state, tracked docs, last pull/push, conflicts, errors | Live IPC |
| `rmsync pause` | Stop syncing without stopping the daemon | IPC → state DB |
| `rmsync resume` | Resume | IPC → state DB |
| `rmsync sync-now` | Force an immediate poll cycle | IPC |
| `rmsync conflicts` | List unresolved `.md.conflict` files | State DB |
| `rmsync doctor` | Run all 10 health checks, exit 1 on failure | Direct |
| `rmsync logs -f` | Tail the structured JSON log | File tail |
| `rmsync start` | Boot the launchd agent (idempotent) | `launchctl bootstrap` |
| `rmsync stop` | Stop the launchd agent (idempotent) | `launchctl bootout` |
| `rmsync restart` | Replace the running instance | `launchctl kickstart -k` |
| `rmsync relocate <path>` | Move sync dir + rewrite state + update config + restart agent | Composite |
| `rmsync uninstall` | Remove the launchd agent (leaves state + config) | Delegates to script |

`daemon` and `init` also exist but you don't run them by hand — `daemon`
is what launchd invokes; `init` just prints a pointer to `install.sh`.

Everything that changes daemon state (`pause`, `resume`, `sync-now`)
goes through the Unix-socket IPC. Everything that controls the agent
lifecycle (`start`, `stop`, `restart`, `relocate`) talks to `launchctl`.

---

## How do I…

### …edit a Markdown file on my Mac and see it on the tablet

Just edit it.

```sh
echo "new line" >> ~/Library/CloudStorage/Dropbox/reMarkable/hello.md
```

What happens:

1. FSEventStream fires within ~100ms.
2. Watcher debounces 2s (coalesces rapid editor saves).
3. Worker packs the file, shells `rmapi put --force` to the cloud.
4. Sync appears on the tablet the next time you sync it (swipe-down
   from the top on the home screen) or within its own auto-sync window.

End-to-end ~5s from save to cloud, plus however long the tablet takes
to pull.

`rmsync status` will show `last push:` updated and `tracked docs:`
incremented if it was a new file.

### …write on the tablet and have it appear as Markdown locally

Write on the tablet. When the tablet syncs back to the cloud (auto on
modern firmware), our poller sees it.

Poll intervals adapt based on recent activity:
- **15s** when something changed in the last 5 minutes
- **30s** default
- **120s** when idle for 20+ minutes

So the first change after a quiet stretch can take up to 2 minutes to
show up locally. Once you start editing, subsequent changes are 15s.

If you don't want to wait:

```sh
rmsync sync-now
```

Which kicks the poller immediately.

### …move the sync dir to Dropbox (or anywhere else)

One command handles everything — stops the agent, moves the files,
rewrites `state.db`'s `local_path` column for every tracked doc,
updates `sync_dir` in `config.toml`, restarts the agent:

```sh
rmsync relocate ~/Dropbox/reMarkable
```

Pass `--force` if the target already has `.md` files and you want to
merge. Pass `--keep-stopped` to leave the agent down for manual
follow-up work.

You're currently on Dropbox's CloudStorage-mounted folder:
`~/Library/CloudStorage/Dropbox/reMarkable/`. If you move back to
local:

```sh
rmsync relocate ~/rmsync-writing
```

#### `relocate` vs editing `sync_dir` in config.toml

Both exist because they do different things. Use the right one:

| You want to… | Use | Why |
|---|---|---|
| Change where synced `.md` files live on disk | **`rmsync relocate <path>`** | Moves the existing files, updates the state DB, edits the config, restarts the daemon. All atomic. |
| Change any other config key | Edit `config.toml` + `rmsync restart` | No other field has this much stuff depending on it. |

**`config.toml` is the source of truth.** The daemon reads `sync_dir`
from it at startup. What `relocate` does is update that value along
with the two things that would break if you changed it alone:

1. The `.md` files themselves — they have to physically move.
2. The state DB — every row stores an absolute `local_path`. Without
   rewriting those, the daemon would think every tracked doc was
   deleted from disk the next time it starts up.

If you edit `sync_dir` in `config.toml` by hand and restart:

- The daemon comes up looking at the new path.
- That directory is probably empty (you didn't move the files).
- Startup reconcile sees every tracked doc's `local_path` pointing at
  the old location and reads them as "missing from disk."
- That fires the "local file missing on startup" handler, which tries
  to propagate deletions to the cloud.

**Don't edit `sync_dir` in `config.toml` manually.** Always use
`rmsync relocate`.

After `relocate` completes you can cat the config to verify:

```sh
$ grep sync_dir ~/.config/rmsync/config.toml
sync_dir      = "/Users/you/Dropbox/reMarkable"
```

The change is persistent — it survives daemon restarts, launchd
reboots, machine reboots. Just like any other config edit, except you
didn't have to do it yourself.

### …pause the daemon without uninstalling it

```sh
rmsync pause
# … daemon is now idle. tablet changes still queued up but not pulled; …
# … local edits still not pushed …
rmsync resume
```

The paused state persists across daemon restarts (stored in
`state.db`'s `settings` table). Menu bar icon shows ⏸ while paused.

### …resolve a conflict

A conflict means both sides changed the same doc between syncs. The
daemon never silently picks a winner. Instead it writes a
`<stem>.md.conflict` file with git-style markers:

```
<<<<<<< local
your local edits
=======
what came back from the tablet
>>>>>>> remote
```

The original `.md` is left untouched (the version from before the
conflict was detected). Nothing pushes until you resolve.

List unresolved ones:

```sh
rmsync conflicts
```

Resolve:

```sh
$EDITOR ~/sync-dir/foo.md.conflict
# edit: delete the <<<<<<<, =======, >>>>>>> lines, keep the content
# you want. you can mix from both sides.

mv ~/sync-dir/foo.md.conflict ~/sync-dir/foo.md
# overwrites the stale .md with your merged version. the daemon picks
# this up as a normal local edit and pushes.
```

After the push, both sides are in sync again and `rmsync conflicts`
returns empty.

### …change config and have it take effect

Edit the TOML file:

```sh
$EDITOR ~/.config/rmsync/config.toml
```

**The daemon does not watch config.toml** — it reads the file once at
startup and holds the values for the life of the process. Restart for
edits to take effect:

```sh
rmsync restart
```

The default config's header comment reminds you of this.

> **Exception:** don't edit `sync_dir` directly. Use `rmsync relocate`
> — it updates the config *and* the three other things that depend on
> it in sync. See the previous section for the reasoning.

Config keys and defaults (all paths relative to your home):

| Key | Default | Effect |
|---|---|---|
| `sync_dir` | `~/rmsync-writing` | Where local `.md` files live. **Change with `rmsync relocate`, not here** — see above. |
| `remote_folder` | `Writing` | Which cloud folder to mirror |
| `worker_pool_size` | `3` | Parallel pull/push workers |
| `poll_interval_seconds` | `30` | Default poll cadence |
| `poll_active_interval_seconds` | `15` | After recent activity |
| `poll_idle_interval_seconds` | `120` | After 20+ min quiet |
| `debounce_seconds` | `2.0` | Local edit → push delay |
| `echo_fence_seconds` | `5.0` | Drop watcher events we caused |
| `retry_max_attempts` | `3` | Per-operation retry budget |
| `push_strategy` | `native_plain` | Also: `native_formatted` (stub), `pdf` (stub) |
| `dry_run` | `false` | Log intent, don't execute |
| `[log].level` | `INFO` | `DEBUG` / `INFO` / `WARNING` / `ERROR` |
| `[deletion].enable_propagation` | `true` | Master switch for rename/delete propagation. Default flipped on in v0.2.27 (was opt-in in v0.2.19–v0.2.26). Set false to disable. |
| `[deletion].trash_retention_days` | `30` | Auto-prune cadence (`0` = keep forever). |
| `[deletion].bulk_delete_threshold` | `0.5` | Refuse if `>N` of tracked docs would be deleted in window. |
| `[deletion].bulk_delete_window_seconds` | `30` | Rolling window for the bulk-delete brake. |

### …recover a file I deleted by mistake

If `[deletion] enable_propagation = true` is set, every local
delete (and tablet-side delete) parks the file under
`<sync_dir>/.rmsync-trash/<utc-stamp>/<rel-path>` before doing
anything irreversible. To inspect and recover:

```sh
rmsync trash list                       # everything currently parked
rmsync trash restore "old/note.md"      # one-file restore
rmsync trash restore --all              # bulk restore
```

Restored files reappear at their original location; the daemon's
watcher sees them on its next tick and re-pushes to the cloud as
if newly created.

The reMarkable cloud also keeps its own trash for cloud-side
deletes, recoverable via the cloud UI within reMarkable's
retention window. So a delete can be undone from either side
within the relevant window.

To prune the trash on demand:

```sh
rmsync trash prune                       # honors trash_retention_days
rmsync trash prune --days 7              # one-off override
```

The daemon also auto-prunes at startup based on
`trash_retention_days` (set to 0 to keep forever).

### …organize my docs in folders

`mkdir <sync_dir>/papers/2026/` creates a matching folder on the
cloud (and on the tablet) on the next sync cycle. Save
`<sync_dir>/papers/2026/foo.md` and the doc lands at
`/Writing/papers/2026/foo` on the cloud rather than flat at the
top. Folder creation works in both directions:

- Local mkdir → cloud mkdir (always-on, v0.2.22+).
- Cloud mkdir on the tablet → local empty dir on next poll.
- Local rmdir on an empty dir → cloud rmdir (gated on
  `[deletion] enable_propagation = true`; only fires once the
  cloud folder is verified empty).
- Cloud rmdir → local empty-dir cleanup (same propagation gate;
  only removes if the local dir is also empty).

So you can structure a long writing project however you like —
chapters, sections, sub-projects — and it stays in sync. Hidden
dirs (`.git`, `.obsidian`, anything starting with `.`) are
filtered out, so an Obsidian vault inside `sync_dir` won't
leak its `.obsidian/` plugins folder to the cloud.

### …revert a doc to an earlier version

Every time the daemon writes a `.md` file (either pulled from
the cloud or about to push), it parks a snapshot of the bytes at
`<stateDir>/backups/<doc-id>/<utc-stamp>.md`. Default retention
is 30 snapshots per doc; bump or shrink via
`backup_snapshots_to_keep` in config.toml.

You don't need to opt in — snapshots are always taken for
tracked docs. To browse / diff / revert:

```sh
# all snapshots for this draft, newest first
rmsync history list ~/rmsync-writing/Chapter-3.md

# unified diff vs the most recent snapshot
rmsync history diff ~/rmsync-writing/Chapter-3.md

# unified diff vs a specific snapshot (paste timestamp from list)
rmsync history diff ~/rmsync-writing/Chapter-3.md \
    --against 2026-04-29T22:14:08Z

# revert. parks the current local file in .rmsync-trash/ first
# (recoverable via `rmsync trash restore`), then asks the daemon
# to push the reverted content to the cloud immediately.
rmsync history restore ~/rmsync-writing/Chapter-3.md \
    --to 2026-04-29T22:14:08Z
```

The `cause` column in `history list` distinguishes:

- `push` — bytes saved on a save / push to cloud.
- `pull_overwrite` — bytes captured before the daemon overwrote
  the local file with a remote edit. This is the safety net for
  "the daemon just clobbered something I was working on".

Storage is keyed on the doc UUID (not the local path), so
`rmsync relocate` doesn't orphan history. Disk usage is bounded
by `backup_snapshots_to_keep` × file size — typically a few MB
per actively-written doc.

---

## Optional: drop-folder for sending PDFs / EPUBs

Add to `~/.config/rmsync/config.toml`:

```toml
[inbox]
local_dir         = "~/rmsync-writing/_inbox"
remote_folder     = "Inbox"
delete_after_push = true
```

Then `rmsync restart`. Drop a `.pdf` or `.epub` into `local_dir`;
within ~5 seconds the daemon pushes it to `/Inbox/` on your
reMarkable cloud and (by default) removes the local copy. Closes
the "send paper to tablet" loop without email or rmapi-by-hand.

The daemon creates `local_dir` on startup if missing. Watcher
shares the same FSEvents subscription model as the main
sync_dir watcher — just with a `mode: .inbox` filter that
accepts only PDFs and EPUBs.

`docker exec rmsync rmsync logs -f` (or `rmsync logs -f` on
macOS) shows the push events; the daemon never silently drops a
file:

```
{"event":"inbox push starting","path":"/Users/you/rmsync-writing/_inbox/paper.pdf"}
{"event":"inbox push complete; local removed","path":".../paper.pdf"}
```

Non-`.pdf`/`.epub` files in the inbox are ignored with a one-time
warning per filename.

---

## Optional: web dashboard

Add to `~/.config/rmsync/config.toml`:

```toml
[web]
enabled    = true
bind_addr  = "127.0.0.1"
port       = 7878
# auth_token = "..."   # leave empty → daemon generates one
```

Then `rmsync restart`. Open `http://127.0.0.1:7878/?token=...` —
the token is written to `~/Library/Application Support/rmsync/web-token`
on first start (or whatever you set explicitly). Shows live
status, recent docs, conflicts, with manual sync-now / pause /
resume buttons.

Token gets stored in your browser's localStorage on first load,
so subsequent visits work from `http://127.0.0.1:7878/` without
the query string.

For LAN access (e.g. from another machine on your home network),
set `bind_addr = "0.0.0.0"`. The token still gates every API
call. macOS users typically prefer the menubar; the web UI is
there for parity with the Linux/Docker build and for users who
want a glanceable browser tab.

---

## Menu bar

Look at your menu bar — you'll see an icon near the top-right of the
screen. Click it for the menu.

### Icon states

| Icon | Meaning |
|---|---|
| ✓ | Synced, idle |
| tablet-and-pencil + ⟳ | Syncing |
| tablet-and-pencil + ⚠ | Unresolved conflicts present |
| tablet-and-pencil + ⏸ | Paused |
| tablet-and-pencil + ✗ | Error or daemon stopped |

### Menu items

- **Synced (N docs)** — status line, updates live from IPC
- **Last pull / push** — relative time (e.g. "2 min ago")
- **Open Sync Folder** — reveals it in Finder
- **Show Conflicts (N)** — hidden when zero
- **Pause / Resume** — toggles the pause state (persists)
- **Sync Now** — force poll
- **Restart Daemon** — `launchctl kickstart -k`
- **Open Logs** — opens the log file in Console.app
- **Edit Config…** — opens `config.toml`
- **Quit Menu Bar** — stops the menu bar only; daemon keeps syncing

---

## Logs + diagnostics

### Where logs go

```
~/Library/Logs/rmsync/stdout.log     # daemon (structured JSON, one event per line)
~/Library/Logs/rmsync/stderr.log     # daemon stderr
~/Library/Logs/rmsync/menubar.log    # menu bar
```

### Live tail

```sh
rmsync logs -f
```

Ctrl+C to stop.

Or grep for just structured events:

```sh
tail -f ~/Library/Logs/rmsync/stdout.log | grep '"event"'
```

### `rmsync doctor`

Runs 10 health checks, prints ✓ / ! / ✗ per check, exits 1 if anything
is ✗. Checks: rmapi on PATH, rmapi version, rmapi authenticated, remote
Writing folder reachable, local sync_dir writable, state DB openable,
launchd plist loaded, disk space, log dir writable, clock sanity.

Run it when anything seems off.

### Inspect state directly

```sh
# How many docs are tracked? When did each last sync?
sqlite3 "$HOME/Library/Application Support/rmsync/state.db" \
    "SELECT doc_id, substr(local_path, -30) AS path, last_pull_at, last_push_at
     FROM documents ORDER BY last_push_at DESC"

# What's paused and which author UUID does this install write with?
sqlite3 "$HOME/Library/Application Support/rmsync/state.db" \
    "SELECT * FROM settings"
```

### Xattrs on a pulled file

Every pulled `.md` carries xattrs telling you where it came from:

```sh
xattr -l ~/Library/CloudStorage/Dropbox/reMarkable/hello.md
```

You'll see `rmsync.doc_id`, `rmsync.remote_path`,
`rmsync.remote_modified`, `rmsync.page_ids`, plus the Finder
`kMDItemWhereFroms` / `kMDItemKind` / `_kMDItemUserTags` entries that
surface in Finder's Get Info panel.

---

## Rebuild after code changes

```sh
cd ~/code/rmsync
./install.sh
```

Rebuilds both products in release mode, refreshes the plists, kicks
both agents. Idempotent.

For an in-place rebuild without touching launchd:

```sh
cd ~/code/rmsync/swift
swift build -c release --product rmsync
rmsync restart
```

The `~/.local/bin/rmsync` symlink points at the release-build path, so
any `swift build -c release` pickup is reflected immediately in new CLI
invocations. Launchd-launched daemon picks up the new binary on the
next `restart` or `kickstart`.

Run the tests before shipping anything:

```sh
cd ~/code/rmsync/swift
swift test                              # fast: 48 Swift Testing + 50 RMScene
RMSYNC_LIVE=1 PATH="$HOME/bin:$PATH" swift test     # also run the 2 live-cloud push smoke tests
```

---

## Uninstall

Stop the agents and remove them, keeping your config / state / logs:

```sh
cd ~/code/rmsync
./uninstall.sh
```

Nuclear option — wipe state too:

```sh
./uninstall.sh --purge
```

Purge removes:
- `~/.config/rmsync/`
- `~/Library/Application Support/rmsync/`
- `~/Library/Logs/rmsync/`

After either, the `.md` files in the sync dir stay on disk. You have
to remove those manually.

---

## Rough edges to know about

### Rename / move / delete propagation (default)

**Default since v0.2.27** (was opt-in via `[deletion]
enable_propagation = true` in v0.2.19–v0.2.26).

The daemon mirrors deletes and renames in both directions
without any configuration:

- **Local delete → cloud trash.** Removing `hello.md` from
  `sync_dir` parks the file in `<sync_dir>/.rmsync-trash/` and
  moves the cloud doc to the reMarkable cloud's trash (`rmapi rm`
  is a soft-delete — recoverable from the cloud UI within
  reMarkable's retention window).
- **Cloud delete → local trash.** Deleting a doc on the tablet
  (or via `rmapi rm`) drops the local file into
  `<sync_dir>/.rmsync-trash/` on the next poll cycle.
- **Local rename → cloud rename.** `mv old.md new.md` calls
  `rmapi mv` to move the cloud doc to match.
- **Cloud rename → local rename.** Renaming on the tablet moves
  the local file to match.

Recovery: `rmsync trash list` shows recent deletions;
`rmsync trash restore <rel-path>` puts a file back (the daemon
re-pushes it to the cloud on the next watcher tick). The trash
auto-prunes at daemon startup based on `trash_retention_days`;
set to 0 to keep forever.

Safety gates that protect against runaway events:
- **Soft-delete to `.rmsync-trash/`.** Nothing is hard-deleted
  on the local side — recoverable for `trash_retention_days`
  (default 30 days).
- **Bulk-delete brake.** Refuses to apply more than
  `bulk_delete_threshold` of tracked docs in a
  `bulk_delete_window_seconds` window. An accidental
  `rm -rf sync_dir` parks the bulk in trash, refuses the cloud
  side, and surfaces `error_state = "bulk_delete_refused"` in
  `rmsync status`.
- **Per-doc lock.** Rename + delete + push on the same doc
  serialize through `LockRegistry`.
- **Echo fence.** Cloud→local rename seeds the fence so the
  watcher's resulting filesystem event for our own move is
  suppressed (otherwise we'd ping-pong forever).
- **First-start-after-upgrade guard (v0.2.31+).** The daemon
  stamps its version into state.db at the end of every
  successful reconcile. On the next start, if the binary's
  version differs from what's stored (i.e., you just upgraded),
  the deletion-reconcile pass runs in **skip-propagation
  mode**: tracked-but-locally-missing rows get parked with
  `error_state = "missing_pre_upgrade"` instead of cascading
  to cloud-side deletes. Protects users who rm'd files locally
  on a version that didn't propagate (the pre-v0.2.27 default)
  from having those rms silently cascade now that propagation
  is on. Run `rmsync errors` after upgrade to see the parked
  rows and pick: `rmapi rm <remote_path>` if you meant to
  delete on cloud, or `rmsync sync-now` to re-pull the local
  files from cloud.

To opt out (v0.2.18-style behavior — local delete logs but
doesn't touch cloud), explicitly set:

```toml
[deletion]
enable_propagation = false
```

Tunables (defaults shown):

```toml
[deletion]
trash_retention_days       = 30   # 0 keeps trash forever
bulk_delete_threshold      = 0.5  # >50% of tracked → refuse burst
bulk_delete_window_seconds = 30
```

### `rmapi put --force` only

Our push path uses `rmapi put --force` to update an existing doc in
place. **Never** hand-invoke `rmapi put --content-only` — that flag is
PDF-only and will fail loudly. Plain `rmapi put` without `--force`
errors when the doc already exists.

### Dropbox "conflicted copy" files ignored

If Dropbox decides to manufacture a `foo (Mac mini's conflicted copy
2026-04-17).md` file, the watcher ignores it. It won't be pushed as a
new reMarkable doc. You handle Dropbox's conflict resolution manually
— keep the copy you want, delete the other.

### Handwriting pages pull as empty

Only typed text extracts to Markdown. Pages that are purely
handwriting come through as empty strings and don't appear in the
`.md`. Notebooks mixing the two keep only the typed text.

### Never edit `sync_dir` in config.toml by hand

Use `rmsync relocate <new-path>` instead. The command moves the files,
rewrites the state DB, and updates the config atomically. Editing just
the config leaves every tracked doc's `local_path` pointing at a
missing location, which the daemon interprets as "user deleted
everything" on next startup. See the **relocate vs editing sync_dir**
table in the "How do I…" section above.

### Dropbox "smart sync" / online-only

If Dropbox has the sync folder on smart-sync (online-only files), our
watcher will see 0-byte placeholders and push empties. Keep the sync
folder set to "Always Keep on This Device" in Dropbox's UI.

---

## Quick sanity check

```sh
rmsync status                              # daemon alive, talks IPC
rmsync doctor                              # all ✓
ls ~/Library/LaunchAgents/com.user.rmsync* # both plists present
ps auxww | grep rmsync | grep -v grep      # both processes running
```

If any of those surprise you, `rmsync restart` is the fast fix.
