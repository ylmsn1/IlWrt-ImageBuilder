#!/bin/sh
# ============================================================================
# stage1-live-ipv6-proxy.sh —— 阶段一：在【现有固件】上现场验证设计（不刷机）
#
# 用法（软路由 SSH 里执行）：
#   sh stage1-live-ipv6-proxy.sh precheck   只读预检，不改任何东西
#   sh stage1-live-ipv6-proxy.sh status     看当前态与快照位置
#   sh stage1-live-ipv6-proxy.sh apply      ★ 精确快照 + 写全套 UCI + 写 sysctl
#   sh stage1-live-ipv6-proxy.sh revert     从快照逐位还原（真·零损失）
#
# 【为什么需要它】
#   99-z-bypass.sh 是「首次开机执行一次」的 uci-defaults 脚本：它改完 UCI
#   不会 reload 任何服务（靠后续 boot 流程自然生效），还带一堆开机专属动作
#   （扫物理网口、删 wan、生成 api_secret、停 PassWall、写 sysupgrade.conf）。
#   把它直接拿到正在跑的设备上 sh 一遍，既不会生效，又会污染运行态。
#   本脚本只复刻【与 IPv6 默认代理有关的 UCI + sysctl】，其余一概不碰：
#     不碰 network.lan 的 IPv4 地址/网关/DNS、不碰 br-lan 端口、不删 wan、
#     不生成 api_secret、不停 PassWall、不动 nikki.config.enabled。
#
# 【快照为什么放 /etc 而不是 /tmp】
#   OpenWrt 的 /tmp 是 tmpfs，apply 之后必须 reboot 才能完全生效，reboot 会把
#   快照清空 —— 那样 revert 就失效了。故快照落在持久 overlay 的
#   /etc/ipv6-stage1-backup/，并保证 apply 幂等（已有快照就拒绝二次 apply）。
#
# 【apply 之后必须 reboot】
#   现场逐个 reload 五个服务有顺序坑（lan6 是 @lan 别名、odhcpd 要重读、
#   Nikki 要重生成 profile）。reboot 是最干净、且与刷机后最接近的状态。
#   本脚本【故意不 reload】，只写盘，随后由你执行 reboot。
#   br-lan 的静态 192.168.1.253 不变，重启后 SSH 照通。
#
# 【revert 与 rollback-ipv6-proxy.sh 的区别】
#   rollback 的 off 是硬编码「回到 v6 裸连光猫」，恢复不了现场原本的
#   ipv6=0 / ignore=1 / 无 lan6 / 无 masq6 / 无 sysctl 文件。
#   阶段一【只用本脚本的 revert】，它按快照逐位还原，才叫零损失。
#   rollback 是刷完 -v6 固件之后才用的运行态开关。
# ============================================================================

FAKE6="fdfe:dcba:9876::1/64"
SNAP="/etc/ipv6-stage1-backup"
SYSCTL_FILE="/etc/sysctl.d/99-bypass-router.conf"
ACTION="${1:-status}"

say() { printf '%s\n' "$*"; }
val() { printf '  %-42s = %s\n' "$1" "$(uci -q get "$1" 2>/dev/null || echo '(未设置)')"; }

# ---------------- 只读预检 ----------------
do_precheck() {
    say "===== 阶段一 · 只读预检 ====="
    RC=0
    chk() {
        if eval "$2" >/dev/null 2>&1; then printf '  [OK]   %s\n' "$1"
        else printf '  [FAIL] %s\n' "$1"; RC=$((RC + 1)); fi
    }
    chk "uci nikki.mixin 存在（固件 v6 UCI 的落点）"      "uci -q get nikki.mixin"
    chk "uci nikki.proxy 存在"                              "uci -q get nikki.proxy"
    chk "Nikki 已启用且有运行 profile"                      "test -f /etc/nikki/run/config.yaml"
    chk "odhcpd init 存在"                                   "test -x /etc/init.d/odhcpd"
    chk "network init 存在"                                  "test -x /etc/init.d/network"
    chk "firewall init 存在"                                 "test -x /etc/init.d/firewall"
    chk "nikki init 存在"                                    "test -x /etc/init.d/nikki"
    chk "yq 可用（verify 脚本 B 段依赖）"                    "command -v yq"
    chk "当前未处于已 apply 状态（快照目录不存在）"          "test ! -d $SNAP"

    say ""
    say "===== 当前关键值（只读）====="
    for k in network.lan.ipv6 network.lan.ip6assign network.lan6.proto \
             dhcp.lan.ra dhcp.lan.ra_default dhcp.lan.ignore \
             nikki.mixin.fake_ip6_range nikki.mixin.ipv6 \
             nikki.proxy.ipv6_proxy nikki.config.enabled; do
        val "$k"
    done
    say "  sysctl br-lan.accept_ra = $(sysctl -n net.ipv6.conf.br-lan.accept_ra 2>/dev/null)"
    say "  sysctl all.forwarding   = $(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)"
    say ""
    if [ "$RC" -eq 0 ]; then
        say "预检通过。下一步：sh stage1-live-ipv6-proxy.sh apply，然后 reboot。"
    else
        say "预检有 $RC 项 FAIL —— 不要 apply。最常见是快照目录已存在（先 revert）"
        say "或 Nikki 未启用（先到 LuCI 上传模板并启用）。"
    fi
    return "$RC"
}

# ---------------- 精确快照 ----------------
do_snapshot() {
    mkdir -p "$SNAP" || { say "ERROR: 无法创建 $SNAP"; return 1; }
    for f in network dhcp firewall nikki; do
        if [ -f "/etc/config/$f" ]; then
            cp "/etc/config/$f" "$SNAP/config-$f" || return 1
        else
            : > "$SNAP/config-$f.absent"
        fi
    done
    if [ -f "$SYSCTL_FILE" ]; then
        cp "$SYSCTL_FILE" "$SNAP/sysctl-file"
    else
        : > "$SNAP/sysctl-file.absent"
    fi
    # 记录 apply 前的运行时 sysctl 值，revert 时逐条写回
    : > "$SNAP/sysctl-before"
    for k in net.ipv6.conf.all.forwarding \
             net.ipv6.conf.br-lan.forwarding \
             net.ipv6.conf.br-lan.accept_ra \
             net.ipv6.conf.br-lan.accept_ra_defrtr \
             net.ipv4.conf.br-lan.send_redirects \
             net.ipv4.conf.br-lan.accept_redirects \
             net.ipv4.conf.br-lan.rp_filter; do
        v=$(sysctl -n "$k" 2>/dev/null)
        [ -n "$v" ] && printf '%s=%s\n' "$k" "$v" >> "$SNAP/sysctl-before"
    done
    date > "$SNAP/created-at"
    say "  快照已保存：$SNAP（持久 overlay，reboot 不丢）"
}

# ---------------- 写全套 UCI（与 99-z-bypass.sh 逐项对齐）----------------
do_apply_uci() {
    # network：只加 v6 相关，IPv4 静态 .253 / 网关 / DNS 一概不动
    uci set network.lan.ipv6='1'
    uci set network.lan.delegate='1'
    uci set network.lan.ip6assign='64'
    uci set network.lan6=interface
    uci set network.lan6.proto='dhcpv6'
    uci set network.lan6.device='@lan'
    uci set network.lan6.reqaddress='try'
    uci set network.lan6.reqprefix='auto'
    uci set network.lan6.peerdns='0'
    uci commit network

    # dhcp：RA 接管
    uci -q delete dhcp.lan.ra_management
    uci set dhcp.lan.ignore='0'
    uci set dhcp.lan.dhcpv4='disabled'
    uci set dhcp.lan.dhcpv6='disabled'
    uci set dhcp.lan.ra='server'
    uci set dhcp.lan.ra_default='2'
    uci set dhcp.lan.ra_lifetime='1800'
    uci set dhcp.lan.ra_preference='high'
    uci set dhcp.lan.ra_slaac='1'
    uci -q delete dhcp.lan.ra_flags
    uci add_list dhcp.lan.ra_flags='none'
    uci set dhcp.lan.ndp='disabled'
    uci commit dhcp

    # firewall：同区转发 + NAT66
    LAN_Z=""
    i=0
    while [ "$i" -le 8 ]; do
        [ "$(uci -q get "firewall.@zone[$i].name")" = "lan" ] && { LAN_Z="$i"; break; }
        i=$((i + 1))
    done
    if [ -n "$LAN_Z" ]; then
        uci set "firewall.@zone[$LAN_Z].masq"='1'
        uci set "firewall.@zone[$LAN_Z].mtu_fix"='1'
        uci set "firewall.@zone[$LAN_Z].masq6"='1'
        uci set "firewall.@zone[$LAN_Z].forward"='ACCEPT'
        uci -q get "firewall.@zone[$LAN_Z].network" | grep -qw lan6 || \
            uci add_list "firewall.@zone[$LAN_Z].network"='lan6'
    else
        say "  ERROR: 找不到 firewall 的 lan zone"
        return 1
    fi
    uci set firewall.@defaults[0].flow_offloading='0'
    uci set firewall.@defaults[0].flow_offloading_hw='0'
    uci commit firewall

    # Nikki：与固件脚本同一套 mixin / proxy 值
    uci set nikki.mixin.ipv6='1'
    uci set nikki.mixin.dns_ipv6='1'
    uci set nikki.mixin.fake_ip6_range="$FAKE6"
    uci set nikki.mixin.http_port='0'
    uci set nikki.mixin.socks_port='0'
    uci set nikki.mixin.mixed_port='0'
    uci set nikki.mixin.dns_listen='[::]:1053'
    uci set nikki.mixin.fake_ip_filter='0'
    uci set nikki.mixin.dns_nameserver='0'
    uci set nikki.mixin.dns_nameserver_policy='0'
    uci set nikki.mixin.sniffer_sniff='0'
    uci set nikki.mixin.rule='0'
    uci set nikki.mixin.rule_provider='0'
    uci set nikki.mixin.mixin_file_content='0'
    uci set nikki.proxy.ipv6_proxy='1'
    uci set nikki.proxy.ipv6_dns_hijack='1'
    uci -q get nikki.proxy.lan_inbound_interface | grep -qx 'lan6' || \
        uci add_list nikki.proxy.lan_inbound_interface='lan6'
    uci commit nikki
    # 注意：故意不生成 api_secret（现场面板密钥已在用，别打断），
    #       也不改 nikki.config.enabled（现场 Nikki 必须保持启用）。
}

do_write_sysctl() {
    mkdir -p /etc/sysctl.d
    cat > "$SYSCTL_FILE" <<'EOF'
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
}

# ---------------- revert 的服务重载（立即生效，不强制 reboot）----------------
do_reload_all() {
    say "  重载服务（顺序：network → firewall → dnsmasq → odhcpd → nikki）"
    /etc/init.d/network reload    >/dev/null 2>&1
    /etc/init.d/firewall reload   >/dev/null 2>&1
    /etc/init.d/dnsmasq reload    >/dev/null 2>&1
    /etc/init.d/odhcpd restart    >/dev/null 2>&1
    /etc/init.d/nikki restart     >/dev/null 2>&1
}

case "$ACTION" in
precheck)
    do_precheck
    exit $?
    ;;
status)
    say "===== 阶段一 · 当前态 ====="
    for k in network.lan.ipv6 network.lan.ip6assign network.lan6.proto \
             dhcp.lan.ra dhcp.lan.ra_default dhcp.lan.ra_lifetime \
             nikki.mixin.fake_ip6_range nikki.proxy.ipv6_proxy; do
        val "$k"
    done
    if [ -d "$SNAP" ]; then
        say "  快照：存在（$(cat "$SNAP/created-at" 2>/dev/null)）→ 可 revert"
    else
        say "  快照：不存在 → 尚未 apply，或已 revert"
    fi
    say "  status 全程只读，未修改任何配置。"
    ;;
apply)
    say "===== 阶段一 · apply ====="
    if [ -d "$SNAP" ]; then
        say "ERROR: 快照目录已存在，拒绝二次 apply（会覆盖原始态）。"
        say "       先 sh stage1-live-ipv6-proxy.sh revert，或先 status 看当前态。"
        exit 1
    fi
    if ! uci -q get nikki.mixin >/dev/null 2>&1; then
        say "ERROR: 找不到 nikki.mixin，先跑 precheck 排查。未做任何修改。"
        exit 1
    fi
    say "[1/3] 保存精确快照"
    do_snapshot || exit 1
    say "[2/3] 写入全套 IPv6 默认代理 UCI（IPv4 运行态不动）"
    do_apply_uci || { say "ERROR: UCI 写入失败，请立刻执行 revert"; exit 1; }
    say "[3/3] 写入 sysctl 文件"
    do_write_sysctl
    say ""
    say "  已写入，但【尚未生效】—— 本脚本故意不逐个 reload 服务。"
    say ""
    say "  >>> 现在执行：reboot <<<"
    say "  重启后按开机顺序重建 network / lan6 / odhcpd / Nikki，"
    say "  与刷机后的状态等价；br-lan 静态 192.168.1.253 不变，等 1~2 分钟重连 SSH。"
    say ""
    say "  重连后：sh verify-ipv6-proxy.sh  →  客户端七道闸门"
    say "  不通过：sh stage1-live-ipv6-proxy.sh revert（按快照逐位还原，真·零损失）"
    ;;
revert)
    say "===== 阶段一 · revert（按快照还原）====="
    if [ ! -d "$SNAP" ]; then
        say "ERROR: 找不到快照 $SNAP，无法精确还原。"
        say "       若只想停用 v6 代理，可用 sh rollback-ipv6-proxy.sh off（但那是硬编码态）。"
        exit 1
    fi
    for f in network dhcp firewall nikki; do
        if [ -e "$SNAP/config-$f.absent" ]; then
            rm -f "/etc/config/$f"
        elif [ -f "$SNAP/config-$f" ]; then
            cp "$SNAP/config-$f" "/etc/config/$f"
        fi
    done
    if [ -e "$SNAP/sysctl-file.absent" ]; then
        rm -f "$SYSCTL_FILE"
    elif [ -f "$SNAP/sysctl-file" ]; then
        cp "$SNAP/sysctl-file" "$SYSCTL_FILE"
    fi
    # 把运行时 sysctl 值写回（reboot 后新值已生效，光还原文件不够）
    if [ -f "$SNAP/sysctl-before" ]; then
        while IFS='=' read -r k v; do
            [ -n "$k" ] && sysctl -e -w "$k=$v" >/dev/null 2>&1
        done < "$SNAP/sysctl-before"
    fi
    do_reload_all
    rm -rf "$SNAP"
    say ""
    say "  已按快照逐位还原并删除快照目录。"
    say "  >>> 让每台客户端重连 WiFi / 禁用再启用网卡 <<<"
    say "  （RA 的 Router Lifetime 是 1800 秒，不重连最长要等 30 分钟才切回光猫）"
    say "  想彻底回到开机态可再 reboot 一次；阶段一到此结束，配置与动手前完全一致。"
    ;;
*)
    say "用法: sh $0 precheck|status|apply|revert" >&2
    exit 1
    ;;
esac
