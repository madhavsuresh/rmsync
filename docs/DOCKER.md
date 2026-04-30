# Running rmsync on Linux via Docker

The original rmsync ships as a macOS daemon + menubar app via
Homebrew. This document covers the Docker / Linux deployment for
users without a Mac (typical setup: a small always-on Linux box,
a NAS, or a homelab mini-PC) who want their reMarkable cloud notes
synced to a local filesystem.

The Linux container omits the menubar (no GUI session) and relies
on the container runtime for daemon supervision (no launchd). The
daemon, IPC socket, state DB, and sync workflow are otherwise
identical to the macOS build.

---

## Quick start (one-liner)

Prereqs: Docker engine + compose plugin on a Linux host, and a
reMarkable cloud account (free tier is enough).

```sh
curl -fsSL https://raw.githubusercontent.com/madhavsuresh/rmsync/main/scripts/docker-quickstart.sh | sh
```

That script:

1. Verifies docker + compose are installed and the daemon is reachable.
2. Creates `./rmsync/data/{config,state,sync}` (or pass a custom path).
3. Writes a `docker-compose.yml` with **your host user's UID:GID
   baked in** so synced files belong to you, not root.
4. `docker compose pull && up -d`.
5. Prints exactly the next command to run for one-time rmapi auth.

After it finishes, follow the printed instructions:

```sh
cd rmsync
docker exec -it rmsync rmapi              # interactive auth
docker exec rmsync rmsync doctor          # verify
```

If `doctor` is all ✓, you're done. The daemon is syncing.

### Quick start (manual, if you don't trust curl|sh)

The same steps spelled out:

```sh
mkdir -p data/{config,state,sync}
curl -fsSL -o docker-compose.yml \
    https://raw.githubusercontent.com/madhavsuresh/rmsync/main/docker-compose.yml

# Optional but recommended: uncomment the user: line in
# docker-compose.yml and set it to your UID:GID:
sed -i "s|# user: \"1000:1000\"|user: \"$(id -u):$(id -g)\"|" docker-compose.yml

docker compose up -d
docker exec -it rmsync rmapi              # interactive auth
docker exec rmsync rmsync doctor
```

---

## Volume layout

| Mount | Contents | Why |
|---|---|---|
| `/config` | `config.toml`, `rmapi.conf`, optional `rmapi/` dir | One-time setup; survives container restarts and image upgrades. |
| `/state` | `state.db`, `ipc.sock`, `status.json` | Daemon-private. Don't edit by hand. |
| `/sync` | Your reMarkable Markdown tree | What you sync. Bind-mount to wherever you want the notes to live on the host. |

The entrypoint seeds `/config/config.toml` from a default
template if missing — `sync_dir = "/sync"` and sensible defaults.
You can edit it any time and `docker compose restart rmsync` to
pick up the new values.

---

## Editing on the host

The point of running rmsync on a Linux box is so you can edit the
synced Markdown from your normal editor without Docker getting in
the way. The host's view of `./data/sync/` is the same files the
daemon sees at `/sync/`. Save a `.md`, the daemon's inotify
watcher fires within a few hundred ms, the file pushes to your
reMarkable cloud, and the change shows up on the tablet next sync.

### File ownership

By default the container runs as root, so files written by the
daemon land owned by `root:root`. Most editors don't care, but if
you want files to be owned by your host user, uncomment the
`user:` line in `docker-compose.yml` and set it to your
`id -u:id -g`. The entrypoint and daemon respect any UID.

### inotify watch limit

The Linux kernel caps inotify watches per user at 8192 by
default. If your `sync_dir` has more than ~5000 subdirectories,
you'll exhaust the limit and silently miss events on later
subdirectories. Fix on the host:

```sh
echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/99-inotify.conf
sudo sysctl --system
```

The daemon logs a warning at startup if it's already using >50%
of the kernel default; check `docker logs rmsync | grep watch`.

---

## Web dashboard

Optional embedded HTTP dashboard. Replaces the menubar that
Linux users don't have — shows tracked docs, conflicts, recent
push/pull activity, and exposes manual sync-now / pause / resume
buttons.

Enable in `data/config/config.toml`:

```toml
[web]
enabled   = true
bind_addr = "0.0.0.0"   # 127.0.0.1 for localhost-only; 0.0.0.0 for LAN
port      = 7878
# auth_token = "..."    # optional; if unset, daemon generates one
```

Then bind-mount the port and restart:

```yaml
# docker-compose.yml
services:
  rmsync:
    # ... existing config ...
    ports:
      - "7878:7878"
```

```sh
docker compose up -d
# Read the auto-generated token (only needed if auth_token wasn't set):
docker exec rmsync cat /state/web-token
# Open the URL with ?token=... appended:
#   http://localhost:7878/?token=rmsync-XXXXXXXX-...
```

The browser stores the token in localStorage on first load, so
subsequent visits don't need the query string.

**Security:** `bind_addr = "0.0.0.0"` makes the dashboard
reachable from anywhere on the host's network. The token gates
all `/api/*` endpoints, but for a non-localhost binding you
should also be on a trusted LAN. For "just me on my mini-PC,"
either localhost-only or with the LAN-trusted token is fine.

The dashboard URL also works on the same host without ports
exposed:

```sh
docker exec rmsync curl -s http://localhost:7878/api/status \
    -H "Authorization: Bearer $(docker exec rmsync cat /state/web-token)"
```

## Send PDFs / EPUBs to the tablet (inbox)

Drop a `.pdf` or `.epub` into a configured "inbox" folder; the
daemon pushes it to a cloud folder and (by default) removes it
from local. Useful for "I read this on the tablet" workflows
where you don't want the file round-tripping back as Markdown.

To enable, edit `data/config/config.toml` and add:

```toml
[inbox]
local_dir         = "/sync/_inbox"   # any path inside /sync (or bind-mount another)
remote_folder     = "Inbox"
delete_after_push = true             # set false to keep a copy locally
```

Then restart: `docker compose restart`. The daemon creates the
`_inbox` directory if missing and starts watching for drops.
Workflow:

```sh
# On the host:
cp ~/Downloads/some-paper.pdf data/sync/_inbox/
# Within ~5 seconds (debounce + push), the daemon logs:
#   inbox push starting        path=/sync/_inbox/some-paper.pdf
#   inbox push complete; local removed
# The PDF appears in /Inbox/ on your reMarkable tablet on next sync.
```

Non-`.pdf`/`.epub` files in the inbox dir are ignored with a one-
time warning. Multiple drops in quick succession are debounced
and processed serially.

## Rename / move / delete propagation (opt-in)

Off by default for safety. When enabled, deletes and renames in
the sync dir or on the tablet propagate to the other side. Local
files are soft-deleted into `<sync_dir>/.rmsync-trash/<utc-stamp>/`
first; recovery via `rmsync trash list / restore`. A bulk-delete
brake refuses operations that would remove more than
`bulk_delete_threshold` of tracked docs in
`bulk_delete_window_seconds` — caps the blast radius of a runaway
event storm or accidental `rm -rf`.

Enable in `data/config/config.toml`:

```toml
[deletion]
enable_propagation         = true
trash_retention_days       = 30      # 0 keeps trash forever
bulk_delete_threshold      = 0.5     # >50% of tracked → refuse
bulk_delete_window_seconds = 30
```

Then `docker compose restart rmsync`. Recovery commands:

```sh
docker exec rmsync rmsync trash list
docker exec rmsync rmsync trash restore "old/note.md"
docker exec rmsync rmsync trash restore --all
docker exec rmsync rmsync trash prune          # one-shot manual prune
docker exec rmsync rmsync trash prune --days 7 # one-off override
```

Trash auto-prunes at daemon startup. Refused deletes show up as
`error_state = "bulk_delete_refused"` in `rmsync status` and the
web dashboard.

## Snapshot history (always on)

Every push and every cloud-pull-overwrite parks a copy of the
file at `/state/backups/<doc-id>/<utc-stamp>.md`. v0.2.20+. No
config required — it's running by default. Retention via
`backup_snapshots_to_keep` (default 30).

```sh
docker exec rmsync rmsync history list /sync/Chapter-3.md
docker exec rmsync rmsync history diff /sync/Chapter-3.md
docker exec rmsync rmsync history restore /sync/Chapter-3.md \
    --to 2026-04-29T22:14:08Z
```

`history restore` parks the current file in the trash before
overwriting and asks the daemon to push the reverted content
immediately (via the `push_path` IPC verb). If you bind-mount
the `/state` volume, snapshot history survives container
restarts — same persistence story as `state.db`.

## Operational commands

All `rmsync` subcommands work via `docker exec` against the
running container, talking to the daemon over the IPC socket
that lives in `/state/ipc.sock`:

```sh
docker exec rmsync rmsync status
docker exec rmsync rmsync doctor
docker exec rmsync rmsync sync-now           # force immediate poll
docker exec rmsync rmsync conflicts          # list unresolved
docker exec rmsync rmsync conflicts --resolve-stale
docker exec rmsync rmsync logs --diagnose    # print log paths + tail
docker exec rmsync rmsync pause / resume     # toggle sync
```

`rmsync start / stop / restart` are not applicable in Docker —
those are launchd / agent-lifecycle commands. The container
runtime owns the daemon's lifecycle:

```sh
docker compose restart rmsync   # graceful restart
docker compose stop rmsync      # stop without removing the container
docker compose down             # stop + remove
docker compose pull             # check for image updates
docker compose up -d            # bring back up
```

`rmsync relocate` is also not applicable — edit `sync_dir` in
`/config/config.toml` directly and `docker compose restart` to
pick it up. (Or change the bind-mount target in
`docker-compose.yml`.)

---

## Logs

Two equivalent paths:

```sh
docker logs -f rmsync                          # raw, container-runtime view
docker exec rmsync rmsync logs --diagnose      # structured + interpretation
```

The daemon writes structured JSON to stderr, which docker
captures. There's no separate `~/Library/Logs/rmsync/stdout.log`
inside the container the way there is on macOS.

---

## Upgrading

```sh
docker compose pull
docker compose up -d
```

The image's published `:latest` tag tracks the most recent
release. To pin to a specific version:

```yaml
services:
  rmsync:
    image: ghcr.io/madhavsuresh/rmsync:v0.2.13
```

---

## Limitations vs the macOS build

- **No menubar / GUI**. Headless service.
- **No Finder integration**. Pulled `.md` files don't get
  Spotlight metadata, custom folder icons, or Finder color
  tags — those are macOS-only.
- **No File Provider eviction guard**. Linux has no equivalent
  to the macOS dataless-placeholder concept. If you bind-mount a
  cloud-synced directory (e.g. an rclone mount, an SMB share),
  unreliable underlying storage can still cause issues.
- **No notifications**. Conflict / error events go to the
  structured log instead of a desktop banner.
- **inotify, not FSEvents**. Slightly different event model —
  rename detection uses cookie pairing with a 0.5s grace window
  rather than FSEvents' renamed-flag bit. End-to-end behavior is
  the same.

---

## Building the image yourself

If you'd rather not pull from `ghcr.io`, or you need an arm64 image
(the published one is amd64-only — see "Architecture support"
below):

```sh
git clone https://github.com/madhavsuresh/rmsync.git
cd rmsync
docker build -t rmsync:local .
# Then in docker-compose.yml, replace the image: line with image: rmsync:local
```

The build takes ~5 minutes on a native-arch host (Swift toolchain
compiling release-mode rmsync from source, plus rmapi download).
On Apple Silicon: building an arm64 image natively is fast.

For a multi-arch build (cross-arch via QEMU is slow — 30+ min for
arm64-on-x86):

```sh
docker buildx build --platform linux/amd64,linux/arm64 -t rmsync:local .
```

## Architecture support

The published `ghcr.io/madhavsuresh/rmsync` image is currently
`linux/amd64` only. arm64 was attempted in CI but Swift compilation
under QEMU x86→arm64 emulation didn't finish in a reasonable time
(>1 hour), so the release workflow ships amd64 first.

If you're on an arm64 Linux host (Raspberry Pi 4/5, AWS Graviton,
arm-based mini-PC, Apple Silicon Mac running Linux containers),
build locally with `docker build -t rmsync:local .` — your host's
native arm64 Swift toolchain compiles in normal time.

---

## Troubleshooting

Same diagnostics as macOS — see [USAGE.md](USAGE.md) and
[LLM_CONTEXT.md](LLM_CONTEXT.md) — with the macOS-specific
sections (launchd, Console.app, Finder) ignored. Most useful
starting point if a tester reports something breaking on a
fresh container:

```sh
docker exec rmsync rmsync logs --diagnose
docker exec rmsync rmsync doctor
docker logs --tail 50 rmsync
```

Common surprises:

- **"no logs visible"**: the daemon writes to stderr, captured by
  Docker. Use `docker logs rmsync`, not the macOS-style "open the
  log file" approach.
- **"upload doesn't work but download does"**: usually
  inotify-related. Check `docker exec rmsync rmsync logs --diagnose`
  for "watcher started" with backend=inotify and reasonable watch
  count. If the watch count is small relative to your tree size,
  you're hitting the `max_user_watches` limit on the host.
- **"daemon can't reach the cloud"**: rmapi auth is per-account
  and survives in `/config/rmapi.conf`. If `docker exec rmsync rmapi
  account` fails, redo the one-time auth flow.
