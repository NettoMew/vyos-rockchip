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

# 源 commit、实际构建环境及 overlay 后的 recipe/config/certificates 共同决定缓存。
kernel_inputs_digest() {
  local lkdir="${VYOS_BUILD_TREE}/scripts/package-build/linux-kernel"
  {
    git -C "${VYOS_BUILD_TREE}" rev-parse HEAD || return
    printf '%s\0' "$(resolved_kernel_version)" "${KERNEL_BUILD_MODE:-container}"
    if [[ "${KERNEL_BUILD_MODE:-container}" == "container" ]]; then
      builder_identity || return
    else
      printf '%s\0' "${BUILD_HOST_IMAGE_ID:-native}"
      aarch64-linux-gnu-gcc --version || return
      aarch64-linux-gnu-ld --version || return
    fi
    build_input_files "${LIB_DIR}/kernel.sh" "${lkdir}/config" "${lkdir}/patches" \
      "${lkdir}/"*.sh "${lkdir}/"*.py "${lkdir}/"*.toml \
      "${VYOS_BUILD_TREE}/data/defaults.toml" "${VYOS_BUILD_TREE}/data/certificates"
  } | sha256sum | cut -d' ' -f1
}

kernel_stamp_file() { echo "${STATE_DIR}/kernel-inputs.sha256"; }

# deb 在且输入指纹未变 → 缓存有效
kernel_cache_fresh() {
  compgen -G "$(kernel_deb_glob)" >/dev/null || return 1
  [[ -f "$(kernel_stamp_file)" ]] || return 1
  local digest
  digest="$(kernel_inputs_digest)" || return 1
  [[ "$(cat "$(kernel_stamp_file)")" == "${digest}" ]]
}

stage_kernel() {
  local kv; kv="$(resolved_kernel_version)"
  local mode="${KERNEL_BUILD_MODE:-container}"
  section "VyOS 内核 deb（${kv}，arm64，模式：${mode}）"

  if [[ "${REBUILD_KERNEL:-0}" != "1" ]]; then
    if kernel_cache_fresh; then
      log "内核 deb 已存在且输入未变，跳过（REBUILD_KERNEL=1 强制重编）：$(kernel_deb_glob)"
      return 0
    elif compgen -G "$(kernel_deb_glob)" >/dev/null; then
      log "内核 deb 存在但补丁/配置片段已变化 → 自动重编"
      REBUILD_KERNEL=1
    fi
  fi

  run rm -f "$(kernel_stamp_file)" || return
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

# Validate the same declarative fragment that is merged into the kernel config.
kernel_validate_config() {
  local config="$1" requirements="$2" line key value count=0 failed=0
  [[ -s "${config}" && -s "${requirements}" ]] || { echo 'missing kernel config or feature contract' >&2; return 1; }
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^(CONFIG_[A-Z0-9_]+)=([ym])$ ]]; then
      key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
      count=$((count + 1))
      [[ "${value}" != m ]] || value='[ym]'
      if ! grep -Eq "^${key}=${value}$" "${config}"; then
        echo "kernel feature missing: ${line}" >&2
        failed=1
      fi
    elif [[ "${line}" =~ ^#[[:space:]](CONFIG_[A-Z0-9_]+)[[:space:]]is[[:space:]]not[[:space:]]set$ ]]; then
      key="${BASH_REMATCH[1]}"
      count=$((count + 1))
      if grep -Eq "^${key}=[ym]$" "${config}"; then
        echo "kernel feature must be disabled: ${key}" >&2
        failed=1
      fi
    fi
  done < "${requirements}"
  [[ "${count}" -gt 0 && "${failed}" == 0 ]]
}

kernel_validate_btf() {
  local sections
  sections="$(readelf -SW "$1")" || return
  awk '
    { for (i = 1; i <= NF; i++)
        if ($i == ".BTF" && $(i+1) == "PROGBITS") {
          size = $(i+4); gsub(/0/, "", size)
          if (size != "") found = 1
        }
    }
    END { exit !found }
  ' <<< "${sections}" || { echo "kernel has no nonempty .BTF section: $1" >&2; return 1; }
}

# Check both build outputs and what will actually be shipped, before accepting
# a package from the intentionally tolerated perf failure path.
kernel_validate_build() (
  set -o pipefail
  local src="$1" deb="$2" kv="$3" requirements="$4" tmp
  kernel_validate_config "${src}/.config" "${requirements}" || return
  kernel_validate_btf "${src}/vmlinux" || return
  tmp="$(mktemp -d)" || return
  trap 'rm -rf "${tmp}"' EXIT
  dpkg-deb --fsys-tarfile "${deb}" | tar -xf - -C "${tmp}" \
    "./boot/config-${kv}-vyos" "./boot/vmlinuz-${kv}-vyos" || return
  kernel_validate_config "${tmp}/boot/config-${kv}-vyos" "${requirements}" || return
  cmp "${src}/.config" "${tmp}/boot/config-${kv}-vyos" || return
  cmp "${src}/arch/arm64/boot/Image" "${tmp}/boot/vmlinuz-${kv}-vyos"
)

# 完整解开 data 压缩流，不能把本轮写了一半的 deb 当成 perf 尾部失败的成功包。
kernel_validate_deb() {
  local deb="$1" kv="$2"
  dpkg-deb --info "${deb}" >/dev/null || return
  dpkg-deb --fsys-tarfile "${deb}" >/dev/null || return
  [[ "$(dpkg-deb -f "${deb}" Package)" == "linux-image-${kv}-vyos" \
    && "$(dpkg-deb -f "${deb}" Version)" == "${kv}-1" \
    && "$(dpkg-deb -f "${deb}" Architecture)" == arm64 ]]
}

# --- 模式一：官方流程进容器 ------------------------------------------------------
kernel_build_container() {
  local kv
  printf -v kv '%q' "$1"
  if [[ "${REBUILD_KERNEL:-0}" == "1" ]]; then
    log "REBUILD_KERNEL=1：清理上次的内核源与 deb（容器内执行，规避 root 属主）"
    builder_exec 'rm -rf scripts/package-build/linux-kernel/linux-* \
                         scripts/package-build/linux-kernel/*.deb \
                         packages/linux-*.deb'
  fi

  # 每次实际构建先清理旧 deb，后续存在检查只能接受本轮产物。
  builder_exec 'rm -f scripts/package-build/linux-kernel/linux-image-*.deb packages/linux-image-*.deb' || return

  # build.py 允许失败：官方 bindeb-pkg 带 BUILD_TOOLS=1，6.18 的 tools/perf 在
  # arm64 上有并行构建竞态，常在 linux-image deb 已产出后才炸掉 perf 包——
  # 我们不需要 perf，以 image deb 的完整性与元数据验证为准。glob 的 `-vyos_` 天然排除 -vyos-dbg_。
  builder_exec "
    $(declare -f kernel_validate_deb kernel_validate_config kernel_validate_btf kernel_validate_build)
    cd scripts/package-build/linux-kernel
    ./build.py --packages linux-kernel || echo 'W: build.py 非零退出，必须单独验证本轮 image deb'
    for deb in linux-image-*-vyos_*_arm64.deb; do
      kernel_validate_deb \"\${deb}\" ${kv} || exit 1
      kernel_validate_build linux-${kv} \"\${deb}\" ${kv} config/73-dae.config || exit 1
    done
    mkdir -p /vyos/packages
    mv -v linux-image-*-vyos_*_arm64.deb /vyos/packages/
  "
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
           bc flex bison perl openssl rsync tar xz curl pahole readelf; do
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

  # bindeb-pkg 把 deb 写在源码父目录；仅清理 packages/ 无法排除同版本旧包。
  run rm -f "${kdir}/"linux-image-*.deb "${VYOS_BUILD_TREE}/packages/"linux-image-*.deb || return

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
  for p in "${lkdir}/patches/kernel/"*; do
    [[ -f "${p}" ]] || continue
    log "应用补丁：$(basename "${p}")"
    patch -d "${src}" -p1 -s -f < "${p}" \
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
  kernel_validate_config "${src}/.config" "${lkdir}/config/73-dae.config" \
    || fatal "内核配置不满足 DAE 能力契约（检查 pahole 和 Kconfig 依赖）"

  # --- 构建 deb（bindeb-pkg，容忍 perf 失败）-------------------------------------
  # 顶层只暴露 %pkg 通配，没有单独的 `debian`/`binary-image` target，故走标准
  # bindeb-pkg。它按 binary-arch 序串行打包：linux-image 在最前、perf 在最后；
  # arm64 交叉编 perf 缺目标 libelf 必炸，但那时 linux-image deb 已 dpkg-deb 打好。
  # 所以容忍整体非零退出，以 linux-image deb 的完整性与元数据验证为准（与容器模式 build.py 一致）。
  # DPKG_FLAGS=-d 跳过 dpkg-checkbuilddeps（非 Debian 宿主机没有 dpkg 包数据库）。
  # 代价：会顺带编 dbg/headers（在 perf 之前），多耗时/空间但不影响 image deb。
  run touch "${src}/.scmversion"
  if ( cd "${src}" && "${cross_make[@]}" -j"${JOBS}" bindeb-pkg \
        LOCALVERSION=-vyos KDEB_PKGVERSION="${kv}-1" DPKG_FLAGS=-d ); then
    log "bindeb-pkg 全部成功。"
  else
    warn "bindeb-pkg 非零退出；继续验证本轮 linux-image deb 的完整性与元数据。"
  fi
  local imgdeb="${kdir}/linux-image-${kv}-vyos_${kv}-1_arm64.deb"
  [[ -f "${imgdeb}" ]] || fatal "linux-image deb 未生成（看上面交叉编译日志）"
  kernel_validate_deb "${imgdeb}" "${kv}" || fatal "linux-image deb 损坏或元数据不匹配：${imgdeb}"
  kernel_validate_build "${src}" "${imgdeb}" "${kv}" "${lkdir}/config/73-dae.config" \
    || fatal "内核 BTF 或包内 DAE 能力验收失败"
  run mkdir -p "${VYOS_BUILD_TREE}/packages"
  run cp -v "${imgdeb}" "${VYOS_BUILD_TREE}/packages/"
}
