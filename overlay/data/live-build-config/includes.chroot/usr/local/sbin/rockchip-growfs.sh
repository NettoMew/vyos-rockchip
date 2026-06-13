#!/bin/sh
# rockchip-growfs — 首启把 VyOS persistence 分区扩满整盘。
# 镜像是定长（~4G）的,dd 到更大的卡/eMMC 后尾部会空着;本服务在 vyos-router 之前
# 把 persistence 分区扩到盘尾、再在线 resize2fs,任何容量介质自适应（树莓派/cloud 同理）。
#
# 幂等：按“分区尾之后还剩多少空闲扇区”判断,已接近占满就跳过,故每次启动跑都无副作用,
# 也天然适配“换一张更大的卡重新烧录”。
log() { echo "rockchip-growfs: $*"; }

part=$(findmnt -no SOURCE /usr/lib/live/mount/persistence 2>/dev/null)
[ -n "$part" ] || part=$(blkid -L persistence 2>/dev/null)
[ -b "$part" ] || { log "未找到 persistence 分区,跳过"; exit 0; }

pname=${part##*/}                                  # mmcblk1p2 / sda2 / nvme0n1p2
[ -e "/sys/class/block/$pname/partition" ] || { log "$part 非分区,跳过"; exit 0; }
num=$(cat "/sys/class/block/$pname/partition")
dname=$(basename "$(readlink -f "/sys/class/block/$pname/..")")   # mmcblk1 / sda
disk="/dev/$dname"
[ -b "$disk" ] || { log "推导磁盘失败,跳过"; exit 0; }

dsz=$(cat "/sys/class/block/$dname/size")          # 磁盘总扇区
pstart=$(cat "/sys/class/block/$pname/start")
psz=$(cat "/sys/class/block/$pname/size")
free=$(( dsz - pstart - psz ))
# 空闲不足 ~16MiB（32768×512B）视为已占满（含 GPT 备份头余量）,幂等跳过
if [ "$free" -lt 32768 ]; then
  log "persistence 已占满整盘（剩 ${free} 扇区）,无需扩容"
  exit 0
fi
log "扩容 ${part}（磁盘 ${dsz} 扇区,空闲 ${free} 扇区）"

sgdisk -e "$disk" >/dev/null 2>&1 || true          # GPT 备份头移到盘尾（dd 到更大盘后必需）
if command -v growpart >/dev/null 2>&1; then
  growpart "$disk" "$num" || log "growpart 非零退出（可能已满）"
else
  # 无 growpart：sgdisk 删除并以同一起始扇区重建到盘尾（只动分区表、不动数据,保留 label）
  sgdisk -d "$num" -n "${num}:${pstart}:0" -t "${num}:8300" -c "${num}:persistence" "$disk" >/dev/null 2>&1 \
    || log "sgdisk 重建失败"
fi
partx -u "$disk" 2>/dev/null || partprobe "$disk" 2>/dev/null || true   # 内核重读（末分区可在线扩）
resize2fs "$part" >/dev/null 2>&1 || log "resize2fs 非零退出"
log "完成：$(df -h "$part" 2>/dev/null | awk 'END{print $2" 总 / "$4" 可用"}')"
exit 0
