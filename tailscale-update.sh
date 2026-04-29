#!/bin/bash
#
# Tailscale Jamf updater
# - Runs as root (Jamf default).
# - Upgrades the open-source `tailscale` Homebrew formula in place.
# - Restarts tailscaled so the new daemon binary is the one running.
#
# Safe to run on any cadence (e.g. weekly Recurring Check-in). No-op if
# tailscale isn't installed yet — just exits cleanly so the policy doesn't
# go red on Macs that haven't been deployed yet.
#
# Jamf script parameters:
#   $4 = Override admin user that owns Homebrew (optional, default = brew prefix owner)
#

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root." >&2
    exit 1
fi

#=============================================================================
# Locate Homebrew
#=============================================================================
BREW=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then BREW="$candidate"; break; fi
done

if [[ -z "$BREW" ]]; then
    echo "Homebrew not installed — nothing to update. Exiting cleanly."
    exit 0
fi

#=============================================================================
# Pick the brew owner (brew refuses to run as root)
#=============================================================================
BREW_OWNER="${4:-}"
if [[ -z "$BREW_OWNER" ]]; then
    BREW_OWNER="$(/usr/bin/stat -f%Su "$(dirname "$BREW")")"
fi

if [[ -z "$BREW_OWNER" || "$BREW_OWNER" == "root" ]] \
        || ! /usr/bin/id -u "$BREW_OWNER" >/dev/null 2>&1; then
    echo "ERROR: No usable non-root owner for $BREW. Pass one as Jamf parameter \$4." >&2
    exit 1
fi

echo "Homebrew: $BREW (owner: $BREW_OWNER)"

run_brew() {
    /usr/bin/sudo -u "$BREW_OWNER" "$BREW" "$@" </dev/null
}

#=============================================================================
# Skip if tailscale formula isn't installed (script ran on a Mac without it)
#=============================================================================
if ! run_brew list --formula tailscale >/dev/null 2>&1; then
    echo "tailscale formula not installed — nothing to update. Exiting cleanly."
    exit 0
fi

#=============================================================================
# Capture current version, update brew metadata, upgrade, capture new version
#=============================================================================
OLD_VERSION="$(run_brew list --versions tailscale | awk '{print $2}')"
echo "Current tailscale version: $OLD_VERSION"

run_brew update
run_brew upgrade tailscale || true

NEW_VERSION="$(run_brew list --versions tailscale | awk '{print $2}')"
echo "Installed tailscale version: $NEW_VERSION"

if [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
    echo "Already up to date. No daemon restart needed."
    exit 0
fi

#=============================================================================
# Restart tailscaled so the new binary is the one actually running
#=============================================================================
echo "Restarting tailscaled LaunchDaemon..."
launchctl kickstart -k system/com.tailscale.tailscaled

# Give it a moment to come back up
sleep 3

if ! launchctl list | grep -q com.tailscale.tailscaled; then
    echo "ERROR: tailscaled is not loaded after restart." >&2
    exit 1
fi

TAILSCALE="$(command -v tailscale || true)"
[[ -z "$TAILSCALE" ]] && TAILSCALE="$(run_brew --prefix tailscale)/bin/tailscale"

echo
echo "Tailscale status after upgrade:"
"$TAILSCALE" status || true

echo
echo "Update complete: $OLD_VERSION -> $NEW_VERSION"
exit 0
