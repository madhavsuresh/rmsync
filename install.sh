#!/usr/bin/env bash
# rmsync installer. Idempotent — safe to run multiple times.
#
# Usage:
#   ./install.sh [--debug] [--no-rmapi-install] [--yes]
#
# This script walks through everything a fresh Mac needs:
#   1. Xcode command-line tools (Swift compiler)
#   2. rmapi (the reMarkable cloud CLI) — installed via brew if possible
#   3. Build the Swift daemon + menu bar app
#   4. Write a default config if none exists
#   5. Install and bootstrap the launchd agents
#   6. Append ~/.local/bin to PATH in your shell rc file if missing
#
# Re-run anytime to pick up code changes. The launchd agents are kicked
# on every run so they start the freshly-built binary.
#
# Flags:
#   --debug              Build in debug mode (default: release)
#   --no-rmapi-install   Don't offer to install rmapi automatically
#   --yes                Accept all prompts (non-interactive)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── flags ────────────────────────────────────────────────────────────
BUILD_MODE=release
OFFER_RMAPI=1
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --debug)             BUILD_MODE=debug ;;
        --no-rmapi-install)  OFFER_RMAPI=0 ;;
        --yes|-y)            ASSUME_YES=1 ;;
        -h|--help)
            sed -n '2,19p' "$0" | sed 's|^# \{0,1\}||'
            exit 0
            ;;
        *)
            echo "Unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

# ── output helpers ───────────────────────────────────────────────────
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step()  { bold ""; bold "▸ $*"; }
confirm() {
    # $1 prompt. Returns 0 if user said yes.
    if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
    read -rp "$1 [Y/n] " reply
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# ── 1. Xcode command-line tools ──────────────────────────────────────
step "Checking Swift toolchain"
if ! command -v swift >/dev/null; then
    red "swift not found — Xcode command-line tools aren't installed."
    echo "Run this in a Terminal window, wait for the GUI installer to finish, then re-run ./install.sh:"
    echo "    xcode-select --install"
    exit 1
fi
SWIFT_VERSION=$(swift --version 2>&1 | head -1)
echo "  $SWIFT_VERSION"

# ── 2. rmapi ─────────────────────────────────────────────────────────
step "Checking rmapi"
RMAPI_BIN=""
if command -v rmapi >/dev/null; then
    RMAPI_BIN="$(command -v rmapi)"
elif [[ -x "$HOME/bin/rmapi" ]]; then
    RMAPI_BIN="$HOME/bin/rmapi"
fi

if [[ -z "$RMAPI_BIN" ]]; then
    yellow "  rmapi not found."
    installed=0
    if [[ "$OFFER_RMAPI" -eq 1 ]]; then
        if command -v brew >/dev/null; then
            echo "  Homebrew is available. Install via 'brew install io41/tap/rmapi'?"
            if confirm "  Install rmapi with brew?"; then
                brew install io41/tap/rmapi
                RMAPI_BIN="$(command -v rmapi || true)"
                [[ -n "$RMAPI_BIN" ]] && installed=1
            fi
        fi
    fi
    if [[ "$installed" -eq 0 ]]; then
        red "rmapi is required. Install one of these ways and re-run:"
        red "    brew install io41/tap/rmapi"
        red "    https://github.com/ddvk/rmapi/releases  (verify the release manually, then drop the binary at ~/bin/rmapi)"
        exit 1
    fi
fi
echo "  $RMAPI_BIN"

# Authentication status. This is the first thing that trips up new
# users: the daemon can start, the menu bar can show "idle", but
# nothing will actually sync because rmapi has no cloud credentials.
# Offer to walk the user through the auth flow right now.
NEEDS_AUTH=0
if ! "$RMAPI_BIN" account >/dev/null 2>&1; then
    NEEDS_AUTH=1
    bold ""
    bold "▸ Authenticating rmapi with the reMarkable cloud"
    echo
    echo "  rmsync pushes and pulls documents via rmapi, which talks to"
    echo "  your reMarkable Connect account. We need to link this Mac to"
    echo "  your account — a one-time, ~30-second process:"
    echo
    echo "    1. Open this URL in your browser:"
    bold  "         https://my.remarkable.com/device/desktop/connect"
    echo "    2. Sign in with your reMarkable account if prompted."
    echo "    3. Copy the 8-character code that appears on that page."
    echo "    4. Paste it into the rmapi prompt that's about to open."
    echo
    echo "  The code is only valid for a few minutes and is one-use. If"
    echo "  you miss the window, reload the page for a new one."
    echo
    if confirm "  Ready to do this now?"; then
        echo
        # rmapi reads the code from stdin and exits when authed.
        # It loops on bad input, so hand control over for as long as
        # it takes.
        "$RMAPI_BIN" account || {
            red ""
            red "rmapi authentication didn't complete. You can retry later with:"
            red "    $RMAPI_BIN"
            red "…and then re-run ./install.sh (or just 'rmsync restart')."
            exit 1
        }
        NEEDS_AUTH=0
        green "  rmapi authenticated."
    else
        yellow ""
        yellow "  OK — skipping for now. The daemon will start but won't sync"
        yellow "  until you authenticate. Run this when you're ready:"
        yellow "      $RMAPI_BIN"
        yellow "  …and paste the code from https://my.remarkable.com/device/desktop/connect"
    fi
fi

# ── 3. directories ───────────────────────────────────────────────────
CONFIG_DIR="$HOME/.config/rmsync"
STATE_DIR="$HOME/Library/Application Support/rmsync"
LOG_DIR="$HOME/Library/Logs/rmsync"
AGENT_DIR="$HOME/Library/LaunchAgents"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" "$AGENT_DIR" "$BIN_DIR"

# ── 4. build ─────────────────────────────────────────────────────────
step "Building rmsync ($BUILD_MODE)"
(cd "$SCRIPT_DIR/swift" && swift build -c "$BUILD_MODE")

BUILD_PRODUCT="$SCRIPT_DIR/swift/.build/$BUILD_MODE/rmsync"
if [[ ! -x "$BUILD_PRODUCT" ]]; then
    red "build did not produce $BUILD_PRODUCT"
    exit 1
fi

# Symlink so in-place rebuilds are picked up without re-installing.
ln -sf "$BUILD_PRODUCT" "$BIN_DIR/rmsync"
echo "  symlinked $BIN_DIR/rmsync -> $BUILD_PRODUCT"

# ── 5. default config ────────────────────────────────────────────────
if [[ ! -f "$CONFIG_DIR/config.toml" ]]; then
    step "Writing default config to $CONFIG_DIR/config.toml"
    cat > "$CONFIG_DIR/config.toml" <<EOF
# rmsync configuration. Restart the daemon after edits:
#   rmsync restart

sync_dir      = "$HOME/rmsync-writing"
remote_folder = "Writing"

worker_pool_size               = 3
poll_interval_seconds          = 30
poll_active_interval_seconds   = 15
poll_idle_interval_seconds     = 120
debounce_seconds               = 2.0
echo_fence_seconds             = 5.0
retry_max_attempts             = 3

# native_plain: plain text only (recommended)
# native_formatted: experimental, not fully implemented
# pdf: read-only on tablet, not fully implemented
push_strategy = "native_plain"

backup_snapshots_to_keep = 30
dry_run                  = false

[log]
level = "INFO"   # DEBUG | INFO | WARNING | ERROR

# Optional: drop-folder for sending PDFs / EPUBs to the tablet.
# Drop a file into ``local_dir``, the daemon pushes it to
# ``remote_folder`` on the cloud, then (by default) removes it
# from local. Closes the "send paper to tablet" loop without
# emails or rmapi-by-hand. Uncomment to enable.
# [inbox]
# local_dir         = "$HOME/rmsync-writing/_inbox"
# remote_folder     = "Inbox"
# delete_after_push = true

# Optional: web dashboard at http://127.0.0.1:7878. macOS users
# usually prefer the menubar; included here for parity with the
# Docker config. Auth via Bearer token; if ``auth_token`` is
# unset, daemon generates one in ``\$STATE_DIR/web-token``.
# [web]
# enabled    = true
# bind_addr  = "127.0.0.1"
# port       = 7878

# Optional: rename / move / delete propagation. OFF by default —
# when ``enable_propagation = true``, deletes and renames in the
# sync dir or on the tablet propagate to the other side. Local
# files are soft-deleted into ``<sync_dir>/.rmsync-trash`` first;
# ``rmsync trash list / restore`` recovers them. The bulk-delete
# brake refuses to apply more than ``bulk_delete_threshold`` of
# tracked docs in a ``bulk_delete_window_seconds`` window — caps
# the blast radius of an accidental ``rm -rf``.
# [deletion]
# enable_propagation         = false
# trash_retention_days       = 30
# bulk_delete_threshold      = 0.5
# bulk_delete_window_seconds = 30
EOF
    yellow "  Edit this file if you want sync_dir somewhere other than ~/rmsync-writing."
fi

# ── 6. bootstrap launchd agents ──────────────────────────────────────
# bootstrap_with_retry: launchd's bootout returns before the service is
# fully torn down, so an immediately-following bootstrap sometimes fails
# with "Input/output error" (5). Retry with exponential backoff.
bootstrap_with_retry() {
    local plist="$1"
    local label="$2"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    local wait_ms=250
    for _ in 1 2 3 4; do
        if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; then
            return 0
        fi
        # Already loaded? That's success-of-intent.
        if launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -q "state = "; then
            return 0
        fi
        sleep "$(awk "BEGIN{print $wait_ms/1000}")"
        wait_ms=$((wait_ms * 2))
    done
    yellow "  WARN: failed to bootstrap $label — run 'rmsync restart' manually"
    return 1
}

step "Installing launchd agents"

PLIST="$AGENT_DIR/com.user.rmsync.plist"
sed \
    -e "s|__RMSYNC_BIN__|$BIN_DIR/rmsync|g" \
    -e "s|__HOME__|$HOME|g" \
    "$SCRIPT_DIR/scripts/com.user.rmsync.swift.plist.template" > "$PLIST"
bootstrap_with_retry "$PLIST" "com.user.rmsync"
echo "  daemon agent bootstrapped"

MENUBAR_BIN="$SCRIPT_DIR/swift/.build/$BUILD_MODE/rmsync-menubar"
if [[ -x "$MENUBAR_BIN" ]]; then
    MENUBAR_PLIST="$AGENT_DIR/com.user.rmsync.menubar.plist"
    sed \
        -e "s|__MENUBAR_BIN__|$MENUBAR_BIN|g" \
        -e "s|__HOME__|$HOME|g" \
        "$SCRIPT_DIR/scripts/com.user.rmsync.menubar.plist.template" > "$MENUBAR_PLIST"
    bootstrap_with_retry "$MENUBAR_PLIST" "com.user.rmsync.menubar"
    echo "  menu bar agent bootstrapped"
fi

# ── 7. PATH sanity ───────────────────────────────────────────────────
# Most shells don't include ~/.local/bin by default. Add it to the user's
# rc file so `rmsync` is on PATH in new terminals.
step "Checking PATH"
if printf '%s' ":$PATH:" | grep -q ":$BIN_DIR:"; then
    echo "  $BIN_DIR is already on PATH"
else
    case "${SHELL:-}" in
        */zsh)  RC="$HOME/.zshrc" ;;
        */bash) RC="$HOME/.bash_profile" ;;
        */fish) RC="$HOME/.config/fish/config.fish" ;;
        *)      RC="" ;;
    esac

    if [[ -z "$RC" ]]; then
        yellow "  Unknown shell ($SHELL). Add this to your rc file manually:"
        yellow "      export PATH=\"\$HOME/.local/bin:\$PATH\""
    elif grep -qs '.local/bin' "$RC"; then
        echo "  $RC already references .local/bin"
    else
        if confirm "  Append $BIN_DIR to PATH in $RC?"; then
            if [[ "$RC" == *fish* ]]; then
                mkdir -p "$(dirname "$RC")"
                echo 'fish_add_path -U $HOME/.local/bin' >> "$RC"
            else
                printf '\n# Added by rmsync install.sh\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$RC"
            fi
            echo "  added. Open a new terminal or run: source $RC"
        else
            yellow "  Skipped. Run rmsync as $BIN_DIR/rmsync, or add ~/.local/bin to PATH yourself."
        fi
    fi
fi

# ── summary ──────────────────────────────────────────────────────────
echo
green "rmsync installed."
echo "  binary:  $BIN_DIR/rmsync"
echo "  config:  $CONFIG_DIR/config.toml"
echo "  state:   $STATE_DIR"
echo "  logs:    $LOG_DIR"
echo
echo "Next steps:"
if [[ "$NEEDS_AUTH" -eq 1 ]]; then
    yellow "  ⚠  rmapi still needs authentication before anything will sync."
    yellow "     Run '$RMAPI_BIN' and paste the code from:"
    yellow "         https://my.remarkable.com/device/desktop/connect"
    echo "  Then:"
fi
echo "  • $BIN_DIR/rmsync doctor   # verify everything is green"
echo "  • $BIN_DIR/rmsync status   # check the live daemon"
echo "  • edit $CONFIG_DIR/config.toml, then: rmsync restart"
echo
echo "Full usage: $SCRIPT_DIR/docs/USAGE.md"
