#!/bin/sh
# rmsync-entrypoint.sh — runs as PID 1 inside the rmsync Docker
# container (under tini). Responsibilities:
#
#   1. Set the env vars the daemon's Paths/Logger expect for the
#      Docker volume layout (/config, /state, /sync).
#   2. Seed /config/config.toml from the bundled default if the
#      user hasn't supplied one. Idempotent.
#   3. Tell rmapi where to find its config (so the user's
#      one-time auth lands in /config/rmapi.conf, not a per-run
#      ephemeral path that vanishes on container restart).
#   4. Exec the daemon (or whatever subcommand was passed). Using
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
if [ ! -f "$CONFIG_DIR/config.toml" ]; then
    if [ -f "$DEFAULT_CONFIG" ]; then
        cp "$DEFAULT_CONFIG" "$CONFIG_DIR/config.toml"
        echo "rmsync: seeded default config at $CONFIG_DIR/config.toml" >&2
    else
        echo "rmsync: WARNING — no default config bundled; daemon will refuse to start" >&2
    fi
fi

# Tell rmsync where state, config, and logs live.
export RM_SYNC_CONFIG="$CONFIG_DIR/config.toml"
export RM_SYNC_STATE_DIR="$STATE_DIR"

# Tell rmapi where its auth config lives. rmapi reads ``$XDG_CONFIG_HOME/rmapi``
# (default ``$HOME/.config/rmapi``). Pointing it at /config keeps the
# auth token on the user's volume so it survives container restarts.
mkdir -p "$CONFIG_DIR/rmapi"
export XDG_CONFIG_HOME="$CONFIG_DIR"

# If the first arg is ``daemon`` (default CMD), exec rmsync daemon.
# If it's anything else (like ``status`` or ``doctor`` from a
# ``docker exec``), exec rmsync with those args verbatim. ``exec`` so
# tini's SIGTERM lands on the actual daemon, not the shell.
exec /usr/local/bin/rmsync "$@"
