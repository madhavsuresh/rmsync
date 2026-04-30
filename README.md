# rmsync

Bidirectional background sync between a reMarkable tablet's `Writing/`
folder and a local Markdown tree on macOS. Edit a note on your Mac, it
appears on the tablet within ~5s. Write on the tablet, it shows up as
Markdown locally within 15–120s. Runs as a launchd LaunchAgent; you
don't have to think about it once it's installed.

**v0.2 — Swift daemon, zero Python runtime.** The v0.1 Python
implementation is archived at `python-legacy.tar.gz`.

---

## Quick use

Once installed (see [Quick start](#quick-start) below):

```sh
# everyday — usually all you ever need
rmsync status                        # is the daemon healthy? what's queued?
rmsync doctor                        # full self-check (10 items)
rmsync sync-now                      # force an immediate cycle
rmsync logs --tail                   # follow the daemon log
rmsync conflicts                     # list any unresolved .md.conflict files

# pause / resume — useful before bulk-editing a tree
rmsync pause
rmsync resume

# move the sync dir without losing state
rmsync relocate ~/path/to/new/dir
```

**Just edit Markdown files under your sync dir** (`~/rmsync-writing`
by default). Pushes happen ~5s after you save; pulls land within
15–120s after a tablet edit. The menu bar icon (macOS) or web
dashboard (`[web] enabled = true`) shows live status.

**v0.2.19 — rename / move / delete propagation (opt-in).** Add
this block to `~/.config/rmsync/config.toml` and `rmsync restart`:

```toml
[deletion]
enable_propagation         = true   # off by default — opt in
trash_retention_days       = 30     # 0 keeps trash forever
bulk_delete_threshold      = 0.5    # >50% of tracked → refuse
bulk_delete_window_seconds = 30
```

With propagation on, all four directions sync:

- **Local delete → cloud trash.** `rm hello.md` parks the file in
  `<sync_dir>/.rmsync-trash/<utc-stamp>/` and moves the cloud doc
  to the reMarkable cloud's trash.
- **Cloud delete → local trash.** Deleting on the tablet drops the
  local file into `.rmsync-trash/` on the next poll.
- **Local rename → cloud rename.** `mv old.md new.md` calls
  `rmapi mv` to match.
- **Cloud rename → local rename.** Renaming on the tablet moves
  the local file to match.

Recovery and inspection:

```sh
rmsync trash list                    # everything currently parked
rmsync trash restore "old/note.md"   # put one file back
rmsync trash restore --all           # bulk restore
rmsync trash prune                   # drop entries past retention
```

A bulk-delete brake refuses any operation that would remove more
than `bulk_delete_threshold` of tracked docs in
`bulk_delete_window_seconds` — caps the blast radius of an
accidental `rm -rf`. Refused deletes show up as
`error_state = "bulk_delete_refused"` in `rmsync status` and the
web dashboard.

If you'd rather keep the v0.2.18 behavior (local delete logs but
doesn't propagate), leave the `[deletion]` block out — the
default is `enable_propagation = false`.

Full guide: [`docs/USAGE.md`](docs/USAGE.md) → "Rename / move /
delete propagation is opt-in".

**v0.2.22 — folder structure mirrors both ways.** Subdirectories
under `sync_dir` propagate to the cloud as folders, and vice
versa. `mkdir <sync_dir>/papers/2026/` creates `/Writing/papers/
2026/` on the cloud; saving `<sync_dir>/papers/2026/foo.md`
lands the doc inside that cloud folder rather than flat at the
top. Empty cloud folders (created on the tablet) get mirrored
locally on the next poll cycle. mkdir is always-on (non-
destructive); `rmdir` of an empty local folder propagates only
when `[deletion] enable_propagation = true` and the cloud
folder is verified empty (so a half-cascaded delete burst can't
accidentally trash docs).

**v0.2.20 — snapshot history (always on).** Every push and every
cloud-pull-overwrite parks a copy of the file at
`<stateDir>/backups/<doc-id>/<utc-stamp>.md` so you can always
roll back. Default 30 snapshots per doc; configurable via
`backup_snapshots_to_keep`. No setup required — it's already
running.

```sh
# what saves do I have for this draft?
rmsync history list ~/rmsync-writing/Chapter-3.md

# what changed since the last save?
rmsync history diff ~/rmsync-writing/Chapter-3.md

# revert to an earlier version (current goes to .rmsync-trash/,
# daemon immediately pushes the reverted content to the cloud)
rmsync history restore ~/rmsync-writing/Chapter-3.md \
    --to 2026-04-29T22:14:08Z
```

`history list` is newest-first with a word-count delta column so
you can spot the save where you accidentally cut a paragraph.
`history diff` shells to POSIX `diff -u` (pipes cleanly to
`delta` / `less`). `history restore` parks the current file in
trash before overwriting, so a mistaken restore is itself
recoverable via `rmsync trash restore`.

---

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

```sh
brew install madhavsuresh/rmsync/rmsync
rmapi                           # paste code from remarkable.com/device/desktop/connect
rmsync-install-agents           # seeds default config + boots daemon + menu bar
rmsync doctor                   # should be all ✓
```

`brew upgrade rmsync` from then on for new versions.

### Docker (Linux / mini-PC)

If you don't have a Mac, run rmsync as a daemon container on any
Linux host. No menubar, but everything else works the same.
**One-liner** that handles everything — checks docker, makes the
volume dirs, writes a compose file with your UID baked in, pulls
the image, starts the container, and prints the auth command:

```sh
curl -fsSL https://raw.githubusercontent.com/madhavsuresh/rmsync/main/scripts/docker-quickstart.sh | sh
```

Then:

```sh
cd rmsync
docker exec -it rmsync rmapi   # one-time reMarkable auth (interactive)
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
rmsync doctor    # verify all 10 checks pass
rmsync status    # see what the daemon is doing
```

Edit files under your sync dir (`~/rmsync-writing` by default) and
they'll push to the tablet. Write on the tablet and they'll appear
locally. The menu bar icon tells you at a glance what state the sync
is in.

**For everything else:** [`docs/USAGE.md`](docs/USAGE.md) has the full
operational guide — daily commands, "how do I…" recipes, config
reference, troubleshooting, and rough edges to know about.

---

## Optional features (off by default)

Both are turned on by adding a small block to `config.toml` and
restarting the daemon. Existing installs are unaffected until you
opt in.

### 📥 Inbox folder — drag PDFs / EPUBs to send to the tablet

```toml
[inbox]
local_dir         = "~/rmsync-writing/_inbox"   # any path
remote_folder     = "Inbox"
delete_after_push = true                         # set false to keep a copy
```

Drop a `.pdf` or `.epub` into `local_dir`. Within ~5 seconds the
daemon pushes it to `Inbox/` on your reMarkable cloud and removes
the local file. No email, no rmapi-by-hand. Watcher reuses the
same FSEvents (macOS) / inotify (Linux) code path as the main
sync, just with a `.inbox` mode that filters to PDF/EPUB and
emits a one-way push job.

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
sync-now / pause / resume buttons. Token-authed; works as a
menubar replacement for Linux/Docker users, or as a parity
option for macOS users who prefer the browser.

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

1. **Push-side guard** (`SyncWorker.doPush`). `FileProvider.status(of:)`
   uses `stat()` to detect the dataless signature — `st_size > 0
   && st_blocks == 0` — which is unambiguous on APFS regardless of
   which provider is responsible. If it's dataless and we've
   previously synced non-empty content, the push is refused, a
   banner fires, and the cloud copy is untouched. The push
   automatically resumes once the provider re-materializes the file.

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
default (`~/rmsync-writing`) is local-only and never triggers any
of this. `rmsync relocate ~/rmsync-writing` moves everything there
in place, no data loss.

**If you want cloud backup of your notes anyway**: keep rmsync's
`sync_dir` local, and point a separate backup tool (Time Machine,
Arq, rclone) at that local dir. That way your notes are backed up
without being subject to File Provider eviction.

---

## What it does (and doesn't)

**Does:**

- Mirrors `Writing/` (and only `Writing/`) on the tablet to a local folder.
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
- **Inbox folder for sending PDFs / EPUBs to the tablet.** Drop a file
  into a configured directory; daemon pushes it to the cloud and
  removes the local copy. Closes the "send paper to tablet" loop. Opt-in
  via `[inbox]` in config.toml.
- **Optional web dashboard.** Embed an HTTP server in the daemon (off by
  default) for a browser-based status / sync-now / pause UI. Useful for
  Linux/Docker users without a menubar; a parity option for macOS users
  who prefer the browser. Token-authed.
- **Optional rename / move / delete propagation (v0.2.19+).** Opt in
  via `[deletion] enable_propagation = true` and the daemon mirrors
  deletes and renames in both directions, with soft-delete into
  `<sync_dir>/.rmsync-trash/` and a bulk-delete brake. `rmsync
  trash list / restore` recovers; default 30-day retention auto-prunes.
- **Diagnosable.** `rmsync logs --diagnose` distinguishes "daemon
  never ran" / "crashed pre-logging" / "running but quiet" in one
  command. `rmsync conflicts --resolve-stale` clears stuck conflict
  markers. `scripts/fresh-install-test.sh` wipes-and-reinstalls
  locally to reproduce fresh-install bugs.

**Doesn't:**

- Handwriting OCR — pen strokes come through as empty Markdown.
- Annotation round-tripping — if you annotate a PDF on the tablet, we
  can't convert those annotations to Markdown.
- Image / drawing round-trip.
- Anything outside `Writing/` on your tablet.
- Propagate deletes / renames *by default*. The `[deletion]` block
  above turns it on; without it, local deletes are logged but don't
  touch the cloud — same behavior as v0.2.18 and earlier.

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
- For large sync trees (>5000 subdirs): bump
  `fs.inotify.max_user_watches` on the host. Default 8192 is enough
  for typical use.

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
rmsync logs -f            # tail the structured JSON log
rmsync pause              # suspend syncing (persists across restarts)
rmsync resume             # clear the pause flag
rmsync sync-now           # force an immediate poll cycle
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
pointing at a missing location, which the daemon interprets as "user
deleted everything" on next startup.

Full config reference and behavioural details in `docs/USAGE.md`.

---

## Architecture

```
┌──────────────┐   IPC socket   ┌─────────────────┐
│  rmsync-     │◄──────────────►│  rmsync daemon  │
│  menubar     │                │                 │
│  (launchd)   │                │  ┌────────────┐ │
└──────────────┘                │  │ workers×3  │ │       rmapi
                                │  │ poller     │─┼──────────────► reMarkable
┌──────────────┐   IPC socket   │  │ watcher    │ │                cloud
│  rmsync CLI  │◄──────────────►│  └────────────┘ │
└──────────────┘                │  state.db       │
                                └─────────────────┘
                                       ▲
                                       │ FSEvents
                                       │
                                 ┌─────┴──────┐
                                 │ sync_dir/  │       (e.g. ~/Dropbox/reMarkable)
                                 │   *.md     │
                                 └────────────┘
```

- **Daemon** runs as `com.user.rmsync` under launchd. Watches the sync
  dir via FSEventStream; polls the cloud via rmapi on an adaptive
  schedule (15s active / 30s default / 120s idle).
- **Menu bar app** runs as `com.user.rmsync.menubar`, connects to the
  daemon over a Unix-domain socket, and shows state live.
- **CLI** is the same `rmsync` binary with different subcommands;
  talks to the daemon over the same socket, or falls back to reading
  `state.db` directly when the daemon is down.
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
│   │   │   ├── Watcher/          FSEvents (macOS) + inotify (Linux); shared
│   │   │   │                       filter handles markdown + inbox modes
│   │   │   └── Web/              embedded HTTP dashboard (opt-in)
│   │   ├── rmsync-menubar/      menu bar app (macOS-only)
│   │   └── RMScene/             vendored v6 CRDT codec (cross-platform)
│   └── Tests/                   ~110 tests (Swift Testing + XCTest)
│       ├── rmsyncTests/         daemon tests + live-cloud smoke
│       └── RMSceneTests/        50 codec tests w/ real fixtures
├── assets/folder-icon.icns      bundled Finder folder icon (macOS)
├── scripts/                     launchd plist templates + dev helpers
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
│   ├── TESTING.md               ← test infra (offline/live/fresh-install)
│   └── SWIFT_PORT_PHASE1.md     the port plan we executed
├── Formula/rmsync.rb            Homebrew formula
├── .github/workflows/
│   ├── ci.yml                   macOS + Linux build + live-cloud smoke
│   └── release.yml              tag-triggered: GitHub release + brew bump + GHCR
├── CHANGES_FROM_SPEC.md         invariants from the Python v0.1
├── README.md                    you are here
└── python-legacy.tar.gz         v0.1 archive (safe to delete)
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
  dependency that users install themselves (`brew install io41/tap/rmapi`).
  AGPL-3.0 governs rmapi; it does not reach rmsync, per the standard
  subprocess-aggregation reading. See THIRDPARTY.md for the detailed
  argument.
