#!/bin/bash
#
# Redmi AX6000 ImmortalWrt DIY 配置
#
# 执行时机：
#   feeds update/install 完成后，在 ImmortalWrt 源码根目录执行。
#
# 目标： 
# - Redmi AX6000 
# - Argon 
# - 中文 LuCI 
# - Asia/Shanghai 
# - 2.4G HE40 / Auto 
# - 5G HE80 / 149 
# - 802.11k / 802.11v 
# - U-APSD off 
# - Software Flow Offloading 
#
# 设计原则：
#   - radio0/radio1 不硬编码，通过 band=2g/5g 自动识别。
#   - 不修改 ImmortalWrt 核心源码默认配置
#   - 编译期只加入明确需要的软件包。
#   - 首次启动配置保持幂等
#   - 不修改不确定的内核 / 网络参数。 
#
# 注意： 
# - country=CN 必须与设备实际使用地区一致 
# - UCI set 统一使用： 
#     uci set "${SECTION}.option=value" 
# - 不写成： 
#     uci set "${SECTION}.option='value'"
#

set -e

echo "=================================================="
echo " Redmi AX6000 ImmortalWrt DIY configuration"
echo "=================================================="

# --------------------------------------------------
# 1. 编译时加入需要的软件包
# --------------------------------------------------
echo "配置软件包..."

add_config() {
    local cfg="$1"
    grep -qxF "$cfg" .config 2>/dev/null || echo "$cfg" >> .config
}

package_exists() {
    local package="$1"

    grep -Rqs --include='Makefile' "Package/${package}" package feeds 2>/dev/null
}



# 使用 ImmortalWrt/OpenWrt 标准方式重新解析依赖。 
# make defconfig

# --------------------------------------------------
# 2. 创建首次启动配置
# --------------------------------------------------
echo "创建首次启动配置..."

UCI_DEFAULTS_DIR="package/base-files/files/etc/uci-defaults"
SYSCTL_DIR="package/base-files/files/etc/sysctl.d"

mkdir -p "$UCI_DEFAULTS_DIR"
mkdir -p "$SYSCTL_DIR"

cat <<'FIRSTBOOT' > "${UCI_DEFAULTS_DIR}/99-custom-settings"

#!/bin/sh
#
# Redmi AX6000 ImmortalWrt 首次启动配置
#

set -e

# ================================================== 
# 基础系统 
# ================================================== 
uci set system.@system[0].hostname=Redmi-AX6000 
uci set system.@system[0].timezone=CST-8 
uci set system.@system[0].zonename=Asia/Shanghai 

uci commit system

# ==================================================
# WiFi：自动识别 2.4G / 5G radio
# ==================================================
find_radio_by_band() {
    local target_band="$1"
    local radio 
	
    for radio in $(uci -q show wireless 2>/dev/null | 
        sed -n "s/^wireless\.\([^=]*\)=wifi-device$/\1/p"); do 
        if [ "$(uci -q get "wireless.${radio}.band" 2>/dev/null)" = "$target_band" ]; then 
            echo "$radio" 
            return 0 
        fi 
    done
    
    return 1
}

find_iface_by_device() { 
    local device="$1" 
    local iface 
    local iface_device 
    
    for iface in $(uci -q show wireless 2>/dev/null | 
        sed -n 's/^wireless\.\([^=]*\)=wifi-iface$/\1/p'); do 
        
        iface_device="$(uci -q get "wireless.${iface}.device" 2>/dev/null || true)" 
        
        if [ "$iface_device" = "$device" ]; then 
            echo "$iface" 
            return 0 
        fi 
    done 
    
    return 1 
}

RADIO_2G="$(find_radio_by_band 2g || true)" 
RADIO_5G="$(find_radio_by_band 5g || true)" 

echo "WiFi radio:" 
echo " 2.4G = ${RADIO_2G:-未找到}" 
echo " 5G = ${RADIO_5G:-未找到}"

# ==================================================
# 2.4G
# ==================================================
if [ -n "$RADIO_2G" ]; then
    RADIO="wireless.${RADIO_2G}"
    IFACE_2G="$(find_iface_by_device "$RADIO_2G" || true)"

    # 监管域必须与设备实际使用地区一致。
    uci set "${RADIO}.country=CN"

    # WiFi 6 / 802.11ax；2.4G 使用 HE40。
    uci set "${RADIO}.htmode=HE40"

    # 自动选信道。
    uci set "${RADIO}.channel=auto"

    # 目标发射功率；实际值仍受国家码、硬件和驱动限制。
    uci set "${RADIO}.txpower=23"
    uci set "${RADIO}.disabled=0"
    
    if [ -n "$IFACE_2G" ]; then
        IFACE="wireless.${IFACE_2G}"
        
        # 802.11k / 802.11v。
        uci set "${IFACE}.ieee80211k=1"
        uci set "${IFACE}.bss_transition=1"
        
        # 关闭 U-APSD。
        # 部分老旧/兼容性较差的终端关闭后更稳定。
        uci set "${IFACE}.uapsd=0"

        # SSID / 加密 
        uci set "${IFACE}.ssid=Tenda-nls" 
        uci set "${IFACE}.encryption=psk2+ccmp" 
        uci set "${IFACE}.key=2022@056700"
    fi

    echo "  2.4G: CN / HE40 / Auto / 23dBm / 11k/v / U-APSD off"
fi

# ==================================================
# 5G
# ==================================================
if [ -n "$RADIO_5G" ]; then
    RADIO="wireless.${RADIO_5G}"
    IFACE_5G="$(find_iface_by_device "$RADIO_5G" || true)"
    
    # 监管域必须与设备实际使用地区一致。
    uci set "${RADIO}.country=CN"

    # 稳定性优先：HE80，不强制 HE160。
    uci set "${RADIO}.htmode=HE80"
    
    # 5G 使用非 DFS 高频段；实际可用性仍由监管域/驱动决定。
    uci set "${RADIO}.channel=149"

    uci set "${RADIO}.txpower=23"
    uci set "${RADIO}.disabled=0"

    if [ -n "$IFACE_5G" ]; then
        IFACE="wireless.${IFACE_5G}"
        
        # 802.11k / 802.11v。
        uci set "${IFACE}.ieee80211k=1"
        uci set "${IFACE}.bss_transition=1"
        
        # 关闭 U-APSD。
        # 部分老旧/兼容性较差的终端关闭后更稳定。
        uci set "${IFACE}.uapsd=0"

        # SSID / 加密 
        uci set "${IFACE}.ssid=Tenda-nls_5G" 
        uci set "${IFACE}.encryption=psk2+ccmp" 
        uci set "${IFACE}.key=2022@056700"
    fi

    echo "  5G: CN / HE80 / ch149 / 23dBm / 11k/v / U-APSD off"
fi

uci commit wireless

# ==================================================
# Software Flow Offloading
# ==================================================
if uci -q show firewall.@defaults[0] >/dev/null 2>&1; then
    # 软件流量分载。
    uci set firewall.@defaults[0].flow_offloading=1
    # 明确关闭硬件流量分载。
    uci -q delete firewall.@defaults[0].flow_offloading_hw
    
    uci commit firewall

    echo " Flow Offloading: software"
fi

# ==================================================
# LuCI 中文
# ==================================================
uci set luci.main.lang=zh_cn

# Argon 已安装，则设置为默认主题 
if [ -d /www/luci-static/argon ]; then 
    uci set luci.main.mediaurlbase=/luci-static/argon 
fi

uci commit luci

echo "Redmi AX6000 首次启动配置完成。"

exit 0
FIRSTBOOT

chmod +x "${UCI_DEFAULTS_DIR}/99-custom-settings"

# --------------------------------------------------
# 3. 输出检查
# --------------------------------------------------
echo "检查生成文件..."
test -x ${UCI_DEFAULTS_DIR}/99-custom-settings"

echo ""
echo "=================================================="
echo " diy-part2.sh completed"
echo "=================================================="
