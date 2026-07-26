# APT proxy client setup

`setup-apt-proxy.sh` configures Debian and Ubuntu APT clients to:

- use `https://apt1.risk-mermaid.ts.net` for HTTP repositories while the
  Apt-Cacher-NG service is reachable;
- use the original repository directly when Apt1 is unreachable;
- always retrieve HTTPS repositories directly.

## Server architecture

The Apt-Cacher-NG server is deliberately not exposed on the LAN. The service
listens only on the loopback interface, and Tailscale Serve provides two
tailnet-only TLS endpoints:

| Purpose | Tailnet endpoint | Local target |
| --- | --- | --- |
| APT forward proxy | `https://apt1.risk-mermaid.ts.net:443` | Raw TLS-terminated TCP to `127.0.0.1:3142` |
| Report interface | `https://apt1.risk-mermaid.ts.net:3142/acng-report.html` | HTTPS reverse proxy to `http://127.0.0.1:3142` |

APT clients use the port 443 endpoint without including the default port:

```text
https://apt1.risk-mermaid.ts.net
```

### Restrict Apt-Cacher-NG to localhost

On `apt1`, set the following values in
`/etc/apt-cacher-ng/acng.conf`:

```text
BindAddress: 127.0.0.1 ::1
Port: 3142
```

Restart the service:

```sh
sudo systemctl restart apt-cacher-ng
sudo systemctl status apt-cacher-ng --no-pager
```

Confirm that port 3142 is bound only to `127.0.0.1` and `::1`:

```sh
sudo ss -lntp | grep ':3142'
```

The output must not show `0.0.0.0:3142`, `[::]:3142`, a LAN address, or the
server's Tailscale address.

### Configure Tailscale Serve

Port 443 must use TLS-terminated TCP rather than an HTTP reverse proxy. This
preserves the absolute request URLs required by the APT forward-proxy protocol:

```sh
sudo tailscale serve --bg \
  --tls-terminated-tcp=443 \
  tcp://127.0.0.1:3142
```

Do not add `--proxy-protocol`; Apt-Cacher-NG is not configured to parse PROXY
protocol headers.

Expose the report page separately using a normal HTTPS reverse proxy on port
3142:

```sh
sudo tailscale serve --bg \
  --https=3142 \
  http://127.0.0.1:3142
```

Check both listeners:

```sh
tailscale serve status
```

The report is available only through the tailnet at:

```text
https://apt1.risk-mermaid.ts.net:3142/acng-report.html
```

### Verify the server

Verify the local report page on `apt1`:

```sh
curl --fail http://127.0.0.1:3142/acng-report.html \
  --output /dev/null
```

Verify Debian caching from another tailnet machine:

```sh
curl --proxy https://apt1.risk-mermaid.ts.net \
  --fail --silent --show-error \
  --output /dev/null \
  --write-out 'HTTP %{http_code}, %{size_download} bytes\n' \
  http://deb.debian.org/debian/dists/bookworm/InRelease
```

Verify Proxmox caching:

```sh
curl --proxy https://apt1.risk-mermaid.ts.net \
  --fail --silent --show-error \
  --output /dev/null \
  --write-out 'HTTP %{http_code}, %{size_download} bytes\n' \
  http://download.proxmox.com/debian/pve/dists/trixie/InRelease
```

Both proxy tests should return `HTTP 200`.

## Install on a client

Copy `setup-apt-proxy.sh` to the VM or container and run:

```sh
chmod +x setup-apt-proxy.sh
sudo ./setup-apt-proxy.sh install
```

The installer is safe to run again. It installs:

- `/usr/local/sbin/apt-proxy-detect`
- `/etc/apt/apt.conf.d/99-apt-proxy`
- `/usr/local/sbin/apt-proxy` as a symlink to the cloned installer

If either destination already contains an unmanaged file, it is preserved with
the suffix `.pre-apt-proxy`.

The installer also corrects the incomplete
`http://security.debian.org bookworm-security` entry found in some container
templates. It changes that entry to
`http://deb.debian.org/debian-security bookworm-security` and saves the
original source file with the suffix `.pre-apt-proxy-security`.

## Automatic updates

Before every `install`, `status`, or `test`, the command runs:

```sh
git pull --ff-only
```

If an update is installed, the requested command restarts using the new
version. If GitHub is unavailable, the local repository has tracked changes, or
the script is not running from a Git checkout, it warns and continues with the
installed version. Uninstall never depends on network access.

The installed APT configuration also invokes the same fail-open update check
automatically before:

- `apt update` and `apt-get update`;
- APT install and upgrade operations.

This keeps the Git checkout current even on machines where nobody manually
runs `apt-proxy`. The hook only runs Git; it never starts another APT process,
so it does not recurse or compete for APT's package-manager lock. A failed Git
update is reduced to a warning and never blocks package retrieval.

To skip the update check for one command:

```sh
sudo APT_PROXY_NO_UPDATE=1 apt-proxy test
```

## Check or test

```sh
sudo apt-proxy status
sudo apt-proxy test
```

The decision shown by `status` will be either the Apt1 URL or `DIRECT`.
Set `NO_COLOR=1` to disable colored output.

For an end-to-end failover test, stop `apt-cacher-ng` briefly on Apt1, run the
client test, and then restart the service:

```sh
# On apt1
systemctl stop apt-cacher-ng

# On the client
sudo apt-proxy test

# On apt1
systemctl start apt-cacher-ng
```

## Uninstall

```sh
sudo apt-proxy uninstall
```

Any files saved with `.pre-apt-proxy` are restored.

## Alternate endpoint

The defaults can be overridden during installation:

```sh
sudo APT_PROXY_URL=http://apt1.example:3142 \
  ./setup-apt-proxy.sh install
```
