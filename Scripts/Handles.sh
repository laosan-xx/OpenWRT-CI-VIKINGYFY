#!/bin/bash

PKG_PATH="$GITHUB_WORKSPACE/wrt/package/"
OTHER_PATH="$GITHUB_WORKSPACE/Others/"

#预置Frpc数据
FRPC_CONFIG_FILE="../feeds/packages/net/frp/files/frpc.config"
FRPC_INIT_FILE="../feeds/packages/net/frp/files/frpc.init"
FRPC_LUCI_PATH="../feeds/luci/applications/luci-app-frpc"

if [ -f "$FRPC_CONFIG_FILE" ]; then
	echo " "

	# 生成随机英文字符串（8位）
	RANDOM_NAME=$(cat /dev/urandom | tr -dc 'a-z' | head -c 8)

	sed -i '/config conf '\''common'\''/,/^$/s/option server_addr 127.0.0.1/option server_addr frp.2026178.xyz/' $FRPC_CONFIG_FILE
	sed -i '/config conf '\''common'\''/,/^$/s/option server_port 7000/option server_port 5443/' $FRPC_CONFIG_FILE
	sed -i '/option server_port/a\\toption token TiZTjCmJ9ZwCCiMy' $FRPC_CONFIG_FILE
	sed -i '/option token/a\\toption user '"$RANDOM_NAME"'' $FRPC_CONFIG_FILE
	sed -i '/option user/a\\toption login_fail_exit false' $FRPC_CONFIG_FILE
	sed -i '/option login_fail_exit/a\\toption protocol websocket' $FRPC_CONFIG_FILE
	sed -i '/option protocol/a\\toption tls_enable false' $FRPC_CONFIG_FILE

	# 删除默认ssh部分
	# sed -i '/config conf '\''ssh'\''/,/option remote_port 6000/d' $FRPC_CONFIG_FILE
	# 只删除默认ssh固定端口
	sed -i '/option remote_port 6000/d' $FRPC_CONFIG_FILE
	# 修改ssh的local_ip
	sed -i '/config conf '\''ssh'\''/,/option local_ip/s/option local_ip 127.0.0.1/option local_ip 192.168.100.1/' $FRPC_CONFIG_FILE

	# 添加web配置
	sed -i '$a\\nconfig conf '\''web'\''\n\toption type tcp\n\toption use_encryption true\n\toption use_compression true\n\toption local_ip 127.0.0.1\n\toption local_port 80' $FRPC_CONFIG_FILE

	# 验证修改结果
	echo "验证frpc配置修改结果："
	echo "------------------------"
	echo "common配置："
	grep -A 7 "config conf 'common'" $FRPC_CONFIG_FILE
	echo "------------------------"
	echo "ssh配置："
	grep -A 4 "config conf 'ssh'" $FRPC_CONFIG_FILE
	echo "------------------------"
	echo "web配置："
	grep -A 5 "config conf 'web'" $FRPC_CONFIG_FILE
	echo "------------------------"

	# 拷贝lua控制文件并删除静态目录json,将菜单声明完全交由控制器处理
	rm $FRPC_LUCI_PATH/root/usr/share/luci/menu.d/luci-app-frpc.json
	cp -r $OTHER_PATH/frpc/. $FRPC_LUCI_PATH/

	# 将 FRPC_INIT_FILE 文件复制到 $FRPC_ROOT_PATH/etc/init.d/
	mkdir -p $FRPC_LUCI_PATH/root/etc/init.d
	cp -r $FRPC_INIT_FILE $FRPC_LUCI_PATH/root/etc/init.d/
	test -f $FRPC_LUCI_PATH/root/etc/init.d/frpc.init && echo "frpc.init文件复制成功" || echo "frpc.init文件复制失败"

	# 在 $FRPC_LUCI_PATH/Makefile 中添加以下内容
	echo -e '\ndefine Package/$(PKG_NAME)/postinst\n#!/bin/sh\nchmod 755 "$${IPKG_INSTROOT}/etc/init.d/frpc" >/dev/null 2>&1\nln -sf "../init.d/frpc" \\\n	"$${IPKG_INSTROOT}/etc/rc.d/S99frpc" >/dev/null 2>&1\nexit 0\nendef' >> $FRPC_LUCI_PATH/Makefile
	
	# 检验一下内容是否添加成功
	grep -q 'define Package/$(PKG_NAME)/postinst' $FRPC_LUCI_PATH/Makefile
	if [ $? -eq 0 ]; then
		echo "postinst 内容添加成功"
	else
		echo "postinst 内容添加失败"
	fi

	cd $PKG_PATH && echo "frpc config has been set!"
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

	sed -i 's/fs-ntfs/fs-ntfs3/g' $DM_FILE
	sed -i '/ntfs-3g-utils /d' $DM_FILE

	cd $PKG_PATH && echo "diskman has been fixed!"
fi

#修复99_netspeedtest文件残留问题
if [ -d *"luci-app-netspeedtest"* ]; then
	echo " "

	cd ./luci-app-netspeedtest/

	sed -i '$a\exit 0' ./netspeedtest/files/99_netspeedtest.defaults

	cd $PKG_PATH && echo "netspeedtest has been fixed!"
fi