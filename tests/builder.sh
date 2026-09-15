#!/usr/bin/env bash
# Mock-only regression tests: no daemon, pulls, image builds, or root access.
# Configuration globals are consumed by the dynamically sourced lib/builder.sh.
# shellcheck disable=SC2034
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
VYOS_BUILD_TREE="${TMP}/vyos-build"
mkdir -p "${VYOS_BUILD_TREE}/docker"
printf 'FROM debian:bookworm\n' > "${VYOS_BUILD_TREE}/docker/Dockerfile"
BUILDER_IMAGE=test-builder
BUILDER_PULL_IMAGE=test-pull
BUILDER_PULL=0
MOCK_ARCH=linux/amd64
MOCK_LABEL=stale
MOCK_ID=sha256:local
MOCK_PULL_ARCH=linux/arm64
MOCK_PULL_LABEL=stale
CALLS="${TMP}/calls"
: > "${CALLS}"

log() { :; }
section() { :; }
warn() { :; }
fatal() { echo "$*" >&2; return 1; }
run() { "$@"; }
docker() {
  printf '%s\n' "$*" >> "${CALLS}"
  case "$1 $2" in
    'image inspect')
      local arch="${MOCK_ARCH}" label="${MOCK_LABEL}"
      if [[ "${*: -1}" == "${BUILDER_PULL_IMAGE}" ]]; then
        arch="${MOCK_PULL_ARCH}"; label="${MOCK_PULL_LABEL}"
      fi
      [[ "${arch}" != missing ]] || return 1
      if [[ "$*" == *'{{.Id}}'* ]]; then
        printf '%s %s %s\n' "${arch}" "${MOCK_ID}" "${label}"
      elif [[ "$*" == *'{{.Os}}/{{.Architecture}}'* ]]; then
        printf '%s\n' "${arch}"
      fi
      ;;
    'pull --platform') return 0 ;;
    'tag test-pull') MOCK_ARCH="${MOCK_PULL_ARCH}"; MOCK_LABEL="${MOCK_PULL_LABEL}" ;;
    'build --platform')
      MOCK_ARCH=linux/arm64
      while (($#)); do
        if [[ "$1" == --label ]]; then MOCK_LABEL="${2#*=}"; fi
        shift
      done
      ;;
    'run --rm') return 0 ;;
    *) echo "unexpected docker call: $*" >&2; return 1 ;;
  esac
}
# shellcheck source=/dev/null
source "${ROOT}/lib/builder.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

stage_builder
grep -q '^build --platform linux/arm64 ' "${CALLS}" || fail 'wrong-architecture cache must rebuild'
identity="$(builder_identity)"
[[ "${identity}" == "${MOCK_ID}" ]] || fail 'identity must be the immutable image ID'

: > "${CALLS}"
stage_builder
! grep -Eq '^(build|pull|tag) ' "${CALLS}" || fail 'matching context must reuse cache'

printf 'changed\n' > "${VYOS_BUILD_TREE}/docker/input"
if builder_identity > "${TMP}/identity"; then fail 'modified context accepted'; fi
[[ ! -s "${TMP}/identity" ]] || fail 'invalid identity must produce no stdout'
stage_builder
grep -q '^build ' "${CALLS}" || fail 'changed context must rebuild'

digest="$(builder_context_digest)"
touch "${VYOS_BUILD_TREE}/docker/input"
[[ "$(builder_context_digest)" == "${digest}" ]] || fail 'mtime alone changed identity'
chmod +x "${VYOS_BUILD_TREE}/docker/input"
[[ "$(builder_context_digest)" != "${digest}" ]] || fail 'executable mode was omitted'
ln -s input "${VYOS_BUILD_TREE}/docker/link"
digest="$(builder_context_digest)"
rm "${VYOS_BUILD_TREE}/docker/link"
ln -s Dockerfile "${VYOS_BUILD_TREE}/docker/link"
[[ "$(builder_context_digest)" != "${digest}" ]] || fail 'symlink target was omitted'

MOCK_ARCH=missing
BUILDER_PULL=1
: > "${CALLS}"
stage_builder
grep -q '^build ' "${CALLS}" || fail 'unlabelled or stale pull must not bypass source identity'
! grep -q '^tag ' "${CALLS}" || fail 'unverified pull must not replace builder'

MOCK_ARCH=missing
MOCK_PULL_LABEL="$(builder_context_digest)"
: > "${CALLS}"
stage_builder
grep -q '^tag ' "${CALLS}" || fail 'matching arm64 pull was not adopted'
! grep -q '^build ' "${CALLS}" || fail 'verified pull unnecessarily rebuilt'

MOCK_ARCH=missing
MOCK_PULL_ARCH=linux/amd64
: > "${CALLS}"
stage_builder
grep -q '^build ' "${CALLS}" || fail 'correct label on amd64 pull bypassed architecture check'
! grep -q '^tag ' "${CALLS}" || fail 'amd64 pull was tagged as builder'

MOCK_ARCH=missing
if builder_identity > "${TMP}/identity"; then fail 'missing image accepted'; fi
[[ ! -s "${TMP}/identity" ]] || fail 'missing image emitted identity'

: > "${CALLS}"
BUILDER_CPUS=8 BUILDER_MEMORY=12g JOBS=6 builder_exec 'echo test'
grep -q -- '--cpus 8 --memory 12g --memory-swap 12g' "${CALLS}" || fail 'nested builder resource limits missing'
grep -q -- '-e JOBS=6' "${CALLS}" || fail 'nested builder jobs missing'
grep -Fq -- "${VYOS_BUILD_TREE}:/vyos" "${CALLS}" || fail 'nested bind source changed'
grep -q -- '-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/vyos' "${CALLS}" || fail 'nested Git trust must be limited to /vyos'

# Exercise the outer entry without Docker: record argv while preserving spaces.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf '%s\0' "$@" >> "${DOCKER_CALLS}"
if [[ "$*" == *'image inspect -f {{.Id}}'* ]]; then
  printf 'sha256:%064d\n' 1
fi
MOCK
chmod +x "${TMP}/bin/docker"
DOCKER_CALLS="${TMP}/wrapper-calls" PATH="${TMP}/bin:${PATH}" \
  WORK_DIR="${TMP}/work with spaces" OUT_DIR="${TMP}/output" \
  JOBS=6 BUILD_CPUS=8 BUILD_MEMORY=12g REBUILD_KERNEL=1 KERNEL_BUILD_MODE='' BUILD_HOST_IMAGE_ID=forged \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' \
  bash "${ROOT}/scripts/docker-build.sh" e20c --stages kernel
python3 - "${TMP}/wrapper-calls" "${ROOT}" "${TMP}" <<'PY'
from pathlib import Path
import sys

args = Path(sys.argv[1]).read_bytes().decode().split("\0")[:-1]
root, temporary = sys.argv[2:]
def pair(name, value):
    assert any(args[i:i + 2] == [name, value] for i in range(len(args) - 1)), (name, value)
pair("--cpus", "8")
pair("--memory", "12g")
pair("--memory-swap", "12g")
pair("-e", "JOBS=6")
pair("-e", "BUILDER_CPUS=8")
pair("-e", "BUILDER_MEMORY=12g")
pair("-e", "REBUILD_KERNEL")
pair("-e", "KERNEL_BUILD_MODE=cross")
identity = "sha256:" + "1".zfill(64)
pair("-e", "BUILD_HOST_IMAGE_ID=" + identity)
assert "BUILD_HOST_IMAGE_ID=forged" not in args
pair(identity, "bash")
safe = [str(Path(root).resolve()), str(Path(temporary + "/work with spaces/vyos-build").resolve())]
safe += [str(Path(temporary + "/work with spaces/src/" + name).resolve()) for name in ("u-boot", "rkbin", "rtl8125", "aic8800")]
pair("-e", "GIT_CONFIG_COUNT=6")
for i, path in enumerate(safe):
    pair("-e", f"GIT_CONFIG_KEY_{i}=safe.directory")
    pair("-e", f"GIT_CONFIG_VALUE_{i}={path}")
assert sum(value.startswith("GIT_CONFIG_VALUE_") for value in args) == 6
assert not any(value.startswith("GIT_CONFIG_VALUE_") and value.endswith("=*") for value in args)
for path in (root, temporary + "/work with spaces", temporary + "/output"):
    path = str(Path(path).resolve())
    pair("--mount", f"type=bind,source={path},target={path}")
pair("--mount", "type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock")
pair("--mount", "type=bind,source=/dev,target=/dev")
assert not any("type=bind,source=/proc" in value for value in args)
assert any("mount -t binfmt_misc" in value and 'exec bash scripts/build.sh "$@"' in value for value in args)
assert args[-4:] == ["--", "e20c", "--stages", "kernel"]
PY
DOCKER_CALLS="${TMP}/wrapper-container-calls" PATH="${TMP}/bin:${PATH}" \
  WORK_DIR="${TMP}/work with spaces" OUT_DIR="${TMP}/output" \
  KERNEL_BUILD_MODE=container \
  bash "${ROOT}/scripts/docker-build.sh" e20c --stages kernel
python3 - "${TMP}/wrapper-container-calls" <<'PY'
from pathlib import Path
import sys
args = Path(sys.argv[1]).read_bytes().decode().split("\0")[:-1]
assert args.count("KERNEL_BUILD_MODE=container") == 1
assert "KERNEL_BUILD_MODE=cross" not in args
assert "KERNEL_BUILD_MODE" not in args
PY
echo 'builder mock regressions: PASS'
