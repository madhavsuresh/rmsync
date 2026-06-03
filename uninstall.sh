#!/usr/bin/env bash
# Remove the rmsync launchd agents. Leaves config + state + logs intact
# by default; pass --purge to wipe local rmsync-owned files too.
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.user.rmsync.plist"
MENUBAR_PLIST="$HOME/Library/LaunchAgents/com.user.rmsync.menubar.plist"
BIN_LINK="$HOME/.local/bin/rmsync"

if [[ "${1:-}" == "--purge" ]] && command -v rmsync >/dev/null 2>&1; then
    if rmsync purge --apply; then
        exit 0
    fi
    echo "Falling back to legacy purge path."
fi

launchctl bootout "gui/$(id -u)/com.user.rmsync" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.user.rmsync.menubar" 2>/dev/null || true
rm -f "$PLIST" "$MENUBAR_PLIST" "$BIN_LINK"

if [[ "${1:-}" == "--purge" ]]; then
    rm -rf "$HOME/Library/Application Support/rmsync"
    rm -rf "$HOME/.config/rmsync"
    rm -rf "$HOME/Library/Logs/rmsync"
    echo "rmsync removed. state + config + logs purged."
    echo "The configured sync dir was not removed because CLI purge was unavailable."
else
    echo "rmsync removed. state preserved at ~/Library/Application Support/rmsync"
    echo "Run with --purge to wipe state, config, and logs too."
fi
