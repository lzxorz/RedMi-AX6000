#!/bin/bash
#
# diy-part2.sh
# Redmi AX6000 / ImmortalWrt DIY 配置
# 在 feeds update/install 完成后执行
#
# 主要内容：
#   1. LAN / 主机名 / Argon
#   2. BBR + fq
#   3. 2.4G / 5G 稳定 WiFi 参数
#   4. CN 国家码、非 DFS 5G 高频信道
#   5. 以太网自动协商，不锁 2.5G 速率
#   6. 软件/硬件 Flow Offloading
#   7. 中文界面 + 上海时区
#   8. Tailscale 端口及社区源
#
# 注意：
#   AX6000 不同 ImmortalWrt 分支的 radio 编号可能不同。
#   本脚本按 wireless 中的 band=2g/5g 自动识别 radio，
#   不硬编码 radio0=2.4G / radio1=5G，避免刷错频段。
#

set -e

echo "=================================================="
echo " Redmi AX6000 DIY configuration"
echo "=================================================="

# --------------------------------------------------
# 1. 基础设置
# --------------------------------------------------
echo "[1/6] 基础设置..."

# 默认 LAN IP、主机名、Argon 主题
sed -i 's/192\.168\.1\.1/192.168.8.1/g' package/base-files/files/bin/config_generate
sed -i 's/OpenWrt/Redmi-AX6000/g' package/base-files/files/bin/config_generate
sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# --------------------------------------------------
# 2. 编译时加入需要的软件包
# --------------------------------------------------
echo "[2/6] 检查并加入可选软件包..."

# 避免同一个 CONFIG 被重复追加
add_config() {
    local cfg="$1"
    grep -qxF "$cfg" .config 2>/dev/null || echo "$cfg" >> .config
}

# BBR
if grep -Rqs 'config PACKAGE_kmod-tcp-bbr' package/ 2>/dev/null ||
   grep -Rqs 'Package/kmod-tcp-bbr' package/ 2>/dev/null; then
    add_config "CONFIG_PACKAGE_kmod-tcp-bbr=y"
    echo "  + kmod-tcp-bbr"
fi

# ethtool：用于启动后确保物理网口保持自动协商
if grep -Rqs 'config PACKAGE_ethtool' package/ 2>/dev/null ||
   grep -Rqs 'Package/ethtool' package/ 2>/dev/null; then
    add_config "CONFIG_PACKAGE_ethtool=y"
    echo "  + ethtool"
fi

./scripts/config/conf --defconfig=.config Config.in 2>/dev/null || true

# --------------------------------------------------
# 3. 写入首次启动配置
# --------------------------------------------------
echo "[3/6] 创建首次启动配置..."

mkdir -p package/base-files/files/etc/uci-defaults
mkdir -p package/base-files/files/etc/hotplug.d/net

cat <<'EOF' > package/base-files/files/etc/uci-defaults/99-custom-settings
#!/bin/sh

# ==================================================
# Redmi AX6000 ImmortalWrt 首次启动配置
# ==================================================

# --------------------------------------------------
# 1. Root 密码
# --------------------------------------------------
# 如需修改密码，只改下面两行。
# 注意：固件公开发布时不要把真实密码写进脚本。
ROOT_PASSWORD='290826'

if command -v passwd >/dev/null 2>&1; then
    printf '%s\n%s\n' "$ROOT_PASSWORD" "$ROOT_PASSWORD" | passwd root >/dev/null 2>&1 || true
fi
unset ROOT_PASSWORD

# --------------------------------------------------
# 2. WiFi：根据 band 自动识别 2.4G / 5G
# --------------------------------------------------
# AX6000 不同 ImmortalWrt 分支 radio 编号可能不同，
# 所以不要简单假定 radio0 一定是 2.4G。
#
# 目标：
#   2.4G：HE40、CN、自动信道、23 dBm
#   5G ：HE80、149、23 dBm、关闭 WMM-APSD
#
# 注意：
#   5G 只使用 149/153/157/161/165 中的非 DFS 高频段。
#   为了稳定性默认固定 149；如环境拥堵可改成 153/157/161/165。
#   不默认 HE160，160 MHz 对环境要求高，稳定性不如 HE80。

find_radio_by_band() {
    local band="$1"
    local r b

    for r in radio0 radio1 radio2 radio3; do
        b="$(uci -q get wireless.${r}.band || true)"
        [ "$b" = "$band" ] && {
            echo "$r"
            return 0
        }
    done

    return 1
}

RADIO_2G="$(find_radio_by_band 2g || true)"
RADIO_5G="$(find_radio_by_band 5g || true)"

echo "WiFi radio mapping: 2.4G=${RADIO_2G:-未找到}, 5G=${RADIO_5G:-未找到}"

# ---------- 2.4G ----------
if [ -n "$RADIO_2G" ]; then
    # 强制中国监管域
    uci set wireless.${RADIO_2G}.country='CN'

    # AX/WiFi 6，2.4G 使用 HE40。
    # 2.4G 环境通常比较拥挤，不使用 80MHz。
    uci set wireless.${RADIO_2G}.htmode='HE40'

    # auto 让系统根据环境选信道。
    # 如果希望手工固定，只需改成 1 / 6 / 11。
    uci set wireless.${RADIO_2G}.channel='auto'

    # 23 dBm：作为期望最大功率，实际值仍受 CN/硬件监管限制。
    uci set wireless.${RADIO_2G}.txpower='23'

    uci set wireless.${RADIO_2G}.disabled='0'

    # MU-MIMO
    uci set wireless.${RADIO_2G}.mu_beamformer='1'
    uci set wireless.${RADIO_2G}.mu_beamformee='1'

    # 默认允许驱动进行必要的兼容性扫描。
    # 不强制 noscan=1，避免在高干扰环境下反而降低稳定性。

    # 2.4G WiFi 参数
    IFACE_2G="wireless.default_${RADIO_2G}"
    if uci -q get "${IFACE_2G}.ssid" >/dev/null; then
        uci set "${IFACE_2G}.ieee80211k='1'"
        uci set "${IFACE_2G}.bss_transition='1'"
        uci set "${IFACE_2G}.wnm_sleep_mode='0'"
    fi

    echo "  2.4G: HE40 / auto / 23dBm / CN / MU-MIMO / 11k/v"
fi

# ---------- 5G ----------
if [ -n "$RADIO_5G" ]; then
    # 强制中国监管域，避免使用 00-World。
    uci set wireless.${RADIO_5G}.country='CN'

    # 首选 HE80，稳定性优先。
    # 160MHz 不作为默认值；空旷环境可自行改为 HE160。
    uci set wireless.${RADIO_5G}.htmode='HE80'

    # 149 是默认非 DFS 高频信道。
    # 可手工改成 153 / 157 / 161 / 165。
    uci set wireless.${RADIO_5G}.channel='149'

    uci set wireless.${RADIO_5G}.txpower='23'
    uci set wireless.${RADIO_5G}.disabled='0'

    # MU-MIMO / Beamforming
    uci set wireless.${RADIO_5G}.mu_beamformer='1'
    uci set wireless.${RADIO_5G}.mu_beamformee='1'
    uci set wireless.${RADIO_5G}.su_beamformer='1'
    uci set wireless.${RADIO_5G}.su_beamformee='1'
    uci set wireless.${RADIO_5G}.he_mu_beamformer='1'
    uci set wireless.${RADIO_5G}.he_su_beamformer='1'
    uci set wireless.${RADIO_5G}.he_su_beamformee='1'

    IFACE_5G="wireless.default_${RADIO_5G}"
    if uci -q get "${IFACE_5G}.ssid" >/dev/null; then
        uci set "${IFACE_5G}.ieee80211k='1'"
        uci set "${IFACE_5G}.bss_transition='1'"

        # 关闭 WMM-APSD/U-APSD，减少部分老旧终端休眠/断流兼容问题。
        uci set "${IFACE_5G}.uapsd='0'"
        uci set "${IFACE_5G}.wmm_ap_ac_be='0' 2>/dev/null || true"
    fi

    echo "  5G: HE80 / ch149 / 23dBm / CN / MU-MIMO / Beamforming / 11k/v"
fi

# --------------------------------------------------
# 3. SSID / 密码
# --------------------------------------------------
# 保留原脚本的 SSID / 密码。
# 当前默认 radio 编号不再硬编码，避免频段错配。

if [ -n "$RADIO_2G" ]; then
    IFACE_2G="wireless.default_${RADIO_2G}"
    uci set "${IFACE_2G}.ssid='Tenda-nls'"
    uci set "${IFACE_2G}.encryption='psk2+ccmp'"
    uci set "${IFACE_2G}.key='2022@056700'"
fi

if [ -n "$RADIO_5G" ]; then
    IFACE_5G="wireless.default_${RADIO_5G}"
    uci set "${IFACE_5G}.ssid='Tenda-nls_5G'"
    uci set "${IFACE_5G}.encryption='psk2+ccmp'"
    uci set "${IFACE_5G}.key='2022@056700'"
fi

uci commit wireless

# --------------------------------------------------
# 4. BBR + fq + TCP 缓冲
# --------------------------------------------------
# BBR 不存在时自动跳过，不影响启动。
if command -v sysctl >/dev/null 2>&1; then
    if modprobe tcp_bbr 2>/dev/null; then
        if sysctl net.ipv4.tcp_allowed_congestion_control 2>/dev/null |
            grep -qw bbr; then
            sysctl -w net.ipv4.tcp_congestion_control='bbr' >/dev/null 2>&1 || true
            echo "BBR: enabled"
        fi
    fi

    sysctl -w net.core.default_qdisc='fq' >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_rmem='4096 87380 16777216' >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_wmem='4096 65536 16777216' >/dev/null 2>&1 || true
fi

# 持久化 sysctl，避免每次重启丢失。
SYSCTL_FILE='/etc/sysctl.conf'
touch "$SYSCTL_FILE"

add_sysctl() {
    local key="$1"
    local value="$2"

    if grep -qE "^[[:space:]]*${key}=" "$SYSCTL_FILE" 2>/dev/null; then
        sed -i "s|^[[:space:]]*${key}=.*|${key}=${value}|" "$SYSCTL_FILE"
    else
        echo "${key}=${value}" >> "$SYSCTL_FILE"
    fi
}

add_sysctl 'net.ipv4.tcp_congestion_control' 'bbr'
add_sysctl 'net.core.default_qdisc' 'fq'
add_sysctl 'net.core.rmem_max' '16777216'
add_sysctl 'net.core.wmem_max' '16777216'
add_sysctl 'net.ipv4.tcp_rmem' '4096 87380 16777216'
add_sysctl 'net.ipv4.tcp_wmem' '4096 65536 16777216'

# --------------------------------------------------
# 5. Flow Offloading
# --------------------------------------------------
# AX6000 + MediaTek HNAT/WED 环境下建议开启。
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'
uci commit firewall

# --------------------------------------------------
# 6. LuCI 中文 + 上海时区
# --------------------------------------------------
uci set luci.main.lang='zh_cn'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit luci
uci commit system

# --------------------------------------------------
# 7. Tailscale UDP 41641
# --------------------------------------------------
# 先检查是否已经存在，避免重复添加 firewall rule。
if ! uci show firewall 2>/dev/null | grep -q "Allow-Tailscale-Port"; then
    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name='Allow-Tailscale-Port'
    uci set firewall.@rule[-1].src='*'
    uci set firewall.@rule[-1].dest_port='41641'
    uci set firewall.@rule[-1].proto='udp'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall
fi

# --------------------------------------------------
# 8. Tailscale 社区源
# --------------------------------------------------
# 下载失败不影响路由器正常启动。
TS_KEY_URL='https://Tokisaki-Galaxy.github.io/luci-app-tailscale-community/all/key-build.pub'
TS_FEED='src/gz tailscale_community https://Tokisaki-Galaxy.github.io/luci-app-tailscale-community/all'

if command -v wget >/dev/null 2>&1; then
    wget -qO /tmp/key-build.pub "$TS_KEY_URL" || true

    if [ -s /tmp/key-build.pub ] && command -v opkg-key >/dev/null 2>&1; then
        opkg-key add /tmp/key-build.pub >/dev/null 2>&1 || true
    fi

    if [ -f /etc/opkg/customfeeds.conf ] &&
       ! grep -qF 'tailscale_community' /etc/opkg/customfeeds.conf 2>/dev/null; then
        echo "$TS_FEED" >> /etc/opkg/customfeeds.conf
    fi

    rm -f /tmp/key-build.pub
fi

# --------------------------------------------------
# 9. 首次启动应用配置
# --------------------------------------------------
/etc/init.d/network restart 2>/dev/null || true
wifi reload 2>/dev/null || true
sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true

echo "Redmi AX6000 首次启动配置完成。"
exit 0
EOF

chmod +x package/base-files/files/etc/uci-defaults/99-custom-settings

# --------------------------------------------------
# 4. 2.5G / Ethernet 自动协商
# --------------------------------------------------
echo "[4/6] 创建以太网自动协商 hotplug..."

cat <<'EOF' > package/base-files/files/etc/hotplug.d/net/99-ax6000-autoneg
#!/bin/sh

# Redmi AX6000：
# 不锁 100M/1G/2.5G 速率，始终保持 Auto Negotiation。
# 这样接入不同交换机、光猫、网卡时更不容易出现断流。
#
# ethtool 不存在时直接跳过，不影响网络启动。
command -v ethtool >/dev/null 2>&1 || exit 0

[ -n "$INTERFACE" ] || exit 0

# 只处理 eth* 物理/主控网口，不处理 br-lan、lo、wlan。
case "$INTERFACE" in
    eth*)
        ethtool -s "$INTERFACE" autoneg on >/dev/null 2>&1 || true
        ;;
esac

exit 0
EOF

chmod +x package/base-files/files/etc/hotplug.d/net/99-ax6000-autoneg

# --------------------------------------------------
# 5. 可选：确认 ethtool 已进入固件
# --------------------------------------------------
echo "[5/6] 完成网口自动协商配置..."

# --------------------------------------------------
# 6. 完成
# --------------------------------------------------
echo "[6/6] diy-part2.sh completed"
echo ""
echo "=================================================="
echo " Redmi AX6000 DIY 配置完成"
echo "=================================================="
echo ""
echo "已配置："
echo "  - LAN             : 192.168.8.1"
echo "  - Hostname        : Redmi-AX6000"
echo "  - LuCI             : Argon + 中文"
echo "  - Timezone         : Asia/Shanghai"
echo "  - WiFi country     : CN"
echo "  - 2.4G             : HE40 / Auto / 23dBm / MU-MIMO / 11k/v"
echo "  - 5G               : HE80 / 149 / 23dBm / MU-MIMO / Beamforming / 11k/v"
echo "  - 5G DFS           : 默认避开"
echo "  - WMM-APSD/U-APSD  : 关闭"
echo "  - Ethernet         : Auto Negotiation"
echo "  - BBR + fq         : 可用时启用"
echo "  - TCP Buffer       : 16 MiB"
echo "  - Flow Offloading  : SW + HW"
echo "  - Tailscale UDP    : 41641"
echo ""
echo "提示：5G 如需尝试 160MHz，请自行把 HE80 改为 HE160；"
echo "      但稳定性优先时建议继续使用 HE80。"
echo ""
