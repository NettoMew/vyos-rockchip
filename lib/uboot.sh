#!/usr/bin/env bash
# lib/uboot.sh — 主线 U-Boot 交叉编译（宿主机，aarch64-linux-gnu-）。
# rkbin 提供 DDR init（ROCKCHIP_TPL）与 BL31，产物为整合镜像 u-boot-rockchip.bin，
# 由 image 阶段 dd 到保留区 sector 64（与 alpine 项目同一套约定）。
#
# 板级 U-Boot 源注入 = 文件投放：boards/<board>/uboot/ 镜像 U-Boot 源码树结构，
# 构建前 rsync 进去（e20c 纯主线无此目录；m28k 的 DTS/defconfig 走这里）。

# 选 rkbin blob：显式覆盖（相对 rkbin 的路径）优先，否则按 glob 取版本最新。
rkbin_pick() {
  local override="$1" glob="$2"
  if [[ -n "${override}" ]]; then
    echo "${RKBIN_SRC}/${override}"
    return 0
  fi
  # shellcheck disable=SC2086
  ls -v ${RKBIN_SRC}/${glob} 2>/dev/null | tail -1
}

stage_uboot() {
  section "U-Boot（${BOARD}：${BOARD_UBOOT_DEFCONFIG}）"

  local artifact="${UBOOT_OUT_DIR}/u-boot-rockchip.bin"
  if [[ "${REBUILD_UBOOT:-0}" != "1" && -f "${artifact}" ]]; then
    log "U-Boot 产物已存在，跳过（REBUILD_UBOOT=1 强制重编）：${artifact}"
    return 0
  fi

  local bl31 tpl
  bl31="$(rkbin_pick "${RKBIN_BL31:-}" "${RKBIN_BL31_GLOB}")"
  tpl="$(rkbin_pick "${RKBIN_TPL:-}" "${RKBIN_TPL_GLOB}")"
  [[ -f "${bl31}" ]] || [[ "${DRY_RUN:-0}" == "1" ]] \
    || fatal "BL31 缺失（glob: ${RKBIN_BL31_GLOB}）：${RKBIN_SRC}"
  [[ -f "${tpl}" ]] || [[ "${DRY_RUN:-0}" == "1" ]] \
    || fatal "DDR TPL 缺失（glob: ${RKBIN_TPL_GLOB}）：${RKBIN_SRC}"
  log "rkbin blob：$(basename "${tpl:-?}") + $(basename "${bl31:-?}")"

  # 源码树复位 + 当前板的源注入（保证板间互不渗漏）。boots/<b>/uboot/ 是镜像 U-Boot 源
  # 树结构的“文件覆盖”（m28k 的 DTS/defconfig 走这里），但其下 patches/ 子目录是“补丁库”
  # 非源覆盖 —— rsync 排除它，避免把补丁文件复制进 U-Boot 树（补丁由下方 git apply 应用）。
  run git -C "${UBOOT_SRC}" checkout -- .
  run git -C "${UBOOT_SRC}" clean -fdq
  if [[ -d "${BOARDS_DIR}/${BOARD}/uboot" ]]; then
    log "注入板级 U-Boot 源：boards/${BOARD}/uboot/（排除 patches/）"
    run rsync -a --exclude='patches/' "${BOARDS_DIR}/${BOARD}/uboot/" "${UBOOT_SRC}/"
  fi

  # RK3582 开核（feature-flag 门控，与 lib/r8125.sh 的 BOARD_R8125 同构）：默认开。
  # 砍核全发生在 U-Boot ft_system_setup()（读 OTP 后套市场分级策略）；补丁把三段分级
  # 策略 #if 0 掉，放出 efuse 实测为好的核 + GPU，保留 OTP 对单颗真坏核的屏蔽。真 RK3588S2
  # 上 cpu-code≠0x3582 → 空操作。boards/<b>/uboot/patches/*.patch 按 ls 序 git apply
  # （与 vyos-build 内核 patches/*.patch glob 同构；e20c/m28k 无此目录则跳过）。
  if [[ "${BOARD_UNLOCK_CORES:-0}" == "1" ]]; then
    local pdir="${BOARDS_DIR}/${BOARD}/uboot/patches" p
    [[ -d "${pdir}" ]] || fatal "BOARD_UNLOCK_CORES=1 但缺补丁目录：${pdir}"
    for p in $(ls -v "${pdir}"/*.patch 2>/dev/null); do
      log "开核：git apply $(basename "${p}")"
      run git -C "${UBOOT_SRC}" apply "${p}"
    done
  fi

  run make -C "${UBOOT_SRC}" mrproper
  run make -C "${UBOOT_SRC}" "${BOARD_UBOOT_DEFCONFIG}"
  run make -C "${UBOOT_SRC}" -j"${JOBS}" CROSS_COMPILE=aarch64-linux-gnu- \
    BL31="${bl31}" ROCKCHIP_TPL="${tpl}"

  [[ -f "${UBOOT_SRC}/u-boot-rockchip.bin" ]] || [[ "${DRY_RUN:-0}" == "1" ]] \
    || fatal "U-Boot 构建结束但缺 u-boot-rockchip.bin"
  run install -Dm644 "${UBOOT_SRC}/u-boot-rockchip.bin" "${artifact}"
  log "U-Boot 产物：${artifact}"
}
