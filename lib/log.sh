#!/usr/bin/env bash
# lib/log.sh — 日志与命令执行器，全部模块共用。
# run() 先回显再执行；DRY_RUN=1 时只回显不执行。

C_SECTION=$'\e[1;36m'; C_LOG=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'; C_OFF=$'\e[0m'

log()     { printf '%s[build]%s %s\n' "${C_LOG}" "${C_OFF}" "$*"; }
section() { printf '\n%s==== %s ====%s\n' "${C_SECTION}" "$*" "${C_OFF}"; }
warn()    { printf '%s[warn]%s %s\n' "${C_WARN}" "${C_OFF}" "$*" >&2; }
fatal()   { printf '%s[fatal]%s %s\n' "${C_ERR}" "${C_OFF}" "$*" >&2; exit 1; }

run() {
  printf '%s[run]%s %s\n' "${C_LOG}" "${C_OFF}" "$*"
  [[ "${DRY_RUN:-0}" == "1" ]] || "$@"
}
