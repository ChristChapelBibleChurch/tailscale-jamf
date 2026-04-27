#!/bin/bash
#
# Tailscale Silent Deploy for macOS (open-source tailscaled variant)
# - Installs the open-source tailscale + tailscaled CLI via Homebrew
# - Registers tailscaled as a LaunchDaemon (runs at boot, before login)
# - Authenticates with a pre-authorized tagged auth key (no UI)
# - Enables Tailscale SSH server (only works in this variant)
#
# Why this variant?
#   The .pkg "Standalone" GUI app runs inside Apple's System Extension sandbox,
#   which blocks the Tailscale SSH server. Only the open-source tailscaled
#   daemon can be a Tailscale SSH server on macOS.
#
# Auth key resolution order (first match wins):
#   1. --authkey=tskey-...   CLI flag
#   2. TAILSCALE_AUTHKEY     env var  (great for `ssh host bash -s < script`)
#   3. Jamf script parameter $4
#   4. Config file:  /etc/tailscale-deploy.conf
#                or  ~/.config/tailscale-deploy.conf
#

set -euo pipefail

#=============================================================================
# CONFIGURATION
#=============================================================================
TAILSCALE_TAGS="tag:communications"
TAILSCALE_HOSTNAME="$(scutil --get ComputerName 2>/dev/null | tr ' ' '-' | tr -cd '[:alnum:]-')"

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
# Must be root (LaunchDaemon install + tailscale up touches /var/lib/tailscale)
#=============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must be run as root (use sudo)." >&2
    exit 1
fi

#=============================================================================
# STEP 1: Refuse to coexist with the GUI Tailscale.app or its system extension
#=============================================================================
if [[ -d /Applications/Tailscale.app ]]; then
    echo "ERROR: /Applications/Tailscale.app is installed (Standalone/App Store variant)." >&2
    echo "       It conflicts with the open-source tailscaled daemon." >&2
    echo "       Remove it first:" >&2
    echo "         sudo rm -rf /Applications/Tailscale.app" >&2
    echo "         sudo killall Tailscale 2>/dev/null || true" >&2
    echo "       Then reboot and re-run this script." >&2
    exit 1
fi

# The .app may be deleted but its system extension can still be loaded in
# the kernel. The CLI talks to whichever daemon owns the socket, so a
# leftover sandboxed extension will silently shadow the brew daemon.
if /usr/bin/systemextensionsctl list 2>/dev/null \
        | grep -q 'io.tailscale.ipn.macsys.network-extension'; then
    echo "ERROR: Tailscale's GUI system extension is still loaded." >&2
    echo "       Even though Tailscale.app is gone, its NetworkExtension is" >&2
    echo "       running and intercepting the tailscale CLI socket." >&2
    echo "       Remove it:" >&2
    echo "         sudo systemextensionsctl developer on" >&2
    echo "         sudo systemextensionsctl uninstall W5364U7YZB io.tailscale.ipn.macsys.network-extension" >&2
    echo "         sudo systemextensionsctl developer off" >&2
    echo "         sudo shutdown -r now    # reboot to fully unload" >&2
    exit 1
fi

#=============================================================================
# STEP 2: Locate Homebrew (required to install the open-source tailscaled)
#=============================================================================
BREW=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
        BREW="$candidate"
        break
    fi
done

# Determine which non-root user to run brew as.
# Prefer SUDO_USER (interactive SSH/sudo — that user explicitly invoked us
# and is presumably an admin). Fall back to the GUI console user for Jamf/MDM
# contexts where the script runs as root with no SUDO_USER. Last resort: the
# owner of an existing brew prefix.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    CONSOLE_USER="${SUDO_USER}"
else
    CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null || true)"
fi
if [[ -n "$BREW" && ( -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ) ]]; then
    CONSOLE_USER="$(stat -f%Su "$(dirname "$BREW")")"
fi
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ]]; then
    echo "ERROR: Could not determine a non-root user to run Homebrew as." >&2
    echo "       Set SUDO_USER or run via 'sudo' from a real user account." >&2
    exit 1
fi

# Bootstrap Homebrew if missing
if [[ -z "$BREW" ]]; then
    echo "Homebrew not found — installing it (non-interactive)..."
    sudo -u "$CONSOLE_USER" NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x "$candidate" ]]; then
            BREW="$candidate"
            break
        fi
    done

    if [[ -z "$BREW" ]]; then
        echo "ERROR: Homebrew install completed but brew binary still not found." >&2
        exit 1
    fi
fi

echo "Using Homebrew at $BREW (as user: $CONSOLE_USER)"

run_brew() {
    sudo -u "$CONSOLE_USER" "$BREW" "$@"
}

#=============================================================================
# STEP 3: Install / upgrade tailscale via Homebrew
#=============================================================================
echo "Installing tailscale formula..."
if run_brew list --formula tailscale >/dev/null 2>&1; then
    run_brew upgrade tailscale || true
else
    run_brew install tailscale
fi

# Resolve the absolute paths brew installed.
# tailscale: brew links it into ${prefix}/bin
# tailscaled: lives in the keg (e.g. /opt/homebrew/opt/tailscale/bin/tailscaled),
#             not symlinked into ${prefix}/bin or ${prefix}/sbin
TAILSCALE_KEG="$(run_brew --prefix tailscale)"
TAILSCALE="$(command -v tailscale || true)"
[[ -z "$TAILSCALE" ]] && TAILSCALE="${TAILSCALE_KEG}/bin/tailscale"

TAILSCALED=""
for candidate in \
    "${TAILSCALE_KEG}/bin/tailscaled" \
    "${TAILSCALE_KEG}/sbin/tailscaled" \
    "$(run_brew --prefix)/sbin/tailscaled" \
    "$(run_brew --prefix)/bin/tailscaled"; do
    if [[ -x "$candidate" ]]; then
        TAILSCALED="$candidate"
        break
    fi
done

if [[ ! -x "$TAILSCALE" || -z "$TAILSCALED" ]]; then
    echo "ERROR: tailscale or tailscaled binary missing after brew install." >&2
    echo "       tailscale:  ${TAILSCALE}" >&2
    echo "       tailscaled: ${TAILSCALED:-<not found>}" >&2
    echo "       Keg prefix: ${TAILSCALE_KEG}" >&2
    exit 1
fi

echo "Using tailscale:  $TAILSCALE"
echo "Using tailscaled: $TAILSCALED"

#=============================================================================
# STEP 4: Install tailscaled as a LaunchDaemon (root, runs at boot)
#=============================================================================
echo "Installing tailscaled LaunchDaemon..."
"$TAILSCALED" install-system-daemon

# Give launchd a moment to spin it up
sleep 3

# Sanity check: daemon should now be loaded
if ! launchctl list | grep -q com.tailscale.tailscaled; then
    echo "ERROR: tailscaled LaunchDaemon failed to load." >&2
    exit 1
fi

#=============================================================================
# STEP 5: Bring Tailscale up — auth key, tags, SSH, hostname
#=============================================================================
echo "Authenticating and connecting Tailscale..."
"$TAILSCALE" up \
    --authkey="${TAILSCALE_AUTHKEY}" \
    --advertise-tags="${TAILSCALE_TAGS}" \
    --ssh \
    --hostname="${TAILSCALE_HOSTNAME}" \
    --reset

#=============================================================================
# STEP 6: Verify
#=============================================================================
echo
echo "Tailscale status:"
"$TAILSCALE" status

echo
echo "Tailscale deployment complete."
echo "Hostname: ${TAILSCALE_HOSTNAME}"
echo "Tags:     ${TAILSCALE_TAGS}"
echo
echo "To update later:  sudo -u ${CONSOLE_USER} ${BREW} upgrade tailscale"
exit 0
