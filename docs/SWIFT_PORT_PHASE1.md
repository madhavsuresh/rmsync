# Phase 1: Swift daemon port (rmscene stays as a Python subprocess)

**Status:** plan — not started.
**Timeline:** 8 working weeks, one engineer.
**Outcome:** A Swift replacement for `rmsync daemon` that drops in as the LaunchAgent. CLI, menu bar, launchd integration, and on-disk state DB stay backward-compatible. Python lives on only as a 60-line CLI bridge around the `rmscene` library.

## Goals

1. A single Swift Package Manager project that builds two executables: `rmsync` (daemon + CLI) and `rmsync-menubar` (existing menu bar app, unchanged interface to IPC).
2. Functional parity with the current Python daemon on every path users care about: pull, push, conflict detection, initial reconcile, startup delete/create reconcile, pause/resume, sync-now, relocate.
3. Same on-disk state format (schema v4+), same IPC protocol, same launchd plist shape, same CLI subcommands, same log format. Users shouldn't notice the swap except for a faster cold start.
4. rmscene isolated behind a single subprocess call. If a native Swift CRDT library ever emerges, that call site becomes the only thing that changes.

## Non-goals (deferred / dropped)

- **Port rmscene to Swift.** Out of scope for Phase 1 entirely. See `docs/RMSCENE_BRIDGE.md` (to be written) for the subprocess contract.
- **Drop rmapi.** We keep shelling out to the Go binary; `Process + Pipe` replaces `asyncio.create_subprocess_exec`.
- **iPad / iOS app.** No cross-platform work; macOS 13+ only.
- **Codesigning, notarization, Developer ID.** Personal use; the launchd agent runs unsigned same as today.
- **New features.** No user-visible behaviour changes in Phase 1. Feature work resumes after the port is green.

## Non-obvious constraints carried over from Python

These are hard-won invariants from the current implementation. They must survive the port.

1. **`page_id` stability across pushes** — every push to the same doc must reuse the same sync15 page UUID, or the tablet accumulates ghost pages. Tracked in `documents.page_ids` (JSON column).
2. **`author_uuid` stability across pushes** — every push from this install must use the same CRDT author UUID, or the tablet interleaves text character-by-character. Tracked in `settings.author_uuid`.
3. **`coverPageNumber: -1`** in `.content` JSON — anything else prepends a blank cover page on the tablet.
4. **sync15 `cPages` shape** in `.content` JSON, not the legacy flat `pages: [id, ...]` — legacy causes the tablet to auto-insert a blank template page.
5. **Atomic write + echo fence** — every local file write goes tmp → `os.replace` → mark fence. The watcher drops events within 5s of a fence mark. Critical to prevent pull-push loops.
6. **Sentinel-for-free-kicks semantics** — `rmapi put --force` updates in place, **not** `--content-only` (that's PDF-only).

All six are covered in `CHANGES_FROM_SPEC.md`. The Swift port must bake them in from day one — they are not documentation, they are live behavioural requirements.

## Target architecture

```
rm/
├── swift/                           ← new
│   ├── Package.swift                (Swift 6.0 tools; strict concurrency)
│   ├── Sources/
│   │   ├── rmsync/                  ← new daemon + CLI
│   │   │   ├── main.swift
│   │   │   ├── CLI/                 (ArgumentParser commands)
│   │   │   ├── Daemon/              (actor-based event loop)
│   │   │   ├── Cloud/               (rmapi wrapper; Process + Pipe)
│   │   │   ├── Conversion/          (rmscene subprocess bridge)
│   │   │   ├── State/               (GRDB; Document Codable)
│   │   │   ├── IPC/                 (Unix socket server)
│   │   │   ├── Watcher/             (FSEventStream)
│   │   │   └── Native/              (xattrs, Finder tag, notifications)
│   │   └── rmsync-menubar/          ← existing, moved from ../menubar/
│   └── Tests/
│       ├── rmsyncTests/
│       └── Fixtures/                (real .rm bytes copied from tests/fixtures)
├── bridge/
│   └── rmscene_bridge.py            ← new: ~60-line stdin/stdout protocol
├── src/rm_sync/                     ← stays during transition; deleted in week 8
├── menubar/                         ← deleted in week 1 (folded into swift/)
└── tests/                           ← Python tests stay until swift/Tests port
```

### rmscene bridge contract (freeze this in week 1)

`bridge/rmscene_bridge.py`: single long-lived subprocess driven from Swift over stdin/stdout. Length-prefixed JSON frames.

Commands:

| Command | Payload | Response |
|---|---|---|
| `parse_page` | `{"rm_bytes_b64": "..."}` | `{"text": "hello\nworld\n"}` or `{"error": "..."}` |
| `render_page` | `{"text": "hello\n", "author_uuid": "UUID"}` | `{"rm_bytes_b64": "..."}` |

That's it. Two operations, JSON, base64 for binary payloads. ~100ms per call; amortized over a pull or push operation, negligible.

Why subprocess instead of FFI: rmscene uses rich Python objects internally; exposing them as a stable C ABI is more work than a line-delimited JSON pipe. Subprocess also lets us kill/restart the bridge cleanly if it wedges, and keeps the Python venv isolated.

## Week-by-week

Each week has a concrete deliverable that can be demoed or unit-tested in isolation.

### Week 1 — Project scaffolding, state DB, Codable types

**Ship:** `swift test` passes against a real `state.db` file migrated from the existing Python schema.

- `swift/Package.swift` with Swift 6.0 tools, strict concurrency, macOS 13+ platform.
- Dependencies: `swift-argument-parser`, `GRDB.swift`.
- Move `menubar/` into `swift/Sources/rmsync-menubar/`. `swift build` the whole tree.
- Write `Document`, `Settings`, `SchemaMigrator` types in `State/`. GRDB records matching every column in schema v4.
- Unit test: open the current user's `state.db`, read all documents, round-trip one back through the Swift types, diff columns. Everything equal.
- Freeze the rmscene bridge JSON contract. Write the Python script, verify a hello-world round-trip.

### Week 2 — Config loader, CLI skeleton, IPC server

**Ship:** `rmsync status` and `rmsync daemon --check` work; `rmsync daemon` starts the IPC server and accepts `get_status` over the socket.

- Port `config.py` as `Config.swift` — reads TOML via `TOMLDecoder` (SPM dep), validates via Swift's type system.
- Port `cli.py` commands as ArgumentParser subcommands: `status`, `pause`, `resume`, `sync-now`, `logs`, `conflicts`, `start`, `stop`, `restart`, `doctor`, `relocate`, `daemon`.
- Implement the IPC server (`IPCServer.swift`) — `Network.framework` **listener** on a Unix socket, one NWConnection per client, accept-side reads from clients. Server-side NWConnection **does** work correctly; the client-side is what had issues (see §"why the server can use NWConnection" below).
- Mirror the existing protocol byte-for-byte: hello on connect, `status` broadcasts, `ack` replies.
- CLI routes through `IPCClient` (reuse the POSIX-socket client code from the menu bar — move it into a shared target).

### Week 3 — Cloud wrapper, rmapi subprocess

**Ship:** `Cloud.tree("/Writing")` returns the same `[Node]` shape the Python version does; `swift run rmsync doctor` passes.

- Port `cloud.py` as `Cloud.swift`. Each method shells `rmapi` via `Process` with `executableURL`, reads stdout/stderr from Pipes, parses the same text/JSON formats.
- Implement the shell-mode driver for `find` / `ls` / `stat` (write commands to stdin, parse the `[d]\t<name>` / `[f]\t<name>` output). Straight translation of `cloud.py:_shell`.
- Port `Node` as a struct with the same fields.
- Port the throttle detection regex. Raise `CloudError.throttled` for HTTP 429/503 signals.
- Doctor subcommand: run the same 10 checks, same exit codes.

### Week 4 — Daemon core, worker, job queue

**Ship:** `rmsync daemon` pulls the current contents of `/Writing` into the sync dir, writes the same xattrs, respects the state DB. No push yet.

- Actor-based architecture: `DaemonActor` owns config, state, cloud, fence, lock registry, job queue. Workers are `Task` pool consuming from an `AsyncChannel` (swift-async-algorithms).
- Port `worker.py:_pull` — download via cloud, unpack `.rmdoc`, call rmscene bridge per page, join with page-break sentinel, atomic-write, apply xattrs, stamp fence, upsert state.
- Port `archive.py:unpack` — we own the zip parsing (both legacy and sync15 `cPages` shapes).
- Port `page_splitter.py` — HTML-comment page break sentinel.
- Port `conflict.py:write_conflict` — generate git-style markers.
- Port `echo_fence.py` — dict keyed by path, TTL via `Date()`.
- Port `locks.py` — `[String: AsyncSemaphore]` keyed by doc_id.

### Week 5 — Push path, rmapi put --force, page-id and author-uuid invariants

**Ship:** `rmsync daemon` round-trips a local edit to the cloud; tablet sees clean replacement (no blank cover page, no character interleave, no ghost pages).

- Port `worker.py:_push`. Same sequence: hash check, refuse UUID-named new docs, split pages, render per page via rmscene bridge using the **persisted author UUID**, pack `.rmdoc` reusing the **persisted page UUIDs** (extending only when the page count grows), `rmapi put --force`, restat for `ModifiedClient`.
- Port `archive.py:pack` with the sync15 `cPages` shape and `coverPageNumber: -1`.
- Port `md_to_rm.page_native_plain` as a thin wrapper over `RmsceneBridge.renderPage(text:authorUUID:)`.
- Strategy B and PDF stay stubs (they're stubbed in Python too).
- End-to-end test: push, pull back, assert the round-tripped `.md` matches the input.

### Week 6 — Watcher, poller, startup reconcile

**Ship:** Full daemon behavior. Runs unattended. Everything the current Python daemon does.

- Port `watcher.py` as `LocalWatcher` using `FSEventStreamCreate` + run loop bridge, or `DispatchSource.makeFileSystemObjectSource` per directory. Events coalesced to an `AsyncStream<FSEvent>`.
- Preserve the `_should_ignore` ruleset exactly: `.DS_Store`, hidden dirs, `.tmp`, `.conflict`, `Icon\r`, `"conflicted copy"` (Dropbox).
- Port the debounce (2s per-path timer, resettable) and the rename-detect window.
- Port `poller.py` — same adaptive interval (15/30/120s), same `request_cycle()` API the IPC `sync_now` handler calls.
- Port the three startup reconciles from `daemon.py`:
  - local deletions → cloud trash
  - initial cloud walk → pull everything
  - local-only / locally-edited files → push
- Pause semantics: poller and workers check `state.isPaused()` at the top of each cycle, same as today.

### Week 7 — Native macOS polish, relocate, installer

**Ship:** Feature parity with current Python daemon. `install.sh` switches over to the Swift binary.

- Port `native/macos.py` to `Native/Xattrs.swift` + `Native/FolderIcon.swift` + `Native/Notifications.swift`. Foundation has `URL.setExtendedAttribute(_:forName:)` now (macOS 13+) — no need for `ctypes` dance.
- Port the `relocate` subcommand exactly: stop agent, move tree, rewrite `local_path` prefixes in state DB, edit `config.toml` in place, restart agent. Retries on launchctl bootstrap same as Python.
- Update `install.sh`: `swift build -c release`, drop the binary into `~/.local/bin/rmsync` or `/usr/local/bin/rmsync`, install both plists. Remove the `__PYTHON_BIN__` substitution.
- Update plist template to launch the Swift binary directly.

### Week 8 — Cutover, tests, docs

**Ship:** Python code deleted, all tests passing, README reflects Swift-only reality.

- Port the critical Python tests:
  - `test_state.py` → `StateTests` in GRDB
  - `test_conflict.py` → `ConflictTests`
  - `test_echo_fence.py` → `EchoFenceTests`
  - `test_watcher_ignore.py` → `WatcherIgnoreTests`
  - `test_paths.py` → `PathsTests`
  - `test_ipc.py` → `IPCTests`
  - `test_archive.py` → `ArchiveTests` (including the `coverPageNumber: -1` regression)
  - `test_native_macos.py` → `NativeTests`
  - `test_relocate.py` → `RelocateTests`
  - `test_md_to_rm_roundtrip.py` → **stays as a Python test** against the rmscene bridge. Swift test shells out to `python3 -m pytest bridge/tests` as part of `swift test`.
- Soak test: 24 hours of real usage, watch the logs for anything new or missing.
- Delete `src/rm_sync/`, `pyproject.toml`, `.venv/`. Keep `bridge/` for rmscene.
- Update `README.md` — installation, build, day-to-day commands. The `rmsync` binary name becomes just `rmsync` (no hyphen) to reflect it's a different implementation; CLI compatibility otherwise preserved. Alias `rmsync` for back-compat if wanted.
- Update `CHANGES_FROM_SPEC.md` with a header noting this is now the historic record from the Python version; new invariants get a new doc.

## Dependencies (Swift Package Manager)

| Package | Purpose | Alternative |
|---|---|---|
| [apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI subcommands | — |
| [groue/GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite + Codable | SQLite.swift (lighter but less Codable integration) |
| [apple/swift-async-algorithms](https://github.com/apple/swift-async-algorithms) | `AsyncChannel`, `debounce` | roll our own with `AsyncStream` |
| [JohnSundell/ShellOut](https://github.com/JohnSundell/ShellOut) | optional convenience over `Process` | skip; use `Process + Pipe` directly |
| [dduan/TOMLDecoder](https://github.com/dduan/TOMLDecoder) | TOML → Codable | parse manually (trivial for our 10-key config) |

No SwiftNIO. No Network.framework for the client side of IPC (keep the POSIX approach that works). Network.framework listener for the server side is fine.

### Why the server can use NWConnection even though the client can't

The issue we hit was NWConnection on the **client** side receiving spurious `isComplete=true` when connecting to a Unix socket — TCP-closure semantics leaking into an AF_UNIX connection. The server-side `NWListener` accepting Unix-socket connections doesn't have the same pattern in community reports. But for simplicity and parity with what we know works, the Swift daemon's server-side will also be POSIX + DispatchSource — same 80 lines of code we already have, just running on the other end.

## What gets deleted at the end

- `src/rm_sync/` (entire directory, ~4,200 LoC Python)
- `pyproject.toml`, `.venv/`
- `menubar/` (moved into `swift/Sources/rmsync-menubar/`)
- `tests/` (Python tests — replaced by `swift test`; the rmscene round-trip test moves to `bridge/tests/`)

What stays:
- `bridge/` (the 60-line Python rmscene wrapper + its rmscene dependency)
- `assets/folder-icon.icns`
- `scripts/com.user.rmsync*.plist.template`
- `CHANGES_FROM_SPEC.md`, `README.md`, `install.sh`, `uninstall.sh`
- This document

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| rmscene bridge IPC overhead shows up in real use | Low | Low | Reuse the same subprocess across pages in a single pull/push (persistent bridge, not fork-per-call) |
| FSEventStream ordering differs from watchdog | Medium | Medium | Port `test_watcher_ignore.py` early; fall back to `DispatchSource.makeFileSystemObjectSource` per dir if needed |
| GRDB schema migration breaks on real user DBs | Low | High | Copy the live `state.db` to a test fixture before week 1 ends; add a migration smoke test to CI |
| Swift `Process` inherits behavior quirks different from `asyncio.create_subprocess_exec` (env, signal, stdin buffering) | Medium | Medium | Week 3 integration test against real rmapi — fail fast if a surprise shows up |
| Strict concurrency reveals data races in the current daemon design | Medium | Low | Port is a rewrite, not a transliteration; re-architect around actors where needed |
| 8 weeks slips | Medium | — | Weeks 1–6 are load-bearing; 7 and 8 are polish and can be truncated if needed |

## Success criteria for shipping Phase 1

1. `rmsync doctor` exits 0 against the real cloud.
2. Initial pull of the user's current `/Writing` folder produces byte-identical `.md` content to the Python daemon's output (diff every file).
3. A push from Swift daemon produces the same bytes on the cloud (re-stat, compare `ModifiedClient`, download, compare `.md` round-trip) as a push from Python would.
4. `rmsync pause` / `resume` round-trip < 200ms (IPC latency target, same as Python).
5. `launchctl bootstrap` the Swift agent, let it run 48h, no orphan push/pull jobs, no growth in cloud `cPages` entries, no "conflict" false positives, steady memory (< 150 MB RSS, same as Python target).
6. Menu bar works unchanged.

## Rough cost / payoff

- **Cost:** 8 weeks of engineering time.
- **Payoff:**
  - Faster cold start on launchd (Python interpreter boot + rmscene import is ~0.5–1s; Swift is instant).
  - Better integration with macOS logging (os.Logger → Console.app filtering).
  - One toolchain. The menu bar and daemon share types, share IPC code.
  - Actors give us compile-time guarantees we currently get from asyncio discipline.
  - Path to iPadOS if someone ever wants it (rmscene would become the block again, but at least the daemon isn't).
- **Break-even:** immediate if the Python interpreter startup ever becomes a UX issue; otherwise 6–12 months of saved maintenance headaches.

## What we need to decide before starting

1. Binary name: `rmsync` (new) or keep `rmsync` (alias)?
2. Single executable (daemon + CLI in one binary, subcommand dispatch) or two (`rmsync-daemon`, `rmsync`)?
3. Do we want strict concurrency on from week 1 (more typing upfront, more safety) or defer until week 6 (move faster early, refactor later)?
4. Does the menu bar app stay in `menubar/` or migrate into the new `swift/` package structure?

None of these are blockers, but it's cheaper to answer before the scaffolding lands in week 1 than after.
