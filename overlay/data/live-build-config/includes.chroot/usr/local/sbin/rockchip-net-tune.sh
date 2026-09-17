#!/bin/sh
# 板级启动设置：IRQ、XPS、UDP GRO forwarding 和 CPU governor。
# Ethernet offload、RPS/RFS 由 VyOS 配置管理；不在启动后覆盖，也不通过调整
# channel 数量重建队列。升级迁移要求见 docs/network-performance.md。
# IRQ 使用在线高 capacity CPU，各接口独立轮转；XPS/governor 策略保持不变。
# 性能收益须独立测试，不能由脚本执行成功推断。
# 可选覆盖 /etc/rockchip/net-tune.conf（仅在自动判错时才放，默认四板都不带）：
#   GOVERNOR="ondemand"                  # 改回省电
#   IFACE_CPU="eth0:2 eth1:3 eth2:4"     # 显式把某口 IRQ 钉到指定 CPU（覆盖自动分核）
set -e

[ -r /etc/rockchip/net-tune.conf ] && . /etc/rockchip/net-tune.conf
GOVERNOR="${GOVERNOR:-performance}"

log() { echo "rockchip-net-tune: $*"; }

# 仅从在线 CPU 选最高 capacity 组；>=3 个在线核时先排除 CPU0。
# E52C 得到 4/5/6/7；同构平台按编号轮转。缺少 capacity 时沿用 1024 回退。
cpu_targets() {
  for c in /sys/devices/system/cpu/cpu[0-9]*/; do
    [ -d "$c" ] || continue
    [ "$(cat "${c}online" 2>/dev/null || echo 1)" = 0 ] && continue
    id=$(basename "$c"); id=${id#cpu}
    cap=$(cat "${c}cpu_capacity" 2>/dev/null || echo 1024)
    echo "$cap $id"
  done | sort -k1,1nr -k2,2n | awk '
    { cap[NR]=$1; cpu[NR]=$2 }
    END {
      for (i=1; i<=NR; i++) {
        if (NR>=3 && cpu[i]==0) continue
        if (!found) { best=cap[i]; found=1 }
        if (cap[i]==best) printf "%s ", cpu[i]
      }
    }'
}

# 取列表第 i 个（0 基，循环）
nth() { i=$1; shift; [ "$#" -gt 0 ] || return 0; i=$(( i % $# )); shift "$i"; echo "$1"; }

# CPU id 列表 → 十六进制掩码
mask_of() { m=0; for id in "$@"; do m=$(( m | (1 << id) )); done; printf '%x' "$m"; }

# 网口的 IRQ 列表（优先 MSI；退回 /proc/interrupts 按名匹配）
iface_irqs() {
  d="/sys/class/net/$1/device"
  if [ -d "$d/msi_irqs" ]; then
    for f in "$d/msi_irqs"/*; do [ -e "$f" ] && basename "$f"; done
  else
    awk -v n="$1" '$NF==n { sub(/:/,"",$1); print $1 }' /proc/interrupts
  fi | sort -n
}

# 受管物理网口（eth*/lan*/wan*）
managed_ifaces() {
  for nd in /sys/class/net/*; do
    [ -e "$nd/device" ] || continue
    ic=$(basename "$nd")
    case "$ic" in eth*|lan*|wan*) echo "$ic" ;; esac
  done
}

# --- 等所有受管口被 VyOS 置为 admin-up 再调优（真机时序坑，2026-06-14）---------------
# 坑：vyos-router.service 的 unit 很早就 "Started"（systemd 认为 active），但真正的接口
# 配置/up 由它**异步**在之后做（首启 ~33–57s 才 Configuration success）。而 r8125 的 MSI
# IRQ 与 rx/tx 队列要到接口 open(admin-up) 才分配 → 只 After=vyos-router 就动手会扑空：
# IRQ 没出来、队列没建 → 亲和/RPS 全落空（不依赖网卡的 governor 仍生效，故只它成功）。
# 解法：自旋等到每个受管口 IFF_UP 再调（eth1 无网线也算 admin-up，只是 NO-CARRIER），
# 最多 ~120s（受管口为空则立即继续；个别口永不 up 则到顶后对已 up 的口照调）。
i=0
while [ "$i" -lt 240 ]; do
  pending=0
  for ic in $(managed_ifaces); do
    f=$(cat "/sys/class/net/$ic/flags" 2>/dev/null || echo 0)
    [ $(( f & 1 )) -eq 1 ] || pending=1
  done
  [ "$pending" -eq 0 ] && break
  i=$(( i + 1 )); sleep 0.5
done
sleep 1   # admin-up 后给 IRQ/队列分配结算一点时间

# --- CPU 目标池 / 在线核数 ----------------------------------------------------------
TARGETS=$(cpu_targets)
NCPU=$(nproc 2>/dev/null || echo 1)

# XPS 掩码：>=4 核时排除 CPU0（留控制面），否则用全部核
if [ "$NCPU" -ge 4 ]; then
  xps_ids=""; for n in $(seq 1 $(( NCPU - 1 )) 2>/dev/null); do xps_ids="$xps_ids $n"; done
else
  xps_ids=""; for n in $(seq 0 $(( NCPU - 1 )) 2>/dev/null); do xps_ids="$xps_ids $n"; done
fi
XPS_MASK=$(mask_of $xps_ids)

# --- 逐网口：UDP GRO forwarding + IRQ 亲和 + XPS ---------------------------------
iface_index=0
for ndir in /sys/class/net/*; do
  [ -e "$ndir/device" ] || continue          # 只动物理网卡
  ifc=$(basename "$ndir")
  case "$ifc" in eth*|lan*|wan*) ;; *) continue ;; esac
  counter=$iface_index
  iface_index=$(( iface_index + 1 ))

  # 当前 VyOS 无此独立配置节点，保留已有 UDP forwarding 行为；不强制开启 GRO。
  ethtool -K "$ifc" rx-udp-gro-forwarding on 2>/dev/null || true

  # ① IRQ 亲和。优先用 net-tune.conf 的显式 IFACE_CPU 覆盖；否则自动轮转分核。
  forced=""
  for pair in $IFACE_CPU; do
    [ "${pair%:*}" = "$ifc" ] && forced="${pair#*:}"
  done
  for irq in $(iface_irqs "$ifc"); do
    [ -w "/proc/irq/$irq/smp_affinity_list" ] || continue
    if [ -n "$forced" ]; then
      cpu="$forced"
    else
      cpu=$(nth "$counter" $TARGETS); counter=$(( counter + 1 ))
    fi
    [ -n "$cpu" ] || continue
    echo "$cpu" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null \
      && log "IRQ $irq ($ifc) -> CPU $cpu" || true
  done

  # XPS（发）：与 IRQ、接收方向的 RPS/RFS 独立。
  for q in "$ndir"/queues/tx-*; do
    [ -d "$q" ] || continue
    [ -w "$q/xps_cpus" ] && { echo "$XPS_MASK" > "$q/xps_cpus" 2>/dev/null || true; }
  done
done

# --- CPU governor ------------------------------------------------------------------
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w "$g" ] && { echo "$GOVERNOR" > "$g" 2>/dev/null || true; }
done
log "governor=$GOVERNOR, XPS_MASK=$XPS_MASK, cpu_targets=[$TARGETS]"

exit 0
