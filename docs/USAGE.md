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
~/Library/Application Support/rmsync/remote-cache/     # rendered pull snapshot cache
~/Library/Application Support/rmsync/ipc.sock          # live IPC socket
~/Library/Application Support/rmsync/status.json       # slow-cadence snapshot
~/Library/Logs/rmsync/stderr.log                       # structured daemon log
~/Library/Logs/rmsync/stdout.log                       # usually empty under Swift
~/Library/Logs/rmsync/menubar.log                      # menu bar log
~/Library/CloudStorage/Dropbox/reMarkable/              # your sync dir (Dropbox today)
```

The agents start automatically at login and restart on crash.
Set `RM_SYNC_CACHE_DIR` to move the pull snapshot cache somewhere else.

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
"rmapi authenticated" check and explicit pull/push commands cannot
reach the cloud.

---

## Daily commands

Core subcommands. Run any of them from anywhere.

| Command | What it does | Mechanism |
|---|---|---|
| `rmsync status` | Current state, tracked docs, last pull/push, conflicts, errors | Live IPC |
| `rmsync pull` | Fetch cloud changes into a staging area without touching local files | rmapi + remote cache + staging dir |
| `rmsync pull --full` | Bypass the remote cache and re-download every cloud document | rmapi + staging dir |
| `rmsync diff [path]` | Show currently staged cloud changes, or a unified diff for one path | Staging manifest |
| `rmsync accept <path>` | Apply selected staged cloud changes locally | Staging → sync dir |
| `rmsync accept --all` | Apply every staged non-delete cloud change | Staging → sync dir |
| `rmsync accept --include-deletes <path>` | Accept staged cloud deletes, moving local files to trash | Staging → `.rmsync-trash` |
| `rmsync push [path ...]` | Push local Markdown changes to the cloud | Direct rmapi |
| `rmsync push --include-deletes` | Also propagate tracked local files missing on disk | Direct rmapi |
| `rmsync force-push` | Stage current cloud state and preview replacing it with the local tree | rmapi + staging dir |
| `rmsync force-push --apply` | Replace same-path cloud docs, upload local-only docs, and trash remote-only docs | Direct rmapi |
| `rmsync git init` | Initialize `/sync/<repo>` for a git-backed workflow | git refs + rmapi |
| `rmsync git pull` / `rmsync-git pull` | Render cloud state into a new git branch | rmapi + git branch |
| `rmsync git push` / `rmsync-git push` | Merge cloud with `HEAD`, then upload the verified git tree | git merge-tree + rmapi |
| `rmsync pause` | Set the paused status flag | IPC → state DB |
| `rmsync resume` | Clear the paused status flag | IPC → state DB |
| `rmsync sync-now` | Deprecated; automatic polling is disabled | IPC |
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

`pull`, `accept`, and `push` are the default sync-mutating commands in
the explicit model. `rmsync git ...` is an optional git-backed workflow
for repositories; it does not replace the normal staged
`pull`/`diff`/`accept`/`push` flow. Everything that controls the agent
lifecycle (`start`, `stop`, `restart`, `relocate`) talks to `launchctl`.

---

## How do I…

### …edit a Markdown file on my Mac and see it on the tablet

Edit it, then push when you are ready.

```sh
echo "new line" >> ~/Library/CloudStorage/Dropbox/reMarkable/hello.md
rmsync push hello.md
```

What happens:

1. `rmsync push` packs the selected Markdown file as a reMarkable doc.
2. It checks the stored cloud baseline unless you passed `--force`.
3. It shells `rmapi put --force` to update the cloud.
4. Sync appears on the tablet the next time you sync it (swipe-down
   from the top on the home screen) or within its own auto-sync window.

`rmsync status` will show `last push:` updated and `tracked docs:`
incremented if it was a new file.

### …write on the tablet and have it appear as Markdown locally

Write on the tablet and let the tablet sync back to the reMarkable
cloud. Then pull into staging:

```sh
rmsync pull
rmsync diff
rmsync diff path/from/diff.md
rmsync accept path/from/diff.md
```

`rmsync pull` never overwrites local files directly. It stages cloud
content, classifies each path as added, modified, deleted, conflict, or
local_modified, and leaves local state untouched until you accept a
staged entry. Repeated pulls reuse a verified remote snapshot cache when
the cloud metadata fingerprint is unchanged; pass `--full` to bypass the
cache and re-download every cloud document.

### …make my Mac copy overwrite the tablet/cloud copy

Use `force-push` when the local Markdown tree is the authority and the
current reMarkable cloud state should be replaced wholesale.

```sh
rmsync force-push
# review the printed create_remote / overwrite_remote / delete_remote plan
# inspect the staged remote snapshot if needed
rmsync force-push --apply
```

The preview command always downloads the current cloud state into the
staging directory before printing the plan. Applying the plan:

1. replaces remote docs whose paths also exist locally,
2. uploads local-only Markdown files,
3. moves remote-only docs to the reMarkable cloud trash,
4. refuses any remote doc that failed to stage, because deleting or
   overwriting content that was not downloaded would defeat the recovery
   point.

`force-push` bypasses cloud-baseline conflict checks, but it does not
bypass local data-loss guards: dataless File Provider placeholders and
suspicious empty local reads are still refused.

### …use git as the sync boundary

Run this from an existing git repository when you want every synced
state to be a real commit. This is a separate optional mode: existing
`rmsync pull`, `rmsync diff`, `rmsync accept`, and `rmsync push` keep
using the configured `remote_folder` and continue to work exactly as
before.

```sh
rmsync-git init --name attack
rmsync-git push
```

This creates `/sync/attack` on the reMarkable cloud and stores
repo-local metadata under `.git/rmsync-git/`. The hidden ref
`refs/rmsync-git/attack/cloud` records the last git commit whose
Markdown tree was verified to match the cloud.

When the tablet/cloud changes, import it as a branch:

```sh
rmsync-git pull
# prints a branch like rmsync/cloud/attack/20260603T041500Z-a1b2c3d4
git merge rmsync/cloud/attack/20260603T041500Z-a1b2c3d4
```

When pushing, rmsync-git renders the current cloud, asks git to perform
a three-way merge with `refs/rmsync-git/<name>/cloud` as the base, and
uploads only the resulting Markdown tree. If git reports conflicts, no
cloud documents are changed; resolve the branch with normal git tools,
commit the resolution, then run `rmsync-git push` again.

Clean independent changes are merged automatically. If that merge brings
tablet edits into your branch, `rmsync-git push` creates a real merge
commit before upload so the local branch and cloud never describe
different resolved states. A dirty worktree is refused by default.

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
- The state DB still points at the old absolute paths.
- Status, history, trash, and future explicit sync operations can then
  reason about the wrong files.

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
# … paused status is set; no background sync exists in explicit mode …
rmsync resume
```

The paused state persists across daemon restarts (stored in
`state.db`'s `settings` table). Menu bar icon shows paused while the
flag is set.

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
# overwrites the stale .md with your merged version.
rmsync push foo.md
```

After the explicit push, both sides are in sync again and
`rmsync conflicts` returns empty.

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

Modern config keys and defaults (all paths relative to your home):

| Key | Default | Effect |
|---|---|---|
| `sync_dir` | `~/rmsync-writing` | Where local `.md` files live. **Change with `rmsync relocate`, not here** — see above. |
| `remote_folder` | `Writing` | Which cloud folder to mirror |
| `[deletion].trash_retention_days` | `30` | Retention used by `rmsync trash prune` (`0` = keep forever). |
| `[web].enabled` | `false` | Enable the optional HTTP dashboard. |
| `[web].bind_addr` | `127.0.0.1` | Dashboard bind address; use `0.0.0.0` only on trusted networks. |
| `[web].port` | `7878` | Dashboard port. |
| `[web].auth_token` | generated when unset | Bearer token for dashboard API requests. |

Normal `rmsync push` is incremental: unchanged tracked Markdown files
are skipped and do not call `rmapi`. Use `rmsync push --force` when you
intentionally want to re-upload selected files. Older config keys from
the watcher/poller daemon are still accepted for existing installs, but
new configs omit them because explicit sync does not use background
watching, polling, or automatic delete propagation.

### …recover a file I deleted by mistake

Explicit delete acceptance parks local files under
`<sync_dir>/.rmsync-trash/<utc-stamp>/<rel-path>` before doing
anything irreversible. To inspect and recover local trash:

```sh
rmsync trash list                       # everything currently parked
rmsync trash restore "old/note.md"      # one-file restore
rmsync trash restore --all              # bulk restore
```

Restored files reappear at their original location. They are not pushed
automatically; run `rmsync push <path>` if you want the restored
content on the cloud.

The reMarkable cloud also keeps its own trash for cloud-side
deletes, recoverable via the cloud UI within reMarkable's
retention window. So a delete can be undone from either side
within the relevant window.

To prune the trash on demand:

```sh
rmsync trash prune                       # honors trash_retention_days
rmsync trash prune --days 7              # one-off override
```

The status-only daemon does not prune automatically; run
`rmsync trash prune` when you want to enforce `trash_retention_days`
(set to 0 to keep forever).

### …organize my docs in folders

`mkdir <sync_dir>/papers/2026/` creates local structure. When you push
`<sync_dir>/papers/2026/foo.md`, the doc lands at
`/Writing/papers/2026/foo` on the cloud rather than flat at the top.
Cloud folder structure appears in the staged tree after `rmsync pull`;
accepting selected files creates the corresponding local directories.

So you can structure a long writing project however you like —
chapters, sections, sub-projects — and it stays in sync. Hidden
dirs (`.git`, `.obsidian`, anything starting with `.`) are
filtered out, so an Obsidian vault inside `sync_dir` won't
leak its `.obsidian/` plugins folder to the cloud.

### …revert a doc to an earlier version

Every explicit push and accepted pull overwrite for a tracked doc parks
a snapshot of the bytes at
`<stateDir>/backups/<doc-id>/<utc-stamp>.md`. Default retention
is 30 snapshots per doc.

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
# (recoverable via `rmsync trash restore`). Push explicitly after
# inspecting the restored content.
rmsync history restore ~/rmsync-writing/Chapter-3.md \
    --to 2026-04-29T22:14:08Z
```

The `cause` column in `history list` distinguishes:

- `push` — bytes captured before a tracked local file is pushed.
- `pull_overwrite` — bytes captured before an accepted cloud change
  overwrites a local file.

Storage is keyed on the doc UUID (not the local path), so
`rmsync relocate` doesn't orphan history. Disk usage is bounded
by roughly 30 snapshots × file size — typically a few MB per
actively-written doc.

---

## Optional: drop-folder for sending PDFs / EPUBs

Add to `~/.config/rmsync/config.toml`:

```toml
[inbox]
local_dir         = "~/rmsync-writing/_inbox"
remote_folder     = "Inbox"
delete_after_push = true
```

This legacy config block is retained, but the explicit sync daemon does
not start automatic inbox watchers. Use rmapi directly for PDF / EPUB
sends until rmsync has a dedicated explicit send command.

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
status, recent docs, conflicts, with pause / resume buttons. Pull,
accept, and push stay in the CLI so sync intent is explicit.

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
- **Manual sync mode** — informational; use `rmsync pull` / `push`
- **Restart Daemon** — `launchctl kickstart -k`
- **Open Logs** — opens the log file in Console.app
- **Edit Config…** — opens `config.toml`
- **Quit Menu Bar** — stops the menu bar only; daemon/status IPC keeps running

---

## Logs + diagnostics

### Where logs go

```
~/Library/Logs/rmsync/stderr.log     # daemon (structured JSON, one event per line)
~/Library/Logs/rmsync/stdout.log     # usually empty under Swift
~/Library/Logs/rmsync/menubar.log    # menu bar
```

### Live tail

```sh
rmsync logs -f
```

Ctrl+C to stop.

Or grep for just structured events:

```sh
tail -f ~/Library/Logs/rmsync/stderr.log | grep '"event"'
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

### How versioning works

rmsync is not Git and does not keep a commit graph. It also does not
merge local Markdown edits with tablet edits using a CRDT.

The durable sync baseline is the `documents` table in
`state.db`. Each row stores:

- the reMarkable document UUID (`doc_id`),
- the local and remote paths,
- the cloud `ModifiedClient` timestamp from `rmapi stat`,
- the last synced Markdown SHA-256 hash,
- the page IDs reused on future pushes,
- pull/push timestamps and conflict/error markers.

The push path is optimistic: before a normal push, it stats the cloud
doc and refuses the push if the cloud `ModifiedClient` no longer
matches the stored baseline. The pull path compares local hash, remote
hash, and baseline hash, then stages conflicts instead of merging them.
`remote_version` is kept as a local counter for packed archives, but on
modern sync15 cloud metadata the server-side `Version` field is not a
reliable change signal; `ModifiedClient` is.

The `.rm` page payloads that rmsync writes do use reMarkable's
CRDT-shaped scene format internally so the tablet accepts typed text and
page IDs remain stable. That CRDT is inside the document payload; it is
not a cross-device merge engine in rmsync.

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

### Rename / move / delete propagation

Rename, move, and delete propagation is explicit. The daemon no longer
mirrors destructive changes just because it observed a filesystem or
cloud event.

- **Local delete → cloud trash.** Delete the local file, then run
  `rmsync push --include-deletes` when you really want the tracked cloud
  doc moved to the reMarkable cloud trash.
- **Cloud delete → local trash.** Run `rmsync pull`, review the staged
  delete with `rmsync diff`, then accept it with
  `rmsync accept --include-deletes <path>`.
- **Local rename / move → cloud update.** Rename or move the local file,
  then push the new path explicitly.
- **Cloud rename / move → local update.** Pull, review the staged path,
  then accept it explicitly.

Recovery: `rmsync trash list` shows local files parked by accepted
deletes; `rmsync trash restore <rel-path>` puts one back. Restoring does
not push automatically, so run `rmsync push <path>` after inspection if
the restored content should go to the cloud.

Modern delete-related config:

```toml
[deletion]
trash_retention_days = 30   # 0 keeps trash forever
```

### `rmapi put --force` only

Our push path uses `rmapi put --force` to update an existing doc in
place. **Never** hand-invoke `rmapi put --content-only` — that flag is
PDF-only and will fail loudly. Plain `rmapi put` without `--force`
errors when the doc already exists.

### Dropbox "conflicted copy" files ignored

If Dropbox decides to manufacture a `foo (Mac mini's conflicted copy
2026-04-17).md` file, the sync filter ignores it. It won't be pushed
as a new reMarkable doc. You handle Dropbox's conflict resolution
manually — keep the copy you want, delete the other.

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

If Dropbox has the sync folder on smart-sync (online-only files), a
manual push can still read placeholder bytes instead of the full file.
Keep the sync folder set to "Always Keep on This Device" in Dropbox's
UI before pushing.

---

## Quick sanity check

```sh
rmsync status                              # daemon alive, talks IPC
rmsync doctor                              # all ✓
ls ~/Library/LaunchAgents/com.user.rmsync* # both plists present
ps auxww | grep rmsync | grep -v grep      # both processes running
```

If any of those surprise you, `rmsync restart` is the fast fix.
