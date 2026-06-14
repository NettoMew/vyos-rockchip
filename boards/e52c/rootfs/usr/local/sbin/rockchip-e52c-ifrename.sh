#!/bin/sh
# rockchip-e52c-ifrename.sh — Radxa E52C 确定性网口命名。
#   eth0 = WAN，eth1 = LAN —— 两口都是 RTL8125（driver r8125），无 gmac 可作锚。
#
# 两口同驱动，无法靠 driver 区分；唯一稳定的判别量是 PCIe 拓扑（哪个控制器/插槽）。
# 但 RK3588S 上 pcie2x1l1/l2 的内核设备名按 CPU 地址命名（如 R5S 的 3c0000000.pcie，
# 不是 DT 节点名），真机才知确切串；故这里**不钉死地址**，改为：把所有 r8125 口按其
# PCIe 设备路径字符串排序，第一个→eth0(WAN)、第二个→eth1(LAN)。PCIe 拓扑固定 → 排序
# 每启一致、确定且幂等，无需任何硬编码地址。
#
# 为什么不靠 udev VYOS_IFNAME 预定义命名（像 RK3528 那样）：r8125 是 out-of-tree 模块、
# 晚加载，其 add 事件在启动期 VyOS 的 udev 预定义命名不稳定应用（R5S 真机同款踩坑）。
# 故用本服务在 vyos-router 之前**显式** ip-link 改名，绕开竞态。配套 60-rockchip-net.rules
# 设 VYOS_IFNAME="%k"（保持现名）防止 vyos_net_name 把口改回自动枚举名 e3/e4。
# 仅 E52C 装（boards/e52c/rootfs/）。
#
# 若真机发现物理 WAN/LAN 与 eth0/eth1 相反：把下面 i=0 的目标名 eth0/eth1 对调即可。
set -e

# 等两个 RTL8125 都就绪（r8125 晚加载），最多 ~30s
i=0
while [ "$i" -lt 60 ]; do
  r=0
  for n in /sys/class/net/*; do
    [ -e "$n/device/driver" ] || continue
    [ "$(basename "$(readlink "$n/device/driver")")" = "r8125" ] && r=$((r + 1))
  done
  [ "$r" -ge 2 ] && break
  i=$((i + 1)); sleep 0.5
done

# 收集所有 r8125 口的 “PCIe路径<TAB>当前名”，按路径排序（确定顺序）
list=$(
  for n in /sys/class/net/*; do
    [ -e "$n/device/driver" ] || continue
    [ "$(basename "$(readlink "$n/device/driver")")" = "r8125" ] || continue
    printf '%s\t%s\n' "$(readlink -f "$n/device")" "$(basename "$n")"
  done | sort
)

# 排序后第 1 个 → eth0(WAN)，第 2 个 → eth1(LAN)。for 不在管道里 → idx 累加可见。
map=""; idx=0
for name in $(echo "$list" | awk -F'\t' 'NF==2{print $2}'); do
  case "$idx" in 0) t=eth0 ;; 1) t=eth1 ;; *) t="" ;; esac
  idx=$((idx + 1))
  [ -n "$t" ] && [ "$name" != "$t" ] && map="$map $name:$t"
done
[ -n "$map" ] || echo "rockchip-e52c-ifrename: 无需改名（名字已就位）"

# 先全部 down + 改临时名，避免目标名占用冲突；再从临时名落到目标名
for pair in $map; do
  c=${pair%:*}
  ip link set "$c" down 2>/dev/null || true
  ip link set "$c" name "t_$c" 2>/dev/null || true
done
for pair in $map; do
  c=${pair%:*}; t=${pair#*:}
  ip link set "t_$c" name "$t" 2>/dev/null && echo "rockchip-e52c-ifrename: rename $c -> $t" \
    || echo "rockchip-e52c-ifrename: FAILED $c -> $t"
done

# 命名已定。VYOS_IFNAME 的 predefined 路径会让 vyos_net_name 把“名字”写进 /run/udev/vyos/,
# vyos-interface-rescan 随后会误把它当 MAC 解析、抛 AddrFormatError traceback（不致命）。
# 等改名触发的 udev 事件处理完,清空该暂存目录 → 不再 traceback。两口 MAC 随机、本就不靠
# hw-id 持久化,清它无副作用（同 R5S）。
command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null || true
rm -f /run/udev/vyos/* 2>/dev/null || true
exit 0
