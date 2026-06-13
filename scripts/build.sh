#!/usr/bin/env bash
# scripts/build.sh — 唯一入口（orchestrator）。
#
#   scripts/build.sh e20c                 # 全链：deps→sources→overlay→builder→kernel→iso→uboot→image
#   scripts/build.sh e20c --dry-run       # 只解析配置、打印计划与缓存状态，不构建不联网不 sudo
#   scripts/build.sh --stages kernel,iso  # 板无关阶段可不带板名
#   REBUILD_KERNEL=1 / REBUILD_ISO=1 / REBUILD_UBOOT=1 / REFRESH_SOURCES=1 / SKIP_FETCH=1
#
# 阶段全部幂等：昂贵产物（内核 deb / ISO / U-Boot bin）有缓存即跳过。
# 内核与 ISO 是板无关产物（RK3528 家族共享）；仅 uboot 与 image 按板出活。

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
LIB_DIR="${PROJECT_ROOT}/lib"

# shellcheck source=/dev/null
source "${LIB_DIR}/log.sh"

# 顺序即依赖：iso 产出"板无关 base"（make iso 即止于此）；aic8800/r8125/oled 在其后
# 把"本板专属"资产产到 board-assets/（需 kernel 树，cross 模式），由 image 阶段注入。
ALL_STAGES=(deps sources overlay builder kernel iso aic8800 r8125 oled uboot image)
BOARD_STAGES=(uboot image)   # 需要板名的阶段（aic8800/r8125/oled 内部按 BOARD_* 判断，无板时自跳过）

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- 参数解析 -------------------------------------------------------------------
BOARD=""
DRY_RUN="${DRY_RUN:-0}"
STAGES_CSV=""
while (($#)); do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --stages)    STAGES_CSV="${2:?--stages 需要参数}"; shift ;;
    --stages=*)  STAGES_CSV="${1#*=}" ;;
    -h|--help)   usage ;;
    -*)          fatal "未知参数：$1（--help 看用法）" ;;
    *)           [[ -z "${BOARD}" ]] || fatal "板名只能给一个：${BOARD} vs $1"
                 BOARD="$1" ;;
  esac
  shift
done
export DRY_RUN

if [[ -n "${STAGES_CSV}" ]]; then
  IFS=',' read -r -a PLAN <<< "${STAGES_CSV}"
else
  PLAN=("${ALL_STAGES[@]}")
fi

stage_planned() { local s; for s in "${PLAN[@]}"; do [[ "${s}" == "$1" ]] && return 0; done; return 1; }

# 校验阶段名 + 板名必要性
for s in "${PLAN[@]}"; do
  [[ " ${ALL_STAGES[*]} " == *" ${s} "* ]] || fatal "未知阶段：${s}（可选：${ALL_STAGES[*]}）"
done
for s in "${BOARD_STAGES[@]}"; do
  if stage_planned "${s}" && [[ -z "${BOARD}" ]]; then
    fatal "阶段 ${s} 需要板名，例如：scripts/build.sh e20c"
  fi
done

# --- 配置装载：build.conf → board.conf → env 派生 → 各阶段模块 --------------------
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/build.conf"
if [[ -n "${BOARD}" ]]; then
  BOARD_CONF="${PROJECT_ROOT}/boards/${BOARD}/board.conf"
  [[ -f "${BOARD_CONF}" ]] || fatal "板不存在：${BOARD}（缺 ${BOARD_CONF}）"
  # shellcheck source=/dev/null
  source "${BOARD_CONF}"
fi
for m in env deps sources overlay builder kernel iso aic8800 r8125 oled uboot image; do
  # shellcheck source=/dev/null
  source "${LIB_DIR}/${m}.sh"
done

# --- 计划摘要 -------------------------------------------------------------------
section "构建计划"
log "板:          ${BOARD:-<无（板无关阶段）>}"
[[ -n "${BOARD}" ]] && {
  log "SoC:         ${BOARD_SOC}（rkbin: ${RKBIN_TPL:-${RKBIN_TPL_GLOB}} + ${RKBIN_BL31:-${RKBIN_BL31_GLOB}}）"
  log "U-Boot:      ${BOARD_UBOOT_DEFCONFIG} @ ${UBOOT_REF}"
  log "串口:        ${BOARD_SERIAL_CONSOLE},${BOARD_SERIAL_BAUD}n8"
}
log "vyos-build:  ${VYOS_BUILD_REPO} ${VYOS_BUILD_REF:+(${VYOS_BUILD_REF})}"
log "内核:        $(resolved_kernel_version)（官方版本 + RK3528 片段）"
log "flavor:      ${FLAVOR}（arm64 ISO）"
log "阶段:        ${PLAN[*]}"

if [[ "${DRY_RUN}" == "1" ]]; then
  section "缓存状态（dry-run）"
  kernel_will_build=0
  if kernel_cache_fresh; then
    log "kernel: 已缓存且输入未变 → 跳过"
  elif compgen -G "$(kernel_deb_glob)" >/dev/null; then
    log "kernel: deb 在但补丁/片段有变 → 将自动重编"; kernel_will_build=1
  else
    log "kernel: 待构建"; kernel_will_build=1
  fi
  if [[ "${kernel_will_build}" == "0" ]] && iso_cache_fresh; then
    log "iso:    已缓存且内核/overlay 未变 → 跳过（$(current_iso)）"
  elif [[ -n "$(current_iso)" ]]; then
    log "iso:    在但内核 deb 较新或 flavor/hook 有变 → 将自动重建"
  else
    log "iso:    待构建"
  fi
  if [[ -n "${BOARD}" ]]; then
    [[ -f "${UBOOT_OUT_DIR}/u-boot-rockchip.bin" ]] \
      && log "uboot:  已缓存 → 跳过" || log "uboot:  待构建"
    stage_image
  fi
  log "dry-run 结束，未执行任何构建。"
  exit 0
fi

# --- 执行 -----------------------------------------------------------------------
for s in "${PLAN[@]}"; do "stage_${s}"; done

section "全部阶段完成"
