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
# - BBR + fq（内核支持时） 
# - Software Flow Offloading 
#
# 设计原则：
#   - radio0/radio1 不硬编码，通过 band=2g/5g 自动识别。
#   - 不修改不确定的内核 / 网络参数
#   - 首次启动配置保持幂等
# - 编译期只加入明确需要的软件包
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
echo " Redmi AX6000 DIY configuration"
echo "=================================================="

# --------------------------------------------------
# 1. 基础设置
# --------------------------------------------------
echo "[1/5] 配置主机名 / Argon..."

# 默认主机名
if [ -f package/base-files/files/bin/config_generate ]; then
    sed -i 's/ImmortalWrt/Redmi-AX6000/g' package/base-files/files/bin/config_generate
fi

if [ -f feeds/luci/collections/luci/Makefile ]; then
    sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile
fi

# --------------------------------------------------
# 2. 编译时加入需要的软件包
# --------------------------------------------------
echo "[2/5] 配置软件包 / BBR..."

add_config() {
    local cfg="$1"
    grep -qxF "$cfg" .config 2>/dev/null || echo "$cfg" >> .config
}

# Argon 
if grep -Rqs 'Package/luci-theme-argon' package feeds 2>/dev/null; then 
    
    add_config "CONFIG_PACKAGE_luci-theme-argon=y" 
    echo " + luci-theme-argon" 
else 
    echo " - luci-theme-argon 未找到，跳过" 
fi

# BBR
if grep -Rqs 'config PACKAGE_kmod-tcp-bbr' package feeds 2>/dev/null ||
   grep -Rqs 'Package/kmod-tcp-bbr' package feeds 2>/dev/null; then
    
    add_config "CONFIG_PACKAGE_kmod-tcp-bbr=y"
    echo "  + kmod-tcp-bbr"
else
    echo "  - kmod-tcp-bbr 未找到，跳过"
fi

# 使用 ImmortalWrt/OpenWrt 标准方式重新解析依赖。 
make defconfig

# --------------------------------------------------
# 3. 创建首次启动配置
# --------------------------------------------------
echo "[3/5] 创建首次启动配置..."

mkdir -p package/base-files/files/etc/uci-defaults
mkdir -p package/base-files/files/etc/sysctl.d
mkdir -p package/base-files/files/etc/modules.d

# -------------------------------------------------- 
# BBR：启动时尝试加载模块 
# -------------------------------------------------- 
cat <<'EOF' > package/base-files/files/etc/modules.d/99-bbr 
tcp_bbr 
EOF

# -------------------------------------------------- 
# 首次启动配置 
# --------------------------------------------------
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
# 2. BBR + fq
# ==================================================
BBR_AVAILABLE=0

if command -v sysctl >/dev/null 2>&1; then
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr 2>/dev/null || true
    fi

    if sysctl net.ipv4.tcp_allowed_congestion_control 2>/dev/null | grep -qw bbr; then
        BBR_AVAILABLE=1
        
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true 
        
        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true 
        
        cat > /etc/sysctl.d/99-bbr.conf <<'EOF' 
        net.ipv4.tcp_congestion_control=bbr 
        net.core.default_qdisc=fq 
        EOF
        
        echo "  BBR: enabled"
    else
        echo "  BBR: unavailable"
    fi
fi

# ==================================================
# 3. Software Flow Offloading
# ==================================================
if uci -q show firewall.@defaults[0] >/dev/null 2>&1; then
    uci set firewall.@defaults[0].flow_offloading=1
    uci -q delete firewall.@defaults[0].flow_offloading_hw
    uci commit firewall

    echo " Flow Offloading: software"
fi

# ==================================================
# 4. LuCI 中文 + 上海时区
# ==================================================
uci set luci.main.lang=zh_cn

# 如果 Argon 已安装，则设置为默认主题 
if [ -d /www/luci-static/argon ]; then 
    uci set luci.main.mediaurlbase=/luci-static/argon 
fi

uci commit luci

uci set system.@system[0].timezone=CST-8
uci set system.@system[0].zonename=Asia/Shanghai

uci commit system

# ==================================================
# 应用配置
# ==================================================
if [ -f /etc/sysctl.d/99-bbr.conf ]; then
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
fi

/etc/init.d/network restart >/dev/null 2>&1 || true
wifi reload >/dev/null 2>&1 || true

echo "Redmi AX6000 首次启动配置完成。"
exit 0
FIRSTBOOT

chmod +x package/base-files/files/etc/uci-defaults/99-custom-settings

# --------------------------------------------------
# 4. 输出检查
# --------------------------------------------------
echo "[4/5] 检查生成文件..."
test -x package/base-files/files/etc/uci-defaults/99-custom-settings
test -f package/base-files/files/etc/modules.d/99-bbr

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
echo "  U-APSD           : 关闭"
echo "  BBR + fq         : 可用时启用"
echo "  Flow Offloading  : Software"

echo ""
echo "=================================================="
echo " diy-part2.sh completed"
echo "=================================================="
