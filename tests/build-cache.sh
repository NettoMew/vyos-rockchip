#!/usr/bin/env bash
# Local Git repositories and mocked build commands only; no network or compiler.
# Modules are sourced from isolated fixtures; globals supply their build context.
# shellcheck disable=SC1090,SC2034
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fixture() {
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  WORK_DIR="${TMP}/work"; STATE_DIR="${WORK_DIR}/state"
  VYOS_BUILD_TREE="${WORK_DIR}/vyos-build"
  UBOOT_SRC="${WORK_DIR}/src/u-boot"; RKBIN_SRC="${WORK_DIR}/src/rkbin"
  UBOOT_OUT_DIR="${WORK_DIR}/uboot/test"; ISO_KEEP_DIR="${WORK_DIR}/iso"
  LIB_DIR="${TMP}/lib"; OVERLAY_DIR="${TMP}/overlay"; BOARDS_DIR="${TMP}/boards"
  BOARD="test"; BOARD_UBOOT_DEFCONFIG=test_defconfig; BOARD_UNLOCK_CORES=0
  RKBIN_BL31=bl31; RKBIN_TPL=tpl; RKBIN_BL31_GLOB=bl31; RKBIN_TPL_GLOB=tpl
  VYOS_VERSION="test-1"; BUILD_BY=builder; FLAVOR=rockchip; BUILDER_IMAGE="test"
  KERNEL_BUILD_MODE=container; JOBS=1; MOCK_BUILDER=sha256:one
  mkdir -p "${STATE_DIR}" "${LIB_DIR}" "${OVERLAY_DIR}" "${BOARDS_DIR}/test/overlay" "${ISO_KEEP_DIR}" "${UBOOT_OUT_DIR}"
  cp "${ROOT}/lib/"{sources,kernel,iso,uboot,overlay}.sh "${LIB_DIR}/"
  for module in sources kernel iso uboot overlay; do source "${LIB_DIR}/${module}.sh"; done
  log() { :; }; warn() { :; }; section() { :; }
  fatal() { echo "$*" >&2; exit 1; }
  run() { "$@"; }
  builder_identity() { [[ -n "${MOCK_BUILDER}" ]] && printf '%s\n' "${MOCK_BUILDER}"; }
  resolved_kernel_version() { echo 6.18.1; }
  kernel_deb_glob() { echo "${VYOS_BUILD_TREE}/packages/linux-image-6.18.1-vyos_*_arm64.deb"; }
  current_iso() { [[ ! -f "${ISO_KEEP_DIR}/test.iso" ]] || echo "${ISO_KEEP_DIR}/test.iso"; }
  aarch64-linux-gnu-gcc() { echo 'gcc fixture 1'; }
  aarch64-linux-gnu-ld() { echo 'ld fixture 1'; }
  for dir in "${VYOS_BUILD_TREE}" "${UBOOT_SRC}" "${RKBIN_SRC}"; do
    git init -q "${dir}"
    git -C "${dir}" config user.name fixture
    git -C "${dir}" config user.email fixture@example.invalid
    echo initial > "${dir}/README"
    git -C "${dir}" add README
    git -C "${dir}" commit -qm initial
  done
  LK="${VYOS_BUILD_TREE}/scripts/package-build/linux-kernel"
  mkdir -p "${LK}/config/arm64" "${LK}/patches/kernel" "${VYOS_BUILD_TREE}/data/certificates" "${VYOS_BUILD_TREE}/packages"
  echo config > "${LK}/config/arm64/vyos_defconfig"
  echo fragment > "${LK}/config/board.config"
  echo patch > "${LK}/patches/kernel/board.patch"
  echo recipe > "${LK}/build-kernel.sh"
  echo 'kernel_version = "6.18.1"' > "${VYOS_BUILD_TREE}/data/defaults.toml"
  echo certificate > "${VYOS_BUILD_TREE}/data/certificates/test.pem"
  echo bl31 > "${RKBIN_SRC}/bl31"; echo tpl > "${RKBIN_SRC}/tpl"
}

source_sha() {
  local sha; sha="$(git -C "${VYOS_BUILD_TREE}" rev-parse HEAD)"
  git_clone_shallow "${VYOS_BUILD_TREE}" "${sha}" "${WORK_DIR}/src/fresh"
  [[ "$(git -C "${WORK_DIR}/src/fresh" rev-parse HEAD)" == "${sha}" ]]
}
source_changed_ref() {
  git -C "${VYOS_BUILD_TREE}" tag first
  git_clone_shallow "${VYOS_BUILD_TREE}" first "${WORK_DIR}/src/fresh"
  echo second >> "${VYOS_BUILD_TREE}/README"
  git -C "${VYOS_BUILD_TREE}" commit -qam second
  local sha; sha="$(git -C "${VYOS_BUILD_TREE}" rev-parse HEAD)"
  echo overlay > "${WORK_DIR}/src/fresh/README"
  echo overlay > "${WORK_DIR}/src/fresh/old-overlay"
  git_clone_shallow "${VYOS_BUILD_TREE}" "${sha}" "${WORK_DIR}/src/fresh"
  [[ "$(git -C "${WORK_DIR}/src/fresh" rev-parse HEAD)" == "${sha}" && ! -e "${WORK_DIR}/src/fresh/old-overlay" ]]
}
source_same_head() {
  local sha; sha="$(git -C "${VYOS_BUILD_TREE}" rev-parse HEAD)"
  git_clone_shallow "${VYOS_BUILD_TREE}" "${sha}" "${WORK_DIR}/src/fresh"
  echo overlay > "${WORK_DIR}/src/fresh/README"
  REFRESH_SOURCES=1 git_clone_shallow "${VYOS_BUILD_TREE}" "${sha}" "${WORK_DIR}/src/fresh"
  [[ "$(cat "${WORK_DIR}/src/fresh/README")" == overlay ]]
}
source_offline_mismatch() {
  git -C "${VYOS_BUILD_TREE}" tag first
  git_clone_shallow "${VYOS_BUILD_TREE}" first "${WORK_DIR}/src/fresh"
  if ( SKIP_FETCH=1 git_clone_shallow "${VYOS_BUILD_TREE}" deadbeef "${WORK_DIR}/src/fresh" ); then return 1; fi
}
source_outside_work() {
  git clone -q "${VYOS_BUILD_TREE}" "${TMP}/outside"
  echo second >> "${VYOS_BUILD_TREE}/README"; git -C "${VYOS_BUILD_TREE}" commit -qam second
  local sha; sha="$(git -C "${VYOS_BUILD_TREE}" rev-parse HEAD)"
  if ( git_clone_shallow "${VYOS_BUILD_TREE}" "${sha}" "${TMP}/outside" ); then return 1; fi
}

source_work_root_alias() {
  git init -q "${WORK_DIR}"
  git -C "${WORK_DIR}" remote add origin "${VYOS_BUILD_TREE}"
  local sha; sha="$(git -C "${VYOS_BUILD_TREE}" rev-parse HEAD)"
  if ( git_clone_shallow "${VYOS_BUILD_TREE}" "${sha}" "${WORK_DIR}/." ); then return 1; fi
}
source_symlink_escape() {
  mkdir "${TMP}/outside"
  ln -s "${TMP}/outside" "${WORK_DIR}/link"
  local sha; sha="$(git -C "${VYOS_BUILD_TREE}" rev-parse HEAD)"
  if ( git_clone_shallow "${VYOS_BUILD_TREE}" "${sha}" "${WORK_DIR}/link/new" ); then return 1; fi
  [[ ! -e "${TMP}/outside/new" ]]
}
cache_fail_closed() {
  echo deb > "${VYOS_BUILD_TREE}/packages/linux-image-6.18.1-vyos_6.18.1-1_arm64.deb"
  kernel_inputs_digest > "$(kernel_stamp_file)"
  kernel_cache_fresh
  touch "${ISO_KEEP_DIR}/test.iso"
  iso_overlay_digest > "$(iso_overlay_stamp)"
  iso_cache_fresh
  MOCK_BUILDER=""
  if kernel_cache_fresh; then return 1; fi
  if iso_cache_fresh; then return 1; fi
}
uboot_cache_reuse() {
  echo artifact > "${UBOOT_OUT_DIR}/u-boot-rockchip.bin"
  uboot_inputs_digest > "${UBOOT_OUT_DIR}/inputs.sha256"
  make() { return 1; }
  stage_uboot
  echo changed >> "${RKBIN_SRC}/tpl"
  if ( stage_uboot ); then return 1; fi
  [[ ! -e "${UBOOT_OUT_DIR}/inputs.sha256" ]]
}

kernel_recipe() { local before; before="$(kernel_inputs_digest)"; echo changed >> "${LK}/build-kernel.sh"; [[ "${before}" != "$(kernel_inputs_digest)" ]]; }
kernel_certificate() { local before; before="$(kernel_inputs_digest)"; echo changed >> "${VYOS_BUILD_TREE}/data/certificates/test.pem"; [[ "${before}" != "$(kernel_inputs_digest)" ]]; }
kernel_builder() { local before; before="$(kernel_inputs_digest)"; MOCK_BUILDER=sha256:two; [[ "${before}" != "$(kernel_inputs_digest)" ]]; }
kernel_mode() { local before; before="$(kernel_inputs_digest)"; KERNEL_BUILD_MODE=cross; [[ "${before}" != "$(kernel_inputs_digest)" ]]; }
kernel_cross_fixture() {
  local source="${TMP}/archive/linux-6.18.1"
  mkdir -p "${source}/certs" "${source}/scripts/kconfig" "${WORK_DIR}/kernel"
  echo 'CN = test' > "${source}/certs/default_x509.genkey"
  printf '#!/bin/sh\ntouch .config\n' > "${source}/scripts/kconfig/merge_config.sh"
  chmod +x "${source}/scripts/kconfig/merge_config.sh"
  tar -cf "${LK}/linux-6.18.1.tar.xz" -C "${TMP}/archive" linux-6.18.1
  rm "${LK}/patches/kernel/board.patch"
  kernel_cross_assert_deps() { :; }
}
kernel_new_deb() {
  kernel_cross_fixture
  make() {
    local deb="${WORK_DIR}/kernel/linux-image-6.18.1-vyos_6.18.1-1_arm64.deb"
    if [[ "${PACKAGE_CORRUPT:-0}" == 1 ]]; then
      echo partial > "${deb}"
    else
      make_image_deb "${deb}"
    fi
    return 1
  }
  KERNEL_BUILD_MODE=cross
  stage_kernel
  kernel_validate_deb "${VYOS_BUILD_TREE}/packages/linux-image-6.18.1-vyos_6.18.1-1_arm64.deb" 6.18.1
  [[ -s "$(kernel_stamp_file)" ]]
}
kernel_container_new_deb() {
  make_image_deb "${TMP}/container-image.deb"
  [[ "${PACKAGE_CORRUPT:-0}" != 1 ]] || echo partial > "${TMP}/container-image.deb"
  printf '#!/bin/sh\ncp "%s" linux-image-6.18.1-vyos_6.18.1-1_arm64.deb\nexit 1\n' \
    "${TMP}/container-image.deb" > "${LK}/build.py"
  chmod +x "${LK}/build.py"
  builder_exec() {
    local script="${1//\/vyos\/packages/${VYOS_BUILD_TREE}\/packages}"
    ( cd "${VYOS_BUILD_TREE}" && "${BASH}" -eu -c "${script}" )
  }
  stage_kernel
  kernel_validate_deb "${VYOS_BUILD_TREE}/packages/linux-image-6.18.1-vyos_6.18.1-1_arm64.deb" 6.18.1
  [[ -s "$(kernel_stamp_file)" ]]
}
kernel_container_corrupt_deb() {
  if PACKAGE_CORRUPT=1 "${BASH}" "$0" kernel_container_new_deb; then return 1; fi
}
kernel_corrupt_new_deb() {
  # A fresh shell preserves errexit inside stage_kernel, unlike an `if function`.
  if PACKAGE_CORRUPT=1 "${BASH}" "$0" kernel_new_deb; then return 1; fi
}
make_image_deb() {
  local package="${TMP}/package" deb="$1"
  mkdir -p "${package}/DEBIAN" "${package}/boot"
  printf 'Package: linux-image-6.18.1-vyos\nVersion: 6.18.1-1\nArchitecture: arm64\nMaintainer: Test <test@example.invalid>\nDescription: test\n' > "${package}/DEBIAN/control"
  echo image > "${package}/boot/vmlinuz"
  dpkg-deb --build "${package}" "${deb}" >/dev/null
}
overlay_owner_flags() {
  rsync() {
    [[ " $* " == *" --no-owner "* && " $* " == *" --no-group "* ]] || return 1
    command rsync "$@"
  }
  stage_overlay
  mkdir -p "${BOARDS_DIR}/${BOARD}/uboot"
  echo source > "${BOARDS_DIR}/${BOARD}/uboot/source"
  make() { touch "${UBOOT_SRC}/u-boot-rockchip.bin"; }
  # macOS install has no -D; validate rsync arguments before the install boundary.
  install() { cp "${UBOOT_SRC}/u-boot-rockchip.bin" "${UBOOT_OUT_DIR}/u-boot-rockchip.bin"; }
  stage_uboot
}

kernel_stale_deb() {
  kernel_cross_fixture
  echo stale > "${WORK_DIR}/kernel/linux-image-6.18.1-vyos_6.18.1-1_arm64.deb"
  kernel_cross_assert_deps() { :; }
  make() { return 1; }
  if ( kernel_build_cross 6.18.1 ); then return 1; fi
  ! compgen -G "$(kernel_deb_glob)" >/dev/null
}
iso_inputs() {
  touch "${ISO_KEEP_DIR}/test.iso"
  local input before
  for input in version author flavor builder recipe source; do
    before="$(iso_overlay_digest)"
    case "${input}" in
      version) VYOS_VERSION="test-2";; author) BUILD_BY=other;; flavor) FLAVOR=other;;
      builder) MOCK_BUILDER=sha256:two;; recipe) echo '# changed' >> "${LIB_DIR}/iso.sh";;
      source) echo second >> "${VYOS_BUILD_TREE}/README"; git -C "${VYOS_BUILD_TREE}" commit -qam second;;
    esac
    [[ "${before}" != "$(iso_overlay_digest)" ]] || { echo "ISO ignored ${input}"; return 1; }
  done
}
uboot_inputs() {
  local before; before="$(uboot_inputs_digest)"
  echo changed >> "${RKBIN_SRC}/tpl"
  [[ "${before}" != "$(uboot_inputs_digest)" ]]
  before="$(uboot_inputs_digest)"; BOARD_UNLOCK_CORES=1
  [[ "${before}" != "$(uboot_inputs_digest)" ]]
  before="$(uboot_inputs_digest)"; mkdir -p "${BOARDS_DIR}/${BOARD}/uboot"; echo dts > "${BOARDS_DIR}/${BOARD}/uboot/board.dts"
  [[ "${before}" != "$(uboot_inputs_digest)" ]]
}
uboot_unstamped() {
  touch "${UBOOT_OUT_DIR}/u-boot-rockchip.bin"
  make() { return 1; }
  if ( stage_uboot ); then return 1; fi
}

overlay_deleted_files() {
  echo upstream > "${VYOS_BUILD_TREE}/tracked"
  git -C "${VYOS_BUILD_TREE}" add tracked
  git -C "${VYOS_BUILD_TREE}" commit -qm tracked
  echo override > "${OVERLAY_DIR}/tracked"
  mkdir -p "${OVERLAY_DIR}/patches"
  echo old > "${OVERLAY_DIR}/patches/old.patch"
  stage_overlay
  echo unrelated > "${VYOS_BUILD_TREE}/unrelated"
  rm "${OVERLAY_DIR}/tracked"
  mv "${OVERLAY_DIR}/patches/old.patch" "${OVERLAY_DIR}/patches/new.patch"
  stage_overlay
  [[ "$(cat "${VYOS_BUILD_TREE}/tracked")" == upstream ]]
  [[ ! -e "${VYOS_BUILD_TREE}/patches/old.patch" && -f "${VYOS_BUILD_TREE}/patches/new.patch" && -f "${VYOS_BUILD_TREE}/unrelated" ]]
}
host_image_inputs() {
  KERNEL_BUILD_MODE=cross
  local kernel uboot
  kernel="$(kernel_inputs_digest)"; uboot="$(uboot_inputs_digest)"
  BUILD_HOST_IMAGE_ID=sha256:changed
  [[ "${kernel}" != "$(kernel_inputs_digest)" && "${uboot}" != "$(uboot_inputs_digest)" ]]
}
kernel_package_validation() {
  local deb="${TMP}/image.deb"
  make_image_deb "${deb}"
  kernel_validate_deb "${deb}" 6.18.1
  if kernel_validate_deb "${deb}" 6.18.2; then return 1; fi
  python3 - "${deb}" <<'PYTEST'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_bytes(p.read_bytes()[:-32])
PYTEST
  if kernel_validate_deb "${deb}" 6.18.1; then return 1; fi
}

if (($#)); then fixture; "$1"; exit; fi
failed=0
for test in source_sha source_changed_ref source_same_head source_offline_mismatch source_outside_work source_work_root_alias source_symlink_escape cache_fail_closed uboot_cache_reuse kernel_recipe kernel_certificate kernel_builder kernel_mode kernel_stale_deb kernel_new_deb kernel_corrupt_new_deb kernel_container_new_deb kernel_container_corrupt_deb kernel_package_validation overlay_owner_flags overlay_deleted_files host_image_inputs iso_inputs uboot_inputs uboot_unstamped; do
  if "${BASH}" "$0" "${test}" > /dev/null 2>&1; then printf 'PASS %s\n' "${test}"; else printf 'FAIL %s\n' "${test}"; failed=$((failed+1)); fi
done
((failed == 0))
