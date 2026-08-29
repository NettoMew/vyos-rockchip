#!/bin/bash
# rockchip-hostname-sync.sh — 从 VyOS 生成的 /etc/hosts 同步 /etc/hostname
#
# VyOS 的 system_host-name.py 通过 hostnamectl set-hostname --static 写 /etc/hostname，
# 但 live-boot overlay 下该调用可能不生效（systemd-hostnamed 写穿透问题）。
# 本脚本以 /etc/hosts 为权威来源（VyOS commit 必然更新它），直接落盘 /etc/hostname。

set -e

HOSTS_FILE="/etc/hosts"
HOSTNAME_FILE="/etc/hostname"

# 从 VyOS 生成的 /etc/hosts 提取 hostname（127.0.1.1 行第二字段）
CONFIGURED_HOSTNAME=$(awk '/^127\.0\.1\.1[[:space:]]/ {print $2; exit}' "$HOSTS_FILE")
CURRENT_HOSTNAME=$(cat "$HOSTNAME_FILE" 2>/dev/null || echo "")

if [ -z "$CONFIGURED_HOSTNAME" ]; then
    # /etc/hosts 里没有 127.0.1.1 行（VyOS 尚未提交过 host-name 配置）
    # 用默认值 vyos（与 VyOS config.boot.default 一致）
    CONFIGURED_HOSTNAME="vyos"
fi

if [ "$CONFIGURED_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
    echo "$CONFIGURED_HOSTNAME" > "$HOSTNAME_FILE"
    /usr/bin/hostname "$CONFIGURED_HOSTNAME" 2>/dev/null || true
fi
