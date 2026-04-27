#!/bin/bash
#
# Tailscale Silent Deploy for macOS (Jamf-ready)
# - Installs Standalone .pkg
# - Authenticates with pre-authorized tagged auth key (no login required)
# - Enables Tailscale SSH
# - Enables auto-updates
# - Runs invisibly (no GUI interaction)
#
# Auth key resolution order (first match wins):
#   1. --authkey=tskey-...   CLI flag (works locally and over ssh)
#   2. TAILSCALE_AUTHKEY     env var (e.g. `ssh host TAILSCALE_AUTHKEY=... bash -s < script`)
#   3. Jamf script parameter $4
#   4. Config file:  /etc/tailscale-deploy.conf  or  ~/.config/tailscale-deploy.conf
#      (file should contain a single line: TAILSCALE_AUTHKEY=tskey-...)
#

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================
TAILSCALE_TAGS="tag:communications"

# Tailscale Standalone .pkg download URL (always latest stable)
PKG_URL="https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg"

PKG_PATH="/tmp/Tailscale.pkg"

#=============================================================================
# Resolve auth key
#=============================================================================
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

# 1. CLI flag --authkey=...
for arg in "$@"; do
    case "$arg" in
        --authkey=*) TAILSCALE_AUTHKEY="${arg#--authkey=}" ;;
    esac
done

# 2/3. Jamf passes $1=mountpoint $2=computer $3=user $4=first param
if [[ -z "${TAILSCALE_AUTHKEY}" && $# -ge 4 && "${4:-}" == tskey-* ]]; then
    TAILSCALE_AUTHKEY="$4"
fi

# 4. Config file fallback
if [[ -z "${TAILSCALE_AUTHKEY}" ]]; then
    for cfg in "/etc/tailscale-deploy.conf" "${HOME:-/var/root}/.config/tailscale-deploy.conf"; do
        if [[ -r "$cfg" ]]; then
            # shellcheck disable=SC1090
            source "$cfg"
            [[ -n "${TAILSCALE_AUTHKEY:-}" ]] && break
        fi
    done
fi

if [[ -z "${TAILSCALE_AUTHKEY}" || "${TAILSCALE_AUTHKEY}" != tskey-* ]]; then
    echo "ERROR: No valid Tailscale auth key provided." >&2
    echo "Provide one via --authkey=tskey-..., TAILSCALE_AUTHKEY env var," >&2
    echo "Jamf parameter \$4, or /etc/tailscale-deploy.conf" >&2
    exit 1
fi

#=============================================================================
# STEP 1: Download & Install Tailscale (Standalone variant)
#=============================================================================
echo "Downloading Tailscale Standalone .pkg..."
/usr/bin/curl -fsSL -o "${PKG_PATH}" "${PKG_URL}"

echo "Installing Tailscale..."
/usr/sbin/installer -pkg "${PKG_PATH}" -target /

rm -f "${PKG_PATH}"

sleep 5

#=============================================================================
# STEP 2: Set the CLI path
#=============================================================================
TAILSCALE_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

if [[ ! -f "${TAILSCALE_CLI}" ]]; then
    echo "ERROR: Tailscale CLI not found at ${TAILSCALE_CLI}"
    exit 1
fi

#=============================================================================
# STEP 3: Launch Tailscale.app to activate the system extension
#=============================================================================
open -gj /Applications/Tailscale.app

echo "Waiting for Tailscale daemon to be ready..."
sleep 10

#=============================================================================
# STEP 4: Bring Tailscale up — auth key, tags, SSH
#=============================================================================
echo "Configuring and connecting Tailscale..."
"${TAILSCALE_CLI}" up \
    --authkey="${TAILSCALE_AUTHKEY}" \
    --advertise-tags="${TAILSCALE_TAGS}" \
    --ssh \
    --reset

#=============================================================================
# STEP 5: Enable auto-updates
#=============================================================================
echo "Enabling auto-updates..."
"${TAILSCALE_CLI}" set --auto-update

#=============================================================================
# STEP 6: Verify
#=============================================================================
echo "Tailscale status:"
"${TAILSCALE_CLI}" status

echo "Tailscale deployment complete."
exit 0
