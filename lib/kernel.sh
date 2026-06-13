#!/usr/bin/env bash
# lib/kernel.sh — VyOS 内核 deb 构建，两种模式（KERNEL_BUILD_MODE 选择）：
#
#   container（默认）：官方 package-build/linux-kernel 流程原样在 arm64 容器里跑
#                      （qemu 仿真，慢但与官方构建环境零差异）。
#   cross            ：宿主机交叉编译（aarch64-linux-gnu-，快一个量级）。复刻官方
#                      build-kernel.sh 的语义——同一份补丁目录（ls 序）、同一组
#                      config 片段（merge_config.sh）、同样的证书链与包版本号，
#                      产物 deb 同名同版本。两点有意差异：① 不带 BUILD_TOOLS=1
#                      （perf 包镜像不装，且其 arm64 并行构建有竞态）；② headers
#                      包里的宿主脚本是 x86 的（镜像只装 linux-image，无感）。
#
# 板级注入对两种模式一视同仁：overlay 投放进 work 树的 config/*.config 与
# patches/kernel/*.patch 都是数据，两条路径消费同一份。
#
# 产物 deb 进 vyos-build/packages/ → build-vyos-image 当 packages.chroot 直装，
# 压过仓库同名内核包。只搬 linux-image 本体（dbg/headers 绝不能进镜像）。

# 内核输入指纹：补丁目录 + 全部 config 片段（overlay 投放后的 work 树为准）。
# 板级补丁/片段一变指纹就变 → 自动重编，杜绝"旧 deb 不含新板 DTS"这类脚枪。
kernel_inputs_digest() {
  local lkdir="${VYOS_BUILD_TREE}/scripts/package-build/linux-kernel"
  { cat "${lkdir}/config/arm64/vyos_defconfig" \
        "${lkdir}/config/"*.config \
        "${lkdir}/patches/kernel/"* 2>/dev/null; } | sha256sum | cut -d' ' -f1
}

kernel_stamp_file() { echo "${STATE_DIR}/kernel-inputs.sha256"; }

# deb 在且输入指纹未变 → 缓存有效
kernel_cache_fresh() {
  compgen -G "$(kernel_deb_glob)" >/dev/null || return 1
  [[ -f "$(kernel_stamp_file)" ]] || return 1
  [[ "$(cat "$(kernel_stamp_file)")" == "$(kernel_inputs_digest)" ]]
}

stage_kernel() {
  local kv; kv="$(resolved_kernel_version)"
  local mode="${KERNEL_BUILD_MODE:-container}"
  section "VyOS 内核 deb（${kv}，arm64，模式：${mode}）"

  if [[ "${REBUILD_KERNEL:-0}" != "1" ]]; then
    if kernel_cache_fresh; then
      log "内核 deb 已存在且输入未变，跳过（REBUILD_KERNEL=1 强制重编）：$(ls $(kernel_deb_glob))"
      return 0
    elif compgen -G "$(kernel_deb_glob)" >/dev/null; then
      log "内核 deb 存在但补丁/配置片段已变化 → 自动重编"
      REBUILD_KERNEL=1
    fi
  fi

  case "${mode}" in
    container) kernel_build_container "${kv}" ;;
    cross)     kernel_build_cross "${kv}" ;;
    *)         fatal "未知 KERNEL_BUILD_MODE=${mode}（可选：container、cross）" ;;
  esac

  if [[ "${DRY_RUN:-0}" != "1" ]]; then
    compgen -G "$(kernel_deb_glob)" >/dev/null \
      || fatal "内核构建结束但 packages/ 下没有预期的 deb"
    run mkdir -p "${STATE_DIR}"
    kernel_inputs_digest > "$(kernel_stamp_file)"
  fi
}

# --- 模式一：官方流程进容器 ------------------------------------------------------
kernel_build_container() {
  if [[ "${REBUILD_KERNEL:-0}" == "1" ]]; then
    log "REBUILD_KERNEL=1：清理上次的内核源与 deb（容器内执行，规避 root 属主）"
    builder_exec 'rm -rf scripts/package-build/linux-kernel/linux-* \
                         scripts/package-build/linux-kernel/*.deb \
                         packages/linux-*.deb'
  fi

  # build.py 允许失败：官方 bindeb-pkg 带 BUILD_TOOLS=1，6.18 的 tools/perf 在
  # arm64 上有并行构建竞态，常在 linux-image deb 已产出后才炸掉 perf 包——
  # 我们不需要 perf，以 deb 是否落盘为准。glob 的 `-vyos_` 天然排除 -vyos-dbg_。
  builder_exec '
    cd scripts/package-build/linux-kernel
    ./build.py --packages linux-kernel || echo "W: build.py 非零退出（多半是 perf），以 deb 落盘为准"
    mkdir -p /vyos/packages
    mv -v linux-image-*-vyos_*_arm64.deb /vyos/packages/
  '
}

# --- 模式二：宿主机交叉编译 ------------------------------------------------------
# 6.18 起 kbuild 的 debian/rules 全面 debhelper 化：除交叉工具链与 dpkg 外，
# 宿主机还需 debhelper（Arch 走 AUR）。dpkg-checkbuilddeps 在非 Debian 宿主机
# 必然误报（没有 dpkg 包数据库），故 DPKG_FLAGS=-d 跳过，真实工具由
# kernel_cross_assert_deps 验证。
kernel_cross_assert_deps() {
  local -a missing=() c
  for c in aarch64-linux-gnu-gcc dpkg-buildpackage dpkg-deb fakeroot \
           dh_listpackages dh_gencontrol dh_builddeb \
           bc flex bison perl openssl rsync tar xz curl; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  ((${#missing[@]} == 0)) || fatal "交叉编内核缺宿主机依赖：${missing[*]}
  （Arch：debhelper 在 AUR；其余 pacman -S --needed dpkg fakeroot bc flex bison openssl rsync）"
}

kernel_build_cross() {
  local kv="$1"
  local lkdir="${VYOS_BUILD_TREE}/scripts/package-build/linux-kernel"
  local kdir="${WORK_DIR}/kernel"
  local src="${kdir}/linux-${kv}"
  local cross_make=(make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)

  kernel_cross_assert_deps
  [[ "${DRY_RUN:-0}" == "1" ]] && { log "dry-run：交叉编 ${kv} → packages/"; return 0; }

  if [[ "${REBUILD_KERNEL:-0}" == "1" ]]; then
    run rm -f "${VYOS_BUILD_TREE}/packages/"linux-image-*.deb
  fi

  # --- 取源：优先复用容器流程下载过的 tarball，否则 kernel.org 拉新并尽力验签 ----
  run mkdir -p "${kdir}"
  local tarball="${lkdir}/linux-${kv}.tar.xz"
  if [[ ! -f "${tarball}" ]]; then
    tarball="${kdir}/linux-${kv}.tar.xz"
    if [[ ! -f "${tarball}" ]]; then
      run curl -fL -o "${tarball}" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${kv}.tar.xz"
      if command -v gpg2 >/dev/null 2>&1 \
         && gpg2 --locate-keys torvalds@kernel.org gregkh@kernel.org >/dev/null 2>&1; then
        run curl -fL -o "${tarball%.xz}.sign" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${kv}.tar.sign"
        xz -cd "${tarball}" | gpg2 --verify "${tarball%.xz}.sign" - \
          || fatal "内核 tarball GPG 验签失败：${tarball}"
        log "内核 tarball GPG 验签通过。"
      else
        warn "无 gpg2 或取不到 kernel.org 公钥，跳过验签（容器模式会验）。"
      fi
    fi
  fi

  # --- 全新树（保证补丁序与配置确定性）-------------------------------------------
  log "解包内核源码 → ${src}"
  run rm -rf "${src}"
  run tar -xf "${tarball}" -C "${kdir}"
  [[ -d "${src}" ]] || fatal "解包后未见 ${src}"

  # --- 补丁：与官方 build-kernel.sh 同目录同序（ls），含 overlay 投放的板级补丁 --
  local p
  for p in $(ls "${lkdir}/patches/kernel"); do
    log "应用补丁：${p}"
    patch -d "${src}" -p1 -s -f < "${lkdir}/patches/kernel/${p}" \
      || fatal "补丁失败：${p}"
  done

  # --- 证书链（与官方一致）：data/certificates/*.pem 进内核信任环 ----------------
  run sed -i -e "s/CN =.*/CN=VyOS Networks build time autogenerated Kernel key/" \
    "${src}/certs/default_x509.genkey"
  local trusted_frag=""
  if compgen -G "${VYOS_BUILD_TREE}/data/certificates/*.pem" >/dev/null; then
    cat "${VYOS_BUILD_TREE}/data/certificates/"*.pem > "${src}/trusted_keys.pem"
    trusted_frag="${kdir}/trusted-keys.config"
    printf 'CONFIG_SYSTEM_TRUSTED_KEYRING=y\nCONFIG_SYSTEM_TRUSTED_KEYS="trusted_keys.pem"\n' \
      > "${trusted_frag}"
  fi

  # --- 配置：vyos_defconfig 为底 + config/*.config 片段 merge（官方同源）---------
  local -a frags=("${lkdir}/config/arm64/vyos_defconfig")
  local f
  for f in "${lkdir}/config/"*.config; do
    [[ -f "${f}" ]] && frags+=("${f}")
  done
  [[ -n "${trusted_frag}" ]] && frags+=("${trusted_frag}")
  log "merge_config：${#frags[@]} 个片段"
  ( cd "${src}" && \
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    scripts/kconfig/merge_config.sh "${frags[@]}" ) \
    || fatal "merge_config 失败"
  [[ -f "${src}/.config" ]] || fatal "merge_config 没有产出 .config"

  # --- 构建 deb（bindeb-pkg，容忍 perf 失败）-------------------------------------
  # 顶层只暴露 %pkg 通配，没有单独的 `debian`/`binary-image` target，故走标准
  # bindeb-pkg。它按 binary-arch 序串行打包：linux-image 在最前、perf 在最后；
  # arm64 交叉编 perf 缺目标 libelf 必炸，但那时 linux-image deb 已 dpkg-deb 打好。
  # 所以容忍整体非零退出，以 linux-image deb 是否落盘为准（与容器模式 build.py 一致）。
  # DPKG_FLAGS=-d 跳过 dpkg-checkbuilddeps（非 Debian 宿主机没有 dpkg 包数据库）。
  # 代价：会顺带编 dbg/headers（在 perf 之前），多耗时/空间但不影响 image deb。
  run touch "${src}/.scmversion"
  if ( cd "${src}" && "${cross_make[@]}" -j"${JOBS}" bindeb-pkg \
        LOCALVERSION=-vyos KDEB_PKGVERSION="${kv}-1" DPKG_FLAGS=-d ); then
    log "bindeb-pkg 全部成功。"
  else
    warn "bindeb-pkg 非零退出（多半是 perf 包），以 linux-image deb 落盘为准。"
  fi
  local imgdeb="${kdir}/linux-image-${kv}-vyos_${kv}-1_arm64.deb"
  [[ -f "${imgdeb}" ]] || fatal "linux-image deb 未生成（看上面交叉编译日志）"
  run mkdir -p "${VYOS_BUILD_TREE}/packages"
  run cp -v "${imgdeb}" "${VYOS_BUILD_TREE}/packages/"
}
