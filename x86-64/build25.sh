#!/bin/bash
# Log file for debugging
# 目前支持少部分第三方软件apk 通过打开shell/apk-custom-packages.sh的注释来集成
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入环境变量ENABLE_PPPOE等 写入配置文件 供99-custom.sh读取
cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/apk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

  # 拷贝 run/x86 下所有 run 文件和apk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-apk-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  # 解压并拷贝apk到packages目录
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi


# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#25.12
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# ======== shell/apk-custom-packages.sh =======
# 合并imm仓库以外的第三方插件 暂时注释
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"


# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p files/usr/bin
    # Download mihomo
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-amd64-compatible-v1.19.24.gz"
    mkdir -p files/usr/bin
    wget -qO- "$MIHOMO_URL" | gzip -dc > files/usr/bin/mihomo
    chmod +x files/usr/bin/mihomo
    echo "✅ 已下载 mihomo core"
    ls -lah files/usr/bin
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi
# ============= 第三方插件集成：Nikki 代理（旁路由专用） =============
# 自动取最新 release，不再写死版本号；写死会导致以后永远停在旧版
NIKKI_VER=$(curl -fsSL --max-time 20 https://api.github.com/repos/nikkinikki-org/OpenWrt-nikki/releases/latest \
  | grep -m1 '"tag_name"' | cut -d '"' -f4)
if [ -z "$NIKKI_VER" ]; then
    echo "⚠️ GitHub API 取版本失败（常见于未认证请求的限流），回退到 v1.26.2"
    NIKKI_VER="v1.26.2"
fi
NIKKI_URL="https://github.com/nikkinikki-org/OpenWrt-nikki/releases/download/${NIKKI_VER}/nikki_x86_64-openwrt-25.12.tar.gz"
echo "⬇️ 下载 Nikki ${NIKKI_VER}"

rm -rf /tmp/nikki && mkdir -p /tmp/nikki /home/build/immortalwrt/packages
# --connect-timeout / --max-time 是防卡死的关键：没有超时的话，传输中途停住 curl
# 会一直挂着，Actions 要等 6 小时才判失败（本机实测下到 2/3 处卡死过一次）。
curl -fL --retry 3 --connect-timeout 10 --max-time 900 -o /tmp/nikki.tar.gz "$NIKKI_URL" || { echo "❌ Nikki 下载失败，终止构建"; exit 1; }
tar -xzf /tmp/nikki.tar.gz -C /tmp/nikki || { echo "❌ Nikki 解压失败，终止构建"; exit 1; }
ls /tmp/nikki/*.apk >/dev/null 2>&1 || { echo "❌ Nikki apk 不存在，终止构建"; exit 1; }

# 只取四件套，不取 mihomo-alpha（两个内核 CONFLICTS 互斥，会打架）
for f in /tmp/nikki/nikki-*.apk /tmp/nikki/luci-app-nikki-*.apk \
         /tmp/nikki/luci-i18n-nikki-zh-cn-*.apk /tmp/nikki/mihomo-meta-*.apk; do
  [ -f "$f" ] && cp -v "$f" /home/build/immortalwrt/packages/
done

# ---- 主力：Nikki + mihomo（模板实际运行 TCP Redirect + UDP TUN）----
PACKAGES="$PACKAGES nikki luci-app-nikki luci-i18n-nikki-zh-cn mihomo-meta"
# Nikki 的 ca-bundle / curl / yq / firewall4 / ip-full / kmod-* 都写在 apk 的
# Depends 里，ImageBuilder 会自动解析；真缺了构建会当场报错，不必重复列一遍。

# ---- 备用：PassWall（用户要求两个都装，但同一时间只启用一个，见 99-z-bypass.sh）----
PACKAGES="$PACKAGES luci-app-passwall luci-i18n-passwall-zh-cn"
PACKAGES="$PACKAGES xray-core sing-box hysteria tuic-client v2ray-geoip v2ray-geosite"
# 不装 geoview：查过 ImmortalWrt packages 的 Makefile，它是 geo 文件查看/转换工具
# （TITLE: A geofile toolkit），不是 PassWall 的运行依赖。

# ---- 运维工具：只留实际用得上的 ----
PACKAGES="$PACKAGES luci-i18n-nlbwmon-zh-cn"       # 带宽监控（原有菜单，保留）
PACKAGES="$PACKAGES luci-i18n-zerotier-zh-cn"      # 移动家宽 CGNAT 无公网 IPv4，远程回家的唯一途径
# 不装 watchcat：出厂默认「6 小时 ping 不通 8.8.8.8 就强制重启」，移动宽带容易误判。
# 不装 irqbalance / intel-microcode：单臂旁路由 + 两台终端，多核中断均衡和 CPU 微码
# 对 4-6MB/s 的链路没有可感知收益，少一个包少一处变量。

# 构建参数建议（J4125 / 8G 内存 / 256G 盘，仅手机 + 电脑两台终端，光猫拨号 + 旁路由）：
#   profile          = 2G                # 不装 Docker，规则集 + 双内核足够
#   include_docker   = no               # 旁路由不跑容器，省内存和 CPU
#   enable_pppoe     = no               # 拨号由光猫负责，这一项务必保持 no
#   custom_router_ip 任意              # 本模式不读它，旁路由固定 192.168.1.253（光猫 DHCP 池外）
#   luci_version     = 25.12.2         # 每次构建的 release tag 会带上版本号和运行号，可回滚

ls -lah /home/build/immortalwrt/packages/
echo "=== 最终包列表 ==="; echo "$PACKAGES"
# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
