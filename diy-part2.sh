#!/bin/bash
#
# diy-part2.sh
# Redmi AX6000 ImmortalWrt(https://github.com/immortalwrt/immortalwrt) DIY 配置
#
# 在 feeds update/install 完成后执行。
#
# 主要功能：
#   主机名 / Argon
#   BBR + fq + TCP Buffer
#   2.4G / 5G WiFi 稳定参数
#   强制 CN 国家码
#   5G 默认 HE80 + 非 DFS 高频信道
#   Ethernet 自动协商，不手动锁 2.5G 速率
#   软件/硬件 Flow Offloading
#   中文 LuCI + 上海时区
#   Tailscale UDP 41641 + 社区软件源
#
# 重要：
#   - radio0/radio1 不硬编码，通过 band=2g/5g 自动识别。
#   - uci set 统一使用：uci set "${SECTION}.option=value"
#     不要写成：uci set "${SECTION}.option='value'"
#

set -e

echo "=================================================="
echo " Redmi AX6000 DIY configuration"
echo "=================================================="

# --------------------------------------------------
# 1. 基础设置
# --------------------------------------------------
echo "[1/6] 配置 主机名 / Argon..."

if [ -f package/base-files/files/bin/config_generate ]; then
    sed -i 's/ImmortalWrt/Redmi-AX6000/g' package/base-files/files/bin/config_generate
fi

if [ -f feeds/luci/collections/luci/Makefile ]; then
    sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile
fi

# --------------------------------------------------
# 2. 编译时加入需要的软件包
# --------------------------------------------------
echo "[2/6] 配置 BBR / ethtool..."

add_config() {
    local cfg="$1"
    grep -qxF "$cfg" .config 2>/dev/null || echo "$cfg" >> .config
}

if grep -Rqs 'config PACKAGE_kmod-tcp-bbr' package feeds/packages 2>/dev/null ||
   grep -Rqs 'Package/kmod-tcp-bbr' package feeds/packages 2>/dev/null; then
    add_config "CONFIG_PACKAGE_kmod-tcp-bbr=y"
    echo "  + kmod-tcp-bbr"
else
    echo "  - kmod-tcp-bbr 未找到，跳过"
fi

if grep -Rqs 'config PACKAGE_ethtool' package feeds/packages 2>/dev/null ||
   grep -Rqs 'Package/ethtool' package feeds/packages 2>/dev/null; then
    add_config "CONFIG_PACKAGE_ethtool=y"
    echo "  + ethtool"
else
    echo "  - ethtool 未找到，跳过"
fi

./scripts/config/conf --defconfig=.config Config.in 2>/dev/null || true

# --------------------------------------------------
# 3. 创建首次启动配置
# --------------------------------------------------
echo "[3/6] 创建首次启动配置..."

mkdir -p package/base-files/files/etc/uci-defaults

cat <<'FIRSTBOOT' > package/base-files/files/etc/uci-defaults/99-custom-settings
#!/bin/sh
#
# Redmi AX6000 / ImmortalWrt 首次启动配置
#

# ==================================================
# 1. Root 密码
# ==================================================
# 如需修改密码，只修改这一处。
# 公开发布固件时请不要把真实密码写入 GitHub。
ROOT_PASSWORD='290826'

if command -v passwd >/dev/null 2>&1; then
    printf '%s\n%s\n' "$ROOT_PASSWORD" "$ROOT_PASSWORD" |
        passwd root >/dev/null 2>&1 || true
fi
unset ROOT_PASSWORD

# ==================================================
# 2. WiFi：自动识别 2.4G / 5G radio
# ==================================================
find_radio_by_band() {
    local target_band="$1"
    local radio band

    for radio in radio0 radio1 radio2 radio3; do
        band="$(uci -q get "wireless.${radio}.band" 2>/dev/null || true)"
        if [ "$band" = "$target_band" ]; then
            echo "$radio"
            return 0
        fi
    done
    return 1
}

RADIO_2G="$(find_radio_by_band 2g || true)"
RADIO_5G="$(find_radio_by_band 5g || true)"

echo "WiFi radio:"
echo "  2.4G = ${RADIO_2G:-未找到}"
echo "  5G   = ${RADIO_5G:-未找到}"

# ==================================================
# 2.1     2.4G
# ==================================================
if [ -n "$RADIO_2G" ]; then
    RADIO="wireless.${RADIO_2G}"

    # 中国监管域，不使用 00-World。
    uci set "${RADIO}.country=CN"

    # WiFi 6 / 802.11ax；2.4G 使用 HE40，不使用 80MHz。
    uci set "${RADIO}.htmode=HE40"

    # 自动选信道；需要手工固定时改成 1 / 6 / 11。
    uci set "${RADIO}.channel=auto"

    # 目标发射功率；实际值仍受国家码、硬件和驱动限制。
    uci set "${RADIO}.txpower=23"
    uci set "${RADIO}.disabled=0"

    IFACE_2G="wireless.default_${RADIO_2G}"
    if uci -q get "${IFACE_2G}.ssid" >/dev/null 2>&1; then
        # 802.11k：邻居报告。
        uci set "${IFACE_2G}.ieee80211k=1"

        # 802.11v：BSS Transition。
        uci set "${IFACE_2G}.bss_transition=1"
        
        # 关闭 U-APSD。
        # 部分老旧/兼容性较差的终端关闭后更稳定。
        uci set "${IFACE_2G}.uapsd=0"
    fi

    echo "  2.4G: CN / HE40 / Auto / 23dBm / 11k/v"
fi

# ==================================================
# 2.2     5G
# ==================================================
if [ -n "$RADIO_5G" ]; then
    RADIO="wireless.${RADIO_5G}"

    # 中国监管域，不使用 00-World。
    uci set "${RADIO}.country=CN"

    # 稳定性优先：默认 HE80，不默认 HE160。
    uci set "${RADIO}.htmode=HE80"
    
    # 5G 使用非 DFS 高频段。
    # 默认 149，优先保证稳定性。
    #
    # 注意：
    # HE80 下不要把 149/153/157/161/165 简单理解成
    # 五个都可以直接作为 80MHz 主信道。
    # 实际可用信道由国家码、驱动和当前频宽共同决定。
    uci set "${RADIO}.channel=149"

    uci set "${RADIO}.txpower=23"
    uci set "${RADIO}.disabled=0"

    # MediaTek / mac80211 支持时启用 Beamforming / MU-MIMO。
    # 不强制使用 wmm_ap_ac_be 等容易因驱动版本不同而失效的私有/细分选项。
    uci set "${RADIO}.mu_beamformer=1" 2>/dev/null || true
    uci set "${RADIO}.mu_beamformee=1" 2>/dev/null || true
    uci set "${RADIO}.su_beamformer=1" 2>/dev/null || true
    uci set "${RADIO}.su_beamformee=1" 2>/dev/null || true
    uci set "${RADIO}.he_mu_beamformer=1" 2>/dev/null || true
    uci set "${RADIO}.he_su_beamformer=1" 2>/dev/null || true
    uci set "${RADIO}.he_su_beamformee=1" 2>/dev/null || true

    IFACE_5G="wireless.default_${RADIO_5G}"
    if uci -q get "${IFACE_5G}.ssid" >/dev/null 2>&1; then
        # 802.11k / 802.11v。
        uci set "${IFACE_5G}.ieee80211k=1"
        uci set "${IFACE_5G}.bss_transition=1"
        
        # 关闭 U-APSD。
        # 部分老旧/兼容性较差的终端关闭后更稳定。
        uci set "${IFACE_5G}.uapsd=0"
    fi

    echo "  5G: CN / HE80 / ch149 / 23dBm / Beamforming / 11k/v"
fi

# ==================================================
# 3. SSID / 密码
# ==================================================
if [ -n "$RADIO_2G" ]; then
    IFACE_2G="wireless.default_${RADIO_2G}"
    uci set "${IFACE_2G}.ssid=Tenda-nls"
    uci set "${IFACE_2G}.encryption=psk2+ccmp"
    uci set "${IFACE_2G}.key=2022@056700"
fi

if [ -n "$RADIO_5G" ]; then
    IFACE_5G="wireless.default_${RADIO_5G}"
    uci set "${IFACE_5G}.ssid=Tenda-nls_5G"
    uci set "${IFACE_5G}.encryption=psk2+ccmp"
    uci set "${IFACE_5G}.key=2022@056700"
fi

uci commit wireless

# ==================================================
# 4. BBR + fq + TCP Buffer
# ==================================================
if command -v sysctl >/dev/null 2>&1; then
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr 2>/dev/null || true
    fi

    if sysctl net.ipv4.tcp_allowed_congestion_control 2>/dev/null | grep -qw bbr; then
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
        echo "  BBR: enabled"
    else
        echo "  BBR: unavailable"
    fi

    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_max=16777216 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=16777216 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_rmem='4096 87380 16777216' >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_wmem='4096 65536 16777216' >/dev/null 2>&1 || true
fi

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


R_AVAILABLE=0

if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr 2>/dev/null || true
fi

if sysctl net.ipv4.tcp_allowed_congestion_control 2>/dev/null |
    grep -qw bbr; then
    
    BBR_AVAILABLE=1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
fi

if [ "$BBR_AVAILABLE" = "1" ]; then
    add_sysctl 'net.ipv4.tcp_congestion_control' 'bbr'
fi

add_sysctl 'net.core.default_qdisc' 'fq'
add_sysctl 'net.core.rmem_max' '16777216'
add_sysctl 'net.core.wmem_max' '16777216'
add_sysctl 'net.ipv4.tcp_rmem' '4096 87380 16777216'
add_sysctl 'net.ipv4.tcp_wmem' '4096 65536 16777216'

# ==================================================
# 5. Flow Offloading
# ==================================================
if uci -q show firewall.@defaults[0] >/dev/null 2>&1; then
    uci set firewall.@defaults[0].flow_offloading=1
    uci set firewall.@defaults[0].flow_offloading_hw=1
    uci commit firewall
fi

# ==================================================
# 6. LuCI 中文 + 上海时区
# ==================================================
uci set luci.main.lang=zh_cn
uci set system.@system[0].timezone=CST-8
uci set system.@system[0].zonename=Asia/Shanghai
uci commit luci
uci commit system

# ==================================================
# 7. Tailscale UDP 41641
# ==================================================
if ! uci show firewall 2>/dev/null | grep -q "Allow-Tailscale-Port"; then
    RULE="$(uci add firewall rule)"
    uci set "firewall.${RULE}.name=Allow-Tailscale-Port"
    uci set "firewall.${RULE}.src=*"
    uci set "firewall.${RULE}.dest_port=41641"
    uci set "firewall.${RULE}.proto=udp"
    uci set "firewall.${RULE}.target=ACCEPT"
    uci commit firewall
fi

# ==================================================
# 8. Tailscale 社区软件源
# ==================================================
TS_KEY_URL='https://Tokisaki-Galaxy.github.io/luci-app-tailscale-community/all/key-build.pub'
TS_FEED='src/gz tailscale_community https://Tokisaki-Galaxy.github.io/luci-app-tailscale-community/all'

if command -v wget >/dev/null 2>&1; then
    wget -qO /tmp/key-build.pub "$TS_KEY_URL" 2>/dev/null || true

    if [ -s /tmp/key-build.pub ] && command -v opkg-key >/dev/null 2>&1; then
        opkg-key add /tmp/key-build.pub >/dev/null 2>&1 || true
    fi

    if [ -f /etc/opkg/customfeeds.conf ] &&
       ! grep -qF 'tailscale_community' /etc/opkg/customfeeds.conf 2>/dev/null; then
        echo "$TS_FEED" >> /etc/opkg/customfeeds.conf
    fi

    rm -f /tmp/key-build.pub
fi

# ==================================================
# 9. 应用配置
# ==================================================
/etc/init.d/network restart >/dev/null 2>&1 || true
wifi reload >/dev/null 2>&1 || true
sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true

echo "Redmi AX6000 首次启动配置完成。"
exit 0
FIRSTBOOT

chmod +x package/base-files/files/etc/uci-defaults/99-custom-settings


# --------------------------------------------------
# 4. Ethernet 自动协商
# --------------------------------------------------
echo "[4/6] 创建 Ethernet 自动协商 hotplug..."

mkdir -p package/base-files/files/etc/hotplug.d/net

cat <<'EOF' > package/base-files/files/etc/hotplug.d/net/99-ax6000-autoneg
#!/bin/sh

# Redmi AX6000：
# 不手动锁定 100M / 1G / 2.5G。
# 网卡支持什么速率，就让双方自动协商。
#
# 注意：
# 这里只打开 autoneg，
# 不设置 speed / duplex，避免人为锁速率。

command -v ethtool >/dev/null 2>&1 || exit 0
[ -n "$INTERFACE" ] || exit 0

case "$INTERFACE" in
    eth*)
        ethtool -s "$INTERFACE" autoneg on >/dev/null 2>&1 || true
        ;;
esac

exit 0
EOF

chmod +x package/base-files/files/etc/hotplug.d/net/99-ax6000-autoneg


# --------------------------------------------------
# 5. 输出检查
# --------------------------------------------------
echo "[5/6] 检查生成文件..."
test -x package/base-files/files/etc/uci-defaults/99-custom-settings
test -x package/base-files/files/etc/hotplug.d/net/99-ax6000-autoneg

# --------------------------------------------------
# 6. 配置摘要
# --------------------------------------------------
echo "[6/6] 配置摘要..."
echo "  Hostname        : Redmi-AX6000"
echo "  LuCI             : Argon + 中文"
echo "  Timezone         : Asia/Shanghai"
echo "  WiFi country     : CN"
echo "  2.4G             : HE40 / Auto / 23dBm / 11k/v"
echo "  5G               : HE80 / 149 / 23dBm / 11k/v"
echo "  5G DFS           : 默认避开"
echo "  U-APSD  : 关闭"
echo "  BBR + fq         : 可用时启用"
echo "  TCP Buffer       : 16 MiB"
echo "  Flow Offloading  : SW + HW"
echo "  Tailscale UDP    : 41641"

echo ""
echo "=================================================="
echo " diy-part2.sh completed"
echo "=================================================="
