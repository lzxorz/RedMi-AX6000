#!/bin/bash
#
# Redmi AX6000 ImmortalWrt(https://github.com/immortalwrt/immortalwrt) DIY 配置
#
# 执行时机：
#   feeds update/install 完成后，在 ImmortalWrt 源码根目录执行。
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
echo "[1/5] 配置主机名 / Argon..."

if [ -f package/base-files/files/bin/config_generate ]; then
    sed -i 's/ImmortalWrt/Redmi-AX6000/g' package/base-files/files/bin/config_generate
fi

if [ -f feeds/luci/collections/luci/Makefile ]; then
    sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile
fi

# --------------------------------------------------
# 2. 编译时加入需要的软件包
# --------------------------------------------------
echo "[2/5] 配置 BBR / ethtool..."

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

# 让 OpenWrt 重新整理依赖关系；失败直接终止构建。
./scripts/config/conf --defconfig=.config Config.in

# --------------------------------------------------
# 3. 创建首次启动配置
# --------------------------------------------------
echo "[3/5] 创建首次启动配置..."

mkdir -p package/base-files/files/etc/uci-defaults

cat <<'FIRSTBOOT' > package/base-files/files/etc/uci-defaults/99-custom-settings
#!/bin/sh
#
# Redmi AX6000 / ImmortalWrt 首次启动配置
#

# ==================================================
# 1. WiFi：自动识别 2.4G / 5G radio
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
# 2.4G
# ==================================================
if [ -n "$RADIO_2G" ]; then
    RADIO="wireless.${RADIO_2G}"

    # 监管域必须与设备实际使用地区一致。
    uci set "${RADIO}.country=CN"

    # WiFi 6 / 802.11ax；2.4G 使用 HE40。
    uci set "${RADIO}.htmode=HE40"

    # 自动选信道。
    uci set "${RADIO}.channel=auto"

    # 目标发射功率；实际值仍受国家码、硬件和驱动限制。
    uci set "${RADIO}.txpower=23"
    uci set "${RADIO}.disabled=0"

    IFACE_2G="wireless.default_${RADIO_2G}"
    if uci -q get "${IFACE_2G}.ssid" >/dev/null 2>&1; then
        # 802.11k / 802.11v。
        uci set "${IFACE_2G}.ieee80211k=1"
        uci set "${IFACE_2G}.bss_transition=1"
        
        # 关闭 U-APSD。
        # 部分老旧/兼容性较差的终端关闭后更稳定。
        uci set "${IFACE_2G}.uapsd=0"
    fi

    echo "  2.4G: CN / HE40 / Auto / 23dBm / 11k/v / U-APSD off"
fi

# ==================================================
# 5G
# ==================================================
if [ -n "$RADIO_5G" ]; then
    RADIO="wireless.${RADIO_5G}"

    # 监管域必须与设备实际使用地区一致。
    uci set "${RADIO}.country=CN"

    # 稳定性优先：HE80，不强制 HE160。
    uci set "${RADIO}.htmode=HE80"
    
    # 5G 使用非 DFS 高频段；实际可用性仍由监管域/驱动决定。
    uci set "${RADIO}.channel=149"

    uci set "${RADIO}.txpower=23"
    uci set "${RADIO}.disabled=0"

    IFACE_5G="wireless.default_${RADIO_5G}"
    if uci -q get "${IFACE_5G}.ssid" >/dev/null 2>&1; then
        # 802.11k / 802.11v。
        uci set "${IFACE_5G}.ieee80211k=1"
        uci set "${IFACE_5G}.bss_transition=1"
        
        # 关闭 U-APSD。
        # 部分老旧/兼容性较差的终端关闭后更稳定。
        uci set "${IFACE_5G}.uapsd=0"
    fi

    echo "  5G: CN / HE80 / ch149 / 23dBm / 11k/v / U-APSD off"
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
# 4. BBR + fq
# ==================================================
BBR_AVAILABLE=0

if command -v sysctl >/dev/null 2>&1; then
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr 2>/dev/null || true
    fi

    if sysctl net.ipv4.tcp_allowed_congestion_control 2>/dev/null |
       grep -qw bbr; then
        BBR_AVAILABLE=1
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
        echo "  BBR: enabled"
    else
        echo "  BBR: unavailable"
    fi

    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
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

if [ "$BBR_AVAILABLE" = "1" ]; then
    add_sysctl 'net.ipv4.tcp_congestion_control' 'bbr'
    add_sysctl 'net.core.default_qdisc' 'fq'
fi

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
# 应用配置
# ==================================================
/etc/init.d/network restart >/dev/null 2>&1 || true
wifi reload >/dev/null 2>&1 || true
sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true

echo "Redmi AX6000 首次启动配置完成。"
exit 0
FIRSTBOOT

chmod +x package/base-files/files/etc/uci-defaults/99-custom-settings

# --------------------------------------------------
# 4. 输出检查
# --------------------------------------------------
echo "[4/5] 检查生成文件..."
test -x package/base-files/files/etc/uci-defaults/99-custom-settings

# --------------------------------------------------
# 5. 配置摘要
# --------------------------------------------------
echo "[5/5] 配置摘要..."
echo "  Hostname        : Redmi-AX6000"
echo "  LuCI             : Argon + 中文"
echo "  Timezone         : Asia/Shanghai"
echo "  WiFi country     : CN"
echo "  2.4G             : HE40 / Auto / 23dBm / 11k/v"
echo "  5G               : HE80 / 149 / 23dBm / 11k/v"
echo "  U-APSD  : 关闭"
echo "  BBR + fq         : 可用时启用"
echo "  Flow Offloading  : SW + HW"

echo ""
echo "=================================================="
echo " diy-part2.sh completed"
echo "=================================================="
