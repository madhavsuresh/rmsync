# Multi-stage build: heavy ``swift:6.1-jammy`` toolchain layer, then a
# slim runtime layer. The runtime image bundles the rmsync binary,
# the rmapi binary (downloaded from upstream releases — pinned), the
# rmsync entrypoint script, and a default ``config.toml`` template.
#
# Architectures: built multi-arch by the release workflow
# (linux/amd64 + linux/arm64). The base images support both.
#
# Volumes (see docs/DOCKER.md for the full operational model):
#   /config — rmapi.conf and config.toml (one-time auth + edits)
#   /state  — state.db, ipc.sock (daemon-private)
#   /sync   — your reMarkable-bound .md tree
#
# Logs go to stdout/stderr (the daemon's structured-JSON sink writes
# there); docker captures via ``docker logs <container>``.

# -----------------------------------------------------------------------------
# Stage 1: build rmsync from source
# -----------------------------------------------------------------------------
FROM swift:6.1-jammy AS builder

# libsqlite3-dev for GRDB's underlying SQLite linkage. ca-certificates
# so SwiftPM can fetch dependencies over HTTPS during ``swift build``.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libsqlite3-dev \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# Copy only the swift package — no need for install.sh, scripts/, etc.
# inside the builder stage. .dockerignore at the repo root prunes the
# rest, but being explicit here also keeps the build cache stable.
COPY swift /src/swift

# ``--disable-sandbox`` is required because swift-build inside Docker
# can't sandbox itself (no /usr/sbin/sandbox-exec on Linux). ``rmsync``
# is the only product we need from this stage; rmsync-menubar is gated
# out for Linux in Package.swift already.
RUN swift build \
    --package-path /src/swift \
    -c release \
    --product rmsync \
    --disable-sandbox

# -----------------------------------------------------------------------------
# Stage 2: minimal runtime image
# -----------------------------------------------------------------------------
FROM swift:6.1-jammy-slim AS runtime

# Runtime needs: ca-certificates (for rmapi -> reMarkable cloud TLS),
# libsqlite3-0 (GRDB runtime dep — header-less variant of the build
# package), unzip + curl (for fetching the rmapi release zip during
# build), tini (PID 1 signal forwarding so docker stop is graceful).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        libsqlite3-0 \
        tini \
        curl \
        unzip \
 && rm -rf /var/lib/apt/lists/*

# Pull rmapi from upstream releases. Pinned version — bump explicitly
# when upstream releases a new one. Architecture-aware via TARGETARCH
# (set automatically by buildx during multi-arch builds).
#
# Naming convention from ddvk/rmapi releases: ``.zip`` archives named
# ``rmapi-linux-{amd64,arm64}.zip`` (matches the macOS install.sh
# pattern, which uses ``rmapi-macos-{arm64,intel}.zip``). Bumping to
# v0.0.30 to match the version pinned by macOS CI.
ARG RMAPI_VERSION=v0.0.30
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) RMAPI_ARCH=linux-amd64 ;; \
        arm64) RMAPI_ARCH=linux-arm64 ;; \
        *) echo "Unsupported arch: ${TARGETARCH}"; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/rmapi.zip \
        "https://github.com/ddvk/rmapi/releases/download/${RMAPI_VERSION}/rmapi-${RMAPI_ARCH}.zip"; \
    unzip -o /tmp/rmapi.zip -d /usr/local/bin rmapi; \
    rm /tmp/rmapi.zip; \
    chmod +x /usr/local/bin/rmapi; \
    rmapi version

# Copy the daemon binary and helpers from the builder stage.
COPY --from=builder /src/swift/.build/release/rmsync /usr/local/bin/rmsync

# Entrypoint, default config, and packaging-time docs.
COPY docker/rmsync-entrypoint.sh /usr/local/bin/rmsync-entrypoint.sh
COPY docker/config.toml.default /usr/local/share/rmsync/config.toml.default
RUN chmod 0755 /usr/local/bin/rmsync-entrypoint.sh

# Volume mount points. The container runs the daemon as the user
# specified in docker-compose (or ``root`` by default). For shared
# host-mounts you'd typically pass ``--user $(id -u):$(id -g)`` so
# files land with the host user's ownership.
WORKDIR /sync
VOLUME ["/config", "/state", "/sync"]

# tini reaps zombies and forwards SIGTERM cleanly to rmsync. Without
# this PID-1 wrapper, ``docker stop`` waits the full timeout before
# SIGKILLing because Swift's signal handling bypasses the default
# Docker init.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/rmsync-entrypoint.sh"]
CMD ["daemon"]
