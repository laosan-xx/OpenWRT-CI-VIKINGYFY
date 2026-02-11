#!/bin/bash

#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")
#修改默认密码 password
sed -i "s/root:.*/root:\$5\$MZloauSqpcvpjtZb\$NuVJ6qEGPkanc7\/986bDfZnF22V43GXfxl00hhremR4:20440:0:99999:7:::/g" $(find ./package/base-files/files/etc/ -type f -name "shadow")

# TTYD 免登录
# sed -i 's|/bin/login|/bin/login -f root|g' feeds/packages/utils/ttyd/files/ttyd.config

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	#修改WIFI加密
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

# 自定义脚本同步（Others/uci-defaults → package/base-files/files/etc/uci-defaults）
UCI_DEFAULTS_DIR="./package/base-files/files/etc/uci-defaults"
CUSTOM_UCI_DEFAULTS="${GITHUB_WORKSPACE:+$GITHUB_WORKSPACE/Others/uci-defaults}"
CUSTOM_UCI_DEFAULTS="${CUSTOM_UCI_DEFAULTS:-../Others/uci-defaults}"

mkdir -p "$UCI_DEFAULTS_DIR"

if [ -d "$CUSTOM_UCI_DEFAULTS" ] && find "$CUSTOM_UCI_DEFAULTS" -maxdepth 1 -type f | grep -q .; then
	while IFS= read -r FILE; do
		BASENAME=$(basename "$FILE")
		cp -f "$FILE" "$UCI_DEFAULTS_DIR/$BASENAME"
		chmod +x "$UCI_DEFAULTS_DIR/$BASENAME"
	done < <(find "$CUSTOM_UCI_DEFAULTS" -maxdepth 1 -type f)

	echo "已同步自定义 uci-defaults 脚本到: $UCI_DEFAULTS_DIR"
else
	echo "未找到自定义 uci-defaults 脚本，跳过同步"
fi

# 自定义 root 脚本同步（Others/root-scripts → package/base-files/files/root）
ROOT_SCRIPTS_DIR="./package/base-files/files/root"
CUSTOM_ROOT_SCRIPTS="${GITHUB_WORKSPACE:+$GITHUB_WORKSPACE/Others/root-scripts}"
CUSTOM_ROOT_SCRIPTS="${CUSTOM_ROOT_SCRIPTS:-../Others/root-scripts}"

mkdir -p "$ROOT_SCRIPTS_DIR"

if [ -d "$CUSTOM_ROOT_SCRIPTS" ] && find "$CUSTOM_ROOT_SCRIPTS" -maxdepth 1 -type f | grep -q .; then
	while IFS= read -r FILE; do
		BASENAME=$(basename "$FILE")
		cp -f "$FILE" "$ROOT_SCRIPTS_DIR/$BASENAME"
		chmod +x "$ROOT_SCRIPTS_DIR/$BASENAME"
	done < <(find "$CUSTOM_ROOT_SCRIPTS" -maxdepth 1 -type f)

	echo "已同步自定义 root 脚本到: $ROOT_SCRIPTS_DIR"
else
	echo "未找到自定义 root 脚本，跳过同步"
fi

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
# echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#取消nss相关feed
	echo "CONFIG_FEED_nss_packages=n" >> ./.config
	echo "CONFIG_FEED_sqm_scripts_nss=n" >> ./.config
	#开启sqm-nss插件
	echo "CONFIG_PACKAGE_luci-app-sqm=y" >> ./.config
	echo "CONFIG_PACKAGE_sqm-scripts-nss=y" >> ./.config
	#设置NSS版本
	echo "CONFIG_NSS_FIRMWARE_VERSION_11_4=n" >> ./.config
	if [[ "${WRT_CONFIG,,}" == *"ipq50"* ]]; then
		echo "CONFIG_NSS_FIRMWARE_VERSION_12_2=y" >> ./.config
	else
		echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y" >> ./.config
	fi
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
	#其他调整
	echo "CONFIG_PACKAGE_kmod-usb-serial-qualcomm=y" >> ./.config
fi
