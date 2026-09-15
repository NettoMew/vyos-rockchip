#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="${ROOT}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/fixture/r8125-test/src"
printf 'obj-m := r8125.o\n' > "${TMP}/fixture/r8125-test/src/Makefile"
printf 'fixture\n' > "${TMP}/fixture/r8125-test/src/r8125_n.c"
tar -cjf "${TMP}/source.tar.bz2" -C "${TMP}/fixture" r8125-test
DIGEST="$(sha256sum "${TMP}/source.tar.bz2" | cut -d' ' -f1)"

run() { "$@"; }
log() { :; }
fatal() { printf '%s\n' "$*" >&2; exit 1; }

prepare() (
  WORK_DIR="${TMP}/$1"
  R8125_SOURCE_URL="$2"
  R8125_SOURCE_SHA256="$3"
  SKIP_FETCH="${4:-0}"
  source "${ROOT}/lib/r8125.sh"
  r8125_prepare_source
  cmp "${R8125_BUILD_DIR}/r8125_n.c" "${TMP}/fixture/r8125-test/src/r8125_n.c"
)

prepare valid "file://${TMP}/source.tar.bz2" "${DIGEST}"
# A cached, authenticated archive supports offline rebuilds.
prepare valid "file://${TMP}/does-not-exist" "${DIGEST}" 1

# The default is the unchanged, pinned official archive, not a Git mirror.
(
  WORK_DIR="${TMP}/official"
  SKIP_FETCH=1
  unset R8125_SOURCE_URL R8125_SOURCE_SHA256
  git() { fatal 'default source must not invoke Git'; }
  source "${ROOT}/lib/r8125.sh"
  [[ "${R8125_SOURCE_URL}" == "file://${ROOT}/vendor/r8125/r8125-9.018.00.tar.bz2" ]]
  [[ "${R8125_SOURCE_SHA256}" == 66291cb5d4d3b359cfa0c9ca902028d9ce0f76065887cb64b4052dce4a676ff8 ]]
  r8125_prepare_source
  grep -q '9.018.00' "${R8125_BUILD_DIR}/r8125.h"
  grep -q 'module_param(enable_giga_lite,' "${R8125_BUILD_DIR}/r8125_n.c"
)

# A single override must not silently inherit the bundled archive's identity.
for override in url hash; do
  if (
    WORK_DIR="${TMP}/single-${override}"
    unset R8125_SOURCE_URL R8125_SOURCE_SHA256
    if [[ "${override}" == url ]]; then R8125_SOURCE_URL="file://${TMP}/source.tar.bz2"; else R8125_SOURCE_SHA256="${DIGEST}"; fi
    source "${ROOT}/lib/r8125.sh"
    r8125_prepare_source
  ); then fatal 'single source override was accepted'; fi
done

if prepare missing-hash "file://${TMP}/source.tar.bz2" ''; then
  fatal 'archive without a digest was accepted'
fi
if prepare missing-url '' "${DIGEST}"; then
  fatal 'digest without an archive URL was accepted'
fi
if prepare invalid-hash "file://${TMP}/source.tar.bz2" '../invalid'; then
  fatal 'invalid digest was accepted'
fi
if prepare bad-hash "file://${TMP}/source.tar.bz2" "$(printf '%064d' 0)"; then
  fatal 'archive with the wrong digest was accepted'
fi
if prepare missing-cache 'https://example.invalid/source.tar.bz2' "${DIGEST}" 1; then
  fatal 'offline mode fetched a missing archive'
fi
printf 'corrupt\n' > "${TMP}/valid/src/r8125-${DIGEST}.tar.bz2"
if prepare valid "file://${TMP}/source.tar.bz2" "${DIGEST}" 1; then
  fatal 'corrupted cached archive was accepted'
fi

# A matching checksum authenticates bytes, not a safe extraction layout.
python3 - "${TMP}" <<'PY'
import io
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
for name in ('traversal', 'link', 'wrong-layout'):
    with tarfile.open(root / f'{name}.tar.bz2', 'w:bz2') as archive:
        entry = tarfile.TarInfo('r8125/../../escaped' if name == 'traversal' else 'r8125/file')
        if name == 'link':
            entry.type = tarfile.SYMTYPE
            entry.linkname = '/tmp'
            archive.addfile(entry)
        else:
            entry.size = 1
            archive.addfile(entry, io.BytesIO(b'x'))
PY
for name in traversal link wrong-layout; do
  digest="$(sha256sum "${TMP}/${name}.tar.bz2" | cut -d' ' -f1)"
  if prepare "${name}" "file://${TMP}/${name}.tar.bz2" "${digest}"; then
    fatal "unsafe or unsupported archive accepted: ${name}"
  fi
done
[[ ! -e "${TMP}/escaped" ]]

# Exercise the full archive stage without compiling or executing an installer.
(
  WORK_DIR="${TMP}/stage"
  BOARD_R8125=1 BOARD=fixture
  BOARDS_DIR="${TMP}/boards"
  BOARD_ASSETS_DIR="${TMP}/assets"
  R8125_SOURCE_URL="file://${TMP}/source.tar.bz2"
  R8125_SOURCE_SHA256="${DIGEST}"
  JOBS=1
  section() { :; }
  resolved_kernel_version() { printf 'test\n'; }
  make() {
    local arg dir=''
    for arg in "$@"; do
      [[ "${arg}" != kernelrelease ]] || { printf 'test-vyos\n'; return; }
      case "${arg}" in M=*) dir="${arg#M=}" ;; esac
    done
    [[ "${dir}" == */src ]]
    for arg in CONFIG_ASPM=n ENABLE_EEE=n ENABLE_GIGA_LITE=n ENABLE_DASH_SUPPORT=n ENABLE_PAGE_REUSE=n ENABLE_RSS_SUPPORT=y ENABLE_MULTIPLE_TX_QUEUE=y; do
      [[ " $* " == *" ${arg} "* ]]
    done
    printf 'module\n' > "${dir}/r8125.ko"
  }
  mkdir -p "${WORK_DIR}/kernel/linux-test/"{certs,scripts} "${BOARDS_DIR}/fixture/r8125"
  touch "${WORK_DIR}/kernel/linux-test/Module.symvers" "${WORK_DIR}/kernel/linux-test/certs/signing_key.pem"
  printf '#!/bin/sh\nexit 0\n' > "${WORK_DIR}/kernel/linux-test/scripts/sign-file"
  chmod +x "${WORK_DIR}/kernel/linux-test/scripts/sign-file"
  cat > "${BOARDS_DIR}/fixture/r8125/001-test.patch" <<'PATCH'
--- a/r8125_n.c
+++ b/r8125_n.c
@@ -1 +1 @@
-fixture
+patched
PATCH
  source "${ROOT}/lib/r8125.sh"
  stage_r8125
  grep -qx patched "${R8125_BUILD_DIR}/r8125_n.c"
  grep -qx module "${BOARD_ASSETS_DIR}/lib/modules/test-vyos/updates/r8125/r8125.ko"
)

(
  WORK_DIR="${TMP}/dry-run"
  BOARD_R8125=1 DRY_RUN=1
  unset R8125_SOURCE_URL R8125_SOURCE_SHA256
  log() { printf '%s\n' "$*"; }
  section() { :; }
  resolved_kernel_version() { printf 'test\n'; }
  source "${ROOT}/lib/r8125.sh"
  stage_r8125 > "${TMP}/dry-run.log"
  grep -q 'r8125-9.018.00.tar.bz2' "${TMP}/dry-run.log"
  [[ ! -e "${WORK_DIR}" ]]
)

printf 'r8125 source tests passed\n'
