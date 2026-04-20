# rmsync

Bidirectional background sync between a reMarkable tablet's `Writing/`
folder and a local Markdown tree on macOS. Edit a note on your Mac, it
appears on the tablet within ~5s. Write on the tablet, it shows up as
Markdown locally within 15–120s. Runs as a launchd LaunchAgent; you
don't have to think about it once it's installed.

**v0.2 — Swift daemon, zero Python runtime.** The v0.1 Python
implementation is archived at `python-legacy.tar.gz`.

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
brew install <you>/rmsync/rmsync
rmapi                           # paste code from remarkable.com/device/desktop/connect
rmsync-install-agents          # boots daemon + menu bar
rmsync doctor                   # should be all ✓
```

### From source

```sh
git clone https://github.com/<you>/rmsync.git
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

## What it does (and doesn't)

**Does:**

- Mirrors `Writing/` (and only `Writing/`) on the tablet to a local folder.
- Typed-text notebooks round-trip as Markdown.
- Handles conflicts: writes a `.md.conflict` file with git-style
  markers, never silently merges.
- Works from a Dropbox / iCloud / anywhere folder (via `rmsync relocate`).
- Survives reboots, network drops, rmapi throttling, and daemon crashes
  (launchd auto-restarts on crash).
- Tags pulled files with Finder/Spotlight metadata so you can see where
  they came from.

**Doesn't:**

- Handwriting OCR — pen strokes come through as empty Markdown.
- Annotation round-tripping — if you annotate a PDF on the tablet, we
  can't convert those annotations to Markdown.
- Image / drawing round-trip.
- Anything outside `Writing/` on your tablet.
- Real-time delete propagation (local deletes are safety-gated; see
  [`docs/USAGE.md`](docs/USAGE.md) "Rough edges").

---

## Requirements

- **macOS 13+** on Apple Silicon or Intel.
- **Xcode command-line tools** (`xcode-select --install`). Provides
  Swift 6.3+. If the installer errors "swift not found," run that
  command first.
- **rmapi** — the reMarkable cloud CLI. The installer offers to fetch
  this automatically (Homebrew preferred, GitHub release binary as
  fallback). Manual:
  ```sh
  brew install io41/tap/rmapi                     # recommended
  # or download from https://github.com/ddvk/rmapi/releases
  ```
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
│   ├── Package.swift            3 targets: rmsync, rmsync-menubar, RMScene
│   ├── Sources/
│   │   ├── rmsync/              daemon + CLI (~5000 LoC)
│   │   ├── rmsync-menubar/      menu bar app (Swift 6, @MainActor)
│   │   └── RMScene/             vendored v6 CRDT codec
│   └── Tests/                   98 tests (Swift Testing + XCTest)
│       ├── rmsyncTests/         daemon tests + live-cloud smoke
│       └── RMSceneTests/        50 codec tests w/ real fixtures
├── assets/folder-icon.icns      bundled Finder folder icon
├── scripts/                     launchd plist templates
├── install.sh                   one-command install
├── uninstall.sh                 opposite; `--purge` wipes state + config
├── docs/
│   ├── USAGE.md                 ← operational guide (read this)
│   ├── LLM_CONTEXT.md           ← single-file context for LLM chats
│   ├── HOMEBREW.md              ← setting up the brew tap
│   └── SWIFT_PORT_PHASE1.md     the port plan we executed
├── Formula/rmsync.rb           Homebrew formula
├── .github/workflows/release.yml  tag-triggered universal build + release
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
