#!/bin/sh
# 9router-go resource sampler.
#
# Writes one CSV line per interval:
#   ts,cpu_x100,rss_kb,mem_used_kb,data_kb,flash_used_kb,flash_total_kb,
#   proc_ticks,total_ticks,pid,data_used_kb,data_total_kb
#
# cpu_x100 is percent*100 where 100.00 means one fully busy core (top style,
# so a 4-core box can show 400.00). It is derived from deltas of
# /proc/<pid>/stat utime+stime against /proc/stat total jiffies, which avoids
# needing CLK_TCK or getconf on the target.
#
# Columns 5-6 are the overlay filesystem (where the 43 MB binary lives), not
# the data directory: data may sit on a USB stick whose usage is columns 10-11.
#
# The file lives on tmpfs by default (/var/run/9router). That is intentional:
# a router should not write flash every 30 seconds. Point history_file at
# persistent storage only if you accept the flash wear.
#
# rss/mem/data/fs columns are kB. data_kb is `du -sk` of DATA_DIR; on a huge
# data directory raise sample_interval.

CONFIG=9router
RUN_DIR=/var/run/9router
. /lib/functions.sh

trap 'exit 0' TERM INT

mkdir -p "$RUN_DIR" 2>/dev/null

# Restore the last sample so a sampler restart does not produce a bogus CPU
# spike from a zero baseline.
prev_ts=0
prev_proc=0
prev_total=0
prev_pid=0

df2() {
	# $1 = path; prints "total used"
	df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $2, $3 }'
}

while true; do
	config_load "$CONFIG"
	config_get out      main history_file    "$RUN_DIR/monitor.csv"
	config_get data     main data_dir        /srv/9router
	config_get interval main sample_interval 30
	config_get points   main history_points  1440
	config_get bin      main binary          /usr/libexec/9router/9router-go

	case "$interval" in
		''|*[!0-9]*) interval=30 ;;
	esac
	[ "$interval" -ge 15 ] || interval=15
	[ "$interval" -le 3600 ] || interval=3600
	case "$points" in
		''|*[!0-9]*) points=1440 ;;
	esac
	[ "$points" -ge 60 ] || points=60
	[ "$points" -le 20000 ] || points=20000

	mkdir -p "$(dirname "$out")" 2>/dev/null

	if [ -s "$out" ] && [ "$prev_ts" = 0 ]; then
		last=$(tail -n 1 "$out" 2>/dev/null)
		IFS=, read -r prev_ts _ _ _ _ _ _ prev_proc prev_total prev_pid <<EOF
$last
EOF
		case "$prev_ts" in ''|*[!0-9]*) prev_ts=0 ;; esac
		case "$prev_proc" in ''|*[!0-9]*) prev_proc=0 ;; esac
		case "$prev_total" in ''|*[!0-9]*) prev_total=0 ;; esac
		case "$prev_pid" in ''|*[!0-9]*) prev_pid=0 ;; esac
	fi

	now=$(date +%s)
	ncpu=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
	case "$ncpu" in ''|*[!0-9]*|0) ncpu=1 ;; esac

	total=$(awk 'NR == 1 { s = 0; for (i = 2; i <= NF; i++) s += $i; print s; exit }' /proc/stat 2>/dev/null)
	case "$total" in ''|*[!0-9]*) total=0 ;; esac

	# run.sh records $$ before exec(), so the pidfile holds the gateway PID.
	# Verify the PID still belongs to the gateway before trusting it.
	pid=$(cat "$RUN_DIR/9router.pid" 2>/dev/null)
	case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
	if [ "$pid" -gt 0 ] && [ -r "/proc/$pid/cmdline" ] && \
	   ! tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$(basename "$bin")"; then
		pid=0
	fi
	if [ "$pid" = 0 ]; then
		pid=$(pidof "$(basename "$bin")" 2>/dev/null | awk '{ print $1 }')
		case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
	fi

	proc=0
	rss=0
	if [ "$pid" -gt 0 ] && [ -r "/proc/$pid/stat" ]; then
		proc=$(awk -F')' '{ n = split($2, a, " "); print a[12] + a[13] }' "/proc/$pid/stat" 2>/dev/null)
		case "$proc" in ''|*[!0-9]*) proc=0 ;; esac
		rss=$(awk '/^VmRSS:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null)
		case "$rss" in ''|*[!0-9]*) rss=0 ;; esac
	fi

	cpu=0
	dt=$((now - prev_ts))
	dproc=$((proc - prev_proc))
	dtotal=$((total - prev_total))
	if [ "$dt" -gt 0 ] && [ "$dtotal" -gt 0 ] && [ "$dproc" -ge 0 ] && \
	   [ "$prev_ts" -gt 0 ] && [ "$prev_pid" = "$pid" ]; then
		cpu=$((dproc * 10000 * ncpu / dtotal))
	fi

	mem_total=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null)
	mem_avail=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null)
	case "$mem_total" in ''|*[!0-9]*) mem_total=0 ;; esac
	case "$mem_avail" in ''|*[!0-9]*) mem_avail=0 ;; esac
	mem_used=$((mem_total - mem_avail))
	[ "$mem_used" -ge 0 ] || mem_used=0

	data_kb=0
	if [ -d "$data" ]; then
		data_kb=$(du -sk "$data" 2>/dev/null | awk '{ print $1 }')
		case "$data_kb" in ''|*[!0-9]*) data_kb=0 ;; esac
	fi
	# Cache for the rpcd plugin: it reuses this value instead of running du on
	# every status poll.
	printf '%s %s\n' "$now" "$data_kb" > "$RUN_DIR/data.size" 2>/dev/null

	# Flash = overlay when mounted, else the root filesystem.
	flash_dir=/overlay
	[ -d "$flash_dir" ] || flash_dir=/
	set -- $(df2 "$flash_dir")
	fs_total=${1:-0}
	fs_used=${2:-0}
	case "$fs_total" in ''|*[!0-9]*) fs_total=0 ;; esac
	case "$fs_used" in ''|*[!0-9]*) fs_used=0 ;; esac
	if [ "$fs_total" = 0 ]; then
		set -- $(df2 /)
		fs_total=${1:-0}
		fs_used=${2:-0}
	fi

	# Filesystem that holds DATA_DIR (may differ from flash, e.g. USB).
	data_fs_total=0
	data_fs_used=0
	if [ -d "$data" ]; then
		set -- $(df2 "$data")
		data_fs_total=${1:-0}
		data_fs_used=${2:-0}
	fi
	case "$data_fs_total" in ''|*[!0-9]*) data_fs_total=0 ;; esac
	case "$data_fs_used" in ''|*[!0-9]*) data_fs_used=0 ;; esac

	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$now" "$cpu" "$rss" "$mem_used" "$data_kb" "$fs_used" "$fs_total" \
		"$proc" "$total" "$pid" "$data_fs_used" "$data_fs_total" >> "$out" 2>/dev/null || true

	prev_ts=$now
	prev_proc=$proc
	prev_total=$total
	prev_pid=$pid

	count=$(wc -l < "$out" 2>/dev/null)
	case "$count" in ''|*[!0-9]*) count=0 ;; esac
	if [ "$count" -gt $((points + 16)) ]; then
		tail -n "$points" "$out" > "$out.tmp" 2>/dev/null && mv "$out.tmp" "$out"
	fi

	sleep "$interval"
done
