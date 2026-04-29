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

## Quick start

Prereqs: Docker (engine + compose plugin) on a Linux host, a
reMarkable cloud account (free tier is enough), and some disk for
the synced `.md` files.

```sh
# 1. Lay out the volume directories
mkdir -p data/{config,state,sync}

# 2. Drop the docker-compose.yml from this repo next to ./data/
curl -fsSL -o docker-compose.yml \
    https://raw.githubusercontent.com/madhavsuresh/rmsync/main/docker-compose.yml

# 3. Start the container
docker compose up -d

# 4. One-time rmapi authentication (interactive)
docker exec -it rmsync rmapi
#   Open https://my.remarkable.com/device/desktop/connect
#   Sign in, copy the 8-char code, paste it into the rmapi prompt.

# 5. Verify
docker exec rmsync rmsync doctor
docker logs --tail 20 rmsync
```

If `doctor` is all ✓, you're done. The daemon is now syncing.

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

If you'd rather not pull from `ghcr.io`:

```sh
git clone https://github.com/madhavsuresh/rmsync.git
cd rmsync
docker build -t rmsync:local .
# Then in docker-compose.yml, replace the image: line with image: rmsync:local
```

The build takes ~5 minutes (Swift toolchain compiling release-mode
rmsync from source, plus rmapi download). Multi-arch build:

```sh
docker buildx build --platform linux/amd64,linux/arm64 -t rmsync:local .
```

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
