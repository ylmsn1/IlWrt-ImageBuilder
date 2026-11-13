#!/bin/sh
# ============================================================================
# rollback-ipv6-proxy.sh —— 「IPv6 默认代理」运行态停用 / 恢复（无需重刷）
#
# 用法（在软路由 SSH 里执行）：
#   sh rollback-ipv6-proxy.sh status    只读，看当前处于哪一态
#   sh rollback-ipv6-proxy.sh off      停用 v6 代理，回到「v6 裸连光猫」
#   sh rollback-ipv6-proxy.sh on       恢复出厂固化态（v6 默认走代理）
#
# 【它解决什么】
#   刷完 -v6 镜像后如果只是想立刻停用，不必重刷。关掉本机的 RA 与 Nikki
#   的四个 v6 开关，客户端的 v6 默认网关会重新回到光猫。
#
# 【一个必须知道的时间尾巴】
#   客户端的 ::/0 是按 RA 里的 Router Lifetime 记的，odhcpd 默认
#   ra_lifetime = 3 × ra_maxinterval = 3 × 600 = 1800 秒。撤掉 RA 之后，
#   客户端最长还会把 v6 发给旁路由 30 分钟。要【立刻】生效，执行 off 后
#   让每台客户端重连 WiFi / 禁用再启用网卡即可。
#   不要为了减少这个窗口把 ra_lifetime 压到 600 —— 那等于最大发送间隔，
#   无线环境丢一次 RA 就会让客户端撤销 ::/0，正常运行时周期性 v6 抖动。
#
# 【边界】
#   * 这是「停用 v6 代理」，不是完整回退。完整回到纯 IPv4 出厂态仍需
#     重刷 Releases 里不带 -v6 后缀的旧 tag 镜像，且【不保留配置】。
#   * 本脚本改的是 /etc/config 下的运行配置，重启后仍然有效（uci commit）。
#   * 首次开机固化脚本 99-z-bypass.sh 只在「不保留配置」的刷机里执行一次，
#     之后再刷带配置升级不会把它改回来，所以 on/off 不会被自动覆盖。
# ============================================================================

FAKE6="fdfe:dcba:9876::1/64"
ACTION="${1:-status}"

show() {
    printf '  %-38s = %s\n' "$1" "$(uci -q get "$1" 2>/dev/null || echo '(未设置)')"
}

case "$ACTION" in
status)
    echo "===== IPv6 默认代理 · 当前运行态 ====="
    for k in dhcp.lan.ra dhcp.lan.ra_default dhcp.lan.ra_lifetime \
             nikki.mixin.ipv6 nikki.mixin.dns_ipv6 nikki.mixin.fake_ip6_range \
             nikki.proxy.ipv6_proxy nikki.proxy.ipv6_dns_hijack; do
        show "$k"
    done
    echo
    echo "  sysctl br-lan.accept_ra = $(sysctl -n net.ipv6.conf.br-lan.accept_ra 2>/dev/null)"
    echo "  说明：status 全程只读，未修改任何配置。"
    exit 0
    ;;
off)
    echo "===== 停用 IPv6 默认代理 ====="
    # 1) 停止本机发 RA。客户端 ::/0 的旧记录靠重连网卡清掉。
    uci set dhcp.lan.ra='disabled'
    uci commit dhcp
    /etc/init.d/odhcpd restart >/dev/null 2>&1

    # 2) 关掉 Nikki 的 v6 代理与 DNS 劫持，并清掉假 v6 池。
    #    restart 时 nikki.init 的 stop 逻辑会撤掉 ip -6 rule/route 与 nft 规则。
    if uci -q get nikki.mixin >/dev/null 2>&1; then
        uci set nikki.mixin.ipv6='0'
        uci set nikki.mixin.dns_ipv6='0'
        uci -q delete nikki.mixin.fake_ip6_range
        uci set nikki.proxy.ipv6_proxy='0'
        uci set nikki.proxy.ipv6_dns_hijack='0'
        uci commit nikki
        /etc/init.d/nikki restart >/dev/null 2>&1
        echo "  Nikki 四个 v6 开关已关，fake_ip6_range 已清除"
    else
        echo "  WARN: 找不到 nikki.mixin，跳过 Nikki 部分"
    fi

    echo
    echo "  已完成。但客户端的 ::/0 可能还缓存着旁路由（最长 1800 秒）。"
    echo "  >>> 请让每台客户端重连 WiFi 或禁用/启用网卡，立刻切回光猫。 <<<"
    echo "  验证：Windows route print -6 的 ::/0 应重新指向 fe80::1。"
    echo "  完整回退到纯 IPv4 出厂态：重刷不带 -v6 后缀的旧 tag 镜像（不保留配置）。"
    ;;
on)
    echo "===== 恢复 IPv6 默认代理 ====="
    uci set dhcp.lan.ra='server'
    uci set dhcp.lan.ra_default='2'
    uci set dhcp.lan.ra_lifetime='1800'
    uci set dhcp.lan.ra_preference='high'
    uci commit dhcp
    /etc/init.d/odhcpd restart >/dev/null 2>&1

    if uci -q get nikki.mixin >/dev/null 2>&1; then
        uci set nikki.mixin.ipv6='1'
        uci set nikki.mixin.dns_ipv6='1'
        uci set nikki.mixin.fake_ip6_range="$FAKE6"
        uci set nikki.proxy.ipv6_proxy='1'
        uci set nikki.proxy.ipv6_dns_hijack='1'
        uci commit nikki
        /etc/init.d/nikki restart >/dev/null 2>&1
        echo "  Nikki v6 已恢复，fake_ip6_range=$FAKE6"
    else
        echo "  WARN: 找不到 nikki.mixin，跳过 Nikki 部分"
    fi

    echo
    echo "  已完成。同样请让客户端重连网卡，尽快接受新的 RA。"
    echo "  然后跑 sh verify-ipv6-proxy.sh 复核 A/A2/B/C 段。"
    ;;
*)
    echo "用法: sh $0 status|off|on" >&2
    exit 1
    ;;
esac
