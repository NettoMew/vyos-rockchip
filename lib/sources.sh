#!/usr/bin/env bash
# lib/sources.sh — 源码树获取。全部进 work/，只克隆不污染：本项目对 vyos-build
# 的所有定制都以 overlay 文件投放进 work 树（见 lib/overlay.sh），原始检出零改动。
#
# 语义：目录已存在 = 信任不动（增量友好）；REFRESH_SOURCES=1 强制 fetch+reset；
# SKIP_FETCH=1 断网模式，缺了直接报错。

git_clone_shallow() {
  local repo="$1" ref="$2" dir="$3"
  if [[ -d "${dir}/.git" ]]; then
    if [[ "${REFRESH_SOURCES:-0}" == "1" ]]; then
      log "刷新 $(basename "${dir}")（REFRESH_SOURCES=1）"
      run git -C "${dir}" fetch --depth 1 origin ${ref:+"${ref}"}
      run git -C "${dir}" reset --hard FETCH_HEAD
    else
      log "已存在：${dir}（跳过 fetch；要刷新用 REFRESH_SOURCES=1）"
    fi
    return 0
  fi
  [[ "${SKIP_FETCH:-0}" == "1" ]] && fatal "SKIP_FETCH=1 但源码缺失：${dir}"
  run git clone --depth 1 ${ref:+--branch "${ref}"} "${repo}" "${dir}"
}

stage_sources() {
  section "获取源码树"
  run mkdir -p "${WORK_DIR}/src" "${STATE_DIR}" "${ISO_KEEP_DIR}" "${OUT_DIR}"

  git_clone_shallow "${VYOS_BUILD_REPO}" "${VYOS_BUILD_REF}" "${VYOS_BUILD_TREE}"

  # U-Boot / rkbin 只在本次计划里包含 uboot 阶段时才拉（ISO-only 跑法不浪费时间）
  if stage_planned uboot; then
    git_clone_shallow "${UBOOT_REPO}" "${UBOOT_REF}" "${UBOOT_SRC}"
    git_clone_shallow "${RKBIN_REPO}" "${RKBIN_REF}" "${RKBIN_SRC}"
  fi
}
