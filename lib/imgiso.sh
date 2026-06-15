#!/usr/bin/env bash
# lib/imgiso.sh — 每板 ISO（stage_imgiso）：把 image 阶段"注入本板资产后的 squashfs"
# 换进 base ISO 的 live/，remaster 成可被 VyOS `add system image` 原地升级的 ISO。
#
# 动机：base ISO 板无关（不含 r8125/aic8800/oled），直接 add system image 到 r8125 板
# 会装上没网卡驱动的系统。整盘 img 在 image 阶段才注入本板资产——但整盘 img 只能 dd
# 全盘重刷（抹掉 persistence：配置、额外装的 deb）。每板 ISO 填上这个缺口：
#   add system image <iso> → 多版本共存、保留配置/SSH key、可回滚，无需重刷。
#
# 复用 image 阶段已造好的 ${BOARD_ISO_DIR}/filesystem.squashfs（不二次 mksquashfs）。
# xorriso 只替换 live/filesystem.squashfs（+ DTB override 板的 dtb）并重算 sha256sum.txt，
# 其余（内核/initrd/grub/El Torito 引导记录）原样保留 → 既能 add system image，也仍可启动。
#
# DTB override 板（m28k/r5s/e52c）的坑：VyOS 安装器 add 路径只从 ISO live/ 拷
# vmlinuz*/initrd*/filesystem.squashfs，**不拷 dtb**。故把本板内核 DTB 放成
# live/vmlinuz-dtb（蹭 vmlinuz* 拷贝规则）→ 落到 /boot/<ver>/vmlinuz-dtb，由 grub 模板
# （hooks/live/94 注入的条件块，认 dtb 或 vmlinuz-dtb）devicetree 加载。否则升级后内核
# 用 generic U-Boot 控制 DTB（非板专属）→ PCIe 网卡/PMIC/LED 起不来。

stage_imgiso() {
  section "每板 ISO（${BOARD}：add system image 原地升级用）"

  local base sq out version tmp
  base="$(current_iso)"
  sq="${BOARD_ISO_DIR}/filesystem.squashfs"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "dry-run：base ISO=${base:-<待构建>} + ${sq} → live/filesystem.squashfs"
    [[ "${BOARD_DTB_OVERRIDE:-0}" == "1" ]] && log "dry-run：DTB override → live/vmlinuz-dtb"
    log "dry-run：重算 sha256sum.txt → xorriso remaster → out/vyos-<version>-${BOARD_IMAGE_PREFIX}.iso"
    return 0
  fi

  [[ -n "${base}" ]] || fatal "无 base ISO，先跑 iso 阶段"
  [[ -f "${sq}" ]] || fatal "无本板 squashfs（${sq}），先跑 image 阶段"

  mkdir -p "${OUT_DIR}"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # 版本以 base ISO 的 version.json 为权威（osirrox 提取，无需挂载/sudo）
  run xorriso -osirrox on -indev "${base}" -extract /version.json "${tmp}/version.json" >/dev/null 2>&1
  version="$(python3 -c "import json;print(json.load(open('${tmp}/version.json'))['version'])")"
  out="${OUT_DIR}/vyos-${version}-${BOARD_IMAGE_PREFIX}.iso"
  log "版本：${version} → $(basename "${out}")"

  # 重算 sha256sum.txt（安装器 add 前强制 `sha256sum -c sha256sum.txt`，换了 squashfs 必须更新）。
  # 只改 ./live/filesystem.squashfs 这一行的哈希，保留两空格格式（sha256sum -c 把 hash 后
  # 第一个字符当 text/binary 标志位，塌成单空格会把 '.' 误当标志 → 文件名错位、校验失败）。
  run xorriso -osirrox on -indev "${base}" -extract /sha256sum.txt "${tmp}/sha256sum.txt" >/dev/null 2>&1
  run chmod u+w "${tmp}/sha256sum.txt"   # osirrox 提取保留源只读权限，sed/追加前先开写
  local newhash
  newhash="$(sha256sum "${sq}" | cut -d' ' -f1)"
  run sed -i "s|^[0-9a-f]\{64\}\(  \./live/filesystem\.squashfs\)\$|${newhash}\1|" "${tmp}/sha256sum.txt"
  grep -q "^${newhash}  ./live/filesystem.squashfs\$" "${tmp}/sha256sum.txt" \
    || fatal "sha256sum.txt 未能更新 filesystem.squashfs 行（base ISO 布局变了？）"

  # xorriso 替换映射：squashfs + 新 sha256sum（+ override 板的 vmlinuz-dtb）
  local -a maps=(-map "${sq}" /live/filesystem.squashfs
                 -map "${tmp}/sha256sum.txt" /sha256sum.txt)
  if [[ "${BOARD_DTB_OVERRIDE:-0}" == "1" ]]; then
    local dtb="${BOARD_ISO_DIR}/vmlinuz-dtb"
    [[ -f "${dtb}" ]] || fatal "BOARD_DTB_OVERRIDE=1 但缺 ${dtb}（image 阶段应已产出）"
    local dtbhash; dtbhash="$(sha256sum "${dtb}" | cut -d' ' -f1)"
    printf '%s  ./live/vmlinuz-dtb\n' "${dtbhash}" >> "${tmp}/sha256sum.txt"
    maps+=(-map "${dtb}" /live/vmlinuz-dtb)
    log "DTB override → live/vmlinuz-dtb（add system image 携带，grub 模板 devicetree 加载）"
  fi

  # remaster：indev 载入 base → 替换上述文件 → outdev 写新 ISO。`-boot_image any replay`
  # 复刻 base 的 El Torito/isohybrid 引导记录（既供 add system image 读，又仍可 dd 启动）。
  run rm -f "${out}"
  run xorriso -indev "${base}" -outdev "${out}" \
    -boot_image any replay \
    -overwrite on \
    "${maps[@]}" \
    -commit

  section "完成：${out}"
  log "用法：scp 到设备 → configure 外 \`add system image ${out##*/}\`（保留当前配置/SSH key、可回滚）"
  log "首次须先运行一版带本机制的镜像（hook 94 认 vmlinuz-dtb），之后每次更新一条命令即可。"
}
