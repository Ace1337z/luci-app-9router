'use strict';
'require view';
'require form';
'require rpc';
'require ui';

var callRestart = rpc.declare({ object: '9router', method: 'restart', expect: {} });

return view.extend({
	render: function() {
		var m, s, o;

		m = new form.Map('9router', _('9Router'),
			_('Runtime settings for the 9router-go gateway and its resource sampler. ' +
			  'Saving restarts the service, because the init scripts register a procd reload trigger for this config.'));

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

		o = s.option(form.Value, 'release_repo', _('Release repository'),
			_('GitHub owner/repo that publishes the static musl assets ' +
			  '(9router-go-linux-{arch}-static.gz and SHA256SUMS.txt).'));
		o.datatype = 'string';
		o.placeholder = 'owner/9router-go-openwrt';
		o.rmempty = false;

		o = s.option(form.Value, 'release_version', _('Release version'),
			_('"latest" resolves through the GitHub API; pin a tag to avoid API rate limits and surprise upgrades.'));
		o.placeholder = 'latest';
		o.rmempty = false;

		o = s.option(form.ListValue, 'install_arch', _('Force architecture'),
			_('Override CPU detection only if the release asset naming does not match this device.'));
		o.value('', _('auto detect'));
		o.value('amd64', 'amd64');
		o.value('arm64', 'arm64');
		o.value('armv7', 'armv7');
		o.value('armv6', 'armv6');
		o.value('386', '386');
		o.value('mips', 'mips');
		o.value('mipsle', 'mipsle');
		o.value('mips64', 'mips64');
		o.value('mips64le', 'mips64le');
		o.default = '';
		o.rmempty = false;

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

		return m.render();
	}
});
