#!/usr/bin/env bash
# lib/env.sh — 在 build.conf 与 boards/<board>/board.conf 之后 source，
# 派生全部路径/全局量。board 可为空（只跑板无关阶段时）。

# --- 路径 ----------------------------------------------------------------------
WORK_DIR="${WORK_DIR:-${PROJECT_ROOT}/work}"
OUT_DIR="${OUT_DIR:-${PROJECT_ROOT}/out}"
STATE_DIR="${WORK_DIR}/state"
MNT_DIR="${WORK_DIR}/mnt"

VYOS_BUILD_TREE="${WORK_DIR}/vyos-build"
UBOOT_SRC="${WORK_DIR}/src/u-boot"
RKBIN_SRC="${WORK_DIR}/src/rkbin"
ISO_KEEP_DIR="${WORK_DIR}/iso"

OVERLAY_DIR="${PROJECT_ROOT}/overlay"
BOARDS_DIR="${PROJECT_ROOT}/boards"
RESOURCES_DIR="${PROJECT_ROOT}/resources"

# 构建 flavor 名 = overlay/data/build-flavors/rockchip.toml
FLAVOR="${FLAVOR:-rockchip}"

# --- vyos-build 克隆来源自动探测 -------------------------------------------------
if [[ -z "${VYOS_BUILD_REPO}" ]]; then
  local_sibling="$(cd "${PROJECT_ROOT}/../.." 2>/dev/null && pwd)/vyos-build"
  if [[ -d "${local_sibling}/.git" ]]; then
    VYOS_BUILD_REPO="${local_sibling}"
  else
    VYOS_BUILD_REPO="https://github.com/vyos/vyos-build"
  fi
  unset local_sibling
fi

# --- 板级派生（BOARD 为空则跳过）-------------------------------------------------
if [[ -n "${BOARD:-}" ]]; then
  : "${BOARD_SOC:?board.conf 必须设置 BOARD_SOC}"
  : "${BOARD_UBOOT_DEFCONFIG:?board.conf 必须设置 BOARD_UBOOT_DEFCONFIG}"
  : "${BOARD_IMAGE_PREFIX:?board.conf 必须设置 BOARD_IMAGE_PREFIX}"
  BOARD_SERIAL_CONSOLE="${BOARD_SERIAL_CONSOLE:-ttyS0}"
  BOARD_SERIAL_BAUD="${BOARD_SERIAL_BAUD:-1500000}"

  # ttyS0 → CONSOLE_TYPE=ttyS CONSOLE_NUM=0（VyOS grub 变量按此拆分）
  CONSOLE_TYPE="${BOARD_SERIAL_CONSOLE%%[0-9]*}"
  CONSOLE_NUM="${BOARD_SERIAL_CONSOLE#"${CONSOLE_TYPE}"}"

  UBOOT_OUT_DIR="${WORK_DIR}/uboot/${BOARD}"

  # 板级资产暂存（C2）：aic8800/r8125/oled 阶段把"该板专属"的内核模块/固件/二进制/
  # modules-load.d 产到这里（镜像 rootfs 目录结构），image 阶段 host 侧解包 base
  # squashfs 后只注入本板这一份 → 每板镜像只带自己的资产，base ISO 保持板无关。
  BOARD_ASSETS_DIR="${WORK_DIR}/board-assets/${BOARD}"

  # 每板 ISO 中转（imgiso 阶段）：image 阶段把"注入本板资产后的 squashfs"（+ DTB
  # override 板的内核 DTB）落到这里，imgiso 阶段拿它换进 base ISO 的 live/，remaster
  # 成可被 VyOS `add system image` 原地升级的每板 ISO。
  BOARD_ISO_DIR="${WORK_DIR}/board-iso/${BOARD}"

  # SoC → rkbin blob 选择模式。rkbin master 滚版本时会直接替换旧文件，钉死
  # 文件名必碎；按 glob 取版本号最新的一个（uboot.sh 解析），RKBIN_BL31/RKBIN_TPL
  # 可显式覆盖成 rkbin 内的相对路径。
  case "${BOARD_SOC}" in
    rk3528)
      RKBIN_BL31_GLOB="${RKBIN_BL31_GLOB:-bin/rk35/rk3528_bl31_v*.elf}"
      RKBIN_TPL_GLOB="${RKBIN_TPL_GLOB:-bin/rk35/rk3528_ddr_1056MHz_v*.bin}"
      ;;
    rk3568)
      RKBIN_BL31_GLOB="${RKBIN_BL31_GLOB:-bin/rk35/rk3568_bl31_v*.elf}"
      RKBIN_TPL_GLOB="${RKBIN_TPL_GLOB:-bin/rk35/rk3568_ddr_1056MHz_v*.bin}"
      ;;
    rk3588)
      # RK3582（E52C）= RK3588S 残核 bin，boot 等同 rk3588s，用 rk3588 blob。
      # DDR 选 lp4_2112MHz/lp5_2400MHz（rkbin 同一 blob 覆盖 LPDDR4/4X/5、按板载颗粒
      # 自适应）；BL31 取版本最新（v1.54）。RKBIN_TPL 可在 board.conf 显式覆盖到其他频点。
      RKBIN_BL31_GLOB="${RKBIN_BL31_GLOB:-bin/rk35/rk3588_bl31_v*.elf}"
      RKBIN_TPL_GLOB="${RKBIN_TPL_GLOB:-bin/rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v*.bin}"
      ;;
    *) fatal "未知 BOARD_SOC=${BOARD_SOC}（lib/env.sh 的 case 里加一条即可）" ;;
  esac
fi

# --- 运行时解析（fetch 后才有值）--------------------------------------------------
resolved_kernel_version() {
  # 内核版本以 work 树里的 defaults.toml 为准（与官方包生态严格一致）
  [[ -f "${VYOS_BUILD_TREE}/data/defaults.toml" ]] || { echo "<unresolved>"; return; }
  awk -F'"' '/^kernel_version/ {print $2; exit}' "${VYOS_BUILD_TREE}/data/defaults.toml"
}

kernel_deb_glob() {
  local kv; kv="$(resolved_kernel_version)"
  echo "${VYOS_BUILD_TREE}/packages/linux-image-${kv}-vyos_*_arm64.deb"
}

iso_state_file() { echo "${STATE_DIR}/iso-path"; }

current_iso() {
  # 最近一次成功构建并归档的 ISO；不存在返回空
  local f; f="$(iso_state_file)"
  [[ -f "${f}" ]] || return 0
  local p; p="$(cat "${f}")"
  [[ -f "${p}" ]] && echo "${p}"
}
