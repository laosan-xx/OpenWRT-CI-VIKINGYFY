#!/bin/bash

PKG_PATH="$GITHUB_WORKSPACE/wrt/package/"
FEEDS_PATH="$GITHUB_WORKSPACE/wrt/feeds/"

#预置Frpc数据
FRPC_CONFIG_DRV="../feeds/packages/net/frp/files/frpc.config"
if [ -f "$FRPC_CONFIG_DRV" ]; then
	echo " "

	# 生成随机英文字符串（8位）
	RANDOM_NAME=$(cat /dev/urandom | tr -dc 'a-z' | head -c 8)

	sed -i 's/server_addr = 127.0.0.1/server_addr = frp.2026178.xyz/g' $FRPC_CONFIG_DRV
	sed -i 's/server_port = 7000/server_port = 5443/g' $FRPC_CONFIG_DRV
	sed -i '/option server_port/a\\toption token TiZTjCmJ9ZwCCiMy' $FRPC_CONFIG_DRV
	sed -i '/option token/a\\toption user '"$RANDOM_NAME"'' $FRPC_CONFIG_DRV
	sed -i '/option user/a\\toption login_fail_exit false' $FRPC_CONFIG_DRV
	sed -i '/option login_fail_exit/a\\toption protocol websocket' $FRPC_CONFIG_DRV
	sed -i '/option protocol/a\\toption tls_enable false' $FRPC_CONFIG_DRV

	# 删除默认ssh部分
	# sed -i '/config conf '\''ssh'\''/,/option remote_port 6000/d' $FRPC_CONFIG_DRV
	# 只删除默认ssh固定端口
	sed -i '/option remote_port 6000/d' $FRPC_CONFIG_DRV
	# 修改ssh的local_ip
	sed -i '/config conf '\''ssh'\''/,/option local_ip/s/option local_ip 127.0.0.1/option local_ip 192.168.100.1/' $FRPC_CONFIG_DRV

	# 添加web配置
	sed -i '$a\\nconfig conf '\''web'\''\n\toption type tcp\n\toption use_encryption true\n\toption use_compression true\n\toption local_ip 127.0.0.1\n\toption local_port 80' $FRPC_CONFIG_DRV

	# 验证修改结果
	echo "验证frpc配置修改结果："
	echo "------------------------"
	echo "common配置："
	grep -A 7 "config conf 'common'" $FRPC_CONFIG_DRV
	echo "------------------------"
	echo "ssh配置："
	grep -A 4 "config conf 'ssh'" $FRPC_CONFIG_DRV
	echo "------------------------"
	echo "web配置："
	grep -A 5 "config conf 'web'" $FRPC_CONFIG_DRV
	echo "------------------------"

	# 将当前目录frpc下的etc文件夹复制到 ../feeds/luci/applications/luci-app-frpc/root/etc
	cp -r ./frpc/etc ../feeds/luci/applications/luci-app-frpc/root/etc
  test -d ../feeds/luci/applications/luci-app-frpc/root/etc && echo "frp etc目录存在，复制可能成功" || echo "frp etc目录不存在，复制失败"

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

#修改argon主题字体和颜色
# if [ -d *"luci-theme-argon"* ]; then
# 	echo " "

# 	cd ./luci-theme-argon/

# 	sed -i "/font-weight:/ { /important/! { /\/\*/! s/:.*/: var(--font-weight);/ } }" $(find ./luci-theme-argon -type f -iname "*.css")
# 	sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.2'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" ./luci-app-argon-config/root/etc/config/argon

# 	cd $PKG_PATH && echo "theme-argon has been fixed!"
# fi
ARGON_CONFIG_DRV="../feeds/luci/applications/luci-app-argon-config/root/etc/config/argon"
if [ -f "ARGON_CONFIG_DRV" ]; then
	echo " "
 
	sed -i "s/primary '.*'/primary '#31a1a1'/; s/'0.3'/'0.5'/; s/'none'/'bing'/; s/'600'/'normal'/" $ARGON_CONFIG_DRV

	cd $PKG_PATH && echo "argon-config has been set!"
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
