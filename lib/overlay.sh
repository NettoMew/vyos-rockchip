#!/usr/bin/env bash
# lib/overlay.sh — 把本项目对 vyos-build 的全部定制以文件投放方式落进 work 树。
#
# 两层 overlay，路径即语义（镜像 vyos-build 的目录结构，rsync 原样覆盖）：
#   overlay/                  全局定制（flavor、RK3528 内核片段）
#   boards/*/overlay/         板级定制（如 m28k 的内核 DTS/补丁）
#
# 注意是 boards/*（全部板）而非仅当前板：RK3528 家族共享一个内核/一张 ISO，
# 所有板的内核侧资产必须同时在场（与主线"一个内核带全部 DTB"同构）。
# 板间天然正交：m28k 的 DTS 补丁对 e20c 无副作用。
#
# 内核注入零引擎改动的原理（vyos-build 自身的 glob 机制）：
#   scripts/package-build/linux-kernel/config/*.config        自动 merge
#   scripts/package-build/linux-kernel/patches/kernel/*.patch 自动应用

stage_overlay() {
  section "投放 overlay 到 work/vyos-build"
  [[ -d "${VYOS_BUILD_TREE}" ]] || fatal "work 树缺失，先跑 sources 阶段"

  run rsync -a "${OVERLAY_DIR}/" "${VYOS_BUILD_TREE}/"

  local b
  for b in "${BOARDS_DIR}"/*/overlay; do
    [[ -d "${b}" ]] || continue
    log "板级 overlay：$(basename "$(dirname "${b}")")"
    run rsync -a "${b}/" "${VYOS_BUILD_TREE}/"
  done

  # C2：base ISO 必须板无关。清掉历史（pre-C2）可能遗留在 work 树里的板级注入——
  # 那时 aic8800/r8125/oled 阶段把 .ko/固件/oled deb 写进了共享 includes.chroot/packages，
  # 不清的话 base ISO 会再次把它们打进去（前功尽弃）。现在这些资产只去 board-assets/。
  local inc="${VYOS_BUILD_TREE}/data/live-build-config/includes.chroot"
  run rm -rf "${inc}"/lib/modules/*/updates
  run rm -f  "${inc}"/etc/modules-load.d/aic8800.conf "${inc}"/etc/modules-load.d/r8125.conf
  run rm -rf "${inc}"/lib/firmware/aic8800
  run rm -f  "${inc}"/usr/bin/oled-dash "${inc}"/lib/systemd/system/oled-dash.service
  run rm -f  "${VYOS_BUILD_TREE}/packages/"vyos-oled-dash_*.deb
}
