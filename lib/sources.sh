#!/usr/bin/env bash
# lib/sources.sh — 源码树获取。全部进 work/，只克隆不污染：本项目对 vyos-build
# 的所有定制都以 overlay 文件投放进 work 树（见 lib/overlay.sh），原始检出零改动。
#
# 相同目标 HEAD 保留 overlay；目标变更只允许重置 work/ 内的专用检出。
# SKIP_FETCH=1 只接受本地已知 ref；REFRESH_SOURCES=1 刷新可移动分支/标签。

git_clone_shallow() {
  local repo="$1" ref="${2:-HEAD}" dir="$3" target current origin parent root
  ref="${ref:-HEAD}"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "dry-run：${repo} @ ${ref} → ${dir}"
    return 0
  fi
  # 检查最近的已存在父目录，再创建检出，避免穿过符号链接写到 work/ 外。
  root="$(cd "${WORK_DIR}" && pwd -P)" || return
  parent="${dir}"
  while [[ ! -d "${parent}" ]]; do parent="$(dirname "${parent}")"; done
  parent="$(cd "${parent}" && pwd -P)" || return
  [[ "${parent}" == "${root}" || "${parent}/" == "${root}/"* ]] \
    || fatal "拒绝创建或重置 work/ 以外的源码树：${dir}"
  [[ ! -d "${dir}" || "${parent}" != "${root}" ]] || fatal "源码目录不能是 work/ 根目录"
  if [[ ! -d "${dir}/.git" ]]; then
    [[ "${SKIP_FETCH:-0}" != "1" ]] || fatal "SKIP_FETCH=1 但源码缺失：${dir}"
    [[ ! -e "${dir}" ]] || fatal "拒绝覆盖非 Git 目录：${dir}"
    run git init "${dir}" || return
    run git -C "${dir}" remote add origin "${repo}" || return
  fi
  # pwd -P 防止 work/ 下的符号链接把 reset/clean 引向外部目录。
  [[ "$(cd "${dir}" && pwd -P)/" == "$(cd "${WORK_DIR}" && pwd -P)/"* ]] \
    || fatal "拒绝重置 work/ 以外的源码树：${dir}"
  origin="$(git -C "${dir}" remote get-url origin)" || return
  [[ "${origin}" == "${repo}" ]] || fatal "源码 origin 不匹配：${dir}（${origin} != ${repo}）"
  target="$(git -C "${dir}" rev-parse --verify "${ref}^{commit}" 2>/dev/null || true)"
  if [[ -z "${target}" || "${REFRESH_SOURCES:-0}" == "1" ]]; then
    [[ "${SKIP_FETCH:-0}" != "1" ]] || fatal "离线源码无法解析或刷新 ${ref}：${dir}"
    run git -C "${dir}" fetch --depth 1 origin "${ref}" || return
    target="$(git -C "${dir}" rev-parse --verify 'FETCH_HEAD^{commit}')" || return
  fi
  current="$(git -C "${dir}" rev-parse --verify HEAD 2>/dev/null || true)"
  if [[ "${current}" == "${target}" ]]; then
    log "源码已就位：${dir} @ ${target}（保留 overlay）"
    return 0
  fi
  run git -C "${dir}" checkout --detach --force "${target}" || return
  run git -C "${dir}" clean -fdq
}

# 缓存输入按文件名和内容一起散列；目录不存在表示没有该可选 overlay。
# 只由调用者传入小型 recipe/config 树，不扫描下载源码或构建产物。
build_input_files() {
  local path
  for path in "$@"; do
    if [[ -d "${path}" ]]; then
      find "${path}" -type f -exec sha256sum {} + | LC_ALL=C sort || return
    elif [[ -f "${path}" ]]; then
      sha256sum "${path}" || return
    fi
  done
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
