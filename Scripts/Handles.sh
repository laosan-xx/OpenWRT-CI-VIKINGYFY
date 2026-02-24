#!/bin/bash

PKG_PATH="$GITHUB_WORKSPACE/wrt/package/"
OTHER_PATH="$GITHUB_WORKSPACE/Others/"

#解决wan口地址与lan口冲突
HOTPLUG_IFACE_DIR="$GITHUB_WORKSPACE/wrt/files/etc/hotplug.d/iface"
SRC_FILE="$OTHER_PATH/90-autolanip"
DEST_FILE="$HOTPLUG_IFACE_DIR/90-autolanip"

mkdir -p "$HOTPLUG_IFACE_DIR" && \
	echo "目录已就绪：$HOTPLUG_IFACE_DIR"

if [ ! -f "$SRC_FILE" ]; then
	echo "源文件不存在: $SRC_FILE" >&2
else
	if cp -f "$SRC_FILE" "$DEST_FILE"; then
		chmod +x "$DEST_FILE"
		echo "LAN IP 冲突修复脚本添加完成：$DEST_FILE"
	else
		echo "脚本复制失败: $SRC_FILE → $DEST_FILE" >&2
	fi
fi

#如果有选ddnsto，删除ddnsto菜单栏一级菜单DDNSTO（Dev）这个菜单
if [ -d *"luci-app-ddnsto"* ]; then
	echo " "

	sed -i '/entry({"admin", "ddnsto_dev"},/d' "./luci-app-ddnsto/luasrc/controller/ddnsto.lua"

  # 删除 action_ddnsto_dev 函数
  # 使用 sed 删除从 "function action_ddnsto_dev()" 到下一个独立的 "end" 之间的所有行
  # 注意：这里使用 /^function action_ddnsto_dev()/,/^[[:space:]]*end[[:space:]]*$/ 匹配
  # 但在某些 sed 版本中，需要更精确的匹配
  sed -i '/^function action_ddnsto_dev()/,/^end$/d' "./luci-app-ddnsto/luasrc/controller/ddnsto.lua"

	cd $PKG_PATH && echo "DDNSTO(Dev) has been removed!"
fi

#预置HomeProxy数据
if [ -d *"homeproxy"* ]; then
	echo " "

	HP_RULE="surge"
	HP_PATH="homeproxy/root/etc/homeproxy"

	rm -rf ./$HP_PATH/resources/*

	git clone -q --depth=1 --single-branch --branch "release" "https://github.com/laosan-xx/surge-rules.git" ./$HP_RULE/
	cd ./$HP_RULE/ && RES_VER=$(git log -1 --pretty=format:'%s' | grep -o "[0-9]*")

	echo $RES_VER | tee china_ip4.ver china_ip6.ver china_list.ver gfw_list.ver
	awk -F, '/^IP-CIDR,/{print $2 > "china_ip4.txt"} /^IP-CIDR6,/{print $2 > "china_ip6.txt"}' cncidr.txt
	sed 's/^\.//g' direct.txt > china_list.txt ; sed 's/^\.//g' gfw.txt > gfw_list.txt
	mv -f ./{china_*,gfw_list}.{ver,txt} ../$HP_PATH/resources/

	cd .. && rm -rf ./$HP_RULE/

	cd $PKG_PATH && echo "homeproxy date has been updated!"
fi

#修改argon主题字体和颜色
if [ -d *"luci-theme-argon"* ]; then
	echo " "

	cd ./luci-theme-argon/

	sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" ./luci-app-argon-config/root/etc/config/argon

	cd $PKG_PATH && echo "theme-argon has been fixed!"
fi

#修改aurora菜单式样
if [ -d *"luci-app-aurora-config"* ]; then
	echo " "

	cd ./luci-app-aurora-config/

	sed -i "s/nav_submenu_type '.*'/nav_submenu_type 'boxed-dropdown'/g" $(find ./root/ -type f -name "*aurora")

	cd $PKG_PATH && echo "theme-aurora has been fixed!"
fi

#修改qca-nss-drv启动顺序
NSS_DRV="../feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init"
if [ -f "$NSS_DRV" ]; then
	echo " "

	sed -i 's/START=.*/START=85/g' $NSS_DRV

	cd $PKG_PATH && echo "qca-nss-drv has been fixed!"
fi

#修改qca-nss-pbuf启动顺序
NSS_PBUF="./kernel/mac80211/files/qca-nss-pbuf.init"
if [ -f "$NSS_PBUF" ]; then
	echo " "

	sed -i 's/START=.*/START=86/g' $NSS_PBUF

	cd $PKG_PATH && echo "qca-nss-pbuf has been fixed!"
fi

#修复TailScale配置文件冲突
TS_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/tailscale/Makefile")
if [ -f "$TS_FILE" ]; then
	echo " "

	sed -i '/\/files/d' $TS_FILE

	cd $PKG_PATH && echo "tailscale has been fixed!"
fi

#修复Rust编译失败
RUST_FILE=$(find ../feeds/packages/ -maxdepth 3 -type f -wholename "*/rust/Makefile")
if [ -f "$RUST_FILE" ]; then
	echo " "

	sed -i 's/ci-llvm=true/ci-llvm=false/g' $RUST_FILE

	cd $PKG_PATH && echo "rust has been fixed!"
fi

#修复DiskMan编译失败
DM_FILE="./luci-app-diskman/applications/luci-app-diskman/Makefile"
if [ -f "$DM_FILE" ]; then
	echo " "

	sed -i '/ntfs-3g-utils /d' $DM_FILE

	cd $PKG_PATH && echo "diskman has been fixed!"
fi

#修复luci-app-netspeedtest相关问题
if [ -d *"luci-app-netspeedtest"* ]; then
	echo " "

	cd ./luci-app-netspeedtest/

	sed -i '$a\exit 0' ./netspeedtest/files/99_netspeedtest.defaults
	sed -i 's/ca-certificates/ca-bundle/g' ./speedtest-cli/Makefile

	cd $PKG_PATH && echo "netspeedtest has been fixed!"
fi

#修复mbedtls导致编译失败问题
MBEDTLS_FILE="./libs/mbedtls/Makefile"
if [ -f "$MBEDTLS_FILE" ]; then
	echo " "

	sed -i 's/TARGET_CFLAGS := \$(filter-out -O%,\$(TARGET_CFLAGS)) -Wno-unterminated-string-initialization/& -Wno-error -Wno-error=attributes -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0/' $MBEDTLS_FILE

	cd $PKG_PATH && echo "mbedtls has been fixed!"
fi
