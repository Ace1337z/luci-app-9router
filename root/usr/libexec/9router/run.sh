#!/bin/sh
# procd wrapper for 9router-go. Does two things only:
#
# 1. stdin. 9router-go's bare entrypoint shows an interactive menu when stdin
#    is a character device. procd normally gives a child /dev/null, which IS a
#    character device, so the process would print a menu and never listen.
#    Redirecting stdin from the regular empty file /usr/libexec/9router/stdin
#    makes stdinIsTerminal() false and the server starts headless.
# 2. PID file. exec() keeps the PID, so the gateway is traceable by the
#    installer and the sampler without a `pidof` name race.
#
# Configuration is passed by the init script through procd_set_param env:
# BIN, DATA_DIR, HOST, PORT, INITIAL_PASSWORD, AUTO_UPDATE, HOME, TMPDIR.
# Keeping it there lets /etc/config/9router stay mode 0600 (root only).

RUN_DIR=/var/run/9router

: "${DATA_DIR:=/srv/9router}"
: "${HOME:=/var/run/9router}"
: "${TMPDIR:=/var/run/9router}"

export DATA_DIR HOME TMPDIR
export AUTO_UPDATE="${AUTO_UPDATE:-false}"

mkdir -p "$DATA_DIR" "$RUN_DIR" 2>/dev/null
date +%s > "$RUN_DIR/started" 2>/dev/null
echo $$ > "$RUN_DIR/9router.pid" 2>/dev/null

exec "${BIN:-/usr/libexec/9router/9router-go}" < /usr/libexec/9router/stdin
