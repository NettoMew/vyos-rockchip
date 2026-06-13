#!/bin/sh
# rockchip-r5s-ifrename.sh — NanoPi R5S 确定性网口命名：
#   eth0 = WAN  (gmac0, driver rk_gmac-dwmac/st_gmac)
#   eth1 / eth2 = 两个 2.5G RTL8125 (driver r8125)，按 PCIe 控制器路径分：
#     3c0000000.pcie (=pcie@fe260000, pcie2x1) → eth1
#     3c0400000.pcie (=pcie@fe270000, pcie3x1) → eth2
#
# 为什么不用 udev VYOS_IFNAME（像 RK3528 那样）：真机实测在 R5S 上 VyOS 的 udev 预定义
# 命名在启动期不生效——gmac 的真实 add 事件在 initramfs（那时没有 rootfs 的 60 规则），
# rootfs 里又不重命名；r8125 是 out-of-tree 模块、晚到 ~27s 才加载。结果三口名错乱
# (e2/eth0/eth2) → 默认配置里的 eth1 找不到 → "Configuration error"。手动 udevadm
# trigger 能命中规则（说明规则本身对），但开机期那几个 add 事件就是没应用。
# 故用本服务在 vyos-router 之前、按 driver+PCIe 路径**显式**改名，绕开该竞态（确定、幂等）。
# 仅 R5S 装（boards/r5s/rootfs/），RK3528 板不受影响。
set -e

# 等三个口都就绪（gmac + 2×r8125），最多 ~30s（r8125 晚加载）
i=0
while [ "$i" -lt 60 ]; do
  g=""; r=0
  for n in /sys/class/net/*; do
    [ -e "$n/device/driver" ] || continue
    drv=$(basename "$(readlink "$n/device/driver")")
    case "$drv" in rk_gmac-dwmac|st_gmac|stmmac*) g=1 ;; r8125) r=$((r + 1)) ;; esac
  done
  [ -n "$g" ] && [ "$r" -ge 2 ] && break
  i=$((i + 1)); sleep 0.5
done

# 当前名 -> 目标名
map=""
for n in /sys/class/net/*; do
  [ -e "$n/device" ] || continue
  name=$(basename "$n")
  drv=$(basename "$(readlink "$n/device/driver" 2>/dev/null)" 2>/dev/null)
  path=$(readlink -f "$n/device" 2>/dev/null)
  t=""
  case "$drv" in
    rk_gmac-dwmac|st_gmac|stmmac*) t=eth0 ;;
    r8125) case "$path" in
             *3c0000000.pcie*) t=eth1 ;;
             *3c0400000.pcie*) t=eth2 ;;
           esac ;;
  esac
  [ -n "$t" ] && [ "$name" != "$t" ] && map="$map $name:$t"
done
[ -n "$map" ] || echo "rockchip-r5s-ifrename: 无需改名（名字已就位）"

# 先全部 down + 改临时名，避免目标名占用冲突；再从临时名落到目标名
for pair in $map; do
  c=${pair%:*}
  ip link set "$c" down 2>/dev/null || true
  ip link set "$c" name "t_$c" 2>/dev/null || true
done
for pair in $map; do
  c=${pair%:*}; t=${pair#*:}
  ip link set "t_$c" name "$t" 2>/dev/null && echo "rockchip-r5s-ifrename: rename $c -> $t" \
    || echo "rockchip-r5s-ifrename: FAILED $c -> $t"
done

# 命名已定。VYOS_IFNAME 的 predefined 路径会让 vyos_net_name 把“名字”写进
# /run/udev/vyos/,vyos-interface-rescan 随后会误把它当 MAC 解析、抛 AddrFormatError
# traceback（不致命但难看）。等改名触发的 udev 事件处理完,清空该暂存目录 → rescan
# 读不到名字 → 不再 traceback。我们三口 MAC 随机、本就不靠 hw-id 持久化,清它无副作用。
command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true
rm -f /run/udev/vyos/* 2>/dev/null || true
exit 0
