#!/bin/sh
# Install / update the static 9router-go binary from GitHub Releases.
#
# Runs detached from LuCI because a 40 MB download can outlive an rpcd call.
# Progress is published in /var/run/9router/install.state and polled by the
# overview page.
#
# Arguments: [version] [owner/repo]
#   version  "latest" or a release tag such as v1.9.15-owrt.1
#   repo     GitHub owner/repo that publishes the *static* assets
#
# Safety:
#   - refuses to run without SHA256SUMS.txt and a matching entry
#   - keeps the previous binary as <binary>.bak for rollback
#   - verifies the Go binary starts and /health answers before declaring success
#   - leaves /srv/9router (credentials + SQLite) untouched
#
# The binary is downloaded over HTTPS from the release repository configured in
# UCI (release_repo). Change it in LuCI -> Services -> 9Router -> Settings.

CONFIG=9router
RUN_DIR=/var/run/9router
STATE=$RUN_DIR/install.state
LOCK=$RUN_DIR/install.lock
PIDFILE=$RUN_DIR/9router.pid
LOG=/var/log/9router-install.log
TMP=$RUN_DIR/install.tmp

. /lib/functions.sh
config_load "$CONFIG"

config_get BIN     main binary           /usr/libexec/9router/9router-go
config_get DATA    main data_dir         /srv/9router
config_get PORT    main port             20130
config_get BIND    main bind             0.0.0.0
config_get REPO    main release_repo     ''
config_get VERSION main release_version  'latest'
config_get ARCHCFG main install_arch     ''

[ -n "$1" ] && VERSION="$1"
[ -n "$2" ] && REPO="$2"

mkdir -p "$RUN_DIR" /etc/9router /usr/libexec/9router 2>/dev/null

log() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; }

state() {
	local st="$1" pr="$2"
	shift 2
	{
		echo "state=$st"
		echo "progress=$pr"
		echo "message=$(printf '%s' "$*" | tr '\n' ' ')"
		echo "version=$VERSION"
		echo "updated=$(date +%s)"
	} > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE"
}

swapped=0
had_bin=0
part="$BIN.part"
gz="$BIN.part.gz"
sums="$TMP/SHA256SUMS.txt"
bin_name=$(basename "$BIN")

cleanup() {
	rm -rf "$LOCK" "$part" "$gz" "$TMP" 2>/dev/null
}
trap cleanup EXIT INT TERM

gateway_pid() {
	local p
	p=$(cat "$PIDFILE" 2>/dev/null)
	case "$p" in ''|*[!0-9]*) p=0 ;; esac
	if [ "$p" -gt 0 ] && [ -r "/proc/$p/cmdline" ] && \
	   tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF "$bin_name"; then
		echo "$p"
		return 0
	fi
	p=$(pidof "$bin_name" 2>/dev/null | awk '{ print $1 }')
	case "$p" in ''|*[!0-9]*) p=0 ;; esac
	echo "$p"
}

fail() {
	log "FAILED: $*"
	state failed 0 "$*"
	if [ "$swapped" = 1 ]; then
		rm -f "$BIN"
		if [ "$had_bin" = 1 ] && [ -f "$BIN.bak" ]; then
			mv "$BIN.bak" "$BIN"
			log "rolled back to previous binary"
			/etc/init.d/9router start >/dev/null 2>&1
		else
			uci -q set "$CONFIG.main.enabled=0"
			uci -q commit "$CONFIG"
		fi
	fi
	exit 1
}

fetch() {
	local url="$1" dst="$2"
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -T 60 -O "$dst" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -T 60 -O "$dst" "$url"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 30 -o "$dst" "$url"
	else
		return 127
	fi
}

# ---------------------------------------------------------------- validation

# A crashed install can leave the lock behind; 15 minutes is longer than any
# realistic 18 MB download on a router link.
if [ -d "$LOCK" ]; then
	age=$(($(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0)))
	if [ "$age" -gt 900 ]; then
		log "removing stale install lock (${age}s old)"
		rm -rf "$LOCK"
	fi
fi
if ! mkdir "$LOCK" 2>/dev/null; then
	state failed 0 "Another install is already running"
	exit 1
fi

state queued 1 "Preparing"
log "install requested: version=$VERSION repo=$REPO"

case "$REPO" in
	''|*' '*)
		fail "Set a release repository first (Settings -> Release repository), e.g. owner/9router-go-openwrt"
		;;
esac
case "$VERSION" in
	''|*[!A-Za-z0-9._-]*)
		fail "Invalid version: $VERSION"
		;;
esac
if ! echo "$REPO" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
	fail "Invalid repository: $REPO"
fi

# ---------------------------------------------------------------- arch/space

if [ -n "$ARCHCFG" ]; then
	ARCH="$ARCHCFG"
else
	UNAME_M=$(uname -m)
	case "$UNAME_M" in
		x86_64|amd64)        ARCH=amd64 ;;
		aarch64|arm64)       ARCH=arm64 ;;
		armv7l|armv7)        ARCH=armv7 ;;
		armv6l|armv6)        ARCH=armv6 ;;
		i386|i486|i586|i686) ARCH=386 ;;
		mips64el|mips64le)   ARCH=mips64le ;;
		mips64)              ARCH=mips64 ;;
		mipsel)              ARCH=mipsle ;;
		mips)                ARCH=mips ;;
		*)                   fail "Unsupported CPU architecture: $UNAME_M (set install_arch to override)" ;;
	esac
fi
case "$ARCH" in
	amd64|arm64|armv7|armv6|386|mips|mipsle|mips64|mips64le) ;;
	*) fail "Unsupported install_arch: $ARCH" ;;
esac
ASSET="9router-go-linux-${ARCH}-static.gz"
log "arch=$ARCH asset=$ASSET"

mkdir -p "$(dirname "$BIN")" 2>/dev/null || fail "Cannot create $(dirname "$BIN")"
BIN_DIR=$(dirname "$BIN")
avail_kb=$(df -Pk "$BIN_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')
case "$avail_kb" in ''|*[!0-9]*) avail_kb=0 ;; esac

# Sizes: binary 43 MiB, gzipped asset 18 MiB. Peak usage while extracting:
#   first install  18 + 43                       = 61 MiB -> require 68 MiB
#   update         old 43 + 18 + new 43           = 104 MiB -> require 112 MiB
need_kb=69632
[ -f "$BIN" ] && need_kb=114688
if [ "$avail_kb" -lt "$need_kb" ]; then
	fail "Not enough free space on $BIN_DIR: ${avail_kb} KiB available, ${need_kb} KiB required"
fi

# ------------------------------------------------------------------- version

if [ "$VERSION" = "latest" ]; then
	state resolving 10 "Resolving latest release"
	mkdir -p "$TMP"
	if ! fetch "https://api.github.com/repos/$REPO/releases/latest" "$TMP/release.json"; then
		fail "Cannot reach GitHub API for $REPO"
	fi
	TAG=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP/release.json" | head -n 1)
	[ -n "$TAG" ] || fail "Could not read tag_name from $REPO latest release"
	VERSION="$TAG"
	state resolving 15 "Latest is $VERSION"
fi

BASE="https://github.com/$REPO/releases/download/$VERSION"
log "release base: $BASE"

# ------------------------------------------------------------------ download

state downloading 20 "Downloading checksums"
mkdir -p "$TMP"
if ! fetch "$BASE/SHA256SUMS.txt" "$sums"; then
	fail "Cannot download SHA256SUMS.txt (does release $VERSION exist?)"
fi

WANT=$(awk -v a="$ASSET" '$2 == a || $2 == "*" a { print $1; exit }' "$sums")
[ -n "$WANT" ] || fail "No SHA256 entry for $ASSET in release $VERSION"

state downloading 30 "Downloading $ASSET (about 18 MiB)"
log "downloading $BASE/$ASSET"
if ! fetch "$BASE/$ASSET" "$gz"; then
	fail "Download failed: $BASE/$ASSET"
fi
[ -s "$gz" ] || fail "Downloaded file is empty"

state verifying 75 "Verifying SHA256"
GOT=$(sha256sum "$gz" 2>/dev/null | awk '{ print $1 }')
if [ "$GOT" != "$WANT" ]; then
	fail "SHA256 mismatch for $ASSET (got $GOT, want $WANT)"
fi

state extracting 82 "Extracting binary"
gzip -dc "$gz" > "$part" 2>/dev/null || fail "gzip decompression failed"
rm -f "$gz"
part_size=$(wc -c < "$part" 2>/dev/null)
case "$part_size" in ''|*[!0-9]*) part_size=0 ;; esac
[ "$part_size" -gt 10000000 ] || fail "Extracted binary is too small (${part_size} bytes)"
magic=$(head -c 4 "$part" 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$magic" = "7f454c46" ] || fail "Downloaded asset is not an ELF binary"
chmod 0755 "$part"

# --------------------------------------------------------------------- swap
# Stop the service, wait for the process to really exit, then swap. Writing a
# new binary over a running executable gives ETXTBSY on some kernels.

state stopping 88 "Stopping 9router"
/etc/init.d/9router stop >/dev/null 2>&1
i=0
while [ "$i" -lt 10 ]; do
	P=$(gateway_pid)
	[ "$P" = 0 ] && break
	sleep 1
	i=$((i + 1))
done
P=$(gateway_pid)
[ "$P" != 0 ] && kill "$P" 2>/dev/null && sleep 2
P=$(gateway_pid)
[ "$P" = 0 ] || fail "9router is still running (pid $P); refusing to replace its binary"

[ -f "$BIN" ] && had_bin=1
# Move (not delete) the old binary: it stays usable as the rollback target.
[ -f "$BIN.bak" ] && rm -f "$BIN.bak"
[ -f "$BIN" ] && mv "$BIN" "$BIN.bak"
swapped=1
mv "$part" "$BIN" || fail "Could not install $BIN"
chown root:root "$BIN" 2>/dev/null
chmod 0755 "$BIN"
sync

# Password is normally generated by setup.sh; guarantee it here too so a
# previous "123456" default can never be active.
[ -n "$(uci -q get "$CONFIG.main.dashboard_password")" ] || {
	pw=$(hexdump -n 16 -v -e '16/1 "%02x"' /dev/urandom 2>/dev/null)
	[ -n "$pw" ] && uci -q set "$CONFIG.main.dashboard_password=$pw"
}
uci -q set "$CONFIG.main.enabled=1"
uci -q commit "$CONFIG"

state starting 94 "Starting 9router"
/etc/init.d/9router start >/dev/null 2>&1

# ---------------------------------------------------------------- health check

HEALTH_OK=0
if [ "$BIND" = "0.0.0.0" ] || [ "$BIND" = "127.0.0.1" ] || [ "$BIND" = "" ]; then
	i=0
	while [ "$i" -lt 15 ]; do
		sleep 2
		if [ "$(gateway_pid)" != 0 ] && \
		   fetch "http://127.0.0.1:$PORT/health" "$TMP/health" 2>/dev/null && \
		   grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' "$TMP/health" 2>/dev/null; then
			HEALTH_OK=1
			break
		fi
		i=$((i + 1))
	done
else
	# Non-loopback bind: pid liveness is the best check without knowing the
	# address this router is reachable on.
	sleep 5
	[ "$(gateway_pid)" != 0 ] && HEALTH_OK=1
fi

[ "$HEALTH_OK" = 1 ] || fail "9router did not become healthy; previous binary restored"

cat > /etc/9router/installed <<EOF
version=$VERSION
asset=$ARCH
sha256=$WANT
repo=$REPO
binary=$BIN
installed=$(date +%s)
source=luci
EOF
chmod 0644 /etc/9router/installed 2>/dev/null
sync

swapped=0
state done 100 "Installed $VERSION"
log "installed $VERSION ($ARCH) successfully"
exit 0
