'use strict';
'require view';
'require form';
'require rpc';
'require ui';

var callRestart = rpc.declare({ object: '9router', method: 'restart', expect: {} });

var DEFAULT_REPO = 'Ace1337z/luci-app-9router';

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('9router', _('9Router'),
			_('Installation is one click on the Overview page: the package already knows where ' +
			  'to download the static build of luqman-v1/9router-go. Change the fields below only ' +
			  'if this router needs a mirror or a pinned release.'));

		s = m.section(form.NamedSection, 'main', '9router', _('Service'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable'),
			_('Start 9router-go at boot and keep it running under procd supervision.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'bind', _('Bind address'),
			_('0.0.0.0 listens on every interface. Use 127.0.0.1 or a VPN address to keep the dashboard off the LAN.'));
		o.datatype = 'host';
		o.placeholder = '0.0.0.0';
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('Port'));
		o.datatype = 'port';
		o.placeholder = '20130';
		o.rmempty = false;

		o = s.option(form.Value, 'data_dir', _('Data directory'),
			_('SQLite database, JWT secret and uploaded files. Must be on persistent storage. ' +
			  'Changing this does not move existing data; the gateway starts with an empty database.'));
		o.placeholder = '/srv/9router';
		o.rmempty = false;

		s = m.section(form.NamedSection, 'main', '9router', _('Release source (optional)'));
		s.addremove = false;
		s.description = _('Leave these at their defaults for one-click install. An empty repository ' +
			'also means "use the built-in source".');

		o = s.option(form.Value, 'release_repo', _('Release repository'),
			_('GitHub owner/repo that publishes the static musl assets ' +
			  '(9router-go-linux-{arch}-static.gz and SHA256SUMS.txt). ' +
			  'Empty or the old OWNER/ placeholder falls back to the built-in source.'));
		o.datatype = 'string';
		o.placeholder = DEFAULT_REPO;
		o.rmempty = true;

		o = s.option(form.Value, 'release_version', _('Release version'),
			_('"latest" resolves through the GitHub API; pin a tag to avoid API rate limits and surprise upgrades.'));
		o.placeholder = 'latest';
		o.rmempty = true;

		o = s.option(form.ListValue, 'install_arch', _('Force architecture'),
			_('Override CPU detection only if the release asset naming does not match this device. ' +
			  'Only 64-bit amd64 and arm64 builds are published.'));
		o.value('', _('auto detect'));
		o.value('amd64', 'amd64');
		o.value('arm64', 'arm64');
		o.default = '';
		o.rmempty = true;

		s = m.section(form.NamedSection, 'main', '9router', _('Resource sampler'));
		s.addremove = false;

		o = s.option(form.Flag, 'monitor', _('Enable sampler'),
			_('Writes one CSV sample of CPU, RSS, memory, data size and flash usage per interval. ' +
			  'The history file lives on tmpfs by default and is discarded on reboot.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'sample_interval', _('Sample interval (seconds)'),
			_('Minimum 15. Higher values cost less CPU on slow routers.'));
		o.datatype = 'range(15, 3600)';
		o.placeholder = '30';
		o.rmempty = false;

		o = s.option(form.Value, 'history_points', _('History points'),
			_('Samples kept in the CSV. 1440 points at 30 s is 12 hours.'));
		o.datatype = 'range(60, 20000)';
		o.placeholder = '1440';
		o.rmempty = false;

		o = s.option(form.Value, 'history_file', _('History file'),
			_('tmpfs path (default) avoids flash wear. Point this at persistent storage only if you accept the writes.'));
		o.placeholder = '/var/run/9router/monitor.csv';
		o.rmempty = false;

		s = m.section(form.NamedSection, 'main', '9router', _('Actions'));
		s.addremove = false;

		o = s.option(form.Button, '_restart', _('Service'));
		o.inputtitle = _('Restart 9router');
		o.inputstyle = 'apply';
		o.onclick = function() {
			return callRestart().then(function() {
				ui.addNotification(null, E('p', {}, _('9router restarted.')));
			});
		};

		s = m.section(form.NamedSection, 'main', '9router', _('Support'));
		s.addremove = false;

		o = s.option(form.DummyValue, '_maintainer', _('Maintainer'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return '<a href="https://t.me/bytewrt" target="_blank" rel="noopener noreferrer">Telegram @bytewrt</a>' +
			       ' &middot; ' +
			       '<a href="https://github.com/Ace1337z/luci-app-9router/issues" target="_blank" rel="noopener noreferrer">GitHub issues</a>';
		};

		return m.render();
	}
});
