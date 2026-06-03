# rmsync

Explicit push/pull sync between a reMarkable cloud folder and a local
Markdown tree on macOS. The supported tablet namespace is `/sync/notes`;
older `/Writing` configs require a fresh reinstall. Cloud changes are pulled
into a staging area first; you review them, accept the files you want,
and then push local changes deliberately. The daemon stays up for
status, menu bar, and dashboard IPC. It may run a read-only pull
availability probe and, when enabled, the safe auto-push watcher; it
does not pull, reconcile, or delete files in the background.

**Current sync model:** Swift daemon, explicit CLI mutations, one
top-level tablet namespace under `/sync`.

---

## Quick use

Once installed (see [Quick start](#quick-start) below):

```sh
rmsync status                        # is the daemon healthy? what's queued?
rmsync pull                          # fetch cloud changes into staging (uses cache)
rmsync pull --full                   # bypass cache and re-download every cloud doc
rmsync diff [path]                   # review staged changes, or one file diff
rmsync accept <path>                 # apply one staged cloud change locally
rmsync accept --all                  # apply all staged non-delete changes
rmsync push [path ...]               # push local Markdown changes to cloud
rmsync push --include-deletes        # also propagate tracked local deletes
rmsync force-push                    # preview replacing cloud with local tree
rmsync force-push --apply            # overwrite/delete remote-only cloud docs
rmsync init                          # create local dir + /sync/notes if needed
rmsync git init --name my-notes      # optional: initialize /sync/git/my-notes
rmsync git pull                      # optional: import cloud state as a branch
rmsync git push                      # optional: merge HEAD with cloud and upload
rmsync auto-push status              # inspect optional safe auto-push attempts
rmsync doctor                        # full self-check (10 items)
rmsync logs -f                       # follow the shared event log
rmsync conflicts                     # list any unresolved .md.conflict files

# pause / resume — useful before bulk-editing a tree
rmsync pause
rmsync resume

# move the sync dir without losing state
rmsync relocate ~/path/to/new/dir
```

## Sync modes and auto-sync

rmsync has three sync modes. The default is explicit staged sync; the
only background sync mode is opt-in safe auto-push. The daemon may run
a read-only pull availability probe, but there is no cloud-to-local
background sync: tablet/cloud edits always come in through
`rmsync pull`, `rmsync diff`, and `rmsync accept`.

### Sync modes

**Explicit staged sync (default).** Local and cloud changes move only
when you run a command. Push local Markdown with `rmsync push`; fetch
tablet/cloud changes into staging with `rmsync pull`, review them with
`rmsync diff`, then apply selected files with `rmsync accept`. This is
the safest mode and is what new installs use immediately after
`rmsync init`.

**Safe auto-push (opt-in).** The daemon watches and periodically scans
`sync_dir` for stable local `.md` creates/edits, then uploads them
through the same guarded path as `rmsync push` with `force = false` and
`includeDeletes = false`. It is local-to-cloud only. It never accepts
cloud changes, never propagates deletes, and pauses rather than
guessing when the cloud baseline is stale or unsafe.

**Git-backed sync (optional).** If your notes live inside a git
repository and you want git to be the merge/conflict boundary, use
`rmsync git ...` or the `rmsync-git` wrapper. This mode syncs a
separate cloud folder under `/sync/git/<name>` and stores repo-local
metadata under `.git/rmsync-git/`. Auto-push is disabled inside
initialized rmsync-git repositories; upload committed state with
`rmsync git push`.

### Enable a mode

Explicit staged sync needs no extra mode flag:

```sh
rmsync init
rmsync pull
rmsync diff
rmsync accept <path>
rmsync push [path ...]
```

Enable safe auto-push by editing `~/.config/rmsync/config.toml`,
adding or updating `[auto_push]`, then restarting the daemon:

```toml
[auto_push]
enabled               = true
new_files             = true
debounce_seconds      = 2.0
stable_sample_count   = 2
scan_interval_seconds = 30
max_pushes_per_minute = 30
```

```sh
rmsync restart
rmsync auto-push status
```

Enable git-backed sync from inside the git repository you want to
materialize on the tablet:

```sh
cd ~/notes
rmsync git init --name notes
rmsync git push
```

After that, use `rmsync git pull` to import cloud state as a branch,
merge or rebase it with normal git tools, and use `rmsync git push` to
upload the verified `HEAD` tree.

### Config model

`~/.config/rmsync/config.toml` is read once at daemon startup. Edit it,
then run `rmsync restart`; the daemon does not watch config changes.

The core sync keys are:

```toml
sync_dir      = "/Users/you/rmsync-notes"
remote_folder = "sync/notes"
```

`sync_dir` is the local Markdown root. Do not edit it by hand; use
`rmsync relocate <path>` so files, `state.db`, config, and the running
agent stay consistent. `remote_folder` is the reMarkable cloud folder
that explicit sync uses. The supported ordinary namespace is
`sync/notes`; older `/Writing` configs require a fresh reinstall.

The `[auto_push]` block is optional and defaults to disabled:

| Key | Default | Effect |
|---|---:|---|
| `enabled` | `false` | Starts the local watcher/scanner when true. |
| `new_files` | `true` | Allows local-only `.md` files to create cloud docs. |
| `debounce_seconds` | `2.0` | Delay between stability samples. |
| `stable_sample_count` | `2` | Identical size/mtime/hash samples required before upload. |
| `scan_interval_seconds` | `30` | Full-tree scan cadence for edits missed while the daemon was off. |
| `max_pushes_per_minute` | `30` | Rate limit for automatic uploads. |

Older polling, worker, rename, deletion-propagation, and inbox config
keys are rejected at load time. Remove stale legacy keys and rerun
`rmsync init` or reinstall with a fresh config before restarting the
daemon.

### Expected behavior

- Local `.md` creates/edits auto-push only after the file is stable for
  the configured number of samples.
- Tablet/cloud edits never auto-apply locally. Run `rmsync pull`,
  inspect with `rmsync diff`, then accept deliberately.
- Deletes never auto-push. Local deletes require
  `rmsync push --include-deletes`; cloud deletes require
  `rmsync accept --include-deletes`.
- Auto-push refuses stale remote baselines, missing accepted remote
  snapshots, path collisions, dataless File Provider placeholders,
  suspicious empty reads over previously non-empty content, invalid
  UTF-8, and unreadable or non-regular files.
- Refused, failed, skipped, queued, uploading, and succeeded attempts
  are recorded in `state.db` and shown by `rmsync auto-push status`.
- If the daemon restarts during an auto-push, it verifies the
  interrupted operation by downloading and rendering the remote
  document before repairing local state.
- `rmsync pause` suppresses auto-push processing until `rmsync resume`.
  Remote inspection and manual commands remain explicit user actions.

**Rename / move / delete propagation is explicit.** Deleting a local
file no longer deletes the cloud copy unless you run
`rmsync push --include-deletes`. Deleting on the tablet no longer
removes the local copy unless you run `rmsync pull`, inspect the staged
delete, and accept it with `rmsync accept --include-deletes`.

- **Local delete → cloud trash.** `rm hello.md` followed by
  `rmsync push --include-deletes` parks the file in
  `<sync_dir>/.rmsync-trash/<utc-stamp>/` (recoverable) and moves
  the cloud doc to the reMarkable cloud's trash.
- **Cloud delete → local trash.** Deleting on the tablet stages a
  delete on `rmsync pull`; local removal requires
  `rmsync accept --include-deletes`.
- **Local rename → cloud update.** Push the renamed file explicitly.
- **Cloud rename → local update.** Pull, review, and accept the staged
  path change explicitly.

Recovery and inspection:

```sh
rmsync trash list                    # everything currently parked
rmsync trash restore "old/note.md"   # put one file back
rmsync trash restore --all           # bulk restore
rmsync trash prune                   # drop entries past retention
```

Safety gates that protect against accidents:

- **Soft-delete to `.rmsync-trash`.** Nothing is hard-deleted on
  the local side — recoverable for `trash_retention_days` (default
  30 days, set to 0 to keep forever).
- **Explicit delete flags.** Cloud-side staged deletes require
  `rmsync accept --include-deletes`; local deletions require
  `rmsync push --include-deletes`.
- **Previewed force-push.** `rmsync force-push` first downloads the
  current cloud state into staging and prints what local state would
  create, overwrite, or delete remotely. Only
  `rmsync force-push --apply` mutates the cloud.

Modern delete-related config is just local trash retention:

```toml
[deletion]
trash_retention_days = 30  # 0 keeps trash forever
```

Full guide: [`docs/USAGE.md`](docs/USAGE.md) → "Rename / move /
delete propagation".

**Folder structure is preserved through explicit commands.**
Subdirectories under `sync_dir` map to cloud folders when you run
`rmsync push`; cloud folders are represented in the staged pull tree
when you run `rmsync pull`.

**v0.2.20 — snapshot history (always on).** Every push and every
cloud-pull-overwrite parks a copy of the file at
`<stateDir>/backups/<doc-id>/<utc-stamp>.md` so you can always
roll back. Default 30 snapshots per doc. No setup required — it's
already running.

```sh
# what saves do I have for this draft?
rmsync history list ~/rmsync-notes/Chapter-3.md

# what changed since the last save?
rmsync history diff ~/rmsync-notes/Chapter-3.md

# revert to an earlier version (current goes to .rmsync-trash/);
# run `rmsync push` yourself when you want it on the cloud
rmsync history restore ~/rmsync-notes/Chapter-3.md \
    --to 2026-04-29T22:14:08Z
```

`history list` is newest-first with a word-count delta column so
you can spot the save where you accidentally cut a paragraph.
`history diff` shells to POSIX `diff -u` (pipes cleanly to
`delta` / `less`). `history restore` parks the current file in
trash before overwriting, so a mistaken restore is itself
recoverable via `rmsync trash restore`. It does not push
automatically; run `rmsync push <path>` after you inspect the restored
file.

**Server-wins recovery.** If the local Markdown tree is definitely the
source of truth and the tablet/cloud copy should be replaced wholesale,
run:

```sh
rmsync force-push
# inspect the staged remote snapshot and plan
rmsync force-push --apply
```

The preview stage uses the same verified remote snapshot cache as
`rmsync pull`, falling back to downloads when the cache is missing or
stale. Remote-only docs and overwritten remote content are still
inspectable before you apply. Applying replaces same-path remote docs,
uploads local-only files, and moves remote-only docs to cloud trash.

**Git as the sync boundary.** If the local Markdown tree is already a git
repo, you can let git do the merge/conflict work and treat the
reMarkable cloud as a materialized tree.

```sh
cd ~/notes
rmsync git init --name notes
rmsync git push
```

`init` creates `/sync/git/notes` on the reMarkable cloud and fails if
that folder already exists. It also refuses namespace overlap with the
ordinary sync folder; `/sync/notes` and `/sync/git/notes` are siblings,
but ordinary sync should not own `/sync` directly. `push` snapshots the
current cloud, asks git to merge that snapshot with `HEAD`, and uploads
only a verified resolved tree. If git reports conflicts, no cloud
documents are changed; run `rmsync git pull`, merge or rebase the
printed branch with normal git tools, commit the resolution, then run
`rmsync git push` again.

```sh
rmsync git pull
# prints e.g. rmsync/cloud/notes/20260603T041500Z-a1b2c3d4
git merge rmsync/cloud/notes/20260603T041500Z-a1b2c3d4
```

The installed `rmsync-git` wrapper is equivalent to `rmsync git`, so
`rmsync-git push` and `rmsync git push` are the same command.

> ### 🤖 Built with LLM assistance
>
> Almost everything in this repo — Swift source, tests, CI workflows,
> Homebrew formula, this README — was produced through LLM-assisted
> coding. The author directs architecture, reviews every merge, and is
> the responsible party for behavior and licensing, but much of the
> literal text and code (including this paragraph) was drafted by an
> LLM. The `RMScene` target in particular is an LLM-generated Swift
> port of Rick Lupton's Python [rmscene](https://github.com/ricklupton/rmscene).
>
> Practical implications:
>
> - Correctness is defended by the test suite, CI, and `brew audit` —
>   not by intuition. 75+ tests plus a live-cloud smoke test gate the
>   release pipeline.
> - The MIT license and third-party attributions in
>   [LICENSE](LICENSE) / [THIRDPARTY.md](THIRDPARTY.md) apply regardless
>   of authorship source. Derivative-work obligations (Rick Lupton's
>   MIT notice on the rmscene port) are preserved.
> - Bug reports welcome. LLM-assisted code has the same bug distribution
>   as any other code; the surface area and review depth is just
>   different.

---

## Quick start

### Homebrew (recommended)

First install:

```sh
brew install madhavsuresh/rmsync/rmsync
rmapi
rmsync-install-agents
rmsync init
rmsync doctor
rmsync status
```

What each step does:

- `brew install` installs the `rmsync` CLI, the `rmsync-menubar`
  app, `rmapi`, the `rmsync-git` wrapper, and the launchd helper
  commands.
- `rmapi` links this Mac to your reMarkable cloud account. It asks
  for the 8-character pairing code from
  `https://my.remarkable.com/device/desktop/connect`. You do this
  once per Mac; the session is stored under `~/.config/rmapi/`.
- `rmsync-install-agents` writes `~/.config/rmsync/config.toml` if
  it does not exist, creates the state/log/sync directories, and
  starts two launchd agents: the daemon and the menu bar app.
- `rmsync init` verifies local setup and creates the supported
  reMarkable cloud folder, `/sync/notes`, if needed.
- `rmsync doctor` should print all checkmarks. If a line fails, fix
  that line before trying to sync.
- `rmsync status` confirms the daemon is reachable and shows the
  current sync folder, remote folder, tracked docs, conflicts,
  parked errors, last pull/push, and pull availability probe.

After install, the interface has four parts:

| Surface | Use it for | Important boundary |
|---|---|---|
| Sync folder | Edit local Markdown files. Default: `~/rmsync-notes`. | Files do not reach the tablet until you push, unless you explicitly enable safe auto-push. |
| Menu bar | Glanceable state, pull availability, conflicts, parked errors, pause/resume, restart, logs, and config. | It is a status/control surface, not a file browser and not the main sync workflow. |
| CLI | Actual sync commands: `pull`, `diff`, `accept`, `push`, `force-push`, `doctor`, `status`. | Cloud/tablet changes never overwrite local files until you accept them. |
| Web dashboard | Optional browser status page with recent docs, conflicts, and pause/resume. | Pull, accept, push, and force-push stay CLI-only so sync intent is explicit. |

First safe sync loop:

```sh
# Mac -> tablet/cloud
printf "hello from rmsync\n" > ~/rmsync-notes/first-note.md
rmsync push first-note.md

# tablet/cloud -> Mac
rmsync pull
rmsync diff
rmsync accept <path-from-diff>
```

The daemon keeps status, IPC, menu bar, and the optional dashboard
online. It does not silently pull cloud changes, reconcile conflicts,
or propagate deletes in the background.

`brew upgrade rmsync` from then on for new versions.

> **Upgrading from a pre-v0.2.24 install?** `brew upgrade` may fail with
> a conflict on `rmapi`: rmsync v0.2.24 moved to its own pinned `rmapi`
> formula, which conflicts with `io41/tap/rmapi`. Recover with:
>
> ```sh
> brew uninstall --ignore-dependencies io41/tap/rmapi
> brew untap io41/tap
> brew upgrade rmsync
> ```
>
> Your reMarkable cloud auth at `~/.config/rmapi` survives this.

### Docker (Linux / mini-PC)

If you don't have a Mac, run rmsync as a daemon container on any
Linux host. No menubar, but everything else works the same.
**One-liner** that handles everything — checks docker, makes the
volume dirs, writes a compose file with your UID baked in, pulls
the image, starts the container, and prints the auth/init/verify
commands:

```sh
curl -fsSL https://raw.githubusercontent.com/madhavsuresh/rmsync/main/scripts/docker-quickstart.sh | sh
```

Then:

```sh
cd rmsync
docker exec -it rmsync rmapi   # one-time reMarkable auth (interactive)
docker exec rmsync rmsync init
docker exec rmsync rmsync doctor
```

Image (`linux/amd64`) published on every release to
[ghcr.io/madhavsuresh/rmsync](https://github.com/madhavsuresh/rmsync/pkgs/container/rmsync).
arm64 hosts: build locally — `docker build -t rmsync:local .`
(arm64 swift compilation under QEMU emulation is too slow for CI;
native arm64 build is fast). Full guide in
[`docs/DOCKER.md`](docs/DOCKER.md).

### From source

```sh
git clone https://github.com/madhavsuresh/rmsync.git
cd rmsync
./install.sh
```

Three interactive prompts — all safe to hit `y`:

1. Install `rmapi` via Homebrew (or install a verified release binary manually).
2. Authenticate `rmapi` with your reMarkable Connect account (paste an
   8-character code from `https://my.remarkable.com/device/desktop/connect`).
3. Add `~/.local/bin` to your shell's PATH.

Then:

```sh
rmsync init      # create local dir + /sync/notes if needed
rmsync doctor    # verify all 10 checks pass
rmsync status    # see what the daemon is doing
rmsync-git --help # optional wrapper for `rmsync git`
```

Edit files under your sync dir (`~/rmsync-notes` by default), then
run `rmsync push` when you want them on the tablet. Write on the
tablet, let it sync to the cloud, then run `rmsync pull`, `rmsync diff`,
and `rmsync accept` to bring selected changes local. The same interface
model from the Homebrew section applies: sync folder for files, menu
bar for status/control, CLI for sync mutations, optional web dashboard
for browser status.

**For everything else:** [`docs/USAGE.md`](docs/USAGE.md) has the full
operational guide — daily commands, "how do I…" recipes, config
reference, troubleshooting, and rough edges to know about.

---

## Optional features

### 🌐 Web dashboard — browser UI for status / actions

```toml
[web]
enabled    = true
bind_addr  = "127.0.0.1"   # "0.0.0.0" to expose to LAN
port       = 7878
# auth_token = ""          # leave empty → daemon generates one
```

Restart, then open `http://127.0.0.1:7878/?token=...` (the token
is at `$STATE_DIR/web-token` after first start, or whatever you
set in config). Live status, recent docs, conflicts list, and
pause / resume controls. Token-authed; works as a menubar
replacement for Linux/Docker users, or as a parity option for macOS
users who prefer the browser. Pull / accept / push remain CLI-only so
sync intent is explicit.

Full reference for both features in
[`docs/USAGE.md`](docs/USAGE.md) and
[`docs/DOCKER.md`](docs/DOCKER.md).

---

## ⚠️ If your sync folder is inside Dropbox / iCloud / OneDrive / Google Drive

Read this before you set `sync_dir` to a cloud-storage folder. This
has bitten real users (including ours) with real data loss.

macOS File Provider (the kernel shim that Dropbox, iCloud Drive,
OneDrive, Google Drive, and Box all use on modern macOS) can demote
a local file to an **online-only placeholder** when disk is tight.
The filesystem then shows the file at its original logical size but
with zero physical blocks allocated. Reads return empty bytes
without surfacing an error. If rmsync pushed that empty read to the
reMarkable cloud, your doc would be wiped on every device.

**Two independent defenses ship in rmsync** (v0.2.7+):

1. **Push-side guard** (`ExplicitSync.push`). `FileProvider.status(of:)`
   uses `stat()` to detect the dataless signature — `st_size > 0
   && st_blocks == 0` — which is unambiguous on APFS regardless of
   which provider is responsible. If it's dataless and we've
   previously synced non-empty content, the push is refused, a
   banner fires, and the cloud copy is untouched. Re-run
   `rmsync push <path>` after the provider re-materializes the file.

2. **`rmsync doctor` warning.** Path-substring match against known
   File Provider roots. If your `sync_dir` is inside one, doctor
   emits a warn-level line telling you to tick the provider's
   "Always keep on this device" equivalent.

**The provider-level offline setting is not sufficient on its own.**
Dropbox in particular is known to ignore "Always keep on this device"
under disk pressure or across app restarts. The software guards are
there because this is a *product* limitation of the cloud-storage
provider, not something we can fully prevent from our side.

**If you want zero risk**: use a non-cloud sync directory. The
default (`~/rmsync-notes`) is local-only and never triggers any
of this. `rmsync relocate ~/rmsync-notes` moves everything there
in place, no data loss.

**If you want cloud backup of your notes anyway**: keep rmsync's
`sync_dir` local, and point a separate backup tool (Time Machine,
Arq, rclone) at that local dir. That way your notes are backed up
without being subject to File Provider eviction.

---

## What it does (and doesn't)

**Does:**

- Explicitly pushes and pulls one configured cloud folder between the
  tablet cloud and a local folder. The supported ordinary namespace is
  `/sync/notes`.
- Typed-text notebooks round-trip as Markdown.
- Handles conflicts: writes a `.md.conflict` file with git-style
  markers, never silently merges.
- Works from a Dropbox / iCloud / anywhere folder (via `rmsync relocate`).
- Survives reboots, network drops, rmapi throttling, and daemon crashes
  (launchd auto-restarts on crash; Docker compose restarts the container).
- Tags pulled files with Finder/Spotlight metadata so you can see where
  they came from (macOS only).
- **Runs on macOS (menubar) or Linux (Docker, headless)** — same daemon
  binary, same commands, same sync logic. Multi-arch image at
  [`ghcr.io/madhavsuresh/rmsync`](https://github.com/madhavsuresh/rmsync/pkgs/container/rmsync).
- **Optional web dashboard.** Embed an HTTP server in the daemon (off by
  default) for browser-based status / pause UI. Useful for
  Linux/Docker users without a menubar; a parity option for macOS users
  who prefer the browser. Token-authed.
- **Explicit rename / move / delete propagation.** Deletes and path
  changes cross the boundary only when you run the relevant `pull`,
  `accept`, or `push` command. Cloud-side deletes require
  `rmsync accept --include-deletes`; local deletes require
  `rmsync push --include-deletes`.
- **Diagnosable.** `rmsync logs --diagnose` distinguishes "daemon
  never ran" / "crashed pre-logging" / "running but quiet" in one
  command, and `rmsync logs` includes explicit CLI sync operations
  as well as daemon events. `rmsync conflicts --resolve-stale` clears
  stuck conflict markers. `scripts/fresh-install-test.sh`
  wipes-and-reinstalls locally to reproduce fresh-install bugs.

**Doesn't:**

- Handwriting OCR — pen strokes come through as empty Markdown.
- Annotation round-tripping — if you annotate a PDF on the tablet, we
  can't convert those annotations to Markdown.
- Image / drawing round-trip.
- Anything outside the configured cloud folder on your tablet.

---

## Requirements

### macOS install path

- **macOS 13+** on Apple Silicon or Intel.
- **Xcode command-line tools** (`xcode-select --install`). Provides
  Swift 6.0+. If the installer errors "swift not found," run that
  command first.
- **rmapi** — the reMarkable cloud CLI. Pulled in automatically by
  `brew install madhavsuresh/rmsync/rmsync` from this same tap; no
  separate install needed. Manual install (rare):
  ```sh
  brew install madhavsuresh/rmsync/rmapi          # recommended
  # or download a release zip from https://github.com/ddvk/rmapi/releases
  ```
  **Migrating from `io41/tap/rmapi`:** if you installed rmapi from
  the older io41 tap, brew will refuse to install ours alongside.
  Run once:
  ```sh
  brew uninstall io41/tap/rmapi
  brew untap io41/tap
  ```
  Then `brew install madhavsuresh/rmsync/rmsync` (or
  `brew upgrade rmsync`) pulls the version-pinned rmapi we test
  against. **Why not io41 anymore?** The 2026-04 cloud schema-v4
  rollout broke rmapi <0.0.32 with HTTP 400 on every `put`; io41/tap
  stayed pinned at 0.0.29 for weeks. Pulling rmapi from this tap
  cuts the upstream-coordination delay — when ddvk releases a new
  rmapi, our tap auto-opens a bump PR within 24h.

### Linux / Docker install path

- **Docker engine** (with compose plugin) on any Linux host. Tested
  on amd64 + arm64.
- **rmapi** is bundled into the image — no host-side install.
- Legacy inotify watcher settings are still present in config for
  compatibility. Explicit sync does not start a background watcher;
  opt-in `[auto_push]` starts a Markdown-only local watcher/scanner.

### Both paths

- **A reMarkable tablet with cloud sync enabled.** Connect
  subscription is *not* required — free tier works fine.

No Python runtime required. reMarkable's v6 CRDT format is handled by
a native Swift library ([`swift/Sources/RMScene`](swift/Sources/RMScene))
— a port of Rick Lupton's Python
[rmscene](https://github.com/ricklupton/rmscene) (MIT), implemented
in this repo and dual-attributed.

Three Swift packages are fetched from their git repos during the first
build: Apple's `swift-argument-parser`, GRDB, and TOMLDecoder. No
manual action; Swift Package Manager handles it.

---

## Commands

```sh
rmsync start              # start the launchd agent
rmsync stop               # stop it
rmsync restart            # kick the agent (use after config edits or rebuilds)
rmsync status             # current state, tracked docs, last pull/push
rmsync pull               # fetch cloud changes into staging (uses cache)
rmsync pull --full        # bypass cache and re-download every cloud doc
rmsync diff [path]        # review staged cloud changes, or one file diff
rmsync accept <path>      # apply one staged cloud change locally
rmsync accept --all       # apply all staged non-delete changes
rmsync push [path ...]    # push local Markdown changes to cloud
rmsync force-push         # preview replacing cloud state with local tree
rmsync force-push --apply # apply the local-tree overwrite
rmsync init               # create local sync dir + configured cloud folder
rmsync purge              # preview deleting local rmsync files and sync dir
rmsync purge --cloud      # preview also deleting the configured cloud folder
rmsync purge --apply      # apply the local purge
rmsync git init           # optional git-backed sync setup, run in a git repo
rmsync git pull           # optional: import cloud state as a git branch
rmsync git push           # optional: merge HEAD with cloud and upload
rmsync-git push           # same as `rmsync git push`
rmsync auto-push status   # inspect optional safe auto-push attempts
rmsync logs -f            # tail the structured JSON event log
rmsync pause              # set the paused status flag
rmsync resume             # clear the pause flag
rmsync conflicts          # list unresolved conflicts
rmsync doctor             # run all 10 self-checks, exit 1 on failure
rmsync relocate <path>    # move sync dir + rewrite state + update config
rmsync uninstall          # remove the launchd agent (keeps state + config)
```

All `start`/`stop`/`restart` are idempotent.

Full semantics in [`docs/USAGE.md`](docs/USAGE.md).

---

## Configuration

Edit `~/.config/rmsync/config.toml`, then `rmsync restart`. The daemon
reads config once at startup and doesn't watch for changes — restart is
required for any edit to take effect.

**Exception:** don't edit `sync_dir` by hand — use `rmsync relocate`.
It moves the files, rewrites `state.db`'s `local_path` column for every
tracked doc, updates the config, and restarts the agent atomically.
Editing `sync_dir` directly leaves every tracked doc's `local_path`
pointing at the old location, so status, history, trash, and future
explicit sync operations can reason about the wrong files.

Full config reference and behavioural details in `docs/USAGE.md`.

---

## Architecture

```
┌──────────────┐   IPC socket   ┌─────────────────┐
│  rmsync-     │◄──────────────►│  rmsync daemon  │
│  menubar     │                │                 │
│  (launchd)   │                │  status / IPC  │
└──────────────┘                │  dashboard     │
┌──────────────┐   IPC socket   │                 │
│  rmsync CLI  │◄──────────────►│                 │
└──────────────┘                │  state.db       │
                                └─────────────────┘
        │
        │ explicit pull / push via rmapi
        ▼
 reMarkable cloud ◄──────────────► sync_dir/*.md
```

- **Daemon** runs as `com.user.rmsync` under launchd. It keeps IPC,
  dashboard, menu bar state, the optional safe auto-push watcher, and
  a read-only pull availability probe online. It does not run a
  background pull worker, cloud reconciler, or delete propagator.
- **Menu bar app** runs as `com.user.rmsync.menubar`, connects to the
  daemon over a Unix-domain socket, and shows state live.
- **CLI** is the same `rmsync` binary with different subcommands. The
  `pull`, `accept`, and `push` commands perform the actual sync work.
- **State lives in SQLite** at `~/Library/Application Support/rmsync/state.db`.
  Tracks per-doc IDs, page IDs, hashes, timestamps, and a settings
  table (paused flag, stable author UUID).

---

## Layout

```
rmsync/
├── swift/                       Swift Package Manager project
│   ├── Package.swift            3 targets: rmsync, rmsync-menubar (macOS), RMScene
│   ├── Sources/
│   │   ├── rmsync/              daemon + CLI (~6000 LoC, cross-platform)
│   │   │   ├── ExplicitSync.swift staged pull / accept / push workflow
│   │   │   ├── GitSync.swift     optional git-backed sync workflow
│   │   │   ├── Watcher/          opt-in auto-push Markdown watcher
│   │   │   └── Web/              embedded HTTP dashboard (opt-in)
│   │   ├── rmsync-menubar/      menu bar app (macOS-only)
│   │   └── RMScene/             vendored v6 CRDT codec (cross-platform)
│   └── Tests/                   ~110 tests (Swift Testing + XCTest)
│       ├── rmsyncTests/         daemon tests + live-cloud smoke
│       └── RMSceneTests/        50 codec tests w/ real fixtures
├── assets/folder-icon.icns      bundled Finder folder icon (macOS)
├── scripts/                     launchd plist templates + dev helpers + rmsync-git wrapper
├── docker/                      Docker entrypoint + default config
├── Dockerfile                   multi-stage build (swift:6.1-jammy)
├── docker-compose.yml           example single-service compose
├── install.sh                   macOS one-command install (source path)
├── uninstall.sh                 opposite; `--purge` wipes state + config
├── docs/
│   ├── USAGE.md                 ← macOS operational guide
│   ├── DOCKER.md                ← Linux/Docker operational guide
│   ├── LLM_CONTEXT.md           ← single-file context for LLM chats
│   ├── HOMEBREW.md              ← setting up the brew tap
│   └── TESTING.md               ← test infra (offline/live/fresh-install)
├── Formula/rmsync.rb            Homebrew formula
├── .github/workflows/
│   ├── ci.yml                   macOS + Linux build + live-cloud smoke
│   └── release.yml              tag-triggered: GitHub release + brew bump + GHCR
├── CHANGES_FROM_SPEC.md         historical implementation notes
└── README.md                    you are here
```

---

## Testing

```sh
cd swift
swift test                                           # 98 tests, fast
RMSYNC_LIVE=1 PATH="$HOME/bin:$PATH" swift test      # + 2 live-cloud push smoke tests
```

Live tests exercise a real round-trip against the `/rmsync-test`
folder on the author's cloud account; they clean up after themselves.
Set `RMSYNC_LIVE=1` and make sure `rmapi` is authenticated.

---

## License / credits

rmsync itself is **MIT-licensed** — see [LICENSE](LICENSE). Copy it,
fork it, resell it, embed it in anything. The only attribution required
is preserving the MIT copyright notice.

Third-party components each carry their own terms. Full accounting in
[THIRDPARTY.md](THIRDPARTY.md); the short version:

- **`swift/Sources/RMScene/`** — a Swift port of Rick Lupton's Python
  [rmscene](https://github.com/ricklupton/rmscene) (MIT). A language
  port is a derivative work under copyright, so the original MIT
  notice travels with the code alongside the port's own copyright;
  see [`swift/Sources/RMScene/LICENSE`](swift/Sources/RMScene/LICENSE)
  for the dual-attribution text.
- **`swift-argument-parser`** (Apple, Apache-2.0), **`GRDB.swift`**
  (Gwendal Roué, MIT), **`TOMLDecoder`** (Daniel Duan, MIT) — SwiftPM
  dependencies fetched at build time. Not redistributed in source.
- **`rmapi`** — [ddvk/rmapi](https://github.com/ddvk/rmapi) (AGPL-3.0).
  rmsync shells out to it as a separate process; it's a runtime
  dependency installed through this tap (`brew install madhavsuresh/rmsync/rmapi`).
  AGPL-3.0 governs rmapi; it does not reach rmsync, per the standard
  subprocess-aggregation reading. See THIRDPARTY.md for the detailed
  argument.
