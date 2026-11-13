#!/bin/sh
# ============================================================================
# 99-z-bypass.sh —— 单臂旁路由 + IPv6 默认代理（首次开机执行一次，成功后自删）
#
# 版本：2026-11-13 · IPv6 默认代理版。取代原「纯 IPv4 旁路由」版。
#       /etc/uci-defaults/ 里【只能有这一份收口脚本】。不要新增
#       99-z-bypass-ipv6.sh 之类的第二份：字典序里 "-" (0x2D) < "." (0x2E)，
#       带 "-ipv6" 的文件会先执行、随后被本文件覆盖回去，且两份都会跑一次。
#
# 【这一版要达成什么】
#   客户端（Windows + Android）的 IPv6 默认网关由本机的 RA 接管，
#   v6 流量与 v4 一样经过 Nikki / mihomo。开箱即默认，不依赖客户端手工配置。
#
# 【必须接受的代价 —— 目标自带，不是可选项】
#   1. RA 是链路本地广播，无法只发给 .201/.202。同光猫下 FTTR 从光猫和
#      其它自动获取地址的设备，v6 默认网关都可能被抢到 .253。
#   2. 旁路由一停，这些设备的 IPv6 会一起断（v4 若也填 .253 同样断）。
#   3. Android 对 RFC 4191 的 RA preference 支持不一致，双 RA 竞争不保证赢。
#      刷完必须在电脑和手机上分别看 ::/0 指向谁。
#   4. 光猫仍负责 PPPoE 拨号与 IPv4 DHCP；本机绝不发 DHCPv4 / DHCPv6 地址。
#   5. 国内 v6 也会先进 mihomo 再 DIRECT（网关变到本机，且 nikki.conf 出厂
#      proxy_tcp_dport/udp_dport=0-65535、bypass_china_mainland_ip6=0）。
#      好处是广告/跟踪的 REJECT 首次对 v6 生效，代价是多一次本机转发。
#      这是「代理 v6」的必然形态，不是配置写错了。
#
# 【为什么可以只改这一个文件（2026-11-13 源码核查）】
#   * mihomo 官方 docs/config.yaml 有 fake-ip-range6: fdfe:dcba:9876::1/64。
#   * Nikki mixin.uc:75 无条件把 uci nikki.mixin.fake_ip6_range 写进运行
#     profile 的 dns.fake-ip-range6；nikki.init:186 用 yq 深合并；
#     LuCI mixin.js:263 有 fake_ip6_range (cidr6) 字段。
#     => 假 v6 池由【固件 UCI】注入，上传的 YAML 模板一个字都不用改，
#        也不会因用户上传旧模板而失效，更不牵动 enhanced-mode 与 v4 分流。
#   * Nikki hijack.ut:516/548/582/609 生成
#       ip6 daddr @reserved_ip6  ip6 daddr != <fake-ip6-range>  counter return
#     => fdfe:: 虽落在 reserved_ip6 的 fc00::/7 内，也会被自动排除，
#        不会被当保留地址放行。【不要去删 nikki.proxy.reserved_ip6 的 fc00::/7】。
#   * nikki.init:427-430 在 dns_mode=fake-ip 且 fake_ip6_range 非空时创建
#     nikki-dummy 并加 ip -6 route，假 v6 包有本地出口。
#   * nikki.conf 出厂 udp_mode='tun' 已令 tun_enable=1；ipv6_proxy=1 时
#     nikki.init:421-423 自行生成 ip -6 rule / route。【不需要改 tcp_mode】。
#   * v6 UDP / QUIC 的落点由 nft mark + 策略路由决定，不取决于 profile 里
#     有没有写 tun.inet6-address：hijack.ut:158 在 ipv6_proxy=1 时把 ipv6
#     放进 proxy_nfproto，:343 对 tcp+udp 一律打 tun_fw_mark(0x81)，
#     再由 nikki.init:422-423 送进 table 81 → default dev nikki。
#     mihomo config.go:552 内置 tun.inet6-address=fdfe:dcba:9876::1/126，
#     Nikki mixin.uc 不写它、靠内置默认，所以 tun 设备本来就有 v6 地址。
#     => 验收查 `ip -6 addr show dev nikki`，别去 grep 运行 profile 的
#        tun.inet6-address（查不到是正常的），更不需要 reject udp 443 降级。
#   * hijack.ut:533 在 fake_ip_ping_hijack=1 时生成
#       icmpv6 type echo-request ip6 daddr <fake-ip6-range> counter redirect
#     => 客户端 ping -6 fdfe:dcba:9876::1 可以当硬闸门，不是黑洞。
#   * 镜像自带 odhcp6c / odhcpd-ipv6only / firewall4 / luci-proto-ipv6
#     (x86-64/imm25.config)，build25.sh 与 .config 都不用动，
#     也不要补全量 odhcpd（会与 odhcpd-ipv6only 冲突）。
#
# 【沿用原版、绝不改动的部分】
#   IPv4 静态 .253 / 网关 DNS .1、br-lan 端口修正、只插一根上行线、
#   masq=1 单臂回包、flow_offloading=0、PassWall stop+disable、
#   dnsmasq 保持启用、Nikki config.enabled=0（先上传模板填订阅再启用）、
#   11-08 dsh 复核的三处修订（dns_listen / http_port / uuid 密钥）。
# ============================================================================

BYPASS_IP="192.168.1.253"
UPSTREAM_IP="192.168.1.1"
LOGFILE="/etc/config/uci-defaults-log.txt"
FAKE_IP6_RANGE="fdfe:dcba:9876::1/64"

echo "==== 99-z-bypass.sh [IPv6 默认代理] $(date) ====" >>$LOGFILE
echo "接线提醒：br-lan 含全部物理网口，只接一根上行网线，禁止双线接同一交换机" >>$LOGFILE
echo "影响面提醒：本机发 high 优先级 RA，同广播域设备的 v6 默认网关可能被接管" >>$LOGFILE

# ---------------- 1. 收集物理网口（上游变量不会传过来，必须自己扫） ----------------
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

# ---------------- 2. 强制旁路由 + 本机持有 IPv6 前缀 ----------------
# 真正的硬依赖只有 ip6assign：netifd interface.c:1013 据此设置
# assignment_length，才会从 lan6 收到的 PD 里切一个 /64 给 lan，
# odhcpd 的 RA 才有 PIO 可发；缺了它 ra=server 形同虚设。
# delegate 说明（12:30 复核）：interface.c:1071 的默认值本就是 true
# （no_delegation = !default(true)），且这个标志作用于 proto 层——
# 收 PD 的是 lan6，static 的 lan 上写它不改变行为。这里显式写 '1'
# 只是为了版本无关、不依赖隐式默认，删掉同样能跑；别把它当 IPv6 开关，
# 更不要写成 '0'（会让 netifd 对前缀委派的解释偏离预期）。
uci set network.lan.device='br-lan'
uci set network.lan.proto='static'
uci set network.lan.ipaddr="$BYPASS_IP"
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway="$UPSTREAM_IP"
uci set network.lan.dns="$UPSTREAM_IP"
uci set network.lan.ipv6='1'
uci set network.lan.delegate='1'
uci set network.lan.ip6assign='64'
uci -q delete network.wan
uci -q delete network.wan6
uci -q delete network.globals.ula_prefix

# lan6 别名：用 odhcp6c 在用户态处理光猫的 RA / PD，绕开「开了 v6 forwarding
# 后内核默认忽略 RA」的坑。reqprefix=auto 是发 RA 必需的（与「仅本机 v6」版
# 的 reqprefix=no 不能混用）；peerdns=0 不让光猫的 v6 DNS 进系统 resolver。
uci set network.lan6=interface
uci set network.lan6.proto='dhcpv6'
uci set network.lan6.device='@lan'
uci set network.lan6.reqaddress='try'
uci set network.lan6.reqprefix='auto'
uci set network.lan6.peerdns='0'

# 找 br-lan 的 device section。上游用 awk 的 \d+ 匹配 @device[0]，
# 而 awk ERE 不认 \d，多网口时会漏掉第一个物理口，这里按 name 精确提取。
BR=$(uci show network | sed -n "s/^network\.\([^.=]*\)\.name='br-lan'$/\1/p" | head -1)
if [ -z "$BR" ]; then
    echo "WARN: 找不到 br-lan device section，端口列表保持上游设置" >>$LOGFILE
elif [ -n "$ifnames" ]; then
    uci -q delete "network.$BR.ports"
    for port in $ifnames; do
        uci add_list "network.$BR.ports"="$port"
    done
    echo "br-lan ports: $ifnames" >>$LOGFILE
fi
uci commit network

# ---------------- 3. RA 接管（本版核心）----------------
# ignore=0 取保守值：odhcpd 的 config.c 并不直接读 ignore 选项，它在
# ra/dhcpv4/dhcpv6/ndp 任一非 disabled 时自行把 iface->ignore 清成 false；
# 而 dnsmasq.init:542 会读 ignore 来决定是否加 --no-dhcp-interface。
# 设 0 让两边都不被挡，且已核实不会放出 DHCPv4：
#   dnsmasq.init:579 config_get dhcpv4 "$cfg" dhcpv4 disabled
#   dnsmasq.init:603 仅当 dhcpv4 != disabled 才生成 --dhcp-range
#   dnsmasq.init:560 dhcp_check 发现同网段已有 DHCP（光猫）会自行拒绝启动
# 另外 dnsmasq.init:964-977 在有 odhcpd 的镜像里把 DNSMASQ_DHCP_VER 定为 4，
# 因此 :626 的「DHCPv6 版 dnsmasq 也发 RA」分支不会触发，不会双 RA 自相矛盾。
# 下面两项才是真正挡住「抢发地址」的，缺一不可。
# dhcpv4 尤其关键：一旦发出去，客户端手填的 .201/.202 网关体系立刻乱掉。
# ra_preference=high 是胜负手：不写就是默认 medium，与光猫平级，
# 客户端按 RFC 6724 大概率仍选光猫，整套配置空转。
# ra_default=2：odhcpd 官方定义 0=default / 1=ignore no public address /
# 2=ignore all。目标既是「默认代理 IPv6」，就不能只在拿到公网前缀时才「参选」。
# ★ 比「无条件通告」更关键的一层在 router.c:701-706 / 878-887：
#   if (default_router > 1) valid_prefix = true;
#   if (default_route && valid_prefix) lifetime = ra_lifetime; else lifetime = 0
# 只有 2 会在【没有公网前缀时】也把 valid_prefix 强制置真——光猫重启、PD
# 暂时断掉的那几十秒，RA 的 Router Lifetime 依然非 0，客户端保留旧地址、
# 继续把旁路由当网关，代理不中断。若有人把它改回 0/1 或删掉，PD 一断
# odhcpd 就会发出 lifetime=0 的「撤销默认路由器」，全 LAN v6 连同代理一起掉。
# 注意 ra_default 与优先级无关，优先级只由下面那行 ra_preference 决定。
# ra_lifetime 显式 1800（= 3 × ra_maxinterval 600，RFC4861 / config.c:340
# 的默认值）：【不要压到 600】——那正好等于最大 RA 发送间隔，无线环境
# 只要丢一次 RA，客户端就会把 ::/0 过期掉，正常运行时周期性 v6 抖动。
# 回退窗口不靠它缩短：用 rollback-ipv6-proxy.sh + 客户端重连网卡即可立刻生效。
# ra_dns 保持默认 1（README:117）：本机被通告为 v6 DNS，但 Nikki 的
# lan_dns_hijack 在 prerouting 对 @dns_hijack_nfproto（含 ipv6）的 :53
# 一律 redirect 到 1053，包括发给本机的查询，fake-ip 映射不会绕过去。
uci -q delete dhcp.lan.ra_management            # 25.12 已废弃的旧选项
uci set dhcp.lan.ignore='0'
uci set dhcp.lan.dhcpv4='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_default='2'
uci set dhcp.lan.ra_lifetime='1800'
uci set dhcp.lan.ra_preference='high'
uci set dhcp.lan.ra_slaac='1'
uci -q delete dhcp.lan.ra_flags
uci add_list dhcp.lan.ra_flags='none'           # SLAAC-only：RA 不发 M/O 位
uci set dhcp.lan.ndp='disabled'
uci commit dhcp

# ---------------- 4. 单臂转发 + v6 同区转发 + NAT66 ----------------
# mtu_fix=1 只钳 TCP MSS。QUIC/UDP 没有 MSS 可钳，只能靠 ICMPv6 Packet
# Too Big 回传；若出现「v6 网页偶发卡住 / 视频起播慢 / QUIC 断流」，
# 先临时把 network.lan.mtu 降到 1492 验证，别误判成代理质量差（见落地手册排障表）。
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
    uci set "firewall.@zone[$LAN_ZONE].masq"='1'          # IPv4 单臂回包
    uci set "firewall.@zone[$LAN_ZONE].mtu_fix"='1'      # 光猫 PPPoE 钳 MSS
    uci set "firewall.@zone[$LAN_ZONE].masq6"='1'         # NAT66：回程不依赖光猫回指 PD
    uci set "firewall.@zone[$LAN_ZONE].forward"='ACCEPT'  # br-lan 进 br-lan 出的同区转发
    uci -q get "firewall.@zone[$LAN_ZONE].network" | grep -qw lan6 || \
        uci add_list "firewall.@zone[$LAN_ZONE].network"='lan6'
fi
# 流量卸载会让已建连接绕过 netfilter，透明代理直接漏流（v4/v6 同理）
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall

# ---------------- 5. sysctl ----------------
# accept_ra=2 是本版【硬依赖】：all.forwarding=1 之后内核默认不再处理 RA
# （accept_ra=1 会被 forwarding 压制，只有 2 例外），而本机 GUA 与默认路由
# 全靠光猫的 RA。漏了这项，开转发的瞬间本机 v6 自己先塌，客户端即使网关
# 指过来也没有出口，表现为「v6 全断」——最难排查的那种失败。
# 含接口名的行可以放心放在 /etc/sysctl.d/，补应用链路已由源码确认：
#   /etc/init.d/sysctl  start() 用 `sysctl -e -p`，-e 会静默忽略
#     br-lan 尚未创建时的未知键，不会中断后面的行；
#   /etc/hotplug.d/net/00-sysctl 在 ACTION=add 时按
#     `net..*.$DEVICENAME.` 精确筛出本文件里所有 br-lan 行重放一次。
# 所以 accept_ra=2 / forwarding=1 / v4 三行都会在网桥建好后落到内核，
# 验收脚本必须硬断言读回值，不能只打印。
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-bypass-router.conf <<'EOF'
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.br-lan.send_redirects = 0
net.ipv4.conf.br-lan.accept_redirects = 0
net.ipv4.conf.br-lan.rp_filter = 0
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.br-lan.forwarding = 1
net.ipv6.conf.br-lan.accept_ra = 2
net.ipv6.conf.br-lan.accept_ra_defrtr = 1
EOF
sysctl -p /etc/sysctl.d/99-bypass-router.conf >/dev/null 2>&1
# sysctl 文件不在 /etc/config 下，sysupgrade 默认不保留，登记一下
grep -qx '/etc/sysctl.d/99-bypass-router.conf' /etc/sysupgrade.conf 2>/dev/null || \
    echo '/etc/sysctl.d/99-bypass-router.conf' >>/etc/sysupgrade.conf
echo "旁路由固定 $BYPASS_IP，上游 $UPSTREAM_IP，IPv6 默认代理已开启" >>$LOGFILE

# ---------------- 6. 双代理共存：都装，同一时间只运行一个 ----------------
if [ -x /etc/init.d/passwall ]; then
    /etc/init.d/passwall stop 2>/dev/null
    /etc/init.d/passwall disable 2>/dev/null
    echo "PassWall 已装但保持停用" >>$LOGFILE
fi

# ---------------- 7. Nikki 出厂 UCI：IPv6 默认代理 ----------------
# Nikki 用 yq 深合并把 mixin 并进上传的 YAML：模板独有的键保留、同名键覆盖。
# 因此下面 4 个开关 + fake_ip6_range 会覆盖模板里的 ipv6:false / dns.ipv6:false，
# 并在 dns 段补出模板没有的 fake-ip-range6 —— YAML 工作副本无需任何改动，
# store-selected 的 9 个策略组固定出口也不会因为换模板而丢失。
# overwrite_* 全部固定为 0，保住模板的 DNS / fake-ip-filter / 147 条规则。
if uci -q get nikki.mixin >/dev/null 2>&1; then
    uci set nikki.mixin.ipv6='1'                     # 顶层 ipv6: true
    uci set nikki.mixin.dns_ipv6='1'                 # dns.ipv6: true，AAAA 不再为空
    uci set nikki.mixin.fake_ip6_range="$FAKE_IP6_RANGE"   # ★ 假 v6 池，固件内闭环
    uci set nikki.mixin.http_port='0'                # 11-08 Q：关闭无认证局域网出口
    uci set nikki.mixin.socks_port='0'               # 别抢 7891 (redirect)
    uci set nikki.mixin.mixed_port='0'
    uci set nikki.mixin.dns_listen='[::]:1053'       # v6 :53 劫持后为必需项
    uci set nikki.mixin.fake_ip_filter='0'
    uci set nikki.mixin.dns_nameserver='0'
    uci set nikki.mixin.dns_nameserver_policy='0'
    uci set nikki.mixin.sniffer_sniff='0'
    uci set nikki.mixin.rule='0'
    uci set nikki.mixin.rule_provider='0'
    uci set nikki.mixin.mixin_file_content='0'
    uci set nikki.proxy.ipv6_proxy='1'               # 生成 ip -6 rule/route + v6 重定向
    uci set nikki.proxy.ipv6_dns_hijack='1'          # 把 v6 :53 劫到本机 1053
    # 防御性补 lan6：hijack.ut:96-102 用 ubus 把接口解析成 l3_device。
    # lan 已解析出 br-lan，lan6 是 @lan 别名、通常也解析成 br-lan（重复无害）；
    # 若解析出无效设备名，只是多一条永不匹配的 iifname 规则。
    uci -q get nikki.proxy.lan_inbound_interface | grep -qx 'lan6' || \
        uci add_list nikki.proxy.lan_inbound_interface='lan6'
    # 出厂 api_secret 为空而 external-controller 监听 [::]:9090，
    # 不生成等于局域网任何设备都能控制内核。
    if [ -z "$(uci -q get nikki.mixin.api_secret)" ]; then
        API_SECRET=$(tr -d '-' < /proc/sys/kernel/random/uuid)
        [ -n "$API_SECRET" ] && uci set nikki.mixin.api_secret="$API_SECRET"
    fi
    uci commit nikki
    echo "Nikki: ipv6/dns_ipv6/ipv6_proxy/ipv6_dns_hijack=1, fake_ip6_range=$FAKE_IP6_RANGE" >>$LOGFILE
else
    echo "ERROR: 找不到 nikki.mixin，IPv6 代理未固化！请检查 Nikki 是否装进镜像" >>$LOGFILE
fi
# Nikki 出厂 config.enabled=0：先上传模板、填订阅，再在 LuCI 启用。

uci commit
echo "==== 99-z-bypass.sh [IPv6 默认代理] 完成 ====" >>$LOGFILE
exit 0
