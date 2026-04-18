#!/usr/bin/env bash
# Remove the rmsync launchd agents. Leaves config + state + logs intact
# by default; pass --purge to wipe them too.
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.user.rmsync.plist"
MENUBAR_PLIST="$HOME/Library/LaunchAgents/com.user.rmsync.menubar.plist"
BIN_LINK="$HOME/.local/bin/rmsync"

launchctl bootout "gui/$(id -u)/com.user.rmsync" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.user.rmsync.menubar" 2>/dev/null || true
rm -f "$PLIST" "$MENUBAR_PLIST" "$BIN_LINK"

if [[ "${1:-}" == "--purge" ]]; then
    rm -rf "$HOME/Library/Application Support/rm-sync"
    rm -rf "$HOME/.config/rm-sync"
    rm -rf "$HOME/Library/Logs/rm-sync"
    echo "rmsync removed. state + config + logs purged."
else
    echo "rmsync removed. state preserved at ~/Library/Application Support/rm-sync"
    echo "Run with --purge to wipe state, config, and logs too."
fi
