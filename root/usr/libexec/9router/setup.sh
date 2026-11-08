#!/bin/sh
# Idempotent first-install setup for luci-app-9router.
#
# Called from the package postinst and from /etc/uci-defaults, so it must be
# safe to run repeatedly and must not overwrite an existing password or data.

CONFIG=9router
DATA_DIR=$(uci -q get "$CONFIG.main.data_dir")
DATA_DIR=${DATA_DIR:-/srv/9router}
RUN_DIR=/var/run/9router

# Dedicated unprivileged account. OpenWrt base has no useradd(8) unless the
# shadow packages are installed, so append the fixed IDs directly. Prefer
# 65533; walk downwards if that UID/GID is already taken.
if ! grep -q '^9router:' /etc/passwd 2>/dev/null; then
	uid=65533
	while [ "$uid" -gt 64000 ] && awk -F: -v u="$uid" '$3 == u { found = 1 } END { exit !found }' /etc/passwd; do
		uid=$((uid - 1))
	done
	echo "9router:x:$uid:$uid:9router:$RUN_DIR:/bin/false" >> /etc/passwd
fi
if ! grep -q '^9router:' /etc/group 2>/dev/null; then
	gid=65533
	while [ "$gid" -gt 64000 ] && awk -F: -v g="$gid" '$3 == g { found = 1 } END { exit !found }' /etc/group; do
		gid=$((gid - 1))
	done
	echo "9router:x:$gid:" >> /etc/group
fi

mkdir -p "$DATA_DIR" "$RUN_DIR" /usr/libexec/9router /etc/9router
chown 9router:9router "$DATA_DIR" "$RUN_DIR" 2>/dev/null
chmod 0700 "$DATA_DIR" 2>/dev/null
chmod 0755 "$RUN_DIR" 2>/dev/null

# Release source used by the one-click installer. Older configs ship the
# "OWNER/9router-go-openwrt" placeholder, which cannot be downloaded from, so
# treat it as unset and migrate it to the built-in repository. An explicit
# mirror/fork value is left alone.
release_repo=$(uci -q get "$CONFIG.main.release_repo")
case "$release_repo" in
	''|OWNER/*)
		uci -q set "$CONFIG.main.release_repo=Ace1337z/luci-app-9router"
		;;
esac

# Never ship the upstream "123456" fallback. Generate a 32-character hex
# password once; the LuCI page can reveal it to an authenticated root session.
if [ -z "$(uci -q get "$CONFIG.main.dashboard_password")" ]; then
	pw=$(hexdump -n 16 -v -e '16/1 "%02x"' /dev/urandom 2>/dev/null)
	[ -n "$pw" ] || pw=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
	[ -n "$pw" ] && uci -q set "$CONFIG.main.dashboard_password=$pw"
fi

uci -q commit "$CONFIG"

# The dashboard password lives in this file, and the gateway now gets all of its
# settings through the environment, so nothing but root needs to read it.
chmod 0600 /etc/config/$CONFIG 2>/dev/null

# rpcd scans /usr/share/rpcd/ucode at start. Reload so the 9router object is
# callable immediately after an install, without a reboot.
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1

exit 0
