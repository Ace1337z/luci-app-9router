'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

var callStatus = rpc.declare({
	object: '9router',
	method: 'status',
	expect: {}
});

var callStats = rpc.declare({
	object: '9router',
	method: 'stats',
	params: [ 'points' ],
	expect: {}
});

var callInstallStatus = rpc.declare({
	object: '9router',
	method: 'install_status',
	expect: {}
});

var callInstall = rpc.declare({
	object: '9router',
	method: 'install',
	params: [ 'version', 'repo' ],
	expect: {}
});

var callStart = rpc.declare({ object: '9router', method: 'start', expect: {} });
var callStop = rpc.declare({ object: '9router', method: 'stop', expect: {} });
var callRestart = rpc.declare({ object: '9router', method: 'restart', expect: {} });
var callRollback = rpc.declare({ object: '9router', method: 'rollback', expect: {} });
var callUninstall = rpc.declare({ object: '9router', method: 'uninstall', params: [ 'purge' ], expect: {} });
var callLogs = rpc.declare({ object: '9router', method: 'logs', params: [ 'lines' ], expect: {} });
var callReveal = rpc.declare({ object: '9router', method: 'reveal_password', expect: {} });
var callSetPassword = rpc.declare({ object: '9router', method: 'set_password', params: [ 'password' ], expect: {} });

var state = {
	status: null,
	stats: null,
	install: null
};

function kb(v) {
	v = +v || 0;
	if (v >= 1024 * 1024)
		return '%.2f GiB'.format(v / 1024 / 1024);
	if (v >= 1024)
		return '%.1f MiB'.format(v / 1024);
	return '%d KiB'.format(v);
}

function pct(a, b) {
	b = +b || 0;
	if (b <= 0)
		return 0;
	return Math.min(100, Math.max(0, 100 * (+a || 0) / b));
}

function dur(sec) {
	sec = Math.max(0, +sec || 0);
	var d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600),
	    m = Math.floor(sec % 3600 / 60), s = Math.floor(sec % 60);
	if (d) return '%dd %dh'.format(d, h);
	if (h) return '%dh %dm'.format(h, m);
	if (m) return '%dm %ds'.format(m, s);
	return '%ds'.format(s);
}

function clock(ts) {
	var d = new Date((+ts || 0) * 1000);
	return '%02d:%02d'.format(d.getHours(), d.getMinutes());
}

/* Series chart: [values], opts = { max, unit, label, color, fmt } */
function chart(values, opts) {
	opts = opts || {};
	var w = 600, h = 110, pad = 2;
	values = (values || []).map(function(v) { return Math.max(0, +v || 0); });

	if (values.length < 2)
		return E('div', { 'class': 'ifacebox', 'style': 'padding:12px;color:#777' },
			_('Collecting samples...'));

	var max = opts.max;
	if (max == null) {
		max = Math.max.apply(null, values);
		max = max > 0 ? max * 1.15 : 1;
	}
	if (!(max > 0))
		max = 1;

	var scale = function(v) {
		var y = h - pad - (v / max) * (h - 2 * pad);
		return Math.max(pad, Math.min(h - pad, y));
	};
	var step = (w - 2 * pad) / (values.length - 1);
	var pts = values.map(function(v, i) {
		return '%.1f,%.1f'.format(pad + i * step, scale(v));
	});
	var line = pts.join(' ');
	var area = '%.1f,%.1f '.format(pad, h - pad) + line + ' %.1f,%.1f'.format(pad + (values.length - 1) * step, h - pad);
	var last = values[values.length - 1];
	var fmt = opts.fmt || function(v) { return '%.1f'.format(v); };

	return E('div', {}, [
		E('div', { 'style': 'display:flex;justify-content:space-between;font-size:90%;color:#666' }, [
			E('span', {}, opts.label || ''),
			E('span', {}, fmt(last) + (opts.unit ? ' ' + opts.unit : ''))
		]),
		E('svg', {
			'viewBox': '0 0 %d %d'.format(w, h),
			'preserveAspectRatio': 'none',
			'width': '100%',
			'height': '%d'.format(h),
			'style': 'display:block;background:#f8f8f8;border-radius:3px'
		}, [
			E('line', { 'x1': pad, 'y1': pad, 'x2': w - pad, 'y2': pad, 'stroke': '#e4e4e4', 'stroke-width': 1 }),
			E('line', { 'x1': pad, 'y1': (h / 2), 'x2': w - pad, 'y2': (h / 2), 'stroke': '#e4e4e4', 'stroke-width': 1 }),
			E('polygon', { 'points': area, 'fill': opts.color || 'rgba(60,120,200,0.18)', 'stroke': 'none' }),
			E('polyline', { 'points': line, 'fill': 'none', 'stroke': opts.color || '#3c78c8', 'stroke-width': 1.6, 'vector-effect': 'non-scaling-stroke' })
		]),
		E('div', { 'style': 'display:flex;justify-content:space-between;font-size:80%;color:#999' }, [
			E('span', {}, state.stats && state.stats.ts.length ? clock(state.stats.ts[0]) : ''),
			E('span', {}, opts.maxLabel || 'max ' + (opts.max != null ? fmt(opts.max) : fmt(max))),
			E('span', {}, state.stats && state.stats.ts.length ? clock(state.stats.ts[state.stats.ts.length - 1]) : '')
		])
	]);
}

function card(title, body, extra) {
	return E('div', {
		'class': 'ifacebox',
		'style': 'flex:1 1 240px;min-width:240px;padding:12px;border:1px solid #ddd;border-radius:4px;background:#fff'
	}, [
		E('div', { 'style': 'font-weight:bold;margin-bottom:8px;color:#555' }, title),
		body,
		extra || ''
	]);
}

function kv(label, value) {
	return E('div', { 'style': 'display:flex;justify-content:space-between;padding:2px 0;font-size:95%' }, [
		E('span', { 'style': 'color:#666' }, label),
		E('span', { 'style': 'text-align:right' }, value)
	]);
}

function bar(value, total, color) {
	var p = pct(value, total);
	return E('div', { 'style': 'background:#eee;border-radius:3px;height:8px;overflow:hidden;margin:6px 0' }, [
		E('div', { 'style': 'height:8px;width:%.1f%%;background:%s'.format(p, color || '#3c78c8') })
	]);
}

function act(fn) {
	return function(ev) {
		ev.preventDefault();
		var btn = ev.currentTarget;
		btn.disabled = true;
		return Promise.resolve(fn.call(btn)).then(function() {
			btn.disabled = false;
			return refresh();
		}, function(err) {
			btn.disabled = false;
			ui.addNotification(null, E('p', {}, String(err)));
		});
	};
}

/* ---------- section builders ---------- */

function summaryCards() {
	var st = state.status;
	if (!st)
		return E('div', { 'class': 'ifacebox' }, _('Loading...'));

	var run = st.running;
	return E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:12px' }, [
		card(_('Service'), [
			E('div', { 'style': 'font-size:180%;font-weight:bold;color:' + (run ? '#2e7d32' : '#b71c1c') },
				run ? _('Running') : _('Stopped')),
			kv(_('Autostart'), st.enabled ? _('enabled') : _('disabled')),
			kv(_('Uptime'), run ? dur(st.uptime) : '-'),
			kv(_('PID'), run ? String(st.pid) : '-')
		]),
		card(_('Version'), [
			E('div', { 'style': 'font-size:150%;font-weight:bold' }, st.version),
			kv(_('Installed'), st.installed ? _('yes') : _('no')),
			kv(_('Arch'), st.arch || _('unsupported')),
			kv(_('Binary'), st.binary_size ? kb(st.binary_size / 1024) : '-'),
			kv(_('Rollback copy'), st.has_backup ? kb(st.backup_size / 1024) : _('none'))
		]),
		card(_('Dashboard'), [
			kv(_('URL'), E('a', {
				'href': st.url, 'target': '_blank', 'rel': 'noopener noreferrer'
			}, st.url)),
			kv(_('Bind'), st.bind + ':' + st.port),
			kv(_('Password'), st.password_set ? _('set') : _('missing')),
			kv(_('Data dir'), st.data_dir)
		]),
		card(_('Data'), [
			kv(_('Directory'), kb(st.data_kb)),
			kv(_('SQLite DB'), st.db_kb ? kb(st.db_kb) : '-'),
			kv(_('Data FS free'), st.data_total_kb ? kb(st.data_free_kb) : '-'),
			kv(_('Data FS used'), st.data_total_kb ? '%.0f%%'.format(pct(st.data_used_kb, st.data_total_kb)) : '-')
		])
	]);
}

function liveCards() {
	var st = state.status, h = state.stats, last = (h && h.last) || {};
	return E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:12px;margin-top:12px' }, [
		card(_('CPU'), [
			E('div', { 'style': 'font-size:180%;font-weight:bold' }, '%.2f%%'.format(last.cpu || 0)),
			kv(_('RSS'), kb(last.rss)),
			kv(_('System memory used'), kb(last.mem)),
			kv(_('Samples'), String((h && h.points) || 0))
		]),
		card(_('Flash (' + (st ? st.flash_path : '/') + ')'), [
			E('div', { 'style': 'font-size:180%;font-weight:bold' },
				'%.0f%%'.format(pct(last.fs_used, last.fs_total))),
			bar(last.fs_used, last.fs_total, pct(last.fs_used, last.fs_total) > 85 ? '#c62828' : '#2e7d32'),
			kv(_('Used'), kb(last.fs_used)),
			kv(_('Free'), kb((st ? st.free_kb : 0)))
		]),
		card(_('Sampler'), [
			kv(_('Interval'), (h && h.interval ? h.interval : st.sample_interval) + ' s'),
			kv(_('Last sample'), last.age ? dur(last.age) + ' ' + _('ago') : _('none')),
			kv(_('History'), '%d / %d'.format((h && h.points) || 0, st.history_points)),
			kv(_('File'), _('tmpfs') )
		])
	]);
}

function chartsSection() {
	var h = state.stats;
	if (!h || !h.ts || !h.ts.length)
		return E('div', { 'class': 'ifacebox', 'style': 'margin-top:12px;padding:12px' },
			_('No samples yet. The sampler writes one line every %d seconds.').format(state.status ? state.status.sample_interval : 30));

	var flashTotal = Math.max.apply(null, h.fs_total.concat([ 1 ]));

	return E('div', { 'style': 'display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px;margin-top:12px' }, [
		E('div', { 'class': 'ifacebox', 'style': 'padding:10px' }, chart(h.cpu, {
			label: _('Process CPU'),
			unit: '%',
			fmt: function(v) { return '%.2f'.format(v); }
		})),
		E('div', { 'class': 'ifacebox', 'style': 'padding:10px' }, chart(h.rss, {
			label: _('Process RSS'),
			unit: 'MiB',
			color: '#6a1b9a',
			fmt: function(v) { return '%.0f'.format(v / 1024); }
		})),
		E('div', { 'class': 'ifacebox', 'style': 'padding:10px' }, chart(h.fs_used, {
			label: _('Flash used (of %s)').format(kb(flashTotal)),
			unit: 'MiB',
			color: '#ef6c00',
			max: flashTotal,
			fmt: function(v) { return '%.0f'.format(v / 1024); }
		})),
		E('div', { 'class': 'ifacebox', 'style': 'padding:10px' }, chart(h.data, {
			label: _('Data directory'),
			unit: 'MiB',
			color: '#00838f',
			fmt: function(v) { return '%.1f'.format(v / 1024); }
		}))
	]);
}

function installBox() {
	var st = state.status, ins = state.install || {};
	var busy = ins.state && [ 'queued', 'resolving', 'downloading', 'verifying', 'extracting', 'stopping', 'starting' ].indexOf(ins.state) >= 0;
	var pr = +ins.progress || 0;

	var progress = E('div', { 'style': 'margin:8px 0' }, [
		bar(pr, 100, ins.state === 'failed' ? '#c62828' : '#3c78c8'),
		E('div', { 'style': 'font-size:90%;color:#666' }, '%d%% %s'.format(pr, ins.message || ins.state || 'idle'))
	]);

	var buttons = E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:8px;margin-top:8px' }, [
		E('button', {
			'class': 'cbi-button cbi-button-action',
			'disabled': busy ? '' : null,
			'click': act(function() {
				return callInstall(st.release_version || 'latest', st.release_repo || '').then(function(r) {
					if (r && r.error)
						throw new Error(r.error);
					ui.addNotification(null, E('p', {}, _('Install started. This page updates automatically.')));
				});
			})
		}, st.installed ? _('Update / reinstall') : _('Install 9router-go')),

		E('button', {
			'class': 'cbi-button cbi-button-apply',
			'disabled': (busy || st.running) ? '' : null,
			'click': act(function() { return callStart(); })
		}, _('Start')),

		E('button', {
			'class': 'cbi-button',
			'disabled': (!st.running) ? '' : null,
			'click': act(function() { return callStop(); })
		}, _('Stop')),

		E('button', {
			'class': 'cbi-button',
			'disabled': (!st.running || busy) ? '' : null,
			'click': act(function() { return callRestart(); })
		}, _('Restart')),

		E('button', {
			'class': 'cbi-button cbi-button-negative',
			'disabled': (!st.has_backup || busy) ? '' : null,
			'click': act(function() {
				if (!confirm(_('Restore the previous binary? The current binary is deleted.')))
					return;
				return callRollback().then(function(r) {
					if (r && r.error) throw new Error(r.error);
				});
			})
		}, _('Roll back')),

		E('button', {
			'class': 'cbi-button cbi-button-negative',
			'disabled': (!st.installed_by_luci) ? '' : null,
			'click': act(function() {
				if (!confirm(_('Remove the installed binary and keep the data directory %s?').format(st.data_dir)))
					return;
				return callUninstall(false).then(function(r) {
					if (r && r.error) throw new Error(r.error);
				});
			})
		}, _('Uninstall binary'))
	]);

	return E('div', { 'class': 'cbi-section', 'style': 'margin-top:12px;padding:12px;border:1px solid #ddd;border-radius:4px' }, [
		E('h3', { 'style': 'margin:0 0 6px' }, _('Installation')),
		st.needs_reinstall
			? E('div', {
				'style': 'padding:8px;margin-bottom:8px;background:#fff3cd;border:1px solid #ffe08a;border-radius:3px'
			}, _('Version %s was installed by LuCI, but the binary is gone (a sysupgrade or a manual delete removes /usr/libexec/9router). Install it again.').format(st.version))
			: '',
		E('div', { 'style': 'font-size:92%;color:#666' },
			_('Source: %s, version %s. Downloads are verified against SHA256SUMS.txt and the previous binary is kept for rollback.')
				.format(st.release_repo || _('not configured'), st.release_version || 'latest')),
		progress,
		buttons
	]);
}

/* Built once: the poll re-renders the page every 5 s, and recreating the input
   would drop focus and the value while the operator is typing. */
var pwBoxEl = null;

function passwordBox() {
	if (pwBoxEl)
		return pwBoxEl;

	var shown = { value: '' };
	var field = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'readonly': '',
		'style': 'width:100%;font-family:monospace',
		'value': ''
	});

	var reveal = function() {
		return callReveal().then(function(r) {
			field.value = (r && r.password) || '';
			shown.value = field.value;
		});
	};

	var save = function() {
		var pw = field.value;
		if (pw.length < 8 || pw.length > 128) {
			ui.addNotification(null, E('p', {}, _('Password must be 8-128 characters.')));
			return;
		}
		return callSetPassword(pw).then(function(r) {
			if (r && r.error)
				throw new Error(r.error);
			if (r && r.warning)
				ui.addNotification(null, E('p', {}, r.warning), 'warning');
			else if (r && r.restart_required)
				ui.addNotification(null, E('p', {}, _('Password saved. Restart the service to apply.')));
			else
				ui.addNotification(null, E('p', {}, _('Password changed in the 9router dashboard.')));
			return reveal();
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, String(err.message || err)), 'error');
		});
	};

	pwBoxEl = E('div', { 'class': 'cbi-section', 'style': 'margin-top:12px;padding:12px;border:1px solid #ddd;border-radius:4px' }, [
		E('h3', { 'style': 'margin:0 0 6px' }, _('Dashboard password')),
		E('div', { 'style': 'font-size:92%;color:#666;margin-bottom:6px' },
			_('The value shown is the password generated at install time. If it was changed inside the 9router dashboard, that stored password wins; change it there instead.')),
		E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap' }, [
			field,
			E('button', { 'class': 'cbi-button', 'click': function(ev) { ev.preventDefault(); return reveal(); } }, _('Reveal')),
			E('button', {
				'class': 'cbi-button cbi-button-apply',
				'click': function(ev) { ev.preventDefault(); return save(); }
			}, _('Save'))
		])
	]);

	return pwBoxEl;
}

function logsBox() {
	return E('div', { 'class': 'cbi-section', 'style': 'margin-top:12px;padding:12px;border:1px solid #ddd;border-radius:4px' }, [
		E('h3', { 'style': 'margin:0 0 6px' }, _('Diagnostics')),
		E('button', {
			'class': 'cbi-button',
			'click': function(ev) {
				ev.preventDefault();
				return callLogs(200).then(function(r) {
					ui.showModal(_('9Router log'), [
						E('pre', {
							'style': 'max-height:60vh;overflow:auto;white-space:pre-wrap;font-size:85%'
						}, (r && r.log) || _('(empty)')),
						E('div', { 'class': 'right', 'style': 'margin-top:8px' }, [
							E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Close'))
						])
					]);
				});
			}
		}, _('Show log')),
		E('span', { 'style': 'font-size:90%;color:#666;margin-left:8px' },
			_('logread -e 9router and /var/log/9router-install.log'))
	]);
}

function supportBox() {
	return E('div', { 'class': 'cbi-section', 'style': 'margin-top:12px;padding:12px;border:1px solid #ddd;border-radius:4px' }, [
		E('h3', { 'style': 'margin:0 0 6px' }, _('Maintainer')),
		E('div', { 'style': 'font-size:92%;color:#666' },
			_('This LuCI package is maintained by Ace1337z. Report bugs, packaging problems or release requests through either channel.')),
		E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:16px;margin-top:6px' }, [
			E('span', {}, [
				_('Telegram: '),
				E('a', {
					'href': 'https://t.me/bytewrt',
					'target': '_blank',
					'rel': 'noopener noreferrer'
				}, '@bytewrt')
			]),
			E('span', {}, [
				_('GitHub: '),
				E('a', {
					'href': 'https://github.com/Ace1337z/luci-app-9router/issues',
					'target': '_blank',
					'rel': 'noopener noreferrer'
				}, 'Ace1337z/luci-app-9router')
			])
		])
	]);
}

/* ---------- data plumbing ---------- */

function render() {
	var root = document.getElementById('9router-root');
	if (!root)
		return;
	while (root.firstChild)
		root.removeChild(root.firstChild);

	root.appendChild(summaryCards());
	root.appendChild(liveCards());
	root.appendChild(chartsSection());
	root.appendChild(installBox());
	root.appendChild(passwordBox());
	root.appendChild(logsBox());
	root.appendChild(supportBox());
}

function refresh() {
	return Promise.all([
		callStatus(),
		callStats(240),
		callInstallStatus()
	]).then(function(r) {
		state.status = r[0] || null;
		state.stats = r[1] || null;
		state.install = r[2] || null;
		render();
	});
}

return view.extend({
	load: function() {
		/* The first sample arrives from the immediate poll tick in render(). */
		return null;
	},

	render: function() {
		var root = E('div', { 'id': '9router-root' }, [
			E('div', { 'class': 'ifacebox' }, _('Loading...'))
		]);

		/* LuCI inserts the returned node after render() returns, so paint on
		   the next tick and let poll take over from there. */
		window.setTimeout(function() { refresh(); }, 0);

		poll.add(function() {
			return refresh();
		}, 5);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('9Router')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Static 9router-go gateway: install, supervise and watch CPU, RAM, flash and data growth.')),
			root
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
