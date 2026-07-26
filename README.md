# APT proxy client setup

`setup-apt-proxy.sh` configures Debian and Ubuntu APT clients to:

- use `https://apt1.risk-mermaid.ts.net` for HTTP repositories while the
  Apt-Cacher-NG service is reachable;
- use the original repository directly when Apt1 is unreachable;
- always retrieve HTTPS repositories directly.

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

## Check or test

```sh
sudo apt-proxy status
sudo apt-proxy test
```

The decision shown by `status` will be either the Apt1 URL or `DIRECT`.

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
