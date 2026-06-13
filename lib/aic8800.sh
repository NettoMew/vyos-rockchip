#!/usr/bin/env bash
# lib/aic8800.sh — AIC8800 SDIO Wi-Fi out-of-tree 驱动集成（stage_aic8800）。
#
# 必须在 kernel 阶段之后跑：要用同一棵已编译的 work/kernel 树（Module.symvers +
# certs/signing_key.pem），这样模块的 symbol CRC 与签名都和内核 deb 匹配，能过
# MODULE_SIG_FORCE。流程：clone radxa 驱动 → apply 0001(7.1 port)+0002(6.18 适配)
# → 交叉编模块（LOCALVERSION=-vyos 对齐 vermagic；SDIO wifi-only，CONFIG_SDIO_BT=n
# 因 D80 的 BT bringup 会 hang 见 0001 注释）→ sign-file 签名 → 模块/固件/
# modules-load.d 产到 BOARD_ASSETS_DIR（C2：仅本板，image 阶段 host 侧 unsquashfs
# 后注入 squashfs 并 depmod，base ISO 不含 → e20c/r5s 不再误载 aic8800）。
# 仅 BOARD_WIFI_AIC8800=1 的板启用。
#
# 真机验证（2026-06-13，m28k）：开机 systemd-modules-load 早期加载 aic8800_bsp+
# aic8800_fdrv → 固件 fmacfw_8800d80_u02.bin 下载成功 → wlan0 up。注意：运行时
# 手动 insmod 会 -110（SDIO 已 idle），必须开机早期加载，故走 modules-load.d。

AIC8800_REPO="${AIC8800_REPO:-https://github.com/radxa-pkg/aic8800.git}"
AIC8800_COMMIT="${AIC8800_COMMIT:-89f865b80f5f2ba6c0711c560e1d0191e87a1bf0}"
AIC8800_SRC="${WORK_DIR}/src/aic8800"
AIC8800_DRV_SUBDIR="src/SDIO/driver_fw/driver/aic8800"
AIC8800_FW_SUBDIR="src/SDIO/driver_fw/fw"
AIC8800_FW_DEST="/lib/firmware/aic8800/sdio"

stage_aic8800() {
  if [[ "${BOARD_WIFI_AIC8800:-0}" != "1" ]]; then
    log "本板无 AIC8800（BOARD_WIFI_AIC8800≠1），跳过 Wi-Fi 驱动"
    return 0
  fi
  local kv krel kdir
  kv="$(resolved_kernel_version)"
  kdir="${WORK_DIR}/kernel/linux-${kv}"
  section "AIC8800 Wi-Fi 驱动（SDIO：编译 + 签名 + 投放）"

  [[ "${DRY_RUN:-0}" == "1" ]] && { log "dry-run：clone aic8800 → 编模块 → 签 → includes.chroot"; return 0; }
  [[ -f "${kdir}/Module.symvers" ]] || fatal "内核树未编（${kdir} 缺 Module.symvers）；aic8800 必须在 kernel 阶段后"
  [[ -f "${kdir}/certs/signing_key.pem" ]] || fatal "内核 signing_key 缺失，无法签名模块（过不了 MODULE_SIG_FORCE）"

  # 1) 取源 + 补丁（0001 port + 0002 6.18 适配）
  run mkdir -p "${WORK_DIR}/src"
  if [[ ! -d "${AIC8800_SRC}/.git" ]]; then
    [[ "${SKIP_FETCH:-0}" == "1" ]] && fatal "SKIP_FETCH=1 但 aic8800 源缺失"
    run git clone --filter=blob:none "${AIC8800_REPO}" "${AIC8800_SRC}"
  fi
  run git -C "${AIC8800_SRC}" checkout -q "${AIC8800_COMMIT}"
  run git -C "${AIC8800_SRC}" checkout -- .
  local p
  for p in "${BOARDS_DIR}/${BOARD}/aic8800/"*.patch; do
    [[ -f "${p}" ]] || continue
    log "git apply $(basename "${p}")"
    git -C "${AIC8800_SRC}" apply "${p}" || fatal "aic8800 补丁失败：$(basename "${p}")"
  done

  # 2) 交叉编模块（LOCALVERSION=-vyos 对齐内核 vermagic；wifi-only）
  local drv="${AIC8800_SRC}/${AIC8800_DRV_SUBDIR}"
  run make -C "${kdir}" M="${drv}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"${JOBS}" \
    LOCALVERSION=-vyos CONFIG_SDIO_BT=n CONFIG_AIC8800_BTLPM_SUPPORT=n \
    CONFIG_AIC_FW_PATH="\"${AIC8800_FW_DEST}\"" modules
  local bsp="${drv}/aic8800_bsp/aic8800_bsp.ko" fdrv="${drv}/aic8800_fdrv/aic8800_fdrv.ko"
  [[ -f "${bsp}" && -f "${fdrv}" ]] || [[ "${DRY_RUN:-0}" == "1" ]] || fatal "aic8800 .ko 未编出"

  # 3) 签名（内核 signing_key + sha512，过 MODULE_SIG_FORCE）
  krel="$(make -s -C "${kdir}" LOCALVERSION=-vyos kernelrelease)"
  local ko
  for ko in "${bsp}" "${fdrv}"; do
    run "${kdir}/scripts/sign-file" sha512 \
      "${kdir}/certs/signing_key.pem" "${kdir}/certs/signing_key.x509" "${ko}"
  done

  # 4) 投放板级资产暂存（C2：仅本板，image 阶段 host 侧注入 squashfs）：模块+固件+开机加载
  local inc="${BOARD_ASSETS_DIR}"
  run rm -rf "${inc}/lib/modules/${krel}/updates/aic8800" "${inc}${AIC8800_FW_DEST}"
  run mkdir -p "${inc}/lib/modules/${krel}/updates/aic8800" "${inc}${AIC8800_FW_DEST}" "${inc}/etc/modules-load.d"
  run cp "${bsp}" "${fdrv}" "${inc}/lib/modules/${krel}/updates/aic8800/"
  local d
  for d in "${AIC8800_SRC}/${AIC8800_FW_SUBDIR}"/*/; do
    [[ -d "${d}" ]] && run cp -a "${d}"* "${inc}${AIC8800_FW_DEST}/" 2>/dev/null || true
  done
  printf 'aic8800_bsp\naic8800_fdrv\n' > "${WORK_DIR}/aic8800-modload.conf"
  run cp "${WORK_DIR}/aic8800-modload.conf" "${inc}/etc/modules-load.d/aic8800.conf"
  log "AIC8800 模块(已签)+固件+modules-load.d → ${inc}（krel=${krel}）。image 阶段注入并 depmod。"
}
