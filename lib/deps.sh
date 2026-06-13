#!/usr/bin/env bash
# lib/deps.sh — 宿主机依赖检查。只检查不安装：缺什么一次性列全，附 CachyOS/Arch
# 安装提示。容器内依赖由 vyos-build 自己管理，不在此处操心。

stage_deps() {
  section "检查宿主机依赖"
  local -a missing=()
  local c
  for c in git curl docker python3 rsync zstd parted losetup truncate \
           aarch64-linux-gnu-gcc swig bison flex bc make mkfs.ext4 \
           unsquashfs mksquashfs depmod; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  command -v mkfs.vfat >/dev/null 2>&1 || command -v mkfs.fat >/dev/null 2>&1 || missing+=("mkfs.vfat")

  # U-Boot binman 需要 pyelftools
  python3 -c 'import elftools' 2>/dev/null || missing+=("python-pyelftools")

  ((${#missing[@]} == 0)) || fatal "缺少依赖：${missing[*]}
  CachyOS/Arch 参考：sudo pacman -S --needed git curl docker python rsync zstd parted \\
    aarch64-linux-gnu-gcc swig bison flex bc dosfstools e2fsprogs squashfs-tools python-pyelftools qemu-user-static-binfmt"

  # arm64 容器与 squashfs chroot 都依赖 qemu binfmt，且必须带 F（fix-binary）标志，
  # 否则只读 squashfs 里找不到解释器。
  local binfmt=/proc/sys/fs/binfmt_misc/qemu-aarch64
  [[ -f "${binfmt}" ]] || fatal "qemu-aarch64 binfmt 未注册（装 qemu-user-static-binfmt 并重启 systemd-binfmt）"
  grep -q '^flags:.*F' "${binfmt}" || fatal "qemu-aarch64 binfmt 缺少 F 标志，chroot 进 squashfs 会失败"

  docker info >/dev/null 2>&1 || fatal "docker daemon 不可用（或当前用户无权限）"
  log "宿主机依赖齐全。"
}
