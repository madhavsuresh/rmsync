#!/bin/sh
# rmsync-entrypoint.sh — runs as PID 1 inside the rmsync Docker
# container (under tini). Responsibilities:
#
#   1. Set the env vars the daemon's Paths/Logger expect for the
#      Docker volume layout (/config, /state, /sync).
#   2. Seed /config/config.toml from the bundled default if the
#      user hasn't supplied one. Idempotent.
#   3. Tell rmapi where to find its config (so the user's
#      one-time auth lands in /config/rmapi/rmapi.conf, not a
#      per-run ephemeral path that vanishes on container restart).
#   4. Print a clearly-bordered first-run banner if no rmapi
#      auth token exists yet, telling the user exactly what
#      ``docker exec`` command to run next. Suppress the banner
#      after auth is in place.
#   5. Exec the daemon (or whatever subcommand was passed). Using
#      exec means tini directly supervises the rmsync process so
#      SIGTERM forwarding works.
set -eu

CONFIG_DIR=/config
STATE_DIR=/state
SYNC_DIR=/sync
DEFAULT_CONFIG=/usr/local/share/rmsync/config.toml.default

# Ensure the volume mount points exist (they will if the user
# bind-mounted them, but a from-scratch ``docker run`` without
# ``-v`` should still produce a sensible state).
mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$SYNC_DIR"

# Seed config.toml. The default points sync_dir at /sync, which
# the docker-compose / docker run conventions mount as a host
# volume. If the user has already edited /config/config.toml,
# leave it alone.
SEEDED_CONFIG=0
if [ ! -f "$CONFIG_DIR/config.toml" ]; then
    if [ -f "$DEFAULT_CONFIG" ]; then
        cp "$DEFAULT_CONFIG" "$CONFIG_DIR/config.toml"
        SEEDED_CONFIG=1
    else
        echo "rmsync: WARNING — no default config bundled; daemon will refuse to start" >&2
    fi
fi

# Tell rmsync where state, config, and logs live.
export RM_SYNC_CONFIG="$CONFIG_DIR/config.toml"
export RM_SYNC_STATE_DIR="$STATE_DIR"

# Tell rmapi where its auth config lives. rmapi reads
# ``$XDG_CONFIG_HOME/rmapi/rmapi.conf`` (default
# ``$HOME/.config/rmapi``). Point it at /config so the user's
# one-time auth survives container restarts and image upgrades.
mkdir -p "$CONFIG_DIR/rmapi"
export XDG_CONFIG_HOME="$CONFIG_DIR"

# Detect missing rmapi auth and print a high-visibility first-run
# banner. The daemon will boot regardless — but every cloud call
# will fail until the user authenticates, so a clearly-formatted
# banner pointing at the exact next command saves them from
# digging through ``docker logs`` to figure out what's wrong.
#
# Only print this banner from the daemon entrypoint (i.e., when
# the first arg is ``daemon`` or empty). When the container is
# invoked via ``docker exec rmsync rmsync status`` etc., we don't
# want to spam the banner across every CLI call.
if [ ! -f "$CONFIG_DIR/rmapi/rmapi.conf" ] && \
   { [ "$#" -eq 0 ] || [ "$1" = "daemon" ]; }; then
    cat >&2 <<'BANNER'

╔══════════════════════════════════════════════════════════════════╗
║  rmsync — first-run setup                                        ║
║                                                                  ║
║  No rmapi auth detected. The daemon will start but won't sync    ║
║  anything until you authenticate against your reMarkable cloud  ║
║  account (one-time, interactive):                                ║
║                                                                  ║
║      docker exec -it rmsync rmapi                                ║
║                                                                  ║
║  rmapi will print a URL. Open it in a browser, sign in to your  ║
║  reMarkable account, copy the 8-character pairing code, and     ║
║  paste it back into the rmapi prompt. Auth survives container   ║
║  restarts (lives in /config/rmapi/rmapi.conf on the volume).    ║
║                                                                  ║
║  Verify: docker exec rmsync rmsync doctor                       ║
╚══════════════════════════════════════════════════════════════════╝

BANNER
fi

if [ "$SEEDED_CONFIG" = "1" ]; then
    echo "rmsync: seeded default config at $CONFIG_DIR/config.toml" >&2
fi

# If the first arg is ``daemon`` (default CMD), exec rmsync daemon.
# If it's anything else (like ``status`` or ``doctor`` from a
# ``docker exec``), exec rmsync with those args verbatim. ``exec`` so
# tini's SIGTERM lands on the actual daemon, not the shell.
exec /usr/local/bin/rmsync "$@"
