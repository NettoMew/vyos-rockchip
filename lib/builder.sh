#!/usr/bin/env bash
# lib/builder.sh — arm64 构建容器（经 qemu binfmt 仿真）。
# 策略：本地已有 → 用；否则尝试 pull 官方镜像的 arm64 变体；再不行就用
# work 树自带的 docker/ 上下文现场构建（保证工具链与分支严格匹配）。

stage_builder() {
  section "确保 arm64 构建容器：${BUILDER_IMAGE}"

  if docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
    log "镜像已存在。"
    return 0
  fi

  if [[ "${BUILDER_PULL}" == "1" ]]; then
    log "尝试 pull ${BUILDER_PULL_IMAGE}（arm64）…"
    if run docker pull --platform linux/arm64 "${BUILDER_PULL_IMAGE}"; then
      local arch
      arch="$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "${BUILDER_PULL_IMAGE}" 2>/dev/null || true)"
      if [[ "${arch}" == "linux/arm64" ]]; then
        run docker tag "${BUILDER_PULL_IMAGE}" "${BUILDER_IMAGE}"
        return 0
      fi
      warn "pull 到的是 ${arch}，不是 arm64，转为本地构建。"
    else
      warn "pull 失败，转为本地构建。"
    fi
  fi

  log "本地构建容器镜像（qemu 仿真下较慢，一次性）"
  run docker build --platform linux/arm64 --build-arg ARCH=arm64v8/ \
    -t "${BUILDER_IMAGE}" "${VYOS_BUILD_TREE}/docker"
}

# 在容器内（root、/vyos = work 树）执行一段 bash。
# GOSU_UID/GID=0：阻止 entrypoint 按挂载目录属主降权——qemu-user 仿真下 setuid
# 不生效（binfmt 无 C 标志），非 root 用户的 sudo 必死；root 则不需要 setuid。
builder_exec() {
  run docker run --rm --privileged --platform linux/arm64 \
    --sysctl net.ipv6.conf.lo.disable_ipv6=0 \
    -v "${VYOS_BUILD_TREE}:/vyos" -w /vyos \
    -e DEBIAN_FRONTEND=noninteractive \
    -e GOSU_UID=0 -e GOSU_GID=0 \
    -e CCACHE_DIR=/vyos/.ccache \
    "${BUILDER_IMAGE}" bash -ec "$1"
}
