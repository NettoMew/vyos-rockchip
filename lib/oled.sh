#!/usr/bin/env bash
# lib/oled.sh — OLED dashboard 打成外部 deb（stage_oled）。
#
# oled-dash（SSD1306 128x32 仪表盘，读 /proc + ip，经 ssd130x DRM fbdev /dev/fb0
# 画 CPU/内存/网络 + ECG 动画，源自 alpine boards/m28k/oled）静态交叉编译后，连同
# systemd 服务一起产到 BOARD_ASSETS_DIR（C2：仅本板，image 阶段 host 侧注入 squashfs；
# 不再打 deb 进共享 packages/ → e20c/r5s 不再带这个 m28k 专属二进制）。
# 服务**默认不启用**（board-assets 里不放 wants symlink），用户手动
# `systemctl enable --now oled-dash` 开启（服务自带 ExecStartPre 等 /dev/fb0）。
#
# 静态编译（-static）避开宿主 gcc15 glibc 与 VyOS bookworm glibc 2.36 的版本不匹配
# （和 alpine 同理）。运行依赖只有 iproute2（ip，VyOS base 自带）+ /dev/fb0（内核
# ssd130x 模块，由 70-rockchip 片段 CONFIG_DRM_SSD130X=m 提供，DTS oled@3c 节点在
# 140 补丁，udev 按 OF modalias 自动加载）。仅 BOARD_OLED_DASH=1 的板构建。

stage_oled() {
  if [[ "${BOARD_OLED_DASH:-0}" != "1" ]]; then
    log "本板无 OLED dashboard（BOARD_OLED_DASH≠1），跳过"
    return 0
  fi
  section "OLED dashboard（oled-dash 静态编译 → board-assets）"
  [[ "${DRY_RUN:-0}" == "1" ]] && { log "dry-run：静态编 oled-dash + service → BOARD_ASSETS_DIR（服务默认 disabled）"; return 0; }

  local oled="${BOARDS_DIR}/${BOARD}/oled"
  [[ -f "${oled}/oled-dash.c" ]] || fatal "OLED 源缺失：${oled}/oled-dash.c"
  command -v aarch64-linux-gnu-gcc >/dev/null || fatal "缺 aarch64-linux-gnu-gcc"

  local inc="${BOARD_ASSETS_DIR}"
  run mkdir -p "${inc}/usr/bin" "${inc}/lib/systemd/system"

  # 静态交叉编（含同目录 bongo_frames.h）→ board-assets
  run aarch64-linux-gnu-gcc -O2 -static -I"${oled}" \
    -o "${inc}/usr/bin/oled-dash" "${oled}/oled-dash.c" -lm
  run cp "${oled}/oled-dash.service" "${inc}/lib/systemd/system/oled-dash.service"
  log "oled-dash(静态)+service → ${inc}（默认 disabled，手动 systemctl enable --now oled-dash）"
}
