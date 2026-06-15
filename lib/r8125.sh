#!/usr/bin/env bash
# lib/r8125.sh — Realtek 官方 r8125 2.5G 网卡驱动 out-of-tree 集成（stage_r8125）。
#
# NanoPi R5S 的两个 2.5G 口是 RTL8125B。主线 r8169 虽能驱动，但 OpenWrt 同款做法是
# 用 Realtek 官方 r8125（性能/特性更优）。内核补丁 150 已把 RTL8125 的 PCI ID 从 r8169
# 的表里摘掉 → r8125 独占绑定，无 driver_override / 解绑重绑竞态。
#
# 机制与 lib/aic8800.sh 完全同构（同一棵 cross 内核树编译 + 内核 key 签名 + 产到
# BOARD_ASSETS_DIR，C2 下由 image 阶段 host 侧注入 squashfs + depmod），故必须在
# kernel 阶段之后、且 KERNEL_BUILD_MODE=cross（container 模式无宿主侧内核树/Module.symvers）。
#
# 仅 BOARD_R8125=1 的板启用（R5S）；RK3528 板无 RTL8125，跳过。
# 无需固件文件：Makefile ENABLE_USE_FIRMWARE_FILE=n，PHY 固件已内置驱动。

R8125_REPO="${R8125_REPO:-https://github.com/openwrt/rtl8125.git}"
# openwrt/rtl8125 的 9.016.01 发布 tag（Realtek 官方 v9.016.01，对应 immortalwrt R5S 同款）
R8125_COMMIT="${R8125_COMMIT:-a9197034480767a78c4a87b4e4f4125e56a649e2}"
R8125_SRC="${WORK_DIR}/src/rtl8125"

stage_r8125() {
  if [[ "${BOARD_R8125:-0}" != "1" ]]; then
    log "本板无 RTL8125（BOARD_R8125≠1），跳过 r8125 驱动"
    return 0
  fi
  local kv krel kdir
  kv="$(resolved_kernel_version)"
  kdir="${WORK_DIR}/kernel/linux-${kv}"
  section "RTL8125 2.5G 网卡驱动（r8125：编译 + 签名 + 投放）"

  [[ "${DRY_RUN:-0}" == "1" ]] && { log "dry-run：clone openwrt/rtl8125 → 编 r8125.ko → 签 → includes.chroot + modules-load.d"; return 0; }
  [[ -f "${kdir}/Module.symvers" ]] || fatal "内核树未编（${kdir} 缺 Module.symvers）；r8125 须在 kernel 阶段后，且 KERNEL_BUILD_MODE=cross"
  [[ -f "${kdir}/certs/signing_key.pem" ]] || fatal "内核 signing_key 缺失，无法签名模块（过不了 MODULE_SIG_FORCE）"

  # 1) 取源 + 板级补丁（如需对 6.18 适配，放 boards/r5s/r8125/*.patch；通常无需）
  run mkdir -p "${WORK_DIR}/src"
  if [[ ! -d "${R8125_SRC}/.git" ]]; then
    [[ "${SKIP_FETCH:-0}" == "1" ]] && fatal "SKIP_FETCH=1 但 rtl8125 源缺失"
    run git clone --filter=blob:none "${R8125_REPO}" "${R8125_SRC}"
  fi
  run git -C "${R8125_SRC}" checkout -q "${R8125_COMMIT}"
  run git -C "${R8125_SRC}" checkout -- .
  local p
  for p in "${BOARDS_DIR}/${BOARD}/r8125/"*.patch; do
    [[ -f "${p}" ]] || continue
    log "git apply $(basename "${p}")"
    git -C "${R8125_SRC}" apply "${p}" || fatal "r8125 补丁失败：$(basename "${p}")"
  done

  # 2) 交叉编模块（M= 外部模块构建，obj-m := r8125.o；LOCALVERSION 对齐内核 vermagic）
  #    特性 flag（命令行赋值覆盖 Makefile 内默认；与 immortalwrt 的 r8125 包同版本同取舍）：
  #      防链路闪断（issue #1，RTL8125+RK35xx 真机栽过）——三个省电特性全编关：
  #        CONFIG_ASPM=n        PCIe L1 ASPM（编译期去路径，比运行期 aspm=0 更彻底，immortalwrt 同款）
  #        ENABLE_EEE=n         802.3az EEE（节能以太网，掉线重训元凶）
  #        ENABLE_GIGA_LITE=n   RTL8125 私有 2.5G EEE-lite（ethtool --show-eee 看不到的隐藏元凶）
  #      性能——开硬件多队列（net-tune 的 IRQ 亲和/RPS 才有真队列可分核，否则单队列堆一核）：
  #        ENABLE_RSS_SUPPORT=y       硬件 RSS：多 RX 队列按流哈希分核（上限 RX4/TX2）
  #        ENABLE_MULTIPLE_TX_QUEUE=y 多 TX 队列，配合 RSS
  #    其余特性（TX_NO_CLOSE/CONFIG_SOC_LAN）Makefile 默认已 =y，无需重申。
  run make -C "${kdir}" M="${R8125_SRC}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    -j"${JOBS}" LOCALVERSION=-vyos \
    CONFIG_ASPM=n ENABLE_EEE=n ENABLE_GIGA_LITE=n \
    ENABLE_RSS_SUPPORT=y ENABLE_MULTIPLE_TX_QUEUE=y \
    modules
  local ko="${R8125_SRC}/r8125.ko"
  [[ -f "${ko}" ]] || [[ "${DRY_RUN:-0}" == "1" ]] || fatal "r8125.ko 未编出"

  # 3) 签名（内核 signing_key + sha512，过 MODULE_SIG_FORCE）
  krel="$(make -s -C "${kdir}" LOCALVERSION=-vyos kernelrelease)"
  run "${kdir}/scripts/sign-file" sha512 \
    "${kdir}/certs/signing_key.pem" "${kdir}/certs/signing_key.x509" "${ko}"

  # 4) 投放板级资产暂存（C2：仅本板，image 阶段 host 侧注入 squashfs）：模块 + 开机加载
  local inc="${BOARD_ASSETS_DIR}"
  run rm -rf "${inc}/lib/modules/${krel}/updates/r8125"
  run mkdir -p "${inc}/lib/modules/${krel}/updates/r8125" "${inc}/etc/modules-load.d"
  run cp "${ko}" "${inc}/lib/modules/${krel}/updates/r8125/"
  printf 'r8125\n' > "${inc}/etc/modules-load.d/r8125.conf"
  log "r8125 模块(已签)+modules-load.d → ${inc}（krel=${krel}）。image 阶段注入并 depmod。"
}
