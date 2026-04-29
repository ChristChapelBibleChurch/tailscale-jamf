#!/bin/bash
#
# Tailscale Jamf one-shot deploy
# - Designed to be run by Jamf as root (no sudo, no TTY, no prompts).
# - Installs Homebrew (as the GUI console user) if missing.
# - Fetches and runs the latest tailscale-setup.sh from GitHub.
#
# Jamf script parameters:
#   $4 = Tailscale auth key (tskey-auth-...)   [required]
#   $5 = Override admin user to install Homebrew as (optional, default = console user)
#   $6 = Override script URL (optional, defaults to main branch of this repo)
#
# Why a separate user for brew? Homebrew refuses to run as root. We need a
# non-root admin account that owns the Homebrew prefix. By default we use the
# currently logged-in GUI console user; if no one is logged in, pass $5.
#

set -euo pipefail

#=============================================================================
# Parse Jamf parameters
#=============================================================================
AUTHKEY="${4:-${TAILSCALE_AUTHKEY:-}}"
ADMIN_USER_OVERRIDE="${5:-}"
SCRIPT_URL="${6:-https://raw.githubusercontent.com/ChristChapelBibleChurch/tailscale-jamf/main/tailscale-setup.sh}"

if [[ -z "$AUTHKEY" || "$AUTHKEY" != tskey-* ]]; then
    echo "ERROR: Auth key required in Jamf parameter \$4 (or TAILSCALE_AUTHKEY env)." >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This wrapper expects to be run as root (Jamf runs scripts as root)." >&2
    exit 1
fi

#=============================================================================
# Helper: detect a real, local admin account (UID >= 501)
#=============================================================================
is_local_admin() {
    local u="$1"
    [[ -z "$u" || "$u" == "root" || "$u" == "loginwindow" ]] && return 1
    local uid
    uid="$(/usr/bin/id -u "$u" 2>/dev/null)" || return 1
    [[ "$uid" -ge 501 ]] || return 1
    /usr/sbin/dseditgroup -o checkmember -m "$u" admin >/dev/null 2>&1
}

#=============================================================================
# Locate Homebrew
#=============================================================================
BREW=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
        BREW="$candidate"
        break
    fi
done

#=============================================================================
# Install Homebrew if (and only if) it is not already installed
#=============================================================================
if [[ -n "$BREW" ]]; then
    echo "Homebrew already installed at $BREW \u2014 skipping install."
else
    echo "Homebrew not found \u2014 will install."

    #=========================================================================
    # Determine the non-root admin user that should own Homebrew.
    # This lookup only runs when we actually need to install brew.
    #
    # Priority order (first match wins):
    #   1. Jamf parameter $5             explicit override (e.g. "ccbcadmin")
    #   2. /etc/tailscale-deploy.conf    BREW_OWNER=...
    #   3. The console user, only if they're a real local admin
    #   4. A known service-account name from PREFERRED_ADMINS (handles fleets
    #      provisioned with mixed admin account names like jamfadmin/ccbcadmin)
    #   5. The lowest-UID local admin account on the Mac (last resort)
    #
    # DO NOT fall back to a non-admin console user \u2014 brew install will fail
    # and the formula will end up owned by an account that can't manage it.
    #=========================================================================
    ADMIN_USER=""

    # 1. Explicit Jamf override
    if [[ -n "$ADMIN_USER_OVERRIDE" ]]; then
        if is_local_admin "$ADMIN_USER_OVERRIDE"; then
            ADMIN_USER="$ADMIN_USER_OVERRIDE"
        else
            echo "ERROR: Jamf \$5 override '$ADMIN_USER_OVERRIDE' is not a local admin on this Mac." >&2
            exit 1
        fi
    fi

    # 2. Optional config file
    if [[ -z "$ADMIN_USER" && -r /etc/tailscale-deploy.conf ]]; then
        CONF_BREW_OWNER="$(/usr/bin/awk -F= '/^BREW_OWNER=/ { gsub(/"/,"",$2); print $2 }' /etc/tailscale-deploy.conf | tail -1)"
        if [[ -n "$CONF_BREW_OWNER" ]] && is_local_admin "$CONF_BREW_OWNER"; then
            ADMIN_USER="$CONF_BREW_OWNER"
        fi
    fi

    # 3. Console user, only if they happen to be an admin
    if [[ -z "$ADMIN_USER" ]]; then
        CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
        if is_local_admin "$CONSOLE_USER"; then
            ADMIN_USER="$CONSOLE_USER"
        fi
    fi

    # 4. Known service-account names
    PREFERRED_ADMINS=(ccbcadmin jamfadmin)
    if [[ -z "$ADMIN_USER" ]]; then
        for candidate in "${PREFERRED_ADMINS[@]}"; do
            if is_local_admin "$candidate"; then
                ADMIN_USER="$candidate"
                break
            fi
        done
    fi

    # 5. Lowest-UID local admin
    if [[ -z "$ADMIN_USER" ]]; then
        ADMIN_USER="$(
            /usr/bin/dscl . -list /Users UniqueID 2>/dev/null \
                | awk '$2 >= 501 { print $2, $1 }' \
                | sort -n \
                | awk '{print $2}' \
                | while read -r u; do
                    if /usr/sbin/dseditgroup -o checkmember -m "$u" admin >/dev/null 2>&1; then
                        echo "$u"; break
                    fi
                done
        )"
    fi

    if [[ -z "$ADMIN_USER" ]] || ! is_local_admin "$ADMIN_USER"; then
        echo "ERROR: Could not find a local admin user on this Mac to own Homebrew." >&2
        echo "       Pass one as Jamf parameter \$5 (e.g. 'ccbcadmin')," >&2
        echo "       or add 'BREW_OWNER=ccbcadmin' to /etc/tailscale-deploy.conf." >&2
        exit 1
    fi

    ADMIN_HOME="$(/usr/bin/dscl . -read "/Users/$ADMIN_USER" NFSHomeDirectory 2>/dev/null \
        | awk '{print $2}')"

    echo "Installing Homebrew as: $ADMIN_USER (home: $ADMIN_HOME)"

    # NONINTERACTIVE=1: skip "Press RETURN" prompt + auto-accept CLT install.
    # HOME must be set to the admin user's home or brew complains.
    /usr/bin/sudo -u "$ADMIN_USER" -H \
        /usr/bin/env \
            HOME="$ADMIN_HOME" \
            NONINTERACTIVE=1 \
            CI=1 \
        /bin/bash -c \
        "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

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

echo "Homebrew available at: $BREW"

#=============================================================================
# Fetch and run the main tailscale-setup.sh
#=============================================================================
echo "Fetching tailscale-setup.sh from: $SCRIPT_URL"

# Download to a temp file first (instead of piping curl|bash) so that:
#   1. We get curl's real exit code separately from bash's.
#   2. If the inner script exits non-zero, Jamf's log shows the actual error,
#      not curl's misleading "exit 23 / write error" from a closed pipe.
TMP_SCRIPT="$(/usr/bin/mktemp /tmp/tailscale-setup.XXXXXX.sh)"
trap 'rm -f "$TMP_SCRIPT"' EXIT

if ! /usr/bin/curl -fsSL "$SCRIPT_URL" -o "$TMP_SCRIPT"; then
    echo "ERROR: Failed to download $SCRIPT_URL" >&2
    exit 1
fi

if [[ ! -s "$TMP_SCRIPT" ]]; then
    echo "ERROR: Downloaded script is empty." >&2
    exit 1
fi

echo "Running tailscale-setup.sh..."
set +e
TAILSCALE_AUTHKEY="$AUTHKEY" /bin/bash "$TMP_SCRIPT"
SETUP_EXIT=$?
set -e

if [[ $SETUP_EXIT -ne 0 ]]; then
    echo "ERROR: tailscale-setup.sh exited with code $SETUP_EXIT" >&2
    exit $SETUP_EXIT
fi

echo
echo "Jamf one-shot deploy complete."
exit 0
