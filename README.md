# tailscale-jamf

Silent Tailscale deploy script for macOS, suitable for Jamf, local execution, or remote SSH.

## Usage

The script needs a Tailscale auth key. It checks (in order):

1. `--authkey=tskey-...` CLI flag
2. `TAILSCALE_AUTHKEY` environment variable
3. Jamf script parameter `$4`
4. Config file at `/etc/tailscale-deploy.conf` or `~/.config/tailscale-deploy.conf`

### Local

```sh
sudo ./tailscale-setup.sh --authkey=tskey-auth-xxxxx
```

Or stash the key once:

```sh
sudo install -m 600 tailscale-deploy.conf.example /etc/tailscale-deploy.conf
sudo vi /etc/tailscale-deploy.conf   # set the real key
sudo ./tailscale-setup.sh
```

### Remote over SSH

Pass the key via env var without writing it to the remote disk:

```sh
ssh user@host "sudo TAILSCALE_AUTHKEY=tskey-auth-xxxxx bash -s" < tailscale-setup.sh
```

Or, if the script is already on the remote host:

```sh
ssh user@host "sudo /path/to/tailscale-setup.sh --authkey=tskey-auth-xxxxx"
```

### Jamf

Add the script to Jamf and pass the auth key as parameter 4.

## Security

- `*.conf`, `*.authkey`, and `.env*` files are gitignored.
- Never commit a real `tskey-...` value.
