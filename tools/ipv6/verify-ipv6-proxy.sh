#!/bin/sh
# ============================================================================
# verify-ipv6-proxy.sh —— 「IPv6 默认代理」只读验收（固件版 / 阶段一现场版通用）
#
# 用法（软路由本地终端 / SSH 均可，全程只读，不修改任何配置）：
#   sh verify-ipv6-proxy.sh
#
# 配套：ipv6-default/99-z-bypass.sh（首次开机固化脚本）
#       ipv6-default/stage1-live-ipv6-proxy.sh（阶段一现场应用，不刷机）
# 两种场景用同一份断言：阶段一 apply + reboot 之后、阶段二刷机之后，A/A2/B/C
# 段应逐项一致。唯一区别是 A 段第 1 项「uci-defaults 脚本已自删」——现有固件
# 上它早已自删，同样会通过，不必特殊处理。
# 原则：先看 A / A2 / B 段，任一 FAIL 就别往下查了；C 段是运行态；D 段在客户端做。
# 回退：阶段一用 stage1... revert（精确快照）；阶段二重刷不带 -v6 的旧 tag。
# ============================================================================

FAILS=0
CONF="/etc/nikki/run/config.yaml"
FAKE6="fdfe:dcba:9876::1/64"

hr()  { printf '\n===== %s =====\n' "$1"; }
pass(){ printf '  [OK]   %s\n' "$1"; }
fail(){ printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS + 1)); }
info(){ printf '  [..]   %s\n' "$1"; }
eq()  { got=$(uci -q get "$1" 2>/dev/null); if [ "$got" = "$2" ]; then pass "$1 = $2"; else fail "$1 = '$got'（期望 '$2'）"; fi; }

echo "========== IPv6 默认代理 · 只读验收 $(date) =========="

hr "A. 出厂 UCI（99-z-bypass.sh 是否生效）"
if [ -e /etc/uci-defaults/99-z-bypass.sh ]; then
    fail "/etc/uci-defaults/99-z-bypass.sh 仍存在，首次开机脚本没跑完"
else
    pass "首次开机脚本已执行并自删"
fi
eq network.lan.ipv6        '1'
eq network.lan.delegate    '1'    # 与 netifd 默认值相同，显式写只为版本无关
eq network.lan.ip6assign   '64'   # ★ 真硬依赖：netifd 据此切 /64，RA 才有 PIO
eq network.lan6.proto      'dhcpv6'
eq network.lan6.device     '@lan'
eq network.lan6.reqprefix  'auto'
eq network.lan6.peerdns    '0'
eq dhcp.lan.ignore         '0'
eq dhcp.lan.dhcpv4         'disabled'
eq dhcp.lan.dhcpv6         'disabled'
eq dhcp.lan.ra             'server'
eq dhcp.lan.ra_default     '2'
eq dhcp.lan.ra_lifetime    '1800'   # =3×MaxRtrAdvInterval，压到 600 会周期性掉 ::/0
eq dhcp.lan.ra_preference  'high'
eq nikki.mixin.ipv6        '1'
eq nikki.mixin.dns_ipv6    '1'
eq nikki.mixin.dns_listen  '[::]:1053'
eq nikki.mixin.fake_ip6_range "$FAKE6"
eq nikki.proxy.ipv6_proxy       '1'
eq nikki.proxy.ipv6_dns_hijack  '1'
eq firewall.@defaults[0].flow_offloading '0'
LAN_Z=""
i=0
while [ "$i" -le 8 ]; do
    [ "$(uci -q get "firewall.@zone[$i].name")" = "lan" ] && { LAN_Z="$i"; break; }
    i=$((i + 1))
done
if [ -n "$LAN_Z" ]; then
    eq "firewall.@zone[$LAN_Z].masq"      '1'
    eq "firewall.@zone[$LAN_Z].masq6"     '1'
    eq "firewall.@zone[$LAN_Z].forward"   'ACCEPT'
else
    fail "找不到 firewall 的 lan zone"
fi
hr "A2. sysctl 硬闸门（最容易漏：accept_ra≠2 会让本机 v6 自己塌）"
for kv in "net.ipv6.conf.all.forwarding:1" \
          "net.ipv6.conf.br-lan.forwarding:1" \
          "net.ipv6.conf.br-lan.accept_ra:2" \
          "net.ipv6.conf.br-lan.accept_ra_defrtr:1"; do
    k="${kv%%:*}"; want="${kv##*:}"
    v=$(sysctl -n "$k" 2>/dev/null)
    [ "$v" = "$want" ] && pass "$k = $want" \
        || fail "$k = '$v'（期望 $want；若为空气查 hotplug.d/net/00-sysctl 是否重放本行）"
done
info "sysctl 文件里的 br-lan 行（网桥 add 时由 hotplug 重放）："
grep -E 'net\..*\.br-lan\.' /etc/sysctl.d/99-bypass-router.conf 2>/dev/null | sed 's/^/    /'
for k in send_redirects accept_redirects rp_filter; do
    v=$(sysctl -n "net.ipv4.conf.br-lan.$k" 2>/dev/null)
    [ "$v" = "0" ] && pass "br-lan.$k = 0" || fail "br-lan.$k = '$v'（期望 0，v4 分流可能漏）"
done

hr "B. 运行 profile（★ 最容易被忽略的一关）"
if [ ! -f "$CONF" ]; then
    fail "$CONF 不存在 —— Nikki 还没启用 / 没上传模板，后面全部免谈"
    info "到 LuCI「服务 → Nikki」上传工作副本、填订阅并启用后重跑本脚本"
else
    if command -v yq >/dev/null 2>&1; then
        for pair in "ipv6:.ipv6" "dns.ipv6:.dns.ipv6" "enhanced-mode:.dns.enhanced-mode" \
                    "fake-ip-range6:.dns.fake-ip-range6" "fake-ip-range:.dns.fake-ip-range"; do
            label="${pair%%:*}"; key="${pair#*:}"
            v=$(yq -M "$key // \"\"" "$CONF" 2>/dev/null)
            case "$label" in
                ipv6|dns.ipv6)        [ "$v" = "true" ]              && pass "$label = $v" || fail "$label = '$v'（期望 true）" ;;
                enhanced-mode)        [ "$v" = "fake-ip" ]            && pass "$label = $v" || fail "$label = '$v'（期望 fake-ip，别动它）" ;;
                fake-ip-range6)       [ "$v" = "$FAKE6" ]             && pass "$label = $v（mixin 已注入，YAML 不用改）" \
                                                                       || fail "$label = '$v'（期望 $FAKE6）" ;;
                fake-ip-range)        [ "$v" = "198.18.0.1/16" ]      && pass "$label = $v（v4 分流没被牵连）" \
                                                                       || fail "$label = '$v'（期望 198.18.0.1/16）" ;;
            esac
        done
    else
        fail "找不到 yq，无法核对运行 profile"
    fi
    info "运行 profile 里 dns 段相关键（人工复核）："
    grep -nE '^\s*(ipv6|enhanced-mode|fake-ip-range6?):' "$CONF" | head -10 | sed 's/^/    /'
fi

hr "C. 内核 / 路由 / nftables"
if ip -6 addr show dev br-lan 2>/dev/null | grep -qE 'inet6 (2|3)[0-9a-f]{3}:'; then
    pass "br-lan 有全局 IPv6 地址"
else
    fail "br-lan 没有 GUA —— 检查光猫 PD 下发、lan6.reqprefix、accept_ra=2"
fi
ip -6 addr show dev br-lan 2>/dev/null | sed 's/^/    /'
if ip -6 route 2>/dev/null | grep -q 'nikki-dummy'; then
    pass "nikki-dummy 路由已生成（假 v6 池有本地出口）"
else
    fail "没有 nikki-dummy 路由 —— 多半是 fake-ip-range6 没进运行 profile，或 Nikki 未重启"
fi
ip -6 rule show 2>/dev/null | sed 's/^/    /'
if ip -6 rule show 2>/dev/null | grep -q 'lookup 81'; then
    pass "ip -6 rule 有 tun_fw_mark→table 81（v6 UDP/QUIC 的落点）"
else
    fail "ip -6 rule 没有 table 81 —— ipv6_proxy=1 或 Nikki 启动有问题，v6 UDP 会直连"
fi
info "table 81（tun_route_table）内容："
ip -6 route show table 81 2>/dev/null | sed 's/^/    /'
if ip -6 route show table 81 2>/dev/null | grep -q 'default dev nikki'; then
    pass "table 81 有 default dev nikki"
else
    fail "table 81 缺 default dev nikki —— v6 包不会进 tun"
fi
info "全表里假 v6 池的路由（应同时有 nikki-dummy 的 /64 与 nikki 的 /126）："
ip -6 route show table all 2>/dev/null | grep -i 'fdfe' | sed 's/^/    /'
if ip -6 route show table all 2>/dev/null | grep -qi 'fdfe'; then
    pass "假 v6 池在路由表里有出口"
else
    fail "路由表里找不到 fdfe —— fake-ip-range6 没进运行 profile 或 Nikki 未重启"
fi
info "TUN 设备自身的 v6 地址（mihomo 内置 fdfe:dcba:9876::1/126，profile 里查不到是正常的）："
ip -6 addr show dev nikki 2>/dev/null | sed 's/^/    /'
if ip -6 addr show dev nikki 2>/dev/null | grep -qi 'inet6 fdfe:'; then
    pass "tun 设备有 v6 地址（v6 UDP 能进内核）"
else
    fail "tun 设备无 v6 地址 —— 查 nikki 是否起来、tun_stack 是否被改过"
fi
info "nft 全表 ip6 规则条数（0 说明 v6 完全没被劫持）："
IP6RULES=$(nft list ruleset 2>/dev/null | grep -ci 'ip6\|ipv6')
[ -z "$IP6RULES" ] && IP6RULES=0
echo "    ip6 相关行数 = $IP6RULES"
[ "$IP6RULES" -gt 0 ] && pass "nft 有 v6 规则" || fail "nft 里没有 v6 规则"
if nft list table inet nikki >/dev/null 2>&1; then
    pass "inet nikki 表存在"
    if nft list table inet nikki 2>/dev/null | grep -q 'fdfe:dcba:9876'; then
        pass "hijack 规则含假 v6 池排除条件（不会被 reserved_ip6 放行）"
    else
        fail "hijack 规则里没有 fdfe:dcba:9876 —— 假 v6 包可能被直连放行"
    fi
    info "v6 相关规则摘录："
    nft list table inet nikki 2>/dev/null | grep -i 'ip6\|fdfe' | head -12 | sed 's/^/    /'
    if nft list table inet nikki 2>/dev/null | grep -q 'icmpv6 type echo-request'; then
        pass "有 icmpv6 echo-request redirect（客户端 ping -6 假 v6 应有响应）"
    else
        fail "缺 icmpv6 redirect —— fake_ip_ping_hijack 可能被关，ping 闸门不可用"
    fi
    if nft list table inet nikki 2>/dev/null | grep -q '0-65535'; then
        pass "proxy_dport 覆盖 0-65535（所有 v6 端口都进代理，QUIC 不漏）"
    else
        fail "proxy_dport 未覆盖全端口 —— 非标端口 v6 会直连绕过"
    fi
    if nft list set inet nikki china_ip6 2>/dev/null | grep -q 'elements'; then
        info "china_ip6 集非空：国内 v6 会直连，与「默认代理 v6」目标不符，核对 bypass_china_mainland_ip6"
    else
        pass "china_ip6 为空（国内 v6 也进 mihomo 再 DIRECT，属预期行为）"
    fi
else
    fail "inet nikki 表不存在，透明代理没起来"
fi
info "7891 监听（v6 重定向要求 :::7891，不能只有 0.0.0.0:7891）："
(netstat -tln 2>/dev/null || ss -tln 2>/dev/null) | grep 7891 | sed 's/^/    /'
info "NAT66 是否生效："
nft list ruleset 2>/dev/null | grep -i 'masquerade' | head -6 | sed 's/^/    /'
info "v6 DNS 劫持（ra_dns 默认开，本机也会被通告为 v6 DNS）："
# 注意：不要按「grep -A4 ip6」去找 —— Nikki 的规则写的是
#   meta nfproto @dns_hijack_nfproto ... th dport 53 redirect to :1053
# 协议族放在 nft set 里，规则文本里根本没有 ip6 字样，那样查会漏报。
if nft list set inet nikki dns_hijack_nfproto 2>/dev/null | grep -q 'ipv6'; then
    pass "dns_hijack_nfproto 含 ipv6"
else
    fail "dns_hijack_nfproto 不含 ipv6 —— 客户端查 AAAA 可能绕过 fake 池"
fi
if nft list table inet nikki 2>/dev/null | grep -q 'redirect to :1053'; then
    pass "存在 :53 → 1053 redirect（发给本机的 v6 DNS 也会被劫持）"
else
    fail "缺 :53 → 1053 redirect —— AAAA 可能返回真实地址，fake-ip 映射不一致"
fi

hr "D. 客户端侧（在 Windows / 手机上另做，本脚本查不到）"
cat <<'EOF'
  Windows（管理员 CMD / PowerShell）：
    route print -6                                  ::/0 必须指向旁路由 br-lan 的 link-local
    nslookup -type=AAAA www.google.com 192.168.1.253   必须返回 fdfe:dcba:9876::...
    nslookup www.google.com 192.168.1.253              仍须返回 198.18.0.x（v4 分流没被碰坏）
    ping -6 fdfe:dcba:9876::1                          必须通（icmpv6 redirect 会接住）
    netsh interface ipv6 show dnsservers               留意光猫 RDNSS 下发的 fe80::1
  Android：无 v6 网关界面，用浏览器打开 test-ipv6 类站点 + 看面板连接
  预期行为变化：国内 v6 也会先进 mihomo 再 DIRECT（网关在本机 + 端口集全开），
    不是配置写错；好处是广告/跟踪的 REJECT 首次对 v6 生效。

  ★ 闸门 7「真的代理了」：前面六道只证明配置对、fake 池可达，没有一条
    证明某个境外站点确实经节点出去。三条必须【同时】成立：
      1) 客户端浏览器打开 ipv6.google.com；
      2) 在设备上跑下面的 API 命令，出现 v6 地址且 chains[0] 非 DIRECT 的连接；
      3) 同一时刻 nslookup -type=AAAA www.google.com 192.168.1.253 返回 fdfe:。
    只有 1)+2) 可能只是「进了 tun 又直连出去」，必须补齐 3)。

    【14:28 实测纠正】别用 `curl .../connections | grep fdfe` 找正向证据：
    mihomo 的 Redir/TUN 入站 metadata.destinationIP 记录的是【还原后的真实 IP】，
    fake-ip 池地址不进 connections API。本机 14:28 实测 88 条连接里 fdfe 与
    198.18 命中数均为 0（连已在生效的 v4 fake-ip 都不显示），那条命令必假阴性；
    且 destinationIP 有 75 条为空，只 grep 它会二次漏报。
    改用下面这条（v6 出现在 sourceIP / destinationIP / remoteDestination 任一字段）：

      S=$(sed -n 's/^secret: *//p' /etc/nikki/run/config.yaml | tr -d "'\"")
      curl -s -H "Authorization: Bearer $S" http://127.0.0.1:9090/connections \
       | jq -r '.connections[]
         | select(.chains[0] != "DIRECT")
         | select(((.metadata.sourceIP//"") + " " + (.metadata.destinationIP//"")
                   + " " + (.metadata.remoteDestination//"")) | contains(":"))
         | "\(.metadata.sourceIP)  \(.metadata.host)  [\(.chains|join(" > "))]"' \
       | sort -u

    出现任意一行即通过。apply 前实测基线：v6 sourceIP 连接 0 条、非 DIRECT 1 条，
    所以 apply 后冒出 v6 + 节点链就是强证据；secret 长度 16、API HTTP 200 已验证。
    更硬的证据是 nft counter：访问前 / 后各跑一次
      nft list table inet nikki | grep counter
    对比 v6 相关规则的 packets 是否增长（本次基线：表存在、65 条 counter 规则）。

  ── 已知盲区（不是一次性验收项，每次换设备 / 换网络都要重查）──
  双 RA 的失败是【静默】的，没有任何日志会告诉你「这台设备其实走了光猫」：
    Windows   route print -6 看 ::/0 下一跳；
    Android   无命令行，看 WiFi 详情网关，或用 ipv6.google.com + 面板对照；
    FTTR 从光猫下还挂着的设备，也要抽查一台。
  别把「查过一次」当成永久有效。

  若 Android 的 ::/0 仍像指向 fe80::1，先别调 ra_default（它只管「要不要
  通告自己」，与「谁排第一」无关），按三种情况分：
    1) 其实赢了：::/0 是缓存/旧值，去面板搜这台设备的 v6 连接，有就是赢；
    2) 真输了：ra_preference 已是 high，没有更高档位 → 只剩在光猫关 RA/DHCPv6；
    3) 只赢一半：Windows 走旁路由、Android 走光猫 → RFC 6724 + 各家 ROM 差异，
       调参解决不了，回到第 2 条。
  先跑 `ubus call dhcp ipv6ra` 看有没有可通告前缀，再判断属于哪种；
  别靠改 fake-ip-range6 硬凑。

  ── 排障 ──
  v6 网页偶发卡住 / 视频起播慢 / QUIC 断流：mtu_fix=1 只钳 TCP MSS，
    QUIC/UDP 没有 MSS 可钳，只能靠 ICMPv6 Packet Too Big。先把
    network.lan.mtu 临时降到 1492 验证是否消失，别误判成代理质量差。
  仅当 C 段确认 tun 设备没有 v6 地址、v6 QUIC 确实漏流时，才考虑临时降级
    nft insert rule inet fw4 forward meta nfproto ipv6 udp dport 443 reject
  逼客户端回退 TCP/443。注意：这是运行时命令，重启即失效，固化要写进
  firewall include；而且它会让 v6 只剩 TCP，属于功能残缺，不是默认方案。
EOF

hr "汇总 · 七道闸门（按优先级）"
cat <<'EOF'
  1  sysctl net.ipv6.conf.br-lan.accept_ra = 2     最容易漏，漏了本机 v6 自己塌
  2  nslookup -type=AAAA www.google.com .253 → fdfe:dcba:9876::x   假 v6 生效
  3  nslookup www.google.com .253 → 198.18.0.x      v4 没被带坏，掉了立刻回退
  4  ping -6 fdfe:dcba:9876::1（客户端）→ 通        icmpv6 redirect 接住
  5  route print -6 / 手机 WiFi 详情 → ::/0 指向旁路由 link-local
  6  面板「连接」出现 v6 地址、链路非 DIRECT（别 grep fdfe，见 D 段实测纠正）
  7  ipv6.google.com + API 出现 v6 且非 DIRECT + AAAA 返回 fdfe:，三条同时成立
EOF
if [ "$FAILS" -eq 0 ]; then
    echo "  A/A2/B/C 段全部通过。请继续完成 D 段客户端验收（闸门 2~7）。"
else
    echo "  共 $FAILS 项 FAIL。闸门 1 优先于一切；闸门 3 掉了立刻回退。"
fi
echo "  阶段一（未刷机，现场验证）：sh stage1-live-ipv6-proxy.sh revert  ← 按快照精确还原"
echo "  阶段二（刷完 -v6 固件）：sh rollback-ipv6-proxy.sh off 停用（客户端需重连网卡）"
echo "  完整回退：重刷 Releases 里不带 -v6 后缀的旧 tag 镜像（旧镜像保留）。"
echo "  刷机提醒：必须【不保留配置】，否则 overlay whiteout 会挡住 uci-defaults 脚本。"
echo "========== 验收结束（全程只读，未修改任何配置）=========="
