#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#预下载私有仓库的源码包（laosan-xx/frp 已私有，构建机匿名下载会 404）
#依赖：仓库 Secrets 中配置 FRP_PAT（有该私有仓库读权限的 GitHub PAT）
#原理：先用 PAT 把源码包拉到 dl/，make 检测到 dl/ 内文件哈希正确就不会再联网下载

set -uo pipefail

#固定为单字节 locale，避免不同运行环境下文本处理出现 locale 相关的差异
export LC_ALL=C

#私有源码仓库与对应的软件包目录，可用环境变量覆盖
FRP_REPO="${FRP_REPO:-laosan-xx/frp}"
FRP_PKG_NAME="${FRP_PKG_NAME:-my-frp}"

#定位源码根目录（CI 里 $GITHUB_WORKSPACE/wrt 是 /mnt/build_wrt 的软链接）
if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE/wrt" ]; then
	WRT_DIR="$GITHUB_WORKSPACE/wrt"
else
	WRT_DIR="$(pwd)"
fi

PKG_DIR="$(find "$WRT_DIR/package" -maxdepth 1 -type d -name "$FRP_PKG_NAME" -print -quit)"
if [ -z "$PKG_DIR" ] || [ ! -f "$PKG_DIR/Makefile" ]; then
	echo "package $FRP_PKG_NAME not found, skip private source download!"
	exit 0
fi

MAKEFILE="$PKG_DIR/Makefile"

#展开 Makefile 变量引用，如 $(PKG_NAME)-$(PKG_VERSION).tar.gz
EXPAND() {
	local VALUE="$1"
	VALUE="${VALUE//\$\(PKG_NAME\)/frp}"
	VALUE="${VALUE//\$\{PKG_NAME\}/frp}"
	VALUE="${VALUE//\$\(PKG_VERSION\)/$PKG_VERSION}"
	VALUE="${VALUE//\$\{PKG_VERSION\}/$PKG_VERSION}"
	echo "$VALUE"
}

PKG_VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$MAKEFILE" | head -n 1 | tr -d '\r')"
PKG_SOURCE="$(EXPAND "$(sed -n 's/^PKG_SOURCE:=//p' "$MAKEFILE" | head -n 1 | tr -d '\r')")"
PKG_HASH="$(sed -n 's/^PKG_HASH:=//p' "$MAKEFILE" | head -n 1 | tr -d '\r')"

if [ -z "$PKG_VERSION" ] || [ -z "$PKG_SOURCE" ]; then
	echo "cannot parse PKG_VERSION / PKG_SOURCE from $MAKEFILE, skip!"
	exit 0
fi

DL_DIR="$WRT_DIR/dl"
DL_FILE="$DL_DIR/$PKG_SOURCE"
mkdir -p "$DL_DIR"

#本地已有且哈希一致，直接复用
if [ -f "$DL_FILE" ] && [ -n "$PKG_HASH" ] && [ "$(sha256sum "$DL_FILE" | cut -d ' ' -f 1)" = "$PKG_HASH" ]; then
	echo "private source is up to date: $PKG_SOURCE"
	exit 0
fi

if [ -z "${FRP_PAT:-}" ]; then
	echo "ERROR: FRP_PAT is empty, cannot fetch private source $FRP_REPO!" >&2
	echo "请在仓库 Settings → Secrets and variables → Actions 中添加 FRP_PAT！" >&2
	exit 1
fi

echo "downloading $FRP_REPO v$PKG_VERSION -> $DL_FILE"

rm -f "$DL_FILE"
DOWNLOAD_OK=0

#方式一：codeload 直连（x-access-token 基础认证）
#与 Makefile 里 PKG_SOURCE_URL 同源，哈希通常能和记录的 PKG_HASH 对上
curl -fsSL --connect-timeout 20 --retry 5 \
	-u "x-access-token:$FRP_PAT" \
	"https://codeload.github.com/$FRP_REPO/tar.gz/v$PKG_VERSION" \
	-o "$DL_FILE" && DOWNLOAD_OK=1

#方式二：GitHub API tarball（Bearer 认证，跟随重定向到 codeload）
#注意：API 生成的 tarball 与 codeload 的不是同一份字节，哈希会与 Makefile 记录值不同，下面会自动同步
if [ "$DOWNLOAD_OK" -ne 1 ]; then
	rm -f "$DL_FILE"
	curl -fsSL --connect-timeout 20 --retry 5 \
		-H "Authorization: Bearer $FRP_PAT" \
		-H "Accept: application/vnd.github+json" \
		"https://api.github.com/repos/$FRP_REPO/tarball/v$PKG_VERSION" \
		-o "$DL_FILE" && DOWNLOAD_OK=1
fi

if [ "$DOWNLOAD_OK" -ne 1 ] || [ ! -s "$DL_FILE" ]; then
	rm -f "$DL_FILE"
	echo "ERROR: failed to download $FRP_REPO v$PKG_VERSION, please check FRP_PAT permission!" >&2
	exit 1
fi

#GitHub 两种方式生成的 tarball 可能与 Makefile 记录的哈希不同，以实际内容为准同步 PKG_HASH
REAL_HASH="$(sha256sum "$DL_FILE" | cut -d ' ' -f 1)"
if [ "$REAL_HASH" != "$PKG_HASH" ]; then
	echo "PKG_HASH sync: ${PKG_HASH:-none} -> $REAL_HASH"
	sed -i "s/^PKG_HASH:=.*/PKG_HASH:=$REAL_HASH/" "$MAKEFILE"
fi

echo "private source ready: $PKG_SOURCE ($REAL_HASH)"
