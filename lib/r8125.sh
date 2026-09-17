#!/usr/bin/env bash
# lib/r8125.sh — Realtek 官方 r8125 2.5G 网卡驱动 out-of-tree 集成（stage_r8125）。
#
# NanoPi R5S / Radxa E52C 的 2.5G 口使用 Realtek 官方 r8125。
# 内核补丁 150 已把 RTL8125 的 PCI ID 从 r8169
# 的表里摘掉 → r8125 独占绑定，无 driver_override / 解绑重绑竞态。
#
# 机制与 lib/aic8800.sh 完全同构（同一棵 cross 内核树编译 + 内核 key 签名 + 产到
# BOARD_ASSETS_DIR，C2 下由 image 阶段 host 侧注入 squashfs + depmod），故必须在
# kernel 阶段之后、且 KERNEL_BUILD_MODE=cross（container 模式无宿主侧内核树/Module.symvers）。
#
# 仅 BOARD_R8125=1 的板启用（R5S / E52C）；RK3528 板无 RTL8125，跳过。
# 无需固件文件：Makefile ENABLE_USE_FIRMWARE_FILE=n，PHY 固件已内置驱动。

# 官方原包随源码树保存；自定义来源必须同时覆盖 URL 和 SHA256。
if [[ -z "${R8125_SOURCE_URL+x}" && -z "${R8125_SOURCE_SHA256+x}" ]]; then
  R8125_SOURCE_URL="file://${PROJECT_ROOT}/vendor/r8125/r8125-9.018.00.tar.bz2"
  R8125_SOURCE_SHA256="66291cb5d4d3b359cfa0c9ca902028d9ce0f76065887cb64b4052dce4a676ff8"
else
  R8125_SOURCE_URL="${R8125_SOURCE_URL-}"
  R8125_SOURCE_SHA256="${R8125_SOURCE_SHA256-}"
fi

r8125_prepare_source() {
  run mkdir -p "${WORK_DIR}/src"
  [[ -n "${R8125_SOURCE_URL}" && "${R8125_SOURCE_SHA256}" =~ ^[0-9a-f]{64}$ ]] \
    || fatal "R8125_SOURCE_URL 与 64 位小写 R8125_SOURCE_SHA256 必须同时提供"
  local archive="${WORK_DIR}/src/r8125-${R8125_SOURCE_SHA256}.tar.bz2"
  if [[ ! -f "${archive}" ]]; then
    if [[ "${R8125_SOURCE_URL}" == file://* ]]; then
      run cp "${R8125_SOURCE_URL#file://}" "${archive}.tmp" || fatal "r8125 本地原包读取失败"
    else
      [[ "${SKIP_FETCH:-0}" != "1" ]] || fatal "SKIP_FETCH=1 但 r8125 官方原包缓存缺失"
      run curl --fail --location --output "${archive}.tmp" "${R8125_SOURCE_URL}" \
        || fatal "r8125 原包下载失败"
    fi
    printf '%s  %s\n' "${R8125_SOURCE_SHA256}" "${archive}.tmp" | sha256sum -c - \
      || fatal "r8125 原包 SHA256 不匹配"
    run mv "${archive}.tmp" "${archive}"
  fi
  printf '%s  %s\n' "${R8125_SOURCE_SHA256}" "${archive}" | sha256sum -c - \
    || fatal "r8125 缓存原包 SHA256 不匹配"
  # 只接受单根目录、普通文件和目录，拒绝路径穿越及链接后再解包。
  python3 - "${archive}" <<'PY' || fatal "r8125 原包目录结构不安全"
import pathlib
import sys
import tarfile

with tarfile.open(sys.argv[1], 'r:bz2') as archive:
    roots = set()
    for member in archive:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not path.parts:
            raise ValueError('invalid archive path')
        if not (member.isfile() or member.isdir()):
            raise ValueError('archive links and special files are not supported')
        roots.add(path.parts[0])
    if len(roots) != 1:
        raise ValueError('expected one archive root directory')
PY
  R8125_SRC="${WORK_DIR}/src/r8125-${R8125_SOURCE_SHA256}"
  run rm -rf "${R8125_SRC}"
  run mkdir -p "${R8125_SRC}"
  run tar -xjf "${archive}" -C "${R8125_SRC}" --strip-components=1 \
    || fatal "r8125 原包解包失败"
  R8125_BUILD_DIR="${R8125_SRC}/src"
  [[ -f "${R8125_BUILD_DIR}/Makefile" && -f "${R8125_BUILD_DIR}/r8125_n.c" ]] \
    || fatal "r8125 原包缺少 src/Makefile 或 src/r8125_n.c"
}

stage_r8125() {
  if [[ "${BOARD_R8125:-0}" != "1" ]]; then
    log "本板无 RTL8125（BOARD_R8125≠1），跳过 r8125 驱动"
    return 0
  fi
  local kv krel kdir
  kv="$(resolved_kernel_version)"
  kdir="${WORK_DIR}/kernel/linux-${kv}"
  section "RTL8125 2.5G 网卡驱动（r8125：编译 + 签名 + 投放）"

  [[ "${DRY_RUN:-0}" == "1" ]] && { log "dry-run：校验 r8125 原包 ${R8125_SOURCE_URL}（SHA256=${R8125_SOURCE_SHA256}）→ src/ 编模块 → 签名 → board-assets"; return 0; }
  [[ -f "${kdir}/Module.symvers" ]] || fatal "内核树未编（${kdir} 缺 Module.symvers）；r8125 须在 kernel 阶段后，且 KERNEL_BUILD_MODE=cross"
  [[ -f "${kdir}/certs/signing_key.pem" ]] || fatal "内核 signing_key 缺失，无法签名模块（过不了 MODULE_SIG_FORCE）"

  # 1) 取源 + 板级补丁（如需对 6.18 适配，放 boards/r5s/r8125/*.patch；通常无需）
  r8125_prepare_source
  local p
  for p in "${BOARDS_DIR}/${BOARD}/r8125/"*.patch; do
    [[ -f "${p}" ]] || continue
    log "patch $(basename "${p}")"
    patch --batch --forward -d "${R8125_BUILD_DIR}" -p1 < "${p}" \
      || fatal "r8125 补丁失败：$(basename "${p}")"
  done

  # 2) 交叉编模块（M= 外部模块构建，obj-m := r8125.o；LOCALVERSION 对齐内核 vermagic）
  #    命令行赋值覆盖 Makefile 默认。9.018.00 的三个宏仅决定模块参数初值，
  #    并非删除功能；默认关闭省电，加载时仍可显式覆盖。不能据此认定历史掉线原因。
  #        CONFIG_ASPM=n        aspm 默认 0
  #        ENABLE_EEE=n         eee_enable 默认 0
  #        ENABLE_GIGA_LITE=n   enable_giga_lite 默认 0（旧 eee_giga_lite 已移除）
  #      性能——开硬件多队列（net-tune 的 IRQ 亲和/RPS 才有真队列可分核，否则单队列堆一核）：
  #        ENABLE_RSS_SUPPORT=y       硬件 RSS：多 RX 队列按流哈希分核（上限 RX4/TX2）
  #        ENABLE_MULTIPLE_TX_QUEUE=y 多 TX 队列，配合 RSS
  #    9.018 将 DASH/PAGE_REUSE 默认改为 y；显式保留旧版 n，避免同时换管理/收包路径。
  #    TX_NO_CLOSE/CONFIG_SOC_LAN 默认已 =y，无需重申。
  run make -C "${kdir}" M="${R8125_BUILD_DIR}" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    -j"${JOBS}" LOCALVERSION=-vyos \
    CONFIG_ASPM=n ENABLE_EEE=n ENABLE_GIGA_LITE=n \
    ENABLE_DASH_SUPPORT=n ENABLE_PAGE_REUSE=n \
    ENABLE_RSS_SUPPORT=y ENABLE_MULTIPLE_TX_QUEUE=y \
    modules
  local ko="${R8125_BUILD_DIR}/r8125.ko"
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
