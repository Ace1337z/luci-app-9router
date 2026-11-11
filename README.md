# luci-app-9router

LuCI panel that installs, supervises and monitors
[9router-go](https://github.com/luqman-v1/9router-go) on OpenWrt.

Maintainer: **Ace1337z** — Telegram [@bytewrt](https://t.me/bytewrt).
Open an issue on GitHub or send a Telegram message for bugs, packaging
questions and release requests.

The binary is **not** shipped in the firmware. The package installs a small
root-owned installer; the ~43 MB static gateway binary is downloaded on demand
from this repository's GitHub Releases, verified against `SHA256SUMS.txt`, and
kept under `/usr/libexec/9router/9router-go` with a `.bak` copy for rollback.

## Why a custom release repository

Upstream release binaries are **glibc dynamic** (`libc.so.6`, `GLIBC_2.34`) and
do not run on musl-based OpenWrt. This package expects assets built with
`CGO_ENABLED=0`:

```
9router-go-linux-<arch>-static.gz
SHA256SUMS.txt
```

`scripts/build-static.sh` builds those assets for `amd64 arm64`.
32-bit targets are not built: upstream v1.9.15 uses 64-bit-sized integer
constants and does not compile as `arm`/`386`/`mips`.
`.github/workflows/release.yml` runs it on every `v*` tag and attaches the
files to the release.

The package already knows where to fetch the binary: static builds of
`luqman-v1/9router-go` are published on this repository's own GitHub Releases
and the installer uses them by default. There is no source URL to type in —
press **Install 9router-go** on the Overview page.

You can still point the panel at a mirror or pin a release in
**Tools -> 9Router -> Settings -> Release source** (`owner/repo`). Empty or the
legacy `OWNER/...` placeholder means "use the built-in source"; no upgrade
overwrites an explicit mirror value.

## Requirements

| Item | Minimum | Notes |
| --- | --- | --- |
| RAM | 128 MiB | 43 MiB binary, ~45 MiB RSS at idle |
| Free overlay | 68 MiB (first install) | 112 MiB for an update: old binary + download + new binary |
| Packages | `rpcd-mod-ucode`, `ucode-mod-fs`, `ucode-mod-uci`, `uclient-fetch`, `ca-bundle` | pulled in automatically |
| Storage | overlay on flash/eMMC | `/srv/9router` holds SQLite; do not put it on tmpfs |

## Layout

```
/etc/config/9router                     UCI config (password, port, dirs, release repo)
/etc/init.d/9router                     procd service, user 9router
/etc/init.d/9router-monitor             procd sampler (root, nice 10)
/usr/libexec/9router/run.sh             stdin workaround + PID file
/usr/libexec/9router/install.sh         detached downloader/verifier/rollback
/usr/libexec/9router/monitor.sh         CSV sampler
/usr/libexec/9router/setup.sh           idempotent user/dir/password setup
/usr/libexec/9router/9router-go         installed at runtime (not in the package)
/usr/share/rpcd/ucode/9router.uc        ubus object "9router"
/usr/share/luci/menu.d/luci-app-9router.json
/www/luci-static/resources/view/9router/{overview,settings}.js
/srv/9router                            DATA_DIR: db/data.sqlite, jwt-secret, uploads
/var/run/9router/monitor.csv            sampler history (tmpfs, lost on reboot)
/var/run/9router/install.state          installer progress, polled by the UI
/etc/9router/installed                  marker: this binary was installed by LuCI
```

### stdin workaround

9router-go shows an interactive menu when `stdin` is a character device.
procd gives children `/dev/null`, which **is** a character device, so the
process would print a menu and never listen. `run.sh` starts it with stdin
redirected from the regular empty file `/usr/libexec/9router/stdin`, which
makes the binary run headless. Do not "simplify" this by calling the binary
directly from the init script.

## Build

Package (drop the directory into an OpenWrt tree or feed):

```sh
ln -s /path/to/luci-app-9router package/luci-app-9router
make package/luci-app-9router/compile V=s
```

Static assets (needs Go >= 1.22 and bun):

```sh
sh scripts/build-static.sh v1.9.15-owrt.1 dist
ls dist   # *.gz + SHA256SUMS.txt
```

Then create a GitHub release, upload `dist/*`, and set `release_repo` to that
repository.

## Install / upgrade

1. Install the LuCI package (`opkg install` / `apk add`, or bake it into an
   image).
2. Open **Tools -> 9Router**.
3. Press **Install 9router-go** — one click downloads, verifies, installs and
   starts the gateway. No settings are required.

The installer:

1. resolves `latest` through the GitHub API (or uses the pinned version),
2. refuses to start if free space is below the requirement,
3. downloads `SHA256SUMS.txt` and the `.gz`, verifies SHA256,
4. checks the gzip payload is a real ELF > 10 MB,
5. stops the service, waits for the process to exit, moves the old binary to
   `.bak`, installs the new one, `sync`s,
6. starts the service and polls `http://127.0.0.1:<port>/health` for up to 30 s,
7. on any failure restores `.bak` and restarts the previous binary.

Updates never touch `/srv/9router`, so the database and credentials survive.

### The download fails on a carrier that blocks part of GitHub

Symptom: the install stops at *Downloading checksums* and the UI says
`Cannot download SHA256SUMS.txt ...`, even though the release exists and the
version was resolved a second earlier. `/var/log/9router-install.log` shows

```
release base: https://github.com/<owner>/<repo>/releases/download/<tag>
FAILED: Cannot download SHA256SUMS.txt ...
```

Cause: `github.com` resolves to several IPv4 addresses and some mobile
carriers blackhole one of them. `api.github.com` is a *different* address, so
listing the release works while every asset download hangs. `uclient-fetch` is
IPv4-only with no happy-eyeballs: it connects to the single address the
resolver returned and, if that one is dead, fails after its 60 s timeout -
every time.

The installer therefore tries `curl` first (it tries every resolved address,
including IPv6, and follows the redirect to
`release-assets.githubusercontent.com`), then `uclient-fetch` (default family,
then `-6`), then `wget`. If your firmware has no `curl`, installing it
(`apk add curl` / `opkg install curl`) is the reliable workaround; the
`fetched via curl:` line in the log confirms which tool was used.

## Monitoring

`9router-monitor` samples every `sample_interval` seconds (default 30) and
appends one CSV line:

```
ts,cpu_x100,rss_kb,mem_used_kb,data_kb,flash_used_kb,flash_total_kb,
proc_ticks,total_ticks,pid,data_used_kb,data_total_kb
```

- `cpu_x100` is percent x100; `10000` means one fully busy core on any core count.
- `flash_*` is the overlay filesystem, where the binary lives.
- `data_*` is the filesystem that holds `DATA_DIR` (may be USB).
- History is trimmed to `history_points` lines.
- The file is on **tmpfs** (`/var/run/9router`), so nothing writes flash every
  30 s and history resets on reboot. Point `history_file` at persistent storage
  only if you accept the flash wear.

The overview page draws CPU, RSS, flash used and data-directory size from that
CSV.

## Password

`setup.sh` generates a random 32-hex-character dashboard password once and
stores it in `/etc/config/9router` (`dashboard_password`). The upstream
`123456` fallback is never used. Reveal or change it on the overview page;
the gateway reads it at start, so restart the service after changing it.

`/etc/config/9router` is mode `0600` (root only). The gateway never reads UCI:
the init script reads the config as root and passes `BIN`, `DATA_DIR`, `HOST`,
`PORT`, `INITIAL_PASSWORD`, `AUTO_UPDATE`, `HOME` and `TMPDIR` to the child
through `procd_set_param env`.

## Recovery

The package never touches the bootloader, partition table or calibration data,
and the gateway runs as an unprivileged user, so a bad 9router-go binary cannot
brick the router.

- **Service will not start**: the UI shows `Stopped`; check **Show log**.
  Press **Roll back** to restore `.bak`, or **Uninstall binary** to remove it.
- **Bad binary installed, LuCI still reachable**: use *Roll back*.
- **LuCI broken**: `ssh root@router` then
  `/etc/init.d/9router stop` and `rm -f /usr/libexec/9router/9router-go*`.
  LuCI itself never depends on the gateway process.
- **Disk full during update**: the installer aborts before swapping, so the
  previous binary keeps running.
- **After sysupgrade**: `/usr/libexec/9router/9router-go` is not part of the
  package and is removed by the upgrade; `/etc/9router/installed` survives and
  the UI shows *needs reinstall*. Press **Install 9router-go** again.
  `/srv/9router` is on the overlay and survives `sysupgrade` (`-n` discards it,
  as it discards all config).
- **Package removed**: `prerm` stops both services and deletes only a binary
  that has the `/etc/9router/installed` marker. `/srv/9router` is always kept.

## Known limitations

- Only static assets work. A glibc release binary fails with `not found` (the
  interpreter is missing) and the installer's health check catches it, but the
  release repository must publish `*-static.gz`.
- `latest` uses the unauthenticated GitHub API (60 requests/hour per IP). Pin
  `release_version` on routers behind a shared NAT.
- Browser access to the dashboard uses plain HTTP. Bind to `127.0.0.1` or a
  VPN address, or put it behind the router's TLS reverse proxy.
- History is not preserved across reboot by default.
- Only 64-bit `amd64` and `arm64` assets are published. 32-bit routers are not
  supported by the current upstream source.
- The DB is never garbage-collected by this package; watch the *Data directory*
  chart and raise `sample_interval` if `du` on a huge data dir is expensive.

## Test plan

On a spare device (or QEMU with an overlay):

1. Cold boot with the package but no binary: overview shows *Stopped*, install
   button enabled, no error in `logread`.
2. Install with a bad repository: installer fails with a clear message, no
   binary left behind.
3. Install with a truncated asset: SHA256 failure, no service change.
4. Install with a wrong-architecture asset: health check fails, `.bak` restored.
5. Normal install: `/health` answers, dashboard reachable, RSS ~45 MiB.
6. Update to the same release: `.bak` exists, free space guard triggers below
   112 MiB.
7. Roll back: old binary runs, marker removed.
8. Reboot: service comes back if `enabled=1`, sampler history restarts empty.
9. `sysupgrade` keeping config: package present, binary gone, UI says reinstall.
10. `sysupgrade -n`: config and `/srv/9router` gone, password regenerated on
    first boot.
11. Remove the package: services stopped, binary removed, `/srv/9router` intact.
12. Carrier block: `ip route add blackhole 20.205.243.166` (or any address
    `github.com` resolves to) and install again. It must still succeed; the log
    shows `fetched via curl:`. Without the fix this reproduces the
    `Cannot download SHA256SUMS.txt` failure in 60 s.
13. Stalled transfer: `iptables -I OUTPUT -d <asset host> -m connbytes
    --connbytes 2000000: --connbytes-dir original -j DROP` mid-download must
    abort within ~60 s of silence and report the failure, not hang until
    `--max-time`.
