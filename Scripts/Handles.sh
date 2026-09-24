#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE/wrt/package" ]; then
	PACKAGE_PATH="$GITHUB_WORKSPACE/wrt/package"
	FEEDS_PATH="$GITHUB_WORKSPACE/wrt/feeds"
	OTHER_PATH="$GITHUB_WORKSPACE/Others"
else
	PACKAGE_PATH="./package"
	FEEDS_PATH="./feeds"
	OTHER_PATH="$(pwd)/Others"
fi


#移除源码内置的雅典娜LED控制(package/emortal/luci-app-athena-led)
#Packages.sh 的清理只扫描 feeds/luci 与 feeds/packages，源码树自带的同名包不会被删除；
#不删掉会与上游拆分版(athena-led + luci-app-athena-led)重名，设备 profile 强制选中的
#luci-app-athena-led 仍会落到内置旧版，新版永远编不进固件
#删掉内置旧版后，profile 里的 luci-app-athena-led 会自然落到新版，再由 +athena-led 依赖带出核心包，
#这样只有雅典娜设备会带这个菜单；不需要、也不应该在 Config 里全局写 CONFIG_PACKAGE_athena-led=y
ATHENA_BUILTIN="$(find "$PACKAGE_PATH" -mindepth 2 -maxdepth 3 -type d -iname '*athena-led*' 2>/dev/null)"
if [ -n "$ATHENA_BUILTIN" ]; then
	echo " "
	while IFS= read -r DIR; do
		if rm -rf "$DIR"; then
			echo "Delete built-in directory: $DIR"
		else
			echo "built-in directory delete failed: $DIR; continuing!"
		fi
	done <<< "$ATHENA_BUILTIN"
fi

#保持雅典娜LED控制的菜单位置与内置旧版一致(系统菜单)，上游默认挂在服务菜单
ATHENA_MENU="$PACKAGE_PATH/luci-app-athena-led/root/usr/share/luci/menu.d/luci-app-athena-led.json"
if [ -f "$ATHENA_MENU" ]; then
	echo " "
	if sed -i 's#admin/services/athena_led#admin/system/athena_led#' "$ATHENA_MENU"; then
		echo "athena-led has been fixed!"
	else
		echo "athena-led fix failed; continuing!"
	fi
fi

#上游界面包没走 luci.mk，缺少 luci-base/host 时 po2lmo 不可用，中文语言包会静默编不出来
ATHENA_LUCI_MK="$PACKAGE_PATH/luci-app-athena-led/Makefile"
if [ -f "$ATHENA_LUCI_MK" ] && ! grep -q "PKG_BUILD_DEPENDS" "$ATHENA_LUCI_MK"; then
	echo " "
	if sed -i 's#^include \$(INCLUDE_DIR)/package.mk#PKG_BUILD_DEPENDS:=luci-base/host\n&#' "$ATHENA_LUCI_MK"; then
		echo "athena-led i18n depends has been fixed!"
	else
		echo "athena-led i18n depends fix failed; continuing!"
	fi
fi

#移除 jdcloud_re-cs-02 设备 profile 中的独立中文语言包
#源码 target/linux/qualcommax/image/ipq60xx.mk 的 DEVICE_PACKAGES 写死了 luci-i18n-athena-led-zh-cn，
#新版 luci-app-athena-led(v2.4.0) 语言已内置，不再产出该独立包，固件打包时 apk 会报
#"ERROR: unable to select packages: luci-i18n-athena-led-zh-cn (no such package)"
ATHENA_PROFILE_MK="$PACKAGE_PATH/../target/linux/qualcommax/image/ipq60xx.mk"
if [ -f "$ATHENA_PROFILE_MK" ]; then
	echo " "
	if sed -i '/jdcloud_re-cs-02/s/ luci-i18n-athena-led-zh-cn//' "$ATHENA_PROFILE_MK"; then
		echo "athena-led profile has been fixed!"
	else
		echo "athena-led profile fix failed; continuing!"
	fi
fi

HP_DIR="$(find "$PACKAGE_PATH" -maxdepth 3 -type d -iname '*homeproxy*' -print -quit 2>/dev/null)"
if [ -n "$HP_DIR" ]; then
	echo " "
	if hp_preset_resources "$HP_DIR"; then
		echo "homeproxy data has been updated!"
	else
		echo "homeproxy resource preset completed with errors; continuing!"
	fi
fi

#解决wan口地址与lan口冲突
HOTPLUG_IFACE_DIR="$GITHUB_WORKSPACE/wrt/files/etc/hotplug.d/iface"
mkdir -p "$HOTPLUG_IFACE_DIR"
if [ -f "$OTHER_PATH/90-autolanip" ]; then
	echo " "
	if cp -f "$OTHER_PATH/90-autolanip" "$HOTPLUG_IFACE_DIR/90-autolanip" && chmod +x "$HOTPLUG_IFACE_DIR/90-autolanip"; then
		echo "autolanip has been added!"
	else
		echo "autolanip add failed; continuing!"
	fi
fi

#修改argon主题字体和颜色
if [ -d "$PACKAGE_PATH/luci-theme-argon" ]; then
	echo " "
	if sed -i "s/primary '.*'/primary '#31a1a1'/g; s/'0.2'/'0.5'/g; s/'none'/'bing'/g; s/'600'/'normal'/g" \
		"$PACKAGE_PATH/luci-theme-argon/luci-app-argon-config/root/etc/config/argon"; then
		echo "theme-argon has been fixed!"
	else
		echo "theme-argon fix failed; continuing!"
	fi
fi

#修改aurora菜单式样
if [ -d "$PACKAGE_PATH/luci-app-aurora-config" ]; then
	echo " "
	if find "$PACKAGE_PATH/luci-app-aurora-config/root/usr/share/aurora/" -type f -name '*.template' -exec \
		sed -i "s/nav_type '.*'/nav_type 'dropdown'/g; s/struct_radius_base '.*'/struct_radius_base '0.125rem'/g" {} +; then
		echo "theme-aurora has been fixed!"
	else
		echo "theme-aurora fix failed; continuing!"
	fi
fi

#修改mini-diskmanager菜单位置
if [ -d "$PACKAGE_PATH/luci-app-mini-diskmanager" ]; then
	echo " "
	if sed -i "s/services/system/g" \
		"$PACKAGE_PATH/luci-app-mini-diskmanager/luci-app-mini-diskmanager/root/usr/share/luci/menu.d/luci-app-mini-diskmanager.json"; then
		echo "mini-diskmanager has been fixed!"
	else
		echo "mini-diskmanager fix failed; continuing!"
	fi
fi

#修改natmapt菜单位置
if [ -d "$PACKAGE_PATH/luci-app-natmapt" ]; then
	echo " "
	if sed -i "s/network/services/g" \
		"$PACKAGE_PATH/luci-app-natmapt/root/usr/share/luci/menu.d/luci-app-natmap.json"; then
		echo "natmapt has been fixed!"
	else
		echo "natmapt fix failed; continuing!"
	fi
fi

#修复Rust编译失败
if [ -d "$FEEDS_PATH/packages/lang/rust" ]; then
	echo " "
	if sed -i 's/ci-llvm=true/ci-llvm=false/g' \
		"$FEEDS_PATH/packages/lang/rust/Makefile"; then
		echo "rust has been fixed!"
	else
		echo "rust fix failed; continuing!"
	fi
fi
