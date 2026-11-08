#
# Copyright (C) 2026 Ace1337z (Telegram: @bytewrt)
#
# This is free software, licensed under the MIT License.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-9router
PKG_VERSION:=1.0.0
# r2: menu moved to Tools; the overview no longer hardcodes light-theme colours
# (9router.css resolves --v-* first), and it loads that stylesheet itself.
# r3: one-click install (built-in release source), fix "[object HTMLDivElement]"
# cards, optional release override, maintainer contact in the UI.
PKG_RELEASE:=3
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Ace1337z <https://t.me/bytewrt>

LUCI_TITLE:=LuCI panel for 9router-go (install, run, monitor)
LUCI_DESCRIPTION:=Installs the static 9router-go LLM gateway on demand, supervises it with procd, and graphs process CPU, RAM, data-directory growth and flash usage over time.
LUCI_PKGARCH:=all

# luci-base already pulls rpcd-mod-ucode, ucode, ucode-mod-{fs,uci}, but list
# them explicitly: this package runs a ucode rpcd plugin and a shell sampler,
# and a future luci-base refactor must not silently break us.
# uclient-fetch + ca-bundle are the HTTPS download path used by the installer;
# zlib/gzip is provided by busybox, nothing to depend on.
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-ucode +ucode +ucode-mod-fs \
	+ucode-mod-uci +uclient-fetch +ca-bundle

define Package/$(PKG_NAME)/conffiles
/etc/config/9router
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/usr/libexec/9router/setup.sh
	# Same cache flush luci.mk's default postinst does; the menu entry for a
	# newly installed LuCI app is otherwise invisible until the next reboot
	# or manual cache clear.
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
}
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/9router stop 2>/dev/null
	/etc/init.d/9router-monitor stop 2>/dev/null
	# Only remove a binary this package installed. A binary placed by hand has
	# no marker and is left alone. /srv/9router (database, credentials) is
	# always kept: removing a package must not delete user data.
	if [ -f /etc/9router/installed ]; then
		bin=$$(uci -q get 9router.main.binary)
		[ -n "$$bin" ] || bin=/usr/libexec/9router/9router-go
		rm -f "$$bin" "$$bin.bak" /etc/9router/installed
	fi
}
exit 0
endef

# luci.mk installs ./htdocs -> /www and ./root -> /. No custom install block.
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
