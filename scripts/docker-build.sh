#!/usr/bin/env bash
# Docker-only host entry: scripts/docker-build.sh r5s [build.sh arguments...]
# JOBS=16 BUILD_CPUS=16 BUILD_MEMORY=32g; BUILDER_CPUS/MEMORY default to these.
# KERNEL_BUILD_MODE defaults to cross; e20c can explicitly select container.
# Source/work/output paths are mounted at identical absolute paths: sibling
# builder containers resolve bind sources on the HOST daemon, not this container.
# --privileged + /dev are required for loop partitions/chroot, not isolation.
# Resource limits apply to run containers, not daemon-side Docker image builds.
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${PROJECT_ROOT}"
JOBS="${JOBS:-16}"
BUILD_CPUS="${BUILD_CPUS:-16}"
BUILD_MEMORY="${BUILD_MEMORY:-32g}"
BUILDER_CPUS="${BUILDER_CPUS:-${BUILD_CPUS}}"
BUILDER_MEMORY="${BUILDER_MEMORY:-${BUILD_MEMORY}}"
HOST_IMAGE="${HOST_IMAGE:-vyos-rockchip/host:local}"
DOCKER_SOCKET="${DOCKER_SOCKET:-/var/run/docker.sock}"

for value in "${JOBS}" "${BUILD_CPUS}" "${BUILDER_CPUS}"; do
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || { echo 'jobs/cpus must be positive integers' >&2; exit 1; }
done
for value in "${BUILD_MEMORY}" "${BUILDER_MEMORY}"; do
  [[ "${value}" =~ ^[1-9][0-9]*[bkmgBKMG]?$ ]] || { echo 'memory must be a positive Docker size, e.g. 32g' >&2; exit 1; }
done
command -v docker >/dev/null || { echo 'Docker CLI is required on the host' >&2; exit 1; }
docker_host=(docker --host "unix://${DOCKER_SOCKET}")
"${docker_host[@]}" info >/dev/null

# Do not source build.conf here: its bootstrap may use tools (nproc, etc.) that
# belong inside the host image. Pass overrides and load configuration there.
"${docker_host[@]}" build \
  --build-arg "DOCKER_CLI_IMAGE=${DOCKER_CLI_IMAGE:-docker:29.8.0-cli}" \
  -f "${PROJECT_ROOT}/docker/Dockerfile.host" -t "${HOST_IMAGE}" "${PROJECT_ROOT}/docker"
HOST_IMAGE_ID="$("${docker_host[@]}" image inspect -f '{{.Id}}' "${HOST_IMAGE}")"
[[ "${HOST_IMAGE_ID}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'invalid host image identity' >&2; exit 1; }

mkdir -p "${WORK_DIR:-${PROJECT_ROOT}/work}" "${OUT_DIR:-${PROJECT_ROOT}/out}"
WORK_DIR="$(cd "${WORK_DIR:-${PROJECT_ROOT}/work}" && pwd -P)"
OUT_DIR="$(cd "${OUT_DIR:-${PROJECT_ROOT}/out}" && pwd -P)"
mounts=()
for path in "${PROJECT_ROOT}" "${WORK_DIR}" "${OUT_DIR}"; do
  [[ "${path}" != *,* ]] || { echo 'Docker bind paths cannot contain commas' >&2; exit 1; }
  mounts+=(--mount "type=bind,source=${path},target=${path}")
done
environment=(-e "KERNEL_BUILD_MODE=${KERNEL_BUILD_MODE:-cross}" -e "BUILD_HOST_IMAGE_ID=${HOST_IMAGE_ID}")
# Root may read existing bind-mounted checkouts owned by the invoking user.
# Trust only these exact repositories in the child process environment: never
# change host/global Git configuration or trust every repository with '*'.
safe_repositories=("${PROJECT_ROOT}" "${WORK_DIR}/vyos-build" "${WORK_DIR}/src/u-boot"
                   "${WORK_DIR}/src/rkbin" "${WORK_DIR}/src/rtl8125" "${WORK_DIR}/src/aic8800")
environment+=(-e "GIT_CONFIG_COUNT=${#safe_repositories[@]}")
for i in "${!safe_repositories[@]}"; do
  environment+=(-e "GIT_CONFIG_KEY_${i}=safe.directory" -e "GIT_CONFIG_VALUE_${i}=${safe_repositories[i]}")
done
while IFS= read -r name; do
  case "${name}" in
    VYOS_*|UBOOT_*|RKBIN_*|AIC8800_*|R8125_*|OLED_*|REBUILD_*|BUILDER_IMAGE|BUILDER_PULL|BUILDER_PULL_IMAGE|BUILD_BY|FLAVOR|REFRESH_SOURCES|SKIP_FETCH|DRY_RUN|IMAGE_SIZE_GIB|ESP_START_MIB|ESP_SIZE_MIB|ZSTD_LEVEL|KEEP_RAW_IMAGE|HTTP_PROXY|HTTPS_PROXY|NO_PROXY|http_proxy|https_proxy|no_proxy)
      environment+=(-e "${name}") ;;
  esac
done < <(compgen -e)

exec "${docker_host[@]}" run --rm --init --privileged \
  --cpus "${BUILD_CPUS}" --memory "${BUILD_MEMORY}" --memory-swap "${BUILD_MEMORY}" \
  "${mounts[@]}" \
  --mount "type=bind,source=${DOCKER_SOCKET},target=/var/run/docker.sock" \
  --mount type=bind,source=/dev,target=/dev \
  -w "${PROJECT_ROOT}" \
  -e "WORK_DIR=${WORK_DIR}" -e "OUT_DIR=${OUT_DIR}" -e "JOBS=${JOBS}" \
  -e "BUILDER_CPUS=${BUILDER_CPUS}" -e "BUILDER_MEMORY=${BUILDER_MEMORY}" \
  "${environment[@]}" \
  "${HOST_IMAGE_ID}" bash -ec '
    # runc rejects bind mounts inside /proc. Mount the existing kernel binfmt
    # filesystem in this privileged namespace; do not change registrations.
    if [[ "$(uname -m)" != aarch64 ]]; then
      mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
    fi
    exec bash scripts/build.sh "$@"
  ' -- "$@"
