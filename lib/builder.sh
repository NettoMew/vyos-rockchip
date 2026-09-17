#!/usr/bin/env bash
# lib/builder.sh — arm64 构建容器（经 qemu binfmt 仿真）。
# 缓存必须同时匹配 arm64 与当前 docker/ 上下文；仅有同名 tag 不代表可复用。

builder_context_digest() {
  [[ -d "${VYOS_BUILD_TREE}/docker" ]] || return 1
  python3 - "${VYOS_BUILD_TREE}/docker" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
digest = hashlib.sha256()
for parent, directories, files in os.walk(root, followlinks=False):
    directories.sort()
    for name in sorted(directories + files):
        path = Path(parent) / name
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            kind, content = "link", os.readlink(path)
        elif stat.S_ISDIR(mode):
            kind, content = "directory", ""
        elif stat.S_ISREG(mode):
            value = hashlib.sha256()
            with path.open("rb") as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    value.update(block)
            kind, content = "file", value.hexdigest()
        else:
            raise SystemExit(f"unsupported builder context entry: {path}")
        entry = [path.relative_to(root).as_posix(), stat.S_IMODE(mode), kind, content]
        digest.update(json.dumps(entry, separators=(",", ":")).encode() + b"\n")
print(digest.hexdigest())
PY
}

_builder_image_identity() {
  local image="$1" digest="$2" metadata arch id label
  metadata="$(docker image inspect -f '{{.Os}}/{{.Architecture}} {{.Id}} {{index .Config.Labels "org.vyos-rockchip.builder-context-sha256"}}' "${image}" 2>/dev/null)" || return 1
  read -r arch id label <<< "${metadata}"
  [[ "${arch}" == linux/arm64 && "${id}" == sha256:* && "${label}" == "${digest}" ]] || return 1
  printf '%s\n' "${id}"
}

# Read-only cache API: missing/stale/wrong-architecture images return nonzero and
# no stdout. Never pull/build here: dry-run and artifact fingerprints call this.
builder_identity() {
  local digest
  digest="$(builder_context_digest)" || return 1
  _builder_image_identity "${BUILDER_IMAGE}" "${digest}"
}

stage_builder() {
  section "确保 arm64 构建容器：${BUILDER_IMAGE}"
  local digest
  digest="$(builder_context_digest)" || { fatal '缺少 builder docker/ 上下文，请先执行 sources 与 overlay'; return 1; }

  if _builder_image_identity "${BUILDER_IMAGE}" "${digest}" >/dev/null; then
    log "镜像架构与源码上下文匹配。"
    return 0
  fi

  if [[ "${BUILDER_PULL}" == "1" ]]; then
    log "尝试 pull ${BUILDER_PULL_IMAGE}（arm64）…"
    if run docker pull --platform linux/arm64 "${BUILDER_PULL_IMAGE}"; then
      if _builder_image_identity "${BUILDER_PULL_IMAGE}" "${digest}" >/dev/null; then
        run docker tag "${BUILDER_PULL_IMAGE}" "${BUILDER_IMAGE}" || return
        return 0
      fi
      warn "pull 镜像未匹配 arm64 与源码上下文标签，转为本地构建。"
    else
      warn "pull 失败，转为本地构建。"
    fi
  fi

  log "本地构建容器镜像（qemu 仿真下较慢，一次性）"
  run docker build --platform linux/arm64 --build-arg ARCH=arm64v8/ \
    --label "org.vyos-rockchip.builder-context-sha256=${digest}" \
    -t "${BUILDER_IMAGE}" "${VYOS_BUILD_TREE}/docker" || return
  _builder_image_identity "${BUILDER_IMAGE}" "${digest}" >/dev/null || {
    fatal '构建后的 builder 架构或源码标签不匹配'; return 1;
  }
}

# 在容器内（root、/vyos = work 树）执行一段 bash。
# GOSU_UID/GID=0：阻止 entrypoint 按挂载目录属主降权——qemu-user 仿真下 setuid
# 不生效（binfmt 无 C 标志），非 root 用户的 sudo 必死；root 则不需要 setuid。
builder_exec() {
  run docker run --rm --privileged --platform linux/arm64 \
    --cpus "${BUILDER_CPUS:-16}" --memory "${BUILDER_MEMORY:-32g}" --memory-swap "${BUILDER_MEMORY:-32g}" \
    --sysctl net.ipv6.conf.lo.disable_ipv6=0 \
    -v "${VYOS_BUILD_TREE}:/vyos" -w /vyos \
    -e DEBIAN_FRONTEND=noninteractive \
    -e GOSU_UID=0 -e GOSU_GID=0 \
    -e CCACHE_DIR=/vyos/.ccache \
    -e "JOBS=${JOBS:-16}" \
    -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/vyos \
    "${BUILDER_IMAGE}" bash -ec "$1"
}
