#!/bin/sh
# rockchip-leds.sh — 开机配置板载 LED，按"接口角色不变式"驱动，与板族无关：
#   命名规则（60-rockchip-net.rules）保证三板一致：eth0 = WAN，eth1(+eth2) = LAN。
# 故按接口名绑灯即可，无 if-board 分支：
#   状态/心跳灯（green:status / SYS）         → heartbeat
#   WAN 灯（white:wan / WAN / green:wan）      → eth0 netdev（E52C 是 pwm-led green:wan）
#   LAN 灯（white:lan / LAN-1 / green:lan）    → eth1 netdev（E52C 是 pwm-led green:lan）
#   LAN-2 灯（LAN-2）                          → eth2 netdev（R5S 第三口；他板无此灯则跳过）
#   gmac 的 RJ45 内置 PHY 灯（stmmac-0:01:*）→ gmac 物理口（按 driver 认，与 WAN/LAN 角色无关）
# 不同板灯名不同，缺哪个 LED 名相应步骤静默跳过（setnetdev 见目录不存在即返回），无副作用。
set -e

setnetdev() {
    L=$1; DEV=$2; shift 2
    [ -d "/sys/class/leds/${L}" ] || return 0
    echo netdev > "/sys/class/leds/${L}/trigger" 2>/dev/null || return 0
    echo "${DEV}" > "/sys/class/leds/${L}/device_name" 2>/dev/null || true
    for ev in "$@"; do echo 1 > "/sys/class/leds/${L}/${ev}" 2>/dev/null || true; done
}

# 状态/心跳灯（rk3528: green:status；R5S: SYS 已由 DTS 设 heartbeat，此处幂等重设）
for s in green:status SYS; do
    [ -d "/sys/class/leds/${s}" ] && \
        echo heartbeat > "/sys/class/leds/${s}/trigger" 2>/dev/null || true
done

# 按接口名绑网口活动灯（eth0=WAN / eth1,eth2=LAN）——灯名按板族择一存在
for L in white:wan WAN green:wan;   do setnetdev "${L}" eth0 link tx rx; done
for L in white:lan LAN-1 green:lan; do setnetdev "${L}" eth1 link tx rx; done
setnetdev "LAN-2" eth2 link tx rx

# gmac 的 RJ45 内置 PHY 灯（绿=link，黄=收发）——绑到 gmac 物理口本身（其角色随板不同）
gmac=""
for n in /sys/class/net/*; do
    [ -e "${n}/device/driver" ] || continue
    drv=$(basename "$(readlink "${n}/device/driver" 2>/dev/null)" 2>/dev/null)
    case "${drv}" in rk_gmac-dwmac|stmmac*) gmac=$(basename "${n}") ;; esac
done
if [ -n "${gmac}" ]; then
    setnetdev "stmmac-0:01:green:lan" "${gmac}" link
    setnetdev "stmmac-0:01:amber:lan" "${gmac}" tx rx
fi

exit 0
