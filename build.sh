#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
#
# ============================================================================
#  本地 / 物理机 一键编译脚本
#  逻辑等价于 GitHub Actions: QCA-ALL.yml  ->  WRT-CORE.yml
#  适用系统: Debian / Ubuntu 系
#
#  用法:
#    ./build.sh                          # QCA-ALL.yml 默认参数: IPQ60XX-WIFI-YES
#    ./build.sh -c IPQ807X-WIFI-YES      # 换编译配置
#    ./build.sh --test                   # 只生成 .config，不编译固件
#    ./build.sh -j 16                    # 指定编译线程数
#    ./build.sh -h                       # 查看全部选项
#
#  与 CI 的差异(为适配本地重复编译所做改动，其余步骤完全一致):
#    1. 源码目录为 $ROOT/wrt(CI 是 /mnt/build_wrt 软链接)，可用 WRT_DIR 指定到其它磁盘
#    2. 默认不再执行 apt full-upgrade / make clean(可用 --upgrade / --make-clean 打开)
#    3. 重复运行时自动复位源码、重建 .config、重建插件克隆目录，保证与首次结果一致
#    4. 不做 GitHub Release 上传，固件统一输出到 upload/<配置>-<时间>/ 目录
#


#    cd ~/OpenWRT-CI-VIKINGYFY/wrt

#  建议先只把工具链编出来，后面每编一个包都是分钟级
#    make toolchain/install -j$(nproc) V=s

#  找包名路径（插件在 feeds/ 或 package/ 下）
#    find feeds package -maxdepth 4 -name Makefile | grep -i openclash

#  单独编译
#    make package/luci-app-openclash/compile V=s
#  改了源码后：先清再编
#    make package/luci-app-openclash/{clean,compile} V=s
#  内核模块同理
#    make package/kernel/kmod-xxx/compile V=s

#
# ============================================================================

set -euo pipefail

# ============================== 环境变量默认值 ==============================
# ---- QCA-ALL.yml 传给 WRT-CORE.yml 的 with 参数 ----
WRT_CONFIG="${WRT_CONFIG:-IPQ60XX-WIFI-YES}"
WRT_THEME="${WRT_THEME:-aurora}"
WRT_NAME="${WRT_NAME:-TK-WRT}"
WRT_SSID="${WRT_SSID:-TK-WRT}"
WRT_WORD="${WRT_WORD:-tk12345678}"
WRT_IP="${WRT_IP:-192.168.99.1}"
WRT_PW="${WRT_PW:-xxxx}"
# matrix: SOURCE=VIKINGYFY/immortalwrt  BRANCH=main
WRT_SOURCE="${WRT_SOURCE:-VIKINGYFY/immortalwrt}"
WRT_BRANCH="${WRT_BRANCH:-main}"
WRT_REPO="${WRT_REPO:-https://github.com/${WRT_SOURCE}.git}"
WRT_PACKAGE="${WRT_PACKAGE:-}"
WRT_TEST="${WRT_TEST:-false}"

REPO_SET=0

# ---- 本地行为开关 ----
SKIP_DEPS=0
DO_UPGRADE=0
FORCE_CLONE=0
RESET_SRC=1
KEEP_FEEDS=0
MAKE_CLEAN=0
JOBS=""

# ============================== 路径与日志 ==============================
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

WRT_DIR="${WRT_DIR:-$ROOT/wrt}"
UPLOAD_DIR="${UPLOAD_DIR:-$ROOT/upload}"
ENV_FILE="$ROOT/.wrt-env"
SHIM_DIR="$ROOT/.build-shim"

: >"$ENV_FILE"
export GITHUB_WORKSPACE="$ROOT"
export GITHUB_ENV="$ENV_FILE"
export DEBIAN_FRONTEND=noninteractive

C_RESET=$'\033[0m'; C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'

step() { printf '\n%s==> %s%s\n' "$C_CYAN" "$*" "$C_RESET"; }
info() { printf '    %s%s%s\n' "$C_BLUE" "$*" "$C_RESET"; }
ok()   { printf '    %s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '    %s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
die()  { printf '\n%s错误: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

CURRENT_STEP="初始化"
on_error() {
	local rc=$?
	printf '\n%s失败: [%s] 退出码 %s%s\n' "$C_RED" "$CURRENT_STEP" "$rc" "$C_RESET" >&2
	exit "$rc"
}
trap on_error ERR

cleanup() {
	rm -rf -- "$SHIM_DIR" "$ENV_FILE" "$APT_LOG"
}
trap cleanup EXIT

# 把写入 $GITHUB_ENV 的内容同步回当前环境(替代 CI 的 $GITHUB_ENV 机制)
sync_env() {
	[ -s "$GITHUB_ENV" ] || return 0
	local LINE
	while IFS= read -r LINE; do
		[[ "$LINE" == *=* ]] || continue
		export "${LINE%%=*}=${LINE#*=}"
	done <"$GITHUB_ENV"
}

# ============================== apt 容错封装 ==============================
# 物理机的软件源常见问题: 第三方源 GPG key 过期/缺失、仓库不提供 i386 包等，
# 这些与 OpenWrt 编译本身无关，因此统一容错处理，避免整条流程中断。
APT_LOG="$(mktemp 2>/dev/null || echo /tmp/wrt-apt.$$.log)"
: >"$APT_LOG"

apt_last_error() {
	tr -d '\r' <"$APT_LOG" 2>/dev/null | grep -E '^(W|E):' | tail -n 1
}

apt_update() {
	local attempt rc=0
	: >"$APT_LOG"
	for attempt in 1 2 3; do
		if $SUDO apt-get update 2>"$APT_LOG"; then
			return 0
		fi
		rc=$?
		warn "apt-get update 失败(第 $attempt 次): $(apt_last_error)"
		sleep 3
	done
	return "$rc"
}

apt_repair() {
	local KEYS KEY NATIVE
	info "尝试自动修复软件源问题..."

	# 1. 缺失或过期的 GPG key
	KEYS="$(tr -d '\r' <"$APT_LOG" 2>/dev/null | grep -oP '(NO_PUBKEY|EXPKEYSIG) \K[0-9A-Fa-f]{8,40}' | sort -u)"
	for KEY in $KEYS; do
		info "重新导入 GPG key: $KEY"
		$SUDO apt-key adv --keyserver keyserver.ubuntu.com --recv-keys "$KEY" >/dev/null 2>&1 ||
			$SUDO apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys "$KEY" >/dev/null 2>&1 ||
			warn "GPG key $KEY 导入失败"
	done

	# 2. 仓库不提供本机多架构支持的包(典型: llvm-apt 无 i386)
	if tr -d '\r' <"$APT_LOG" 2>/dev/null | grep -q 'binary-i386'; then
		NATIVE="$(dpkg --print-architecture)"
		if dpkg -l 2>/dev/null | grep -q ':i386'; then
			warn "本机装有 i386 软件包，跳过架构调整；请手动给相关源加上 [arch=$NATIVE]"
		else
			info "仓库不提供 i386 且本机无 i386 软件，移除 i386 架构"
			$SUDO dpkg --remove-architecture i386 >/dev/null 2>&1 || warn "移除 i386 架构失败"
		fi
	fi
}

apt_install() {
	local attempt rc=0
	for attempt in 1 2 3; do
		if $SUDO apt-get -yqq install "$@" 2>"$APT_LOG"; then
			return 0
		fi
		rc=$?
		warn "apt-get install 失败(第 $attempt 次): $(apt_last_error)"
		[ "$attempt" = "2" ] && { apt_repair; apt_update || true; }
		sleep 3
	done
	return "$rc"
}

run_init_script() {
	local attempt
	for attempt in 1 2 3; do
		if $SUDO bash -c 'bash <(curl -sL https://build-scripts.immortalwrt.org/init_build_environment.sh)'; then
			return 0
		fi
		warn "官方初始化脚本执行失败(第 $attempt 次)，5 秒后重试..."
		sleep 5
	done
	return 1
}

# ============================== 参数解析 ==============================
usage() {
	cat <<'EOF'
用法: ./build.sh [选项]

配置类(对应 QCA-ALL.yml):
  -c, --config <名称>   编译配置名(Config/ 下的文件名)，默认 IPQ60XX-WIFI-YES
      --theme  <名称>   默认主题，默认 aurora
      --name   <名称>   主机名，默认 TK-WRT
      --ssid   <名称>   WIFI 名称，默认 TK-WRT
      --word   <密码>   WIFI 密码，默认 tk12345678
      --ip     <地址>   管理地址，默认 192.168.99.1
      --pw     <密码>   登录密码提示文字，默认 xxxx
      --source <用户/仓库> 源码仓库，默认 VIKINGYFY/immortalwrt
      --branch <分支>   源码分支，默认 main
      --repo   <地址>   源码地址(默认由 --source 推导)
      --package <串>    额外插件配置行，多行用 \n 分隔
      --test            仅输出配置文件，不编译固件

本地行为类:
  -j, --jobs <数量>     编译线程数，默认 nproc
      --no-deps         跳过依赖安装步骤
      --upgrade         额外执行 apt full-upgrade(同 CI)
      --force-clone     删除并重新拉取源码
      --no-reset        不复位源码(保留上一次编译留下的改动)
      --keep-feeds      跳过 ./scripts/feeds update -a
      --make-clean      配置生成后执行 make clean(同 CI，会显著变慢)
  -h, --help            显示本帮助
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		-c|--config)   WRT_CONFIG="$2"; shift 2;;
		--theme)       WRT_THEME="$2"; shift 2;;
		--name)        WRT_NAME="$2"; shift 2;;
		--ssid)        WRT_SSID="$2"; shift 2;;
		--word)        WRT_WORD="$2"; shift 2;;
		--ip)          WRT_IP="$2"; shift 2;;
		--pw)          WRT_PW="$2"; shift 2;;
		--source)      WRT_SOURCE="$2"; shift 2;;
		--branch)      WRT_BRANCH="$2"; shift 2;;
		--repo)        WRT_REPO="$2"; REPO_SET=1; shift 2;;
		--package)     WRT_PACKAGE="$2"; shift 2;;
		--test)        WRT_TEST=true; shift;;
		-j|--jobs)     JOBS="$2"; shift 2;;
		--no-deps)     SKIP_DEPS=1; shift;;
		--upgrade)     DO_UPGRADE=1; shift;;
		--force-clone) FORCE_CLONE=1; shift;;
		--no-reset)    RESET_SRC=0; shift;;
		--keep-feeds)  KEEP_FEEDS=1; shift;;
		--make-clean)  MAKE_CLEAN=1; shift;;
		-h|--help)     usage; exit 0;;
		*) printf '%s未知参数: %s%s\n' "$C_RED" "$1" "$C_RESET" >&2; usage; exit 1;;
	esac
done

[ "$REPO_SET" = "1" ] || WRT_REPO="https://github.com/${WRT_SOURCE}.git"

# ============================== 运行前检查 ==============================
SUDO=""
if [ "$(id -u)" != "0" ]; then
	command -v sudo >/dev/null 2>&1 || die "非 root 运行且未安装 sudo，请自行安装依赖后加 --no-deps 运行"
	SUDO="sudo"
else
	# OpenWrt 默认禁止 root 编译，此为官方提供的绕过开关
	export FORCE_UNSAFE_CONFIGURE=1
	warn "当前以 root 运行，已设置 FORCE_UNSAFE_CONFIGURE=1；建议使用普通用户编译"
fi

THREADS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

[ -f "$ROOT/Config/$WRT_CONFIG.txt" ] || die "配置文件不存在: $ROOT/Config/$WRT_CONFIG.txt"

export WRT_CONFIG WRT_THEME WRT_NAME WRT_SSID WRT_WORD WRT_IP WRT_PW
export WRT_SOURCE WRT_BRANCH WRT_REPO WRT_PACKAGE WRT_TEST THREADS

printf '%s==================== 编译信息 ====================%s\n' "$C_CYAN" "$C_RESET"
printf '  配置名称: %s\n  源码仓库: %s\n  源码分支: %s\n  源码目录: %s\n' \
	"$WRT_CONFIG" "$WRT_REPO" "$WRT_BRANCH" "$WRT_DIR"
printf '  主机名  : %s   管理地址: %s\n  WIFI    : %s / %s\n' \
	"$WRT_NAME" "$WRT_IP" "$WRT_SSID" "$WRT_WORD"
printf '  主题    : %s   线程: %s   仅输出配置: %s\n' \
	"$WRT_THEME" "$THREADS" "$WRT_TEST"
printf '%s==================================================%s\n' "$C_CYAN" "$C_RESET"

WRT_BUILD_DATE="$(TZ=UTC-8 date +"%y.%m.%d-%H.%M.%S")"

# ============================== 1. Initialization Environment ==============================
CURRENT_STEP="初始化编译环境"
step "[1/11] Initialization Environment"

if [ "$SKIP_DEPS" = "1" ]; then
	warn "已跳过依赖安装(--no-deps)"
elif ! command -v apt-get >/dev/null 2>&1; then
	warn "未检测到 apt-get，请自行安装 OpenWrt 编译依赖后重跑(可加 --no-deps)"
else
	info "更新软件源索引..."
	if ! apt_update; then
		apt_repair
		apt_update || warn "软件源仍有错误，将忽略不可用源继续: $(apt_last_error)"
	fi

	if [ "$DO_UPGRADE" = "1" ]; then
		info "升级系统软件包(--upgrade)..."
		$SUDO apt-get -yqq full-upgrade 2>"$APT_LOG" || warn "系统升级失败，继续安装依赖: $(apt_last_error)"
	fi

	# dos2unix/libfuse-dev 为 CI 原样安装项，其余为本地环境补齐
	info "安装基础工具..."
	if apt_install --no-install-recommends dos2unix libfuse-dev jq unzip zip curl wget ca-certificates; then
		ok "基础工具安装完成"
	else
		warn "基础工具安装失败，编译可能中断；可手动修复软件源后重跑，或加 --no-deps 跳过"
	fi

	$SUDO apt-get -yqq autoremove --purge 2>/dev/null || true
	$SUDO apt-get -yqq autoclean 2>/dev/null || true

	info "执行 immortalwrt 官方环境初始化脚本..."
	if run_init_script; then
		ok "官方依赖安装完成"
	else
		warn "官方初始化脚本执行失败，请检查网络；可稍后重跑或加 --no-deps 跳过"
	fi

	$SUDO systemctl daemon-reload 2>/dev/null || true
	$SUDO timedatectl set-timezone "Asia/Shanghai" 2>/dev/null || true
fi

mkdir -p -- "$(dirname "$WRT_DIR")"

# ============================== 2. Initialization Values ==============================
CURRENT_STEP="解析编译变量"
step "[2/11] Initialization Values"

WRT_TARGET="$(grep -m 1 -oP '^CONFIG_TARGET_\K[\w]+(?=\=y)' "./Config/$WRT_CONFIG.txt")"
WRT_SUBTARGET="$(grep -m 1 -oP "^CONFIG_TARGET_${WRT_TARGET}_\K[\w]+(?=\=y)" "./Config/$WRT_CONFIG.txt")"
[ -n "$WRT_TARGET" ] && [ -n "$WRT_SUBTARGET" ] || die "无法从 Config/$WRT_CONFIG.txt 解析 TARGET/SUBTARGET"

WRT_CACHE_SOURCE="${WRT_SOURCE//\//-}"
WRT_CACHE_BRANCH="${WRT_BRANCH//\//-}"
WRT_CACHE_TARGET="$WRT_TARGET-$WRT_SUBTARGET"
WRT_CACHE_PREFIX="wrt-$WRT_CACHE_SOURCE-$WRT_CACHE_BRANCH-$WRT_CACHE_TARGET"

export WRT_INFO="${WRT_SOURCE%%/*}"
export WRT_DATE="$WRT_BUILD_DATE"
export WRT_MARK="${WRT_SOURCE%%/*}"
export WRT_TARGET WRT_SUBTARGET
export WRT_CACHE_TARGET WRT_CACHE_PREFIX
export WRT_WIFI="wifi-yes"
export WRT_KVER="none"
export WRT_LIST="none"

info "TARGET: $WRT_TARGET / SUBTARGET: $WRT_SUBTARGET"
info "编译日期: $WRT_DATE"

# ============================== 3. Clone Code ==============================
CURRENT_STEP="拉取源码"
step "[3/11] Clone Code"

if [ "$FORCE_CLONE" = "1" ] && [ -d "$WRT_DIR" ]; then
	info "删除旧源码(--force-clone): $WRT_DIR"
	rm -rf -- "$WRT_DIR"
fi

if [ -d "$WRT_DIR/.git" ]; then
	if [ "$RESET_SRC" = "1" ]; then
		info "源码已存在，恢复工作区到 HEAD 后复用: $WRT_DIR"
		git -C "$WRT_DIR" reset -q --hard HEAD
	else
		info "源码已存在，保留本地改动后复用: $WRT_DIR (--no-reset)"
	fi
else
	info "克隆 $WRT_REPO ($WRT_BRANCH) -> $WRT_DIR"
	rm -rf -- "$WRT_DIR"
	git clone --depth=1 --single-branch --branch "$WRT_BRANCH" "$WRT_REPO" "$WRT_DIR"
fi

WRT_HASH="$(git -C "$WRT_DIR" rev-parse HEAD)"
export WRT_HASH
export WRT_CACHE_KEY="$WRT_CACHE_PREFIX-$WRT_HASH"
info "源码提交: $WRT_HASH"

# GitHub Action 移除国内下载源
PROJECT_MIRRORS_FILE="$WRT_DIR/scripts/projectsmirrors.json"
if [ -f "$PROJECT_MIRRORS_FILE" ]; then
	sed -i '/.cn\//d; /tencent/d; /aliyun/d' "$PROJECT_MIRRORS_FILE"
fi

# ============================== 4. Check Scripts ==============================
CURRENT_STEP="修正脚本格式"
step "[4/11] Check Scripts"
if ! command -v dos2unix >/dev/null 2>&1; then
	warn "未安装 dos2unix，跳过格式转换"
else
	find ./ -maxdepth 3 -type f -iregex ".*\(txt\|sh\)$" -exec dos2unix {} \; -exec chmod +x {} \;
	ok "脚本格式检查完成"
fi

# ============================== 本地扩展: 复位上一次编译的改动 ==============================
# CI 每次都是全新容器，本地目录会被重复使用，这里把被脚本改过的文件还原，
# 使 sed / 追加类操作保持幂等(否则第二次编译会产生重复修改)。
CURRENT_STEP="复位源码"
step "[4.5/11] Reset Source (本地幂等处理)"
if [ "$RESET_SRC" = "0" ]; then
	warn "已跳过源码复位(--no-reset)"
else
	(
		cd "$WRT_DIR"
		git checkout -- feeds.conf.default package/base-files target/linux scripts 2>/dev/null || true
		git clean -fdq package/base-files/files/etc/uci-defaults 2>/dev/null || true
		git clean -fdq package/base-files/files/usr/bin 2>/dev/null || true
		rm -f -- files/etc/hotplug.d/iface/90-autolanip
		for D in feeds/luci feeds/packages feeds/routing feeds/telephony; do
			if [ -d "$D/.git" ]; then
				git -C "$D" checkout -- . 2>/dev/null || true
			fi
		done
	)
	rm -f -- "$WRT_DIR/.config"
	ok "源码已复位"
fi

# ============================== 5. Update Feeds ==============================
CURRENT_STEP="更新软件源"
step "[5/11] Update Feeds"
(
	cd "$WRT_DIR"

	sed -i '1i\src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main' feeds.conf.default
	sed -i '1i\src-git passwall_luci https://github.com/laosan-xx/openwrt-passwall.git;main' feeds.conf.default

	if [ "$KEEP_FEEDS" = "1" ]; then
		echo "    跳过 feeds update -a (--keep-feeds)"
	else
		./scripts/feeds update -a
	fi

	rm -rf feeds/packages/lang/golang
	git clone --depth=1 https://github.com/sbwml/packages_lang_golang -b 27.x feeds/packages/lang/golang

	./scripts/feeds install -a
)
ok "软件源处理完成"

# ============================== 6. Custom Packages ==============================
# Packages.sh 内部使用 git clone 安装插件，目录已存在时会失败，
# 这里临时接管 git，让 clone 目标存在时先删除，保证可重复执行。
CURRENT_STEP="处理自定义插件"
step "[6/11] Custom Packages"

mkdir -p -- "$SHIM_DIR"
cat >"$SHIM_DIR/git" <<'SH'
#!/usr/bin/env bash
REAL_GIT="$(PATH="/usr/local/bin:/usr/bin:/bin" command -v git)"
REAL_GIT="${REAL_GIT:-/usr/bin/git}"
if [ "${1:-}" != "clone" ]; then
	exec "$REAL_GIT" "$@"
fi
LAST=""
for TOK in "$@"; do
	case "$TOK" in
		-*|clone) continue ;;
	esac
	LAST="$TOK"
done
TARGET=""
if [ -n "$LAST" ]; then
	if [[ "$LAST" == *://* || "$LAST" == *.git || "$LAST" == git@*:* ]]; then
		TARGET="${LAST##*/}"
		TARGET="${TARGET%.git}"
	else
		TARGET="$LAST"
	fi
fi
if [ -n "$TARGET" ] && [ -e "$TARGET" ]; then
	echo "    [shim] 删除已存在的插件目录: $TARGET"
	rm -rf -- "$TARGET"
fi
exec "$REAL_GIT" "$@"
SH
chmod +x -- "$SHIM_DIR/git"

(
	cd "$WRT_DIR/package"
	PATH="$SHIM_DIR:$PATH" bash "$ROOT/Scripts/Packages.sh"
	PATH="$SHIM_DIR:$PATH" bash "$ROOT/Scripts/Handles.sh"
)
rm -rf -- "$SHIM_DIR"
ok "自定义插件处理完成"

# ============================== 7. Custom Settings ==============================
CURRENT_STEP="生成编译配置"
step "[7/11] Custom Settings"
(
	cd "$WRT_DIR"

	rm -f -- .config
	if [[ "${WRT_CONFIG,,}" == *"test"* ]]; then
		cat "$ROOT/Config/$WRT_CONFIG.txt" >>.config
	else
		cat "$ROOT/Config/$WRT_CONFIG.txt" "$ROOT/Config/GENERAL.txt" >>.config
	fi

	bash "$ROOT/Scripts/Settings.sh"
	sync_env

	make defconfig -j"$THREADS"
	if [ "$MAKE_CLEAN" = "1" ]; then
		info "执行 make clean (--make-clean)"
		make clean -j"$THREADS"
	fi
)
sync_env
ok "编译配置已生成: $WRT_DIR/.config"

# ============================== 8. Remove Shadowsocks / Rust 组件 ==============================
CURRENT_STEP="移除 Shadowsocks 组件"
step "[8/11] Remove Shadowsocks and Rust components"
(
	cd "$WRT_DIR"

	# 1. 彻底关闭 PassWall 内的组件开关
	sed -i 's/CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Client=y/# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Client is not set/' .config
	sed -i 's/CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Server=y/# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Server is not set/' .config
	sed -i 's/CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Client=y/# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Client is not set/' .config
	sed -i 's/CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Server=y/# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Server is not set/' .config
	sed -i 's/CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Client=y/# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Client is not set/' .config
	sed -i 's/CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Server=y/# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Server is not set/' .config

	# 2. 彻底关闭底层所有相关包
	sed -i 's/CONFIG_PACKAGE_shadowsocks-libev.*=y/# CONFIG_PACKAGE_shadowsocks-libev is not set/' .config
	sed -i 's/CONFIG_PACKAGE_shadowsocks-rust.*=y/# CONFIG_PACKAGE_shadowsocks-rust is not set/' .config

	# 3. 额外保险：强制在文件末尾注入禁用指令，防止被依赖关系反选
	echo "CONFIG_PACKAGE_shadowsocks-libev-ss-local=n" >>.config
	echo "CONFIG_PACKAGE_shadowsocks-libev-ss-redir=n" >>.config
	echo "CONFIG_PACKAGE_shadowsocks-libev-ss-server=n" >>.config
	echo "CONFIG_PACKAGE_shadowsocks-rust-sslocal=n" >>.config
	echo "CONFIG_PACKAGE_shadowsocks-rust-ssmanager=n" >>.config
	echo "CONFIG_PACKAGE_shadowsocks-rust-ssserver=n" >>.config
	echo "CONFIG_PACKAGE_shadowsocks-rust-ssservice=n" >>.config
	echo "CONFIG_PACKAGE_shadowsocks-rust-ssurl=n" >>.config
	echo "CONFIG_PACKAGE_shadowsocksr-libev-ssr-local=n" >>.config
	echo "CONFIG_PACKAGE_shadowsocksr-libev-ssr-redir=n" >>.config

	# 最后应用配置
	make defconfig -j"$THREADS"
)

CURRENT_STEP="校验移除结果"
step "[8.5/11] Verify Removal"
(
	cd "$WRT_DIR"
	grep "shadowsocks" .config || echo "Successfully removed!"
)

# ============================== 仅输出配置模式 ==============================
if [ "$WRT_TEST" = "true" ]; then
	CURRENT_STEP="输出配置文件"
	step "[TEST] 仅输出配置文件"
	mkdir -p -- "$UPLOAD_DIR/test"
	cp -f "$WRT_DIR/.config" \
		"$UPLOAD_DIR/test/Config-$WRT_CONFIG-$WRT_INFO-$WRT_BRANCH-$WRT_DATE.txt"
	ok "配置文件已保存: $UPLOAD_DIR/test/Config-$WRT_CONFIG-$WRT_INFO-$WRT_BRANCH-$WRT_DATE.txt"
	exit 0
fi

# ============================== 9. Download Packages ==============================
CURRENT_STEP="下载依赖包"
step "[9/11] Download Packages"
(
	cd "$WRT_DIR"
	# 本地网络环境不如 CI 稳定，失败后单线程重试一次
	make download -j"$THREADS" || make download -j1 V=s
)
ok "依赖包下载完成"

# ============================== 10. Compile Firmware ==============================
CURRENT_STEP="编译固件"
step "[10/11] Compile Firmware (线程: $THREADS)"
BUILD_START=$SECONDS
(
	cd "$WRT_DIR"
	# 失败时单线程重跑，便于定位错误
	make -j"$THREADS" || make -j1 V=s
)
BUILD_COST=$(( SECONDS - BUILD_START ))
ok "编译完成，耗时: $(( BUILD_COST / 3600 )) 小时 $(( BUILD_COST % 3600 / 60 )) 分 $(( BUILD_COST % 60 )) 秒"

# ============================== Machine Information ==============================
CURRENT_STEP="输出机器信息"
step "[10.5/11] Machine Information"
(
	cd "$WRT_DIR"
	echo "======================="
	lscpu | grep -E "name|Core|Thread" || true
	echo "======================="
	df -h
	echo "======================="
	du -h --max-depth=1 || true
	echo "======================="
) || true

# ============================== 11. Package Firmware ==============================
CURRENT_STEP="整理固件"
step "[11/11] Package Firmware"

OUT_DIR="$UPLOAD_DIR/$WRT_CONFIG-$WRT_DATE"
mkdir -p -- "$OUT_DIR"

(
	cd "$WRT_DIR"

	cp -f ./.config "$OUT_DIR/Config-$WRT_CONFIG-$WRT_INFO-$WRT_BRANCH-$WRT_DATE.txt"

	find ./bin/targets/ -iregex ".*\(buildinfo\|json\|sha256sums\|packages\)$" -exec rm -rf {} + || true

	for FILE in $(find ./bin/targets/ -type f -iname "*$WRT_TARGET*"); do
		EXT=$(basename "$FILE" | cut -d '.' -f 2-)
		NAME=$(basename "$FILE" | cut -d '.' -f 1 | grep -io "\($WRT_TARGET\).*")
		NEW_FILE="$NAME"-"$WRT_INFO"-"$WRT_BRANCH"-"$WRT_DATE"."$EXT"
		mv -f "$FILE" "$OUT_DIR/$NEW_FILE"
	done

	find ./bin/targets/ -type f -exec mv -f {} "$OUT_DIR/" \; || true
)

WRT_KVER="$(find "$WRT_DIR/bin/targets/" -type f -name "*.manifest" -exec grep -oP '^kernel - \K[\d\.]+' {} \; 2>/dev/null | head -1)"
WRT_LIST="$(find "$WRT_DIR/bin/targets/" -type f -name "*.manifest" -exec grep -oP '^luci-(app|theme)[^ ]*' {} \; 2>/dev/null | tr '\n' ' ')"
export WRT_KVER WRT_LIST

printf '\n%s==================== 编译完成 ====================%s\n' "$C_GREEN" "$C_RESET"
printf '  固件目录: %s\n' "$OUT_DIR"
printf '  源码    : %s (%s)\n' "$WRT_REPO" "$WRT_BRANCH"
printf '  提交    : %s\n' "$WRT_HASH"
printf '  配置    : %s   平台: %s\n' "$WRT_CONFIG" "$WRT_TARGET"
printf '  登录    : %s   密码: %s\n' "$WRT_IP" "$WRT_PW"
printf '  WIFI    : %s / %s\n' "$WRT_SSID" "$WRT_WORD"
printf '  内核    : %s\n' "$WRT_KVER"
printf '  插件    : %s\n' "$WRT_LIST"
printf '%s==================================================%s\n' "$C_GREEN" "$C_RESET"
ls -lh -- "$OUT_DIR" || true

# 本地不执行 GitHub Release 上传，如需发布可执行:
# gh release create "$WRT_CONFIG-LAOSAN-$WRT_DATE" "$OUT_DIR"/* --repo VIKINGYFY/OpenWRT-CI


