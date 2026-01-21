#!/bin/bash

# 1. 定义 Makefile 所在路径 (根据你的 feed 实际情况修改)
GEOIP_MAKEFILE=$(find $GITHUB_WORKSPACE/wrt/package/feeds/ -name "v2ray-geoip" -type d)/Makefile
GEOSITE_MAKEFILE=$(find $GITHUB_WORKSPACE/wrt/package/feeds/ -name "v2ray-geosite" -type d)/Makefile

# 2. 获取 Makefile 中定义的原始版本号和文件名
# 这样我们才知道要把下载的文件重命名为什么
OLD_IP_VER=$(grep "PKG_VERSION:=" $GEOIP_MAKEFILE | cut -d'=' -f2)
OLD_SITE_VER=$(grep "PKG_VERSION:=" $GEOSITE_MAKEFILE | cut -d'=' -f2)

echo "检测到 Makefile 原始版本: GeoIP($OLD_IP_VER), GeoSite($OLD_SITE_VER)"

# 3. 创建下载目录
mkdir -p $GITHUB_WORKSPACE/wrt/dl

# 4. 下载最新数据文件 (使用 Loyalsoldier 的源，速度快且每日更新)
echo "正在下载最新数据文件..."
curl -L https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -o $GITHUB_WORKSPACE/wrt/dl/v2ray-geoip-$OLD_IP_VER.dat
curl -L https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -o $GITHUB_WORKSPACE/wrt/dl/v2ray-geosite-$OLD_SITE_VER.dat

# 5. 修改 Makefile 绕过 Hash 校验
# 将 PKG_HASH 这一行改为 skip，确保编译时不报错
sed -i 's/PKG_HASH:=.*/PKG_HASH:=skip/g' $GEOIP_MAKEFILE
sed -i 's/PKG_HASH:=.*/PKG_HASH:=skip/g' $GEOSITE_MAKEFILE

echo "更新完成！现在的编译将使用最新的 .dat 数据文件。"
