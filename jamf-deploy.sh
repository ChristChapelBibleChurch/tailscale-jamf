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
# Determine the non-root admin user that should own Homebrew
#=============================================================================
if [[ -n "$ADMIN_USER_OVERRIDE" ]]; then
    ADMIN_USER="$ADMIN_USER_OVERRIDE"
else
    ADMIN_USER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
fi

if [[ -z "$ADMIN_USER" || "$ADMIN_USER" == "root" || "$ADMIN_USER" == "loginwindow" ]]; then
    # No one logged in. Fall back to the first local admin account that isn't
    # a system/service user.
    ADMIN_USER="$(
        /usr/bin/dscl . -list /Users UniqueID 2>/dev/null \
            | awk '$2 >= 501 { print $1 }' \
            | while read -r u; do
                if /usr/sbin/dseditgroup -o checkmember -m "$u" admin >/dev/null 2>&1; then
                    echo "$u"; break
                fi
            done
    )"
fi

if [[ -z "$ADMIN_USER" || "$ADMIN_USER" == "root" ]]; then
    echo "ERROR: Could not find a non-root admin user to own Homebrew." >&2
    echo "       Pass an explicit user as Jamf parameter \$5." >&2
    exit 1
fi

# Verify the user actually exists and is a real account.
if ! /usr/bin/id -u "$ADMIN_USER" >/dev/null 2>&1; then
    echo "ERROR: User '$ADMIN_USER' does not exist on this Mac." >&2
    exit 1
fi

ADMIN_HOME="$(/usr/bin/dscl . -read "/Users/$ADMIN_USER" NFSHomeDirectory 2>/dev/null \
    | awk '{print $2}')"

echo "Will install Homebrew (if needed) as: $ADMIN_USER (home: $ADMIN_HOME)"

#=============================================================================
# Install Homebrew if missing (as the admin user, never as root)
#=============================================================================
BREW=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
        BREW="$candidate"
        break
    fi
done

if [[ -z "$BREW" ]]; then
    echo "Homebrew not found \u2014 installing as $ADMIN_USER..."

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

# Pipe the script body in via stdin, but redirect the wrapped script's stdin
# from /dev/null so its internal brew calls can't accidentally consume the
# script body (same reason tailscale-setup.sh redirects stdin in run_brew).
/usr/bin/curl -fsSL "$SCRIPT_URL" \
    | TAILSCALE_AUTHKEY="$AUTHKEY" /bin/bash -s </dev/null

echo
echo "Jamf one-shot deploy complete."
exit 0
