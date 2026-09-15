#!/usr/bin/env bash
# lib/overlay.sh — 把本项目对 vyos-build 的全部定制以文件投放方式落进 work 树。
#
# 两层 overlay，路径即语义（镜像 vyos-build 的目录结构，rsync 原样覆盖）：
#   overlay/                  全局定制（flavor、RK3528 内核片段）
#   boards/*/overlay/         板级定制（如 m28k 的内核 DTS/补丁）
#
# 注意是 boards/*（全部板）而非仅当前板：RK3528 家族共享一个内核/一张 ISO，
# 所有板的内核侧资产必须同时在场（与主线"一个内核带全部 DTB"同构）。
# 板间天然正交：m28k 的 DTS 补丁对 e20c 无副作用。
#
# 内核注入零引擎改动的原理（vyos-build 自身的 glob 机制）：
#   scripts/package-build/linux-kernel/config/*.config        自动 merge
#   scripts/package-build/linux-kernel/patches/kernel/*.patch 自动应用

# 仅回收上次明确投放的路径，不清理 work 树中的构建产物或人工文件。
overlay_reconcile() {
  run python3 - "${VYOS_BUILD_TREE}" "${STATE_DIR}/overlay-files.json" \
    "${OVERLAY_DIR}" "${BOARDS_DIR}"/*/overlay <<'PYOVERLAY'
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
manifest = Path(sys.argv[2])
current = set()
for source in map(Path, sys.argv[3:]):
    if not source.is_dir():
        continue
    for directory, dirs, files in os.walk(source):
        files += [name for name in dirs if (Path(directory) / name).is_symlink()]
        current.update(str((Path(directory) / name).relative_to(source)) for name in files)
previous = set(json.loads(manifest.read_text())) if manifest.exists() else set()
for name in previous | current:
    path = Path(name)
    if path.is_absolute() or not path.parts or ".." in path.parts or ".git" in path.parts:
        raise SystemExit(f"unsafe overlay path: {name!r}")
    parent = (root / path).parent.resolve()
    if parent != root and root not in parent.parents:
        raise SystemExit(f"overlay path escapes work tree: {name!r}")
for name in sorted(previous - current):
    path = root / name
    tracked = subprocess.run(["git", "-C", str(root), "ls-files", "--error-unmatch", "--", name],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if tracked:
        subprocess.run(["git", "-C", str(root), "restore", "--source=HEAD", "--worktree", "--", name], check=True)
    elif path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        raise SystemExit(f"overlay file became a directory: {name!r}")
# 复制前记录本轮所有路径：即便 rsync 中途失败，下次仍能回收部分投放。
manifest.parent.mkdir(parents=True, exist_ok=True)
temporary = manifest.with_suffix(".tmp")
temporary.write_text(json.dumps(sorted(current)) + "\n")
temporary.replace(manifest)
PYOVERLAY
}

stage_overlay() {
  section "投放 overlay 到 work/vyos-build"
  [[ -d "${VYOS_BUILD_TREE}" ]] || fatal "work 树缺失，先跑 sources 阶段"

  overlay_reconcile || return
  run rsync -a --no-owner --no-group "${OVERLAY_DIR}/" "${VYOS_BUILD_TREE}/"

  local b
  for b in "${BOARDS_DIR}"/*/overlay; do
    [[ -d "${b}" ]] || continue
    log "板级 overlay：$(basename "$(dirname "${b}")")"
    run rsync -a --no-owner --no-group "${b}/" "${VYOS_BUILD_TREE}/"
  done

  # C2：base ISO 必须板无关。清掉历史（pre-C2）可能遗留在 work 树里的板级注入——
  # 那时 aic8800/r8125/oled 阶段把 .ko/固件/oled deb 写进了共享 includes.chroot/packages，
  # 不清的话 base ISO 会再次把它们打进去（前功尽弃）。现在这些资产只去 board-assets/。
  local inc="${VYOS_BUILD_TREE}/data/live-build-config/includes.chroot"
  run rm -rf "${inc}"/lib/modules/*/updates
  run rm -f  "${inc}"/etc/modules-load.d/aic8800.conf "${inc}"/etc/modules-load.d/r8125.conf
  run rm -rf "${inc}"/lib/firmware/aic8800
  run rm -f  "${inc}"/usr/bin/oled-dash "${inc}"/lib/systemd/system/oled-dash.service
  run rm -f  "${VYOS_BUILD_TREE}/packages/"vyos-oled-dash_*.deb
}
