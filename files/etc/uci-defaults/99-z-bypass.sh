#!/bin/sh
# ============================================================================
# 99-z-bypass.sh —— 旁路由收口脚本（首次开机自动执行一次，成功后系统会删除本文件）
#
# 为什么是独立文件：OpenWrt 的 /etc/init.d/boot 用 `ls` 的字典序遍历
# /etc/uci-defaults/ 并逐个 source，所以本文件排在 99-custom.sh 之后执行，
# 可以覆盖上游的设置；上游 99-custom.sh 保持原样，以后同步上游不会冲突。
#
# 与上游 99-custom.sh 的关系：上游按「物理网口数量」分支，多网口会被配成
# 192.168.100.1 + 自己发 DHCP 的二级主路由。本文件不看网口数量，一律收口成
# 旁路由，把上游写过的 lan / wan / wan6 / br-lan 端口 / DHCP 全部覆盖掉。
#
# 接线警告：所有物理网口都并入了 br-lan，只接一根上行网线到光猫。
# 绝不能把两个网口接到同一台光猫或同一台交换机，否则二层环路会让全网瘫痪
# （br-lan 默认不启用 STP）。下面留了可选开关，需要防呆时可取消注释。
# ============================================================================

# ---------------- 按光猫实测页面填写的两个常量 ----------------
# 中国移动 ZXHN G7615AV5（XG-PON/FTTR 主网关）自己 PPPoE 拨号并发 DHCP：
#   光猫 LAN 192.168.1.1/24，DHCP 池 192.168.1.2 ~ 192.168.1.252，
#   下挂 FTTR 从光猫，因此绝不能关光猫 DHCP，也不能本机抢发 DHCP。
# 本机地址必须固定在池外，否则客户端手填的网关会随 DHCP 漂移。
BYPASS_IP="192.168.1.253"
UPSTREAM_IP="192.168.1.1"
LOGFILE="/etc/config/uci-defaults-log.txt"

echo "==== 99-z-bypass.sh $(date) ====" >>$LOGFILE
echo "接线提醒：br-lan 含全部物理网口，只接一根上行网线，禁止双线接同一交换机" >>$LOGFILE

# ---------------- 1. 收集物理网口（变量不会从上游脚本传过来，必须自己扫） ----------------
ifnames=""
for iface in /sys/class/net/*; do
    [ -e "$iface/device" ] || continue
    name=$(basename "$iface")
    case "$name" in
        eth*|en*) ifnames="$ifnames $name" ;;
    esac
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')
echo "physical interfaces: $ifnames" >>$LOGFILE

# ---------------- 2. 强制旁路由：不看网口数量 ----------------
uci set network.lan.device='br-lan'
uci set network.lan.proto='static'
uci set network.lan.ipaddr="$BYPASS_IP"
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway="$UPSTREAM_IP"
uci set network.lan.dns="$UPSTREAM_IP"
uci set network.lan.ipv6='0'
uci set network.lan.delegate='0'
uci -q delete network.wan
uci -q delete network.wan6
uci -q delete network.globals.ula_prefix

# 找 br-lan 的 device section。
# 上游用 awk 的 \d+ 去匹配 device[0]，而 awk 的 ERE 不认识 \d，
# 在多网口机器上会匹配失败 → 第一个物理口被漏在桥外、插上没网。
# 这里直接从 uci show 的输出按 name 精确提取 section id，
# 同时兼容匿名 section @device[n] 和命名 section。
BR=$(uci show network | sed -n "s/^network\.\([^.=]*\)\.name='br-lan'$/\1/p" | head -1)

if [ -z "$BR" ]; then
    echo "WARN: 找不到 br-lan device section，端口列表保持上游设置" >>$LOGFILE
elif [ -n "$ifnames" ]; then
    uci -q delete "network.$BR.ports"
    for port in $ifnames; do
        uci add_list "network.$BR.ports"="$port"
    done
    # 防呆可选：插两根上行线时由 STP 阻塞一端，代价是开机后约 30 秒才通。
    # uci set "network.$BR.stp"='1'
    echo "br-lan ports: $ifnames" >>$LOGFILE
fi
uci commit network

# ---------------- 3. 本机绝不能发 DHCP / RA ----------------
# 系统默认 /etc/config/dhcp 的 lan 段是 dhcpv4/dhcpv6/ra 全 server 且 authoritative，
# 不关会和光猫抢发地址、抢发 IPv6 路由通告，客户端网关飘移、IPv6 绕过 fake-ip。
uci set dhcp.lan.ignore='1'
uci set dhcp.lan.dhcpv4='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci commit dhcp

# ---------------- 4. 单臂转发：一个口进、同一个口出 ----------------
LAN_ZONE=""
i=0
while [ "$i" -le 8 ]; do
    if [ "$(uci -q get "firewall.@zone[$i].name")" = "lan" ]; then
        LAN_ZONE="$i"
        break
    fi
    i=$((i + 1))
done
if [ -n "$LAN_ZONE" ]; then
    uci set "firewall.@zone[$LAN_ZONE].masq"='1'      # IP 动态伪装，回包才原路返回
    uci set "firewall.@zone[$LAN_ZONE].mtu_fix"='1'  # 光猫是 PPPoE，钳制 MSS 防大包卡住
fi
# 流量卸载会让已建立的连接绕过 netfilter，透明代理直接漏流
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall

# 内核默认会给同网段客户端发 ICMP 重定向，把它们引回光猫，代理随之失效
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-bypass-router.conf <<'EOF'
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
sysctl -p /etc/sysctl.d/99-bypass-router.conf >/dev/null 2>&1
# 本脚本首次开机后会被系统删除，sysctl 文件不在 /etc/config 里、sysupgrade 默认不保留，
# 所以登记到 /etc/sysupgrade.conf，保留配置升级后重定向设置不会丢。
grep -qx '/etc/sysctl.d/99-bypass-router.conf' /etc/sysupgrade.conf 2>/dev/null || \
    echo '/etc/sysctl.d/99-bypass-router.conf' >>/etc/sysupgrade.conf
echo "旁路由固定 $BYPASS_IP，上游 $UPSTREAM_IP" >>$LOGFILE

# ---------------- 5. 双代理共存：都装，但同一时间只运行一个 ----------------
# PassWall 与 Nikki 都要接管 nftables / DNS / 路由，同时运行会互相覆盖规则。
# 主力是 Nikki；PassWall 菜单保留，切换时先在 Nikki 停用再启用 PassWall。
if [ -x /etc/init.d/passwall ]; then
    /etc/init.d/passwall stop 2>/dev/null
    /etc/init.d/passwall disable 2>/dev/null
    echo "PassWall 已装但保持停用" >>$LOGFILE
fi

# ---------------- 6. Nikki 出厂 UCI 与模板对齐 ----------------
# Nikki 用 yq 深合并把 UCI 的 mixin 项并进上传的 YAML：模板独有的键保留，
# 同名键被 UCI 覆盖；overwrite_* 为 1 才会删模板的 DNS/规则键（出厂全 0）。
# 下面对齐端口与 IPv6，并显式固定覆盖开关为 0，保住模板的分流规则。
if uci -q get nikki.mixin >/dev/null 2>&1; then
    uci set nikki.mixin.ipv6='0'
    uci set nikki.mixin.dns_ipv6='0'
    uci set nikki.mixin.http_port='7890'          # 模板 port: 7890
    uci set nikki.mixin.socks_port='0'            # 模板 socks-port: 0，别抢 7891
    uci set nikki.mixin.mixed_port='0'            # 模板 mixed-port: 0
    uci set nikki.mixin.dns_listen=':1053'        # 模板 dns.listen: ':1053'
    uci set nikki.mixin.fake_ip_filter='0'
    uci set nikki.mixin.dns_nameserver='0'
    uci set nikki.mixin.dns_nameserver_policy='0'
    uci set nikki.mixin.sniffer_sniff='0'
    uci set nikki.mixin.rule='0'
    uci set nikki.mixin.rule_provider='0'
    uci set nikki.mixin.mixin_file_content='0'
    uci set nikki.proxy.ipv6_proxy='0'
    uci set nikki.proxy.ipv6_dns_hijack='0'
    # 出厂 api_secret 为空而 external-controller 监听 [::]:9090，
    # 局域网里任何设备都能控制内核。首次启动生成随机密钥；LuCI 的
    # 「打开面板」会读取运行配置里的 secret 自动带上，不需要手动填写。
    if [ -z "$(uci -q get nikki.mixin.api_secret)" ]; then
        API_SECRET=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
        [ -n "$API_SECRET" ] && uci set nikki.mixin.api_secret="$API_SECRET"
    fi
    uci commit nikki
    echo "Nikki mixin 已与 Mihomo-Nikki-v7.5 模板对齐，API 密钥已生成" >>$LOGFILE
fi
# Nikki 出厂 config.enabled=0（不自启）：先上传模板、填订阅再启用。
# 模板的 store-selected 缓存仍需在面板里把那几个组重新固定出口。

uci commit
echo "==== 99-z-bypass.sh 完成 ====" >>$LOGFILE
exit 0
