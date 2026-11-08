#!/usr/bin/ucode
// rpcd ucode plugin for luci-app-9router.
//
// Registered by rpcd-mod-ucode from /usr/share/rpcd/ucode. The ubus object is
// "9router"; LuCI talks only to these methods, never to a shell.
//
// Read methods:  status, stats, install_status, logs, reveal_password
// Write methods: install, start, stop, restart, uninstall, rollback, set_password
//
// Every write method maps to a fixed shell command or a UCI write; no caller
// supplied string ever reaches a shell unquoted.

'use strict';

let fs = require('fs');
let uci = require('uci');

let DEFAULT_BIN = '/usr/libexec/9router/9router-go';
let DEFAULT_DATA = '/srv/9router';
// Built-in release source for one-click install. Assets are static builds of
// luqman-v1/9router-go published by this repository's release workflow.
let DEFAULT_REPO = 'Ace1337z/luci-app-9router';
let RUN_DIR = '/var/run/9router';

function cfg(key, def) {
	let c = uci.cursor();
	let v = c.get('9router', 'main', key);
	return (v == null || v === '') ? def : v;
}

// Resolve the release source: explicit mirror wins, empty or the old
// OWNER/... placeholder falls back to the built-in repository.
function release_repo() {
	let r = cfg('release_repo', DEFAULT_REPO);
	if (r == '' || match(r, /^OWNER\//))
		r = DEFAULT_REPO;
	return r;
}

function toint(v, def) {
	let n = +v;
	if (n != n)		// NaN, also covers empty strings and junk
		return def;
	if (n == null)
		return def;
	return int(n);
}

function safe_read(path) {
	try {
		return fs.readfile(path);
	} catch (e) {
		return null;
	}
}

function safe_stat(path) {
	try {
		return fs.stat(path);
	} catch (e) {
		return null;
	}
}

function safe_statvfs(path) {
	try {
		return fs.statvfs(path);
	} catch (e) {
		return null;
	}
}

function sh(cmd) {
	let p = null;
	try {
		p = fs.popen(cmd, 'r');
	} catch (e) {
		return '';
	}
	if (!p)
		return '';
	let out = '';
	try {
		out = p.read('all') || '';
	} catch (e) {
		out = '';
	}
	p.close();
	return out;
}

function shq(s) {
	return "'" + replace(s, "'", "'\\''") + "'";
}

function basename(path) {
	let p = split(path, '/');
	return p[length(p) - 1] || path;
}

function parse_kv(text) {
	let out = {};
	if (!text)
		return out;
	let lines = split(trim(text), '\n');
	for (let i = 0; i < length(lines); i++) {
		let m = match(lines[i], /^([^=]+)=(.*)$/);
		if (m)
			out[trim(m[1])] = trim(m[2]);
	}
	return out;
}

// Resolve the gateway PID. run.sh records $$ before exec(), so after exec the
// recorded PID is the real process. Fall back to pidof for binaries started
// outside procd, and always require /proc/<pid> to exist.
function gateway_pid(bin) {
	let pid = toint(trim(safe_read(RUN_DIR + '/9router.pid') || ''), 0);
	let cmdline = '';
	if (pid > 0) {
		cmdline = safe_read('/proc/' + pid + '/cmdline');
		if (cmdline == null)
			pid = 0;
	}
	if (!pid) {
		let out = trim(sh('pidof ' + shq(basename(bin)) + ' 2>/dev/null'));
		pid = toint(split(out, /\s+/)[0], 0);
		cmdline = pid ? safe_read('/proc/' + pid + '/cmdline') : null;
		if (cmdline == null)
			pid = 0;
	}
	if (!pid)
		return 0;
	// Guard against PID reuse: the process must actually be the gateway binary.
	// cmdline is NUL separated; substring matching works without splitting it.
	if (index(cmdline || '', basename(bin)) < 0)
		return 0;
	return pid;
}

function proc_status(pid) {
	let res = { rss: 0, ticks: 0, pid: pid };
	if (!pid)
		return res;

	let st = safe_read('/proc/' + pid + '/status');
	if (st) {
		let m = match(st, /VmRSS:\s+(\d+)/);
		if (m)
			res.rss = toint(m[1], 0);
	}

	let stat = safe_read('/proc/' + pid + '/stat');
	if (stat) {
		// The comm field is parenthesised and may contain spaces, so split on
		// the last ')' and index from there.
		let p = split(stat, ')');
		if (length(p) >= 2) {
			let a = split(trim(p[1]), /\s+/);
			if (length(a) >= 13)
				res.ticks = toint(a[11], 0) + toint(a[12], 0);
		}
	}
	return res;
}

function mem_used_kb() {
	let t = 0, a = 0;
	let mi = safe_read('/proc/meminfo');
	if (mi) {
		let mt = match(mi, /MemTotal:\s+(\d+)/);
		let ma = match(mi, /MemAvailable:\s+(\d+)/);
		if (mt) t = toint(mt[1], 0);
		if (ma) a = toint(ma[1], 0);
	}
	return (t > a) ? (t - a) : 0;
}

function data_kb(dir) {
	if (!dir)
		return 0;
	let out = sh('du -sk ' + shq(dir) + ' 2>/dev/null');
	let p = split(trim(out), /\s+/);
	return toint(p[0], 0);
}

// `du` walks the whole SQLite tree. The sampler already measures it once per
// interval, so reuse its result while it is fresh instead of walking the tree
// on every 10 s status poll.
function data_kb_cached(dir) {
	let cache = safe_read(RUN_DIR + '/data.size');
	if (cache) {
		let f = split(trim(cache), /\s+/);
		let ts = toint(f[0], 0), kb = toint(f[1], -1);
		if (ts > 0 && kb >= 0 && time() >= ts && (time() - ts) < 120)
			return kb;
	}
	return data_kb(dir);
}

function fs_info(path) {
	let sv = safe_statvfs(path);
	if (!sv)
		sv = safe_statvfs('/');
	if (!sv)
		return { free_kb: 0, total_kb: 0, used_kb: 0 };
	let fr = toint(sv.frsize, 0);
	if (!fr)
		fr = toint(sv.bsize, 4096);
	let free = fr * toint(sv.bavail, 0);
	let total = fr * toint(sv.blocks, 0);
	return {
		free_kb: int(free / 1024),
		total_kb: int(total / 1024),
		used_kb: int((total - free) / 1024)
	};
}

// 9router-go and its data live on the overlay. Report the overlay mount when
// present, because '/' is the squashfs read-only root and never changes.
function flash_path() {
	if (safe_stat('/overlay'))
		return '/overlay';
	return '/';
}

let _machine = null;
function uname_arch() {
	if (_machine)
		return _machine;
	_machine = trim(sh('uname -m 2>/dev/null')) || 'unknown';
	return _machine;
}

function asset_for(machine) {
	switch (machine) {
	case 'x86_64': case 'amd64': return 'amd64';
	case 'aarch64': case 'arm64': return 'arm64';
	case 'armv7l': case 'armv7': return 'armv7';
	case 'armv6l': case 'armv6': return 'armv6';
	case 'i386': case 'i486': case 'i586': case 'i686': return '386';
	case 'mips64el': case 'mips64le': return 'mips64le';
	case 'mips64': return 'mips64';
	case 'mipsel': return 'mipsle';
	case 'mips': return 'mips';
	default: return '';
	}
}

function install_state() {
	let txt = safe_read(RUN_DIR + '/install.state');
	if (!txt)
		return { state: 'idle', progress: 0, message: '' };
	let kv = parse_kv(txt);
	return {
		state: kv.state || 'idle',
		progress: toint(kv.progress, 0),
		message: kv.message || '',
		version: kv.version || '',
		updated: toint(kv.updated, 0)
	};
}

// CSV columns, see monitor.sh:
//   0 ts, 1 cpu_x100, 2 rss_kb, 3 mem_used_kb, 4 data_kb,
//   5 flash_used_kb, 6 flash_total_kb, 7 proc_ticks, 8 total_ticks, 9 pid,
//   10 data_used_kb, 11 data_total_kb
function history(path, points) {
	let out = {
		ts: [], cpu: [], rss: [], mem: [], data: [],
		fs_used: [], fs_total: [], data_used: [], data_total: []
	};
	let txt = safe_read(path);
	if (!txt)
		return out;

	let lines = split(trim(txt), '\n');
	let start = (length(lines) > points) ? (length(lines) - points) : 0;
	for (let i = start; i < length(lines); i++) {
		let f = split(lines[i], ',');
		if (length(f) < 7)
			continue;
		let ts = toint(f[0], 0);
		if (!ts)
			continue;
		out.ts.push(ts);
		out.cpu.push(toint(f[1], 0) / 100);
		out.rss.push(toint(f[2], 0));
		out.mem.push(toint(f[3], 0));
		out.data.push(toint(f[4], 0));
		out.fs_used.push(toint(f[5], 0));
		out.fs_total.push(toint(f[6], 0));
		out.data_used.push(length(f) > 10 ? toint(f[10], 0) : 0);
		out.data_total.push(length(f) > 11 ? toint(f[11], 0) : 0);
	}
	return out;
}

function get_status() {
	let bin = cfg('binary', DEFAULT_BIN);
	let data = cfg('data_dir', DEFAULT_DATA);
	let port = toint(cfg('port', '20130'), 20130);
	let bind = cfg('bind', '0.0.0.0');
	let marker = parse_kv(safe_read('/etc/9router/installed'));
	let bs = safe_stat(bin);
	let installed = !!(bs && bs.type == 'file' && bs.perm && bs.perm.user_exec);
	let pid = gateway_pid(bin);
	let now = time();
	let started = toint(trim(safe_read(RUN_DIR + '/started') || ''), 0);
	let machine = uname_arch();
	let arch = cfg('install_arch', '') || asset_for(machine);
	let flash = fs_info(flash_path());
	let dfs = fs_info(data);
	let db = safe_stat(data + '/db/data.sqlite');
	let bak = safe_stat(bin + '.bak');

	return {
		running: pid > 0,
		pid: pid,
		uptime: (pid > 0 && started > 0 && now > started) ? (now - started) : 0,
		enabled: cfg('enabled', '0') == '1',
		installed: installed,
		// Marker survives sysupgrade (/etc); the binary in /usr/libexec does
		// not, so a marker without a binary means "reinstall after upgrade".
		version: marker.version || 'unknown',
		asset: marker.asset || arch,
		sha256: marker.sha256 || '',
		installed_at: toint(marker.installed, 0),
		installed_by_luci: !!marker.version,
		needs_reinstall: !!marker.version && !installed,
		binary: bin,
		binary_size: bs ? toint(bs.size, 0) : 0,
		has_backup: !!bak,
		backup_size: bak ? toint(bak.size, 0) : 0,
		port: port,
		bind: bind,
		url: 'http://' + (bind == '0.0.0.0' ? (trim(sh('uci -q get network.lan.ipaddr 2>/dev/null')) || 'router') : bind) + ':' + port + '/',
		data_dir: data,
		data_kb: data_kb_cached(data),
		db_kb: db ? int(toint(db.size, 0) / 1024) : 0,
		free_kb: flash.free_kb,
		total_kb: flash.total_kb,
		used_kb: flash.used_kb,
		flash_path: flash_path(),
		data_free_kb: dfs.free_kb,
		data_total_kb: dfs.total_kb,
		data_used_kb: dfs.used_kb,
		password_set: cfg('dashboard_password', '') != '',
		monitor: cfg('monitor', '1') == '1',
		sample_interval: toint(cfg('sample_interval', '30'), 30),
		history_points: toint(cfg('history_points', '1440'), 1440),
		release_repo: release_repo(),
		release_version: cfg('release_version', 'latest'),
		machine: machine,
		arch: arch,
		arch_supported: arch != '',
		install: install_state()
	};
}

// install.lock is a directory created by install.sh. A crash can leave it
// behind; treat anything older than 15 minutes as stale.
function install_lock_stale() {
	let st = safe_stat(RUN_DIR + '/install.lock');
	if (!st)
		return false;
	return (time() - toint(st.mtime, 0)) > 900;
}

return {
	'9router': {
		status: {
			call: function() {
				return get_status();
			}
		},

		stats: {
			args: { points: 240 },
			call: function(request) {
				let points = toint(request.args.points, 240);
				if (points < 10) points = 10;
				if (points > 2000) points = 2000;

				let path = cfg('history_file', RUN_DIR + '/monitor.csv');
				let h = history(path, points);
				let st = get_status();
				let ps = proc_status(st.pid);
				let row = length(h.ts) - 1;
				let last = {
					ts: row >= 0 ? h.ts[row] : 0,
					cpu: row >= 0 ? h.cpu[row] : 0,
					rss: row >= 0 ? h.rss[row] : ps.rss,
					mem: row >= 0 ? h.mem[row] : mem_used_kb(),
					data: row >= 0 ? h.data[row] : st.data_kb,
					fs_used: row >= 0 ? h.fs_used[row] : st.used_kb,
					fs_total: row >= 0 ? h.fs_total[row] : st.total_kb,
					data_used: row >= 0 ? h.data_used[row] : 0,
					data_total: row >= 0 ? h.data_total[row] : st.data_total_kb,
					age: (row >= 0 && time() > h.ts[row]) ? (time() - h.ts[row]) : 0
				};

				h.interval = st.sample_interval;
				h.points = length(h.ts);
				h.last = last;
				h.running = st.running;
				h.monitor = st.monitor;
				return h;
			}
		},

		install_status: {
			call: function() {
				return install_state();
			}
		},

		install: {
			args: { version: 'latest', repo: '' },
			call: function(request) {
				let version = trim(request.args.version || '');
				let repo = trim(request.args.repo || '');
				if (!version)
					version = cfg('release_version', 'latest');
				if (!repo)
					repo = release_repo();

				if (!match(version, /^[A-Za-z0-9._-]+$/))
					return { started: false, error: 'Invalid version' };
				if (!match(repo, /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/))
					return { started: false, error: 'Set a valid owner/repo release source in Settings' };

				if (safe_stat(RUN_DIR + '/install.lock')) {
					if (!install_lock_stale())
						return { started: false, error: 'An install is already running' };
					sh('rm -rf ' + shq(RUN_DIR + '/install.lock'));
				}

				try {
					fs.mkdir(RUN_DIR);
				} catch (e) {}
				let cmd = '/usr/libexec/9router/install.sh ' + shq(version) + ' ' + shq(repo) +
					  ' </dev/null >/dev/null 2>&1 &';
				let p = fs.popen(cmd, 'w');
				p.close();
				return { started: true };
			}
		},

		start: {
			call: function() {
				let bin = cfg('binary', DEFAULT_BIN);
				let st = safe_stat(bin);
				if (!(st && st.type == 'file' && st.perm && st.perm.user_exec))
					return { ok: false, error: '9router-go is not installed; install it first' };
				let c = uci.cursor();
				c.set('9router', 'main', 'enabled', '1');
				c.commit('9router');
				let out = sh('/etc/init.d/9router start 2>&1');
				return { ok: true, output: out };
			}
		},

		stop: {
			call: function() {
				sh('/etc/init.d/9router stop 2>&1');
				let c = uci.cursor();
				c.set('9router', 'main', 'enabled', '0');
				c.commit('9router');
				return { ok: true };
			}
		},

		restart: {
			call: function() {
				let out = sh('/etc/init.d/9router restart 2>&1');
				return { ok: true, output: out };
			}
		},

		rollback: {
			call: function() {
				let bin = cfg('binary', DEFAULT_BIN);
				if (!safe_stat(bin + '.bak'))
					return { ok: false, error: 'No previous binary to restore' };
				sh('/etc/init.d/9router stop 2>&1');
				sh('rm -f ' + shq(bin) + ' && mv ' + shq(bin + '.bak') + ' ' + shq(bin) +
				   ' && chmod 0755 ' + shq(bin));
				// The marker describes the binary we just replaced.
				sh('rm -f /etc/9router/installed');
				sh('/etc/init.d/9router start 2>&1');
				return { ok: true };
			}
		},

		uninstall: {
			args: { purge: false },
			call: function(request) {
				let bin = cfg('binary', DEFAULT_BIN);
				let data = cfg('data_dir', DEFAULT_DATA);
				if (!safe_stat('/etc/9router/installed'))
					return { ok: false, error: 'This binary was not installed by LuCI; remove the package instead' };

				sh('/etc/init.d/9router stop 2>&1');
				sh('rm -f ' + shq(bin) + ' ' + shq(bin + '.bak') + ' /etc/9router/installed');
				let c = uci.cursor();
				c.set('9router', 'main', 'enabled', '0');
				c.commit('9router');

				// Data holds credentials and the SQLite DB; only remove it on an
				// explicit purge, and never a short or root path.
				if (request.args.purge && length(data) > 6 && data != '/')
					sh('rm -rf ' + shq(data));

				return { ok: true };
			}
		},

		logs: {
			args: { lines: 120 },
			call: function(request) {
				let n = toint(request.args.lines, 120);
				if (n < 10) n = 10;
				if (n > 1000) n = 1000;
				let out = sh('(logread -e 9router; cat /var/log/9router-install.log) 2>/dev/null | tail -n ' + n);
				return { log: out };
			}
		},

		reveal_password: {
			call: function() {
				return { password: cfg('dashboard_password', '') };
			}
		},

		// Changing the password cannot be done by writing UCI alone: once a
		// bcrypt hash exists in the gateway's SQLite settings, that hash wins
		// over INITIAL_PASSWORD. So ask the gateway itself to rotate it, using
		// the password we generated at install time as the "current" one.
		set_password: {
			args: { password: '' },
			call: function(request) {
				let pw = request.args.password || '';
				if (length(pw) < 8 || length(pw) > 128)
					return { ok: false, error: 'Password must be 8-128 characters' };
				if (match(pw, /[\r\n]/))
					return { ok: false, error: 'Password must be a single line' };

				let cur = cfg('dashboard_password', '');
				if (cur == '')
					return { ok: false, error: 'No stored password. Reinstall the binary or set one in the 9router dashboard.' };

				let c = uci.cursor();
				let bin = cfg('binary', DEFAULT_BIN);
				let pid = gateway_pid(bin);

				if (!pid) {
					// Service stopped: no way to update the on-disk hash, so
					// only record it for the next start.
					c.set('9router', 'main', 'dashboard_password', pw);
					c.commit('9router');
					return {
						ok: true,
						restart_required: true,
						warning: 'Service stopped. The new password is stored in UCI and is used at the next start only if the dashboard password was never changed inside 9router.'
					};
				}

				let bind = cfg('bind', '0.0.0.0');
				let port = toint(cfg('port', '20130'), 20130);
				let host = (bind == '0.0.0.0' || bind == '') ? '127.0.0.1' : bind;
				if (host == '::' || host == '0:0:0:0:0:0:0:0')
					host = '::1';

				let esc = function(s) {
					return replace(replace(s, '\\', '\\\\'), '"', '\\"');
				};
				let body = '{"password":"' + esc(cur) + '","newPassword":"' + esc(pw) + '"}';
				let tmp = RUN_DIR + '/password-request.json';
				sh('uclient-fetch -q -T 10 -O ' + shq(tmp) + ' --post-data ' + shq(body) +
				   ' ' + shq('http://' + host + ':' + port + '/api/auth/login') + ' 2>/dev/null');
				let resp = safe_read(tmp) || '';
				sh('rm -f ' + shq(tmp));

				if (match(resp, /"success"[[:space:]]*:[[:space:]]*true/)) {
					// Keep UCI in sync so the panel shows the live password.
					// The stored bcrypt hash now wins, so no restart is needed.
					c.set('9router', 'main', 'dashboard_password', pw);
					c.commit('9router');
					return { ok: true, restart_required: false };
				}

				return {
					ok: false,
					error: 'The dashboard did not accept the password stored here. If you changed it inside 9router, change it there instead.',
					detail: trim(resp)
				};
			}
		}
	}
};
