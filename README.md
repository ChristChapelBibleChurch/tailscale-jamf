# tailscale-jamf

Silent Tailscale deploy script for macOS. Installs the **open-source `tailscaled`**
(via Homebrew) as a LaunchDaemon so the device joins the tailnet at boot — before
any user logs in — and enables **Tailscale SSH**.

> Why not the `.pkg` / App Store Tailscale.app? That variant runs in Apple's
> System Extension sandbox, which blocks the Tailscale SSH server. Only the
> open-source `tailscaled` daemon can act as a Tailscale SSH server on macOS.

---

## Quickstart — set up a brand-new Mac remotely over SSH

Use this when you've just received a new Mac (no Tailscale yet) and you
need to enroll it in the tailnet by SSH'ing in over the local network.

**Prereqs on the target Mac:**

- Remote Login enabled (`System Settings → General → Sharing → Remote Login`)
- An admin account named `CCBCAdmin` (substitute your own admin if different)
- The Mac is reachable on the LAN (you have its IP or `.local` name)
- **Homebrew installed** — see [Installing Homebrew](#installing-homebrew-prerequisite) below

**On your machine** \u2014 SSH in first, then run the install on the remote shell
so `sudo` can prompt for the password normally:

```sh
# 1. Get a fresh auth key from https://login.tailscale.com/admin/settings/keys
#    See "Generating the auth key" below \u2014 must be reusable, ephemeral=optional,
#    pre-approved, and tagged with tag:communications.

# 2. SSH into the target Mac
ssh CCBCAdmin@<mac-ip-or-name>

# 3. On the remote shell, install Homebrew if missing, then run the
#    tailscale setup. `sudo -v` prompts for CCBCAdmin's password once and
#    caches it so the brew installer (which uses sudo internally and won't
#    prompt under NONINTERACTIVE=1) and the final tailscale install both
#    reuse the cached credential \u2014 one password prompt total.
AUTHKEY=tskey-auth-xxxxxxxxxxxx

sudo -v

if ! [ -x /opt/homebrew/bin/brew ] && ! [ -x /usr/local/bin/brew ]; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

curl -fsSL https://raw.githubusercontent.com/ChristChapelBibleChurch/tailscale-jamf/main/tailscale-setup.sh \
  | sudo TAILSCALE_AUTHKEY="$AUTHKEY" bash
```

`sudo -v` caches your password for ~5 minutes (the default sudo timeout).
`NONINTERACTIVE=1` then tells the Homebrew installer to skip its "Press RETURN
to continue" and CLT confirmation prompts \u2014 and because sudo is already
authenticated, brew's internal `sudo` calls don't need to prompt either. The
two installs are chained so tailscale starts immediately after Homebrew finishes.

> **Heads-up: Xcode Command Line Tools.** On a fresh Mac with no CLT installed,
> Homebrew triggers the OS to install them. With `NONINTERACTIVE=1` it skips
> the terminal prompt, but macOS may still pop a **GUI dialog on the target
> Mac's screen** asking to confirm. If the Mac is headless or unattended,
> pre-install CLT silently first (one SSH command):
>
> ```sh
> ssh -t CCBCAdmin@<mac-ip-or-name> '
>   sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
>   PROD=$(softwareupdate -l | grep -E "Command Line Tools" | tail -1 | awk -F"*" "{print \$2}" | sed "s/^ *//")
>   sudo softwareupdate -i "$PROD" --verbose
>   sudo rm /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
> '
> ```

> **Why two steps?** Piping `curl ... | ssh "sudo bash -s"` from your laptop
> works, but it ties up stdin with the script body, so `sudo` can't read your
> password from the terminal and may fail with "sudo: a terminal is required".
> SSH'ing first and running the pipeline on the remote shell sidesteps that
> entirely.

1. Refuse to run if the GUI Tailscale.app or its system extension is installed
   (it'll print exact removal commands).
2. Refuse to run if Homebrew isn't installed (install it first — see below).
3. `brew install tailscale`.
4. Register `tailscaled` as a root LaunchDaemon (`com.tailscale.tailscaled`).
5. Run `tailscale up` with the auth key, `tag:communications`, `--ssh`, and the
   Mac's `ComputerName` as the hostname.
6. Print `tailscale status`.

When it finishes, the device shows up in the Tailscale admin console already
tagged, and you can immediately reach it via Tailscale SSH:

```sh
tailscale ssh CCBCAdmin@<computername>
```

---

## Installing Homebrew (prerequisite)

The script does **not** install Homebrew — it only refuses to run without it.
Install Homebrew once on the target Mac before running `tailscale-setup.sh`.

**Interactively, sitting at the Mac:**

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**Remotely over SSH** (must run as a regular admin user, _not_ root — brew
refuses to install as root):

```sh
ssh -t CCBCAdmin@<mac-ip-or-name> \
  'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
```

`NONINTERACTIVE=1` skips the "Press RETURN to continue" prompt, which would
otherwise hang a non-TTY SSH session.

After install, verify:

```sh
ssh CCBCAdmin@<mac-ip-or-name> 'ls /opt/homebrew/bin/brew /usr/local/bin/brew 2>/dev/null'
```

One of those paths must exist — `/opt/homebrew/bin/brew` on Apple Silicon,
`/usr/local/bin/brew` on Intel. The setup script auto-detects either.

---

## Generating the auth key (expires every 90 days)

The script needs a **pre-authorized, tagged auth key** so devices join silently
and land in the right ACL group with no manual approval. **Tags are baked into
the auth key** and the device inherits them automatically — the script itself
is tag-agnostic, so you can use the same script with different keys to deploy
devices into different groups (e.g. `tag:communications`, `tag:office`,
`tag:kiosk`).

1. Sign in to <https://login.tailscale.com/admin/settings/keys>.
2. Click **Generate auth key…**
3. Set:
   - **Reusable:** ✅ on (so the same key works for every Mac you set up)
   - **Ephemeral:** ❌ off (these are long-lived workstations)
   - **Pre-approved:** ✅ on (skip device approval)
   - **Tags:** pick whichever tag(s) the devices using this key should get
     (e.g. `tag:communications`). Make sure a corresponding `tagOwners` entry
     exists in your tailnet policy file (see below).
   - **Expiration:** 90 days (Tailscale's max for auth keys)
4. Copy the `tskey-auth-…` value **immediately** — it's only shown once.
5. Store it in your password manager labeled with the **expiration date** and
   which tag(s) it grants.

### When the key expires (every 90 days)

Auth keys can't be renewed — you generate a new one and rotate:

1. Generate a new key per the steps above.
2. Update wherever you store it for deploys:
   - **1Password / shared vault** — replace the entry, re-share.
   - **Jamf** — edit the policy and replace script parameter `$4` with the new key.
   - **Server-side `/etc/tailscale-deploy.conf`** — `sudo vi` and replace the value.
3. Revoke the old key on the same admin page so a leaked copy can't be used.

> **Tag prerequisites:** before a tagged key works, an ACL **tag owner** must
> exist for that tag in your tailnet policy file, e.g.
> `"tagOwners": { "tag:communications": ["group:admins"] }`. Without that,
> auth-key generation will fail.

---

## How the script picks up the auth key

Resolution order (first match wins):

1. `--authkey=tskey-...` CLI flag
2. `TAILSCALE_AUTHKEY` environment variable
3. Jamf script parameter `$4`
4. Config file: `/etc/tailscale-deploy.conf` or `~/.config/tailscale-deploy.conf`

---

## Other usage modes

### Local (you're sitting at the Mac)

```sh
sudo ./tailscale-setup.sh --authkey=tskey-auth-xxxxx
```

Or stash the key once and forget the flag:

```sh
sudo install -m 600 tailscale-deploy.conf.example /etc/tailscale-deploy.conf
sudo vi /etc/tailscale-deploy.conf   # paste the real key
sudo ./tailscale-setup.sh
```

### Remote SSH, script already on the target

```sh
ssh CCBCAdmin@host "sudo /path/to/tailscale-setup.sh --authkey=tskey-auth-xxxxx"
```

### Remote SSH, stream from your laptop (no file copy)

```sh
ssh CCBCAdmin@host "sudo TAILSCALE_AUTHKEY=tskey-auth-xxxxx bash -s" < tailscale-setup.sh
```

### Remote SSH, always-latest from GitHub

```sh
curl -fsSL https://raw.githubusercontent.com/ChristChapelBibleChurch/tailscale-jamf/main/tailscale-setup.sh \
  | ssh -t CCBCAdmin@host "sudo TAILSCALE_AUTHKEY=tskey-auth-xxxxx bash -s"
```

### Jamf

Add `tailscale-setup.sh` as a script in Jamf and pass the auth key as
**parameter 4**. Homebrew must already be installed on the target device \u2014
deploy it via a separate Jamf policy first (e.g. an "Install Homebrew" script
that runs as the GUI console user before this one).

---

## Updating Tailscale later

The script installs via Homebrew, so updates are a one-liner. The final line of
a successful run prints the exact command for that machine, e.g.:

```sh
sudo -u CCBCAdmin /opt/homebrew/bin/brew upgrade tailscale
```

---

## Troubleshooting

**`ERROR: /Applications/Tailscale.app is installed`**
Remove the GUI variant first — it shadows the open-source daemon's CLI socket:

```sh
sudo rm -rf /Applications/Tailscale.app
sudo killall Tailscale 2>/dev/null || true
sudo shutdown -r now
```

**`ERROR: Tailscale's GUI system extension is still loaded`**
The `.app` is gone but Apple still has the NetworkExtension cached:

```sh
sudo systemextensionsctl developer on
sudo systemextensionsctl uninstall W5364U7YZB io.tailscale.ipn.macsys.network-extension
sudo systemextensionsctl developer off
sudo shutdown -r now
```

**`ERROR: No valid Tailscale auth key provided`**
Your key is missing, expired, or doesn't start with `tskey-`. Generate a new
one (see above).

**`tailscale up` fails with `requested tags … are not permitted`**
The auth key wasn't generated with a tag, or your tailnet policy file has no
`tagOwners` entry for the tag baked into the key.

---

## Security

- `*.conf`, `*.authkey`, and `.env*` are gitignored — see [`.gitignore`](.gitignore).
- Never commit a real `tskey-...` value. If one leaks, **revoke it immediately**
  at <https://login.tailscale.com/admin/settings/keys>.
- `/etc/tailscale-deploy.conf` should be `root:wheel 0600`.
