#!/usr/bin/env bash
# dev-reinstall.sh — one-shot iteration helper for brew-installed rmsync.
#
# Usage:
#   ./scripts/dev-reinstall.sh [-m "commit message"] [--no-push]
#                              [--skip-brew] [-y|--yes]
#
# Why this exists: brew's --HEAD install tracks origin/main, not your
# working tree. So every change has to round-trip through the remote.
# This script compresses the loop:
#
#   1. Commit any uncommitted changes (requires -m).
#   2. Push if origin/main is behind.
#   3. brew upgrade --fetch-HEAD (falls back to uninstall+install).
#   4. launchctl kickstart -k both agents.
#   5. rmsync status.
#
# Flags:
#   -m <msg>       Commit message, required if there are uncommitted changes.
#   --no-push      Skip the push step (assume already on origin/main).
#   --skip-brew    Only commit + push; don't touch brew or launchd.
#   -y, --yes      Non-interactive (no confirm prompts).
#   -h, --help     Print this usage block.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

FORMULA="madhavsuresh/rmsync/rmsync"
TAP="madhavsuresh/rmsync"
DAEMON_LABEL="com.user.rmsync"
MENUBAR_LABEL="com.user.rmsync.menubar"

# ── flags ────────────────────────────────────────────────────────────
COMMIT_MSG=""
DO_PUSH=1
DO_BREW=1
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m)            COMMIT_MSG="${2:-}"; shift 2 ;;
        --no-push)     DO_PUSH=0; shift ;;
        --skip-brew)   DO_BREW=0; shift ;;
        -y|--yes)      ASSUME_YES=1; shift ;;
        -h|--help)
            sed -n '2,23p' "$0" | sed 's|^# \{0,1\}||'
            exit 0
            ;;
        *)
            echo "Unknown flag: $1" >&2
            exit 1
            ;;
    esac
done

# ── output helpers ───────────────────────────────────────────────────
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step()  { bold ""; bold "▸ $*"; }

# ── pre-flight ───────────────────────────────────────────────────────
step "Pre-flight"

branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "main" ]]; then
    red "Current branch is '$branch', not main."
    red "brew's HEAD install tracks origin/main, so this loop only"
    red "makes sense from main. Either switch:"
    red "    git checkout main"
    red "or merge your branch first, then retry."
    exit 1
fi

if [[ $DO_BREW -eq 1 ]]; then
    if ! brew tap | grep -qx "$TAP"; then
        red "Tap '$TAP' is not set up."
        red "Run once:"
        red "    brew tap-new $TAP"
        red "    ln -sf \"\$PWD/Formula/rmsync.rb\" \\"
        red "           \"\$(brew --repo $TAP)/Formula/rmsync.rb\""
        exit 1
    fi
    if ! brew list rmsync >/dev/null 2>&1; then
        red "rmsync is not installed via brew. Install it first:"
        red "    brew install --HEAD $FORMULA"
        red "    rmsync-install-agents"
        exit 1
    fi
fi
green "  on branch main ✓"

# ── 1. commit ────────────────────────────────────────────────────────
step "Commit"

if [[ -n "$(git status --porcelain)" ]]; then
    if [[ -z "$COMMIT_MSG" ]]; then
        red "You have uncommitted changes. Pass '-m \"<message>\"'."
        git status --short >&2
        exit 1
    fi
    git add -A
    git commit -m "$COMMIT_MSG"
    green "  committed: $COMMIT_MSG"
else
    yellow "  no changes to commit"
fi

# ── 2. push ──────────────────────────────────────────────────────────
if [[ $DO_PUSH -eq 1 ]]; then
    step "Push"
    # Count commits on HEAD but not upstream. 0 = already pushed.
    ahead="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    if [[ "$ahead" -gt 0 ]]; then
        git push
        green "  pushed $ahead commit(s)"
    else
        yellow "  origin/main already up to date"
    fi
fi

if [[ $DO_BREW -eq 0 ]]; then
    bold ""
    green "--skip-brew set; done."
    exit 0
fi

# ── 3. brew upgrade --fetch-HEAD ─────────────────────────────────────
step "brew refetch + rebuild"

if ! brew upgrade --fetch-HEAD "$FORMULA" 2>&1 | tee /tmp/dev-reinstall-brew.log; then
    # Brew sometimes bails out in ways --fetch-HEAD can't recover from
    # (e.g., formula changed locally via symlink). Fall back to the
    # hard reset: uninstall and reinstall.
    yellow "  upgrade --fetch-HEAD failed; falling back to uninstall + install"
    brew uninstall rmsync
    brew install --HEAD "$FORMULA"
fi

# If upgrade reported "already up-to-date", that's fine — it means
# origin/main hasn't moved since the last install. No new binary, no
# kickstart needed either.
if grep -q "already installed" /tmp/dev-reinstall-brew.log 2>/dev/null; then
    yellow "  brew reports no change; skipping kickstart"
    bold ""
    green "Done (no-op)."
    exit 0
fi

# ── 4. kickstart launchd agents ──────────────────────────────────────
step "Kickstart launchd agents"

uid="$(id -u)"
for label in "$DAEMON_LABEL" "$MENUBAR_LABEL"; do
    if launchctl kickstart -k "gui/$uid/$label" 2>/dev/null; then
        green "  kicked $label"
    else
        yellow "  $label not loaded; skipping (run rmsync-install-agents to load)"
    fi
done

# ── 5. status ────────────────────────────────────────────────────────
step "Status"

if ! command -v rmsync >/dev/null 2>&1; then
    yellow "  rmsync not on PATH; skipping status check"
else
    # Poll for the daemon to come back up. Fresh launchd kickstart
    # takes 2–4s typically; give it up to 10.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if rmsync status 2>/dev/null | grep -q '^state:'; then
            rmsync status
            break
        fi
        sleep 1
    done || true
    # If we fell out without seeing 'state:', at least print whatever
    # status has (probably "daemon: not running").
    if ! rmsync status 2>/dev/null | grep -q '^state:'; then
        yellow "  daemon didn't come up within 10s; falling back to DB read:"
        rmsync status || true
    fi
fi

bold ""
green "Done."
