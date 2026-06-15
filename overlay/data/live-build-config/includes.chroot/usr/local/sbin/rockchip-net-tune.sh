#!/bin/sh
# rockchip-net-tune.sh — 板无关网络性能调优（开机一次，oneshot）：硬件多队列 + NIC
# offload + IRQ 亲和 + RPS/RFS/XPS + cpufreq performance，让 2.5G 不卡在单核 softirq。
#   ⓪ 硬件多队列(RSS) + NIC offload：把网卡 RX/TX 通道开到硬件上限（RTL8125 编了
#      ENABLE_RSS_SUPPORT 后有 RX4/TX2），并开 GRO/GSO/TSO/SG/UDP-GRO-forwarding。
#      GRO 入向聚合、GSO 出向分段，与 VyOS flowtable 软件流卸载是不同层、叠加关系。
#   ① NIC IRQ 亲和：每个网口的 IRQ 钉到独立 CPU（big.LITTLE 自动优先大核），多队列网卡
#      各队列分到不同核（RSS 真队列分核）→ 避免所有网卡中断堆在 CPU0、单核喂不满 2.5G。
#   ② RPS/RFS/XPS：把协议栈收/发处理摊到其余核（gmac 这种单队列口收益最大）。
#   ③ CPU governor=performance：路由盒吃满频，降转发延迟、提峰值吞吐。
# 与 rockchip-leds.sh 同 philosophy：按接口名/驱动认，板间零 if 分支；缺项静默跳过 →
# e20c/m28k/r5s/e52c 四板同一脚本通用（核数/大小核/口数自适应）。
# 可选覆盖 /etc/rockchip/net-tune.conf（仅在自动判错时才放，默认四板都不带）：
#   GOVERNOR="ondemand"                  # 改回省电
#   IFACE_CPU="eth0:2 eth1:3 eth2:4"     # 显式把某口 IRQ 钉到指定 CPU（覆盖自动分核）
set -e

[ -r /etc/rockchip/net-tune.conf ] && . /etc/rockchip/net-tune.conf
GOVERNOR="${GOVERNOR:-performance}"

log() { echo "rockchip-net-tune: $*"; }

# --- CPU 目标顺序：按 cpu_capacity 降序（大核在前）；>=3 核时排除 CPU0 留给控制面 -------
# 无 cpu_capacity（同构 SoC，如 RK3528/3568 全 A55）则等价按编号。e52c(big.LITTLE) 上得
# "4 5 6 7 1 2 3"（A76 在前、CPU0 不进 IRQ 轮转，与 RPS_MASK=fe 一致）。注意：排除/排序
# 都在管道内完成（for…done|sort|awk），不靠管道外变量——管道里的 for 跑在子 shell，外面
# 读不到它设的变量（旧版用管道外 echo "$zero" 拼 CPU0，子 shell 丢值，是歪打正着）。
cpu_targets() {
  ncpu=$(nproc 2>/dev/null || echo 1)
  skip0=0; [ "$ncpu" -ge 3 ] && skip0=1
  for c in /sys/devices/system/cpu/cpu[0-9]*/; do
    id=$(basename "$c"); id=${id#cpu}
    [ "$skip0" = 1 ] && [ "$id" = 0 ] && continue
    cap=$(cat "${c}cpu_capacity" 2>/dev/null || echo 1024)
    echo "$cap $id"
  done | sort -k1,1nr -k2,2n | awk '{printf "%s ", $2}'
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
  fi
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

# RPS/XPS 掩码：>=4 核时排除 CPU0（留控制面），否则用全部核
if [ "$NCPU" -ge 4 ]; then
  rps_ids=""; for n in $(seq 1 $(( NCPU - 1 )) 2>/dev/null); do rps_ids="$rps_ids $n"; done
else
  rps_ids=""; for n in $(seq 0 $(( NCPU - 1 )) 2>/dev/null); do rps_ids="$rps_ids $n"; done
fi
RPS_MASK=$(mask_of $rps_ids)

# 全局 RFS（加速 RPS、降低乱序）
[ -w /proc/sys/net/core/rps_sock_flow_entries ] && \
  { echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true; }

# --- 逐网口：硬件多队列(RSS) + NIC offload + IRQ 亲和 + RPS/RFS/XPS -------------------
counter=0
for ndir in /sys/class/net/*; do
  [ -e "$ndir/device" ] || continue          # 只动物理网卡
  ifc=$(basename "$ndir")
  case "$ifc" in eth*|lan*|wan*) ;; *) continue ;; esac

  # ⓪ 硬件多队列(RSS)：把 RX/TX 通道开到硬件上限。必须在 IRQ/队列分核之前——`ethtool -L`
  #    会重建 IRQ 与 rx/tx 队列，先开通道后面 ① IRQ 亲和、②③ RPS/XPS 才能落到新队列上。
  #    单队列网卡(不支持/RX≤1)自动跳过；驱动用 combined 还是分离 RX/TX 都兼容。
  chan=$(ethtool -l "$ifc" 2>/dev/null)
  if [ -n "$chan" ]; then
    mco=$(printf '%s\n' "$chan" | awk '/Pre-set/{p=1;next} /Current/{p=0} p&&/^Combined:/{print $2;exit}')
    mrx=$(printf '%s\n' "$chan" | awk '/Pre-set/{p=1;next} /Current/{p=0} p&&/^RX:/{print $2;exit}')
    mtx=$(printf '%s\n' "$chan" | awk '/Pre-set/{p=1;next} /Current/{p=0} p&&/^TX:/{print $2;exit}')
    if [ "${mco:-0}" -gt 1 ] 2>/dev/null; then
      ethtool -L "$ifc" combined "$mco" 2>/dev/null && log "$ifc RSS combined=$mco" || true
    else
      a=""
      [ "${mrx:-0}" -gt 1 ] 2>/dev/null && a="rx $mrx"
      [ "${mtx:-0}" -gt 1 ] 2>/dev/null && a="$a tx $mtx"
      [ -n "$a" ] && { ethtool -L "$ifc" $a 2>/dev/null && log "$ifc RSS channels: $a" || true; }
    fi
  fi

  # ⓪b NIC offload：GRO 入向聚合、GSO/TSO 出向分段、SG、UDP 转发 GRO。逐项设，不支持/[fixed]
  #     的项 `|| true` 静默跳过（一项失败不连累其它）。与 flowtable 软件流卸载叠加，不冲突。
  for feat in gro gso tso sg rx-udp-gro-forwarding; do
    ethtool -K "$ifc" "$feat" on 2>/dev/null || true
  done

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

  # ② RPS（收）+ RFS：把协议栈处理摊开
  for q in "$ndir"/queues/rx-*; do
    [ -d "$q" ] || continue
    [ -w "$q/rps_cpus" ]     && { echo "$RPS_MASK" > "$q/rps_cpus" 2>/dev/null || true; }
    [ -w "$q/rps_flow_cnt" ] && { echo 4096        > "$q/rps_flow_cnt" 2>/dev/null || true; }
  done
  # ③ XPS（发）
  for q in "$ndir"/queues/tx-*; do
    [ -d "$q" ] || continue
    [ -w "$q/xps_cpus" ] && { echo "$RPS_MASK" > "$q/xps_cpus" 2>/dev/null || true; }
  done
done

# --- CPU governor ------------------------------------------------------------------
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w "$g" ] && { echo "$GOVERNOR" > "$g" 2>/dev/null || true; }
done
log "governor=$GOVERNOR, RPS_MASK=$RPS_MASK, cpu_targets=[$TARGETS]"

exit 0
