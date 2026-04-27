#!/usr/bin/env bash
# fresh-install-test.sh — simulate a brand-new brew install of rmsync
# on this machine and roundtrip a test document.
#
# WHY: bugs surface on testers' fresh installs that don't reproduce on
# the dev's machine because the dev has accumulated state (config,
# state.db, TCC permissions, daemon already running). This script
# reproduces a from-scratch install on the dev's own Mac.
#
# DESTRUCTIVE: this MOVES (not deletes) your config, state, logs, and
# sync_dir to a backup directory under /tmp. Restore with --restore-from
# or the printed `mv` command. The backup is timestamped so successive
# runs don't overwrite each other.
#
# Usage:
#   ./scripts/fresh-install-test.sh                  # full test, prompts
#   ./scripts/fresh-install-test.sh -y               # skip prompts
#   ./scripts/fresh-install-test.sh --no-cloud-test  # don't push a probe
#   ./scripts/fresh-install-test.sh --restore-from <dir>   # restore backup
#   ./scripts/fresh-install-test.sh --no-restore     # leave backup at end
#
# Without --no-restore (default), the backup is restored after the
# smoke test so your real install comes back. With --no-restore the
# script exits leaving the brew-fresh state in place; restore manually
# with the printed `mv` commands.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FORMULA="madhavsuresh/rmsync/rmsync"
DAEMON_LABEL="com.user.rmsync"
MENUBAR_LABEL="com.user.rmsync.menubar"

# ── flags ────────────────────────────────────────────────────────────
ASSUME_YES=0
DO_CLOUD_TEST=1
DO_RESTORE=1
RESTORE_FROM=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)         ASSUME_YES=1; shift ;;
        --no-cloud-test)  DO_CLOUD_TEST=0; shift ;;
        --no-restore)     DO_RESTORE=0; shift ;;
        --restore-from)   RESTORE_FROM="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,28p' "$0" | sed 's|^# \{0,1\}||'
            exit 0
            ;;
        *)
            echo "Unknown flag: $1" >&2
            exit 1
            ;;
    esac
done

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step()  { bold ""; bold "▸ $*"; }

confirm() {
    if [[ "$ASSUME_YES" -eq 1 ]]; then return 0; fi
    read -rp "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy] ]]
}

# ── --restore-from short-circuit ─────────────────────────────────────
if [[ -n "$RESTORE_FROM" ]]; then
    step "Restoring backup from $RESTORE_FROM"
    [[ -d "$RESTORE_FROM" ]] || { red "no such backup dir"; exit 1; }
    # First tear down whatever's currently installed.
    launchctl bootout "gui/$(id -u)/$DAEMON_LABEL" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$MENUBAR_LABEL" 2>/dev/null || true
    rm -rf ~/.config/rmsync \
           "$HOME/Library/Application Support/rmsync" \
           ~/Library/Logs/rmsync
    [[ -d "$RESTORE_FROM/config"     ]] && mv "$RESTORE_FROM/config"     ~/.config/rmsync
    [[ -d "$RESTORE_FROM/appsupport" ]] && mv "$RESTORE_FROM/appsupport" "$HOME/Library/Application Support/rmsync"
    [[ -d "$RESTORE_FROM/logs"       ]] && mv "$RESTORE_FROM/logs"       ~/Library/Logs/rmsync
    if [[ -d "$RESTORE_FROM/sync_dir" ]]; then
        SYNC_DEST="$(cat "$RESTORE_FROM/sync_dir.path" 2>/dev/null || echo "$HOME/rmsync-writing")"
        rm -rf "$SYNC_DEST"
        mv "$RESTORE_FROM/sync_dir" "$SYNC_DEST"
    fi
    rmsync-install-agents 2>/dev/null || yellow "  rmsync-install-agents not on PATH; agents not booted"
    green "Restored. Run rmsync doctor to confirm."
    exit 0
fi

# ── pre-flight ───────────────────────────────────────────────────────
step "Pre-flight"

if ! command -v brew >/dev/null; then
    red "brew not found. This script tests the brew-install path; it requires Homebrew."
    exit 1
fi
if ! brew tap | grep -qx "madhavsuresh/rmsync"; then
    yellow "  tap madhavsuresh/rmsync isn't installed; tapping now"
    brew tap madhavsuresh/rmsync 2>/dev/null || {
        red "  brew tap failed. Bail."
        exit 1
    }
fi

# Read the user's current sync_dir from config so we know what to back up.
SYNC_DIR=""
if [[ -f ~/.config/rmsync/config.toml ]]; then
    SYNC_DIR="$(grep -E '^sync_dir' ~/.config/rmsync/config.toml | head -1 \
                | sed -E 's/^sync_dir[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')"
fi
[[ -z "$SYNC_DIR" ]] && SYNC_DIR="$HOME/rmsync-writing"
echo "  sync_dir on disk: $SYNC_DIR"

bold ""
yellow "This will:"
yellow "  1. Stop the running rmsync agents"
yellow "  2. MOVE your config, state, logs, and sync_dir to a backup under /tmp"
yellow "  3. brew uninstall rmsync, then brew install"
yellow "  4. Run rmsync-install-agents on the fresh install"
if [[ "$DO_CLOUD_TEST" -eq 1 ]]; then
    yellow "  5. Push a test .md file and verify it lands on the cloud"
fi
if [[ "$DO_RESTORE" -eq 1 ]]; then
    yellow "  6. Restore your original config/state/logs/sync_dir"
else
    yellow "  6. (--no-restore set) leave the fresh install in place"
fi
bold ""
confirm "Proceed?" || { yellow "Aborted."; exit 0; }

# ── 1. tear down agents ──────────────────────────────────────────────
step "Stopping rmsync agents"
launchctl bootout "gui/$(id -u)/$DAEMON_LABEL"  2>/dev/null || true
launchctl bootout "gui/$(id -u)/$MENUBAR_LABEL" 2>/dev/null || true
sleep 1
green "  agents stopped"

# ── 2. backup user state ─────────────────────────────────────────────
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="/tmp/rmsync-backup-$TS"
mkdir -p "$BACKUP"
step "Moving live state to $BACKUP"

[[ -d ~/.config/rmsync                            ]] && mv ~/.config/rmsync                                 "$BACKUP/config"     && green "  ~/.config/rmsync"
[[ -d "$HOME/Library/Application Support/rmsync"  ]] && mv "$HOME/Library/Application Support/rmsync"       "$BACKUP/appsupport" && green "  ~/Library/Application Support/rmsync"
[[ -d ~/Library/Logs/rmsync                       ]] && mv ~/Library/Logs/rmsync                            "$BACKUP/logs"       && green "  ~/Library/Logs/rmsync"
if [[ -d "$SYNC_DIR" ]]; then
    mv "$SYNC_DIR" "$BACKUP/sync_dir"
    echo "$SYNC_DIR" > "$BACKUP/sync_dir.path"
    green "  $SYNC_DIR"
fi
# Remove any stale agent plists; rmsync-install-agents will recreate them.
rm -f ~/Library/LaunchAgents/com.user.rmsync.plist \
      ~/Library/LaunchAgents/com.user.rmsync.menubar.plist

# ── 3. uninstall + reinstall ─────────────────────────────────────────
step "brew uninstall + brew install"
brew uninstall rmsync 2>&1 | tail -2 || true
brew install "$FORMULA"
green "  fresh install complete"

# ── 4. run the post-install helper ───────────────────────────────────
step "rmsync-install-agents"
rmsync-install-agents

# Brief settle so the daemon binds its IPC socket before we probe.
sleep 3

# ── 5. doctor ────────────────────────────────────────────────────────
step "rmsync doctor"
DOCTOR_OUT="$(rmsync doctor 2>&1)"
echo "$DOCTOR_OUT"
DOCTOR_FAILS="$(echo "$DOCTOR_OUT" | grep -c '^  ✗' || true)"
if [[ "$DOCTOR_FAILS" -gt 0 ]]; then
    red "  doctor reports $DOCTOR_FAILS failure(s) — investigate before continuing"
    [[ "$DO_RESTORE" -eq 1 ]] && yellow "  not auto-restoring; backup still at $BACKUP"
    exit 2
fi
green "  doctor: all ✓"

# ── 6. cloud roundtrip smoke test ────────────────────────────────────
SMOKE_PASSED=0
if [[ "$DO_CLOUD_TEST" -eq 1 ]]; then
    step "Cloud roundtrip smoke test"
    PROBE="freshinstall-smoke-$TS"
    PROBE_FILE="$HOME/rmsync-writing/$PROBE.md"
    PROBE_BODY="probe content $TS — written by fresh-install-test.sh"

    mkdir -p "$HOME/rmsync-writing"
    echo "$PROBE_BODY" > "$PROBE_FILE"
    echo "  wrote $PROBE_FILE"

    # Wait up to 60s for the daemon to push and the cloud to ack.
    # Debounce is 2s + push + propagation; usually under 10s.
    DEADLINE=$(($(date +%s) + 60))
    while [[ "$(date +%s)" -lt "$DEADLINE" ]]; do
        if rmapi find /Writing 2>/dev/null | grep -q "$PROBE\b"; then
            SMOKE_PASSED=1
            break
        fi
        sleep 2
    done

    if [[ "$SMOKE_PASSED" -eq 1 ]]; then
        green "  ✓ probe found on cloud — push path works"
        # Cleanup the probe doc; don't leave it lying around.
        rmapi rm "/Writing/$PROBE" 2>/dev/null || true
        rm -f "$PROBE_FILE"
    else
        red "  ✗ probe never appeared on cloud after 60s — push path is BROKEN"
        red "    last 30 lines of stderr.log:"
        tail -30 ~/Library/Logs/rmsync/stderr.log 2>&1 | sed 's/^/      /'
        red "    last 30 lines of stdout.log:"
        tail -30 ~/Library/Logs/rmsync/stdout.log 2>&1 | sed 's/^/      /'
    fi
fi

# ── 7. restore (or print restoration command) ────────────────────────
if [[ "$DO_RESTORE" -eq 1 ]]; then
    step "Restoring original state"
    rmsync-uninstall-agents 2>/dev/null || true
    rm -rf ~/.config/rmsync \
           "$HOME/Library/Application Support/rmsync" \
           ~/Library/Logs/rmsync \
           "$HOME/rmsync-writing"
    [[ -d "$BACKUP/config"     ]] && mv "$BACKUP/config"     ~/.config/rmsync
    [[ -d "$BACKUP/appsupport" ]] && mv "$BACKUP/appsupport" "$HOME/Library/Application Support/rmsync"
    [[ -d "$BACKUP/logs"       ]] && mv "$BACKUP/logs"       ~/Library/Logs/rmsync
    if [[ -d "$BACKUP/sync_dir" ]]; then
        ORIG_SYNC="$(cat "$BACKUP/sync_dir.path" 2>/dev/null || echo "$HOME/rmsync-writing")"
        mkdir -p "$(dirname "$ORIG_SYNC")"
        mv "$BACKUP/sync_dir" "$ORIG_SYNC"
    fi
    rmsync-install-agents
    rmdir "$BACKUP" 2>/dev/null || true
    green "  restored from $BACKUP (now removed)"
else
    yellow ""
    yellow "Backup left at $BACKUP. Restore with:"
    yellow "  $0 --restore-from $BACKUP"
fi

# ── summary ──────────────────────────────────────────────────────────
bold ""
if [[ "$DO_CLOUD_TEST" -eq 1 ]] && [[ "$SMOKE_PASSED" -ne 1 ]]; then
    red "FAILED — fresh install reproduced a real bug. Backup at $BACKUP for forensics."
    exit 3
fi
green "PASSED — fresh install is healthy."
