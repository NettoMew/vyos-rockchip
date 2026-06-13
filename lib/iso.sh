#!/usr/bin/env bash
# lib/iso.sh — 构建 arm64 generic ISO（容器内，官方 build-vyos-image + 本项目
# rockchip flavor）。ISO 是板无关的中间产物：里面的 filesystem.squashfs 同时
# 服务全部 RK3528 板，由 image 阶段按板组装成可烧录镜像。
#
# 产物归档到 work/iso/ 并记录于 state（work 树内的 build/ 会被下次 make clean 清掉）。

# base ISO（板无关）的内容指纹：只看会进 base 的 overlay（flavor toml、live-build
# hooks、includes）+ 板级 overlay（kernel 补丁/DTS、可能的共享 includes）。
# C2 起板级驱动资产（aic8800/r8125/oled）不再进 base ISO，改 image 阶段 host 侧注入，
# 故不纳入此指纹（它们的变化由 image 阶段每次重新注入接住）。
iso_overlay_digest() {
  { find "${OVERLAY_DIR}" "${BOARDS_DIR}"/*/overlay -type f -print0 2>/dev/null \
      | sort -z | xargs -0 sha256sum 2>/dev/null; } | sha256sum | cut -d' ' -f1
}
iso_overlay_stamp() { echo "${STATE_DIR}/iso-overlay.sha256"; }

# ISO 缓存有效 = 存在 AND 不比内核 deb 旧 AND overlay 定制指纹未变。
iso_cache_fresh() {
  local existing deb
  existing="$(current_iso)"
  [[ -n "${existing}" ]] || return 1
  for deb in $(kernel_deb_glob); do
    [[ -f "${deb}" && "${deb}" -nt "${existing}" ]] && return 1
  done
  [[ -f "$(iso_overlay_stamp)" ]] || return 1
  [[ "$(cat "$(iso_overlay_stamp)")" == "$(iso_overlay_digest)" ]]
}

stage_iso() {
  section "VyOS arm64 ISO（flavor: ${FLAVOR}）"

  if [[ "${REBUILD_ISO:-0}" != "1" ]]; then
    if iso_cache_fresh; then
      log "ISO 已存在且内核未变，跳过（REBUILD_ISO=1 强制重建）：$(current_iso)"
      return 0
    elif [[ -n "$(current_iso)" ]]; then
      log "ISO 存在但内核 deb 更新过 → 自动重建"
    fi
  fi

  # 内核 deb 必须就位，否则 ISO 会装上官方通用内核（缺 RK3528 驱动，无法启动）
  compgen -G "$(kernel_deb_glob)" >/dev/null \
    || { [[ "${DRY_RUN:-0}" == "1" ]] || fatal "packages/ 缺内核 deb，先跑 kernel 阶段"; }

  local version="${VYOS_VERSION:-$(date +%Y.%m.%d-%H%M)-rockchip}"
  log "版本：${version}（构建者 ${BUILD_BY}）"

  # --build-type release：默认的 development 会塞 gdb/strace/vim + vyos-1x-smoketest，
  # 后者 postinst 会拉测试容器（docker blob），网络抖动即 EOF→postinst 退 1→lb build 失败；
  # 且 smoketest 对路由成品镜像无用。release 只多一段 EULA includes，干净、更瘦。
  builder_exec "
    make clean >/dev/null 2>&1 || true
    ./build-vyos-image --version '${version}' --build-by '${BUILD_BY}' --build-type release ${FLAVOR}
  "

  local iso
  iso="$(ls -t "${VYOS_BUILD_TREE}/build/"vyos-*-"${FLAVOR}"-arm64.iso 2>/dev/null | head -1)"
  if [[ -z "${iso}" ]]; then
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    fatal "build/ 下找不到 vyos-*-${FLAVOR}-arm64.iso"
  fi

  run cp --reflink=auto "${iso}" "${ISO_KEEP_DIR}/"
  run mkdir -p "${STATE_DIR}"
  echo "${ISO_KEEP_DIR}/$(basename "${iso}")" > "$(iso_state_file)"
  iso_overlay_digest > "$(iso_overlay_stamp)"
  log "ISO 归档：${ISO_KEEP_DIR}/$(basename "${iso}")"
}
