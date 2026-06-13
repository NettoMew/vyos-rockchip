#!/usr/bin/env bash
# lib/image.sh — 按板组装可烧录镜像（宿主机；需要 root 的命令逐条 sudo）。
#
# 布局（GPT）：
#   sector 64                          u-boot-rockchip.bin（TPL + BL31 + U-Boot）
#   p1  ESP_START_MIB → +ESP_SIZE_MIB  ESP（FAT32，grub-efi arm64，BOOTAA64.EFI）
#   p2  其余 → 100%                    ext4，label=persistence（VyOS live 持久层）
#       /boot/<version>/{vmlinuz,initrd.img,<version>.squashfs,dtbs/}
#       /boot/grub/grub.cfg.d/         官方 image-tools 结构（add system image 原生可用）
#
# C2 板级资产注入：base ISO 是**板无关**的（不含 aic8800/r8125/oled）。本阶段把 base
# 的 filesystem.squashfs 在 host 侧 unsquashfs 出来，rsync 注入**本板** board-assets/
# （内核模块/固件/oled 二进制等），depmod 收编 out-of-tree 模块，再 mksquashfs 重打包成
# 该板的 squashfs 放进持久层 → 每块板镜像只带自己的资产，且全程 host 原生（无 qemu）。
#
# grub 安装与 grub.cfg.d 结构在解包出来的 rootfs 目录里 chroot 由镜像自带的 VyOS 代码
# 完成（resources/grub-setup.py 调 vyos.system.grub，与官方 raw_image.py 同源）。

umount_if() { mountpoint -q "$1" 2>/dev/null && sudo umount "$1" || true; }

cleanup_image() {
  local r="${ROOTFS_DIR}"
  umount_if "${r}/tmp"
  umount_if "${r}/dev"
  umount_if "${r}/proc"
  umount_if "${r}/sys"
  umount_if "${r}/mnt/boot/efi"
  umount_if "${r}/mnt"
  umount_if "${MNT_DIR}/iso"
  umount_if "${MNT_DIR}/root"
  [[ -n "${IMG_LOOP:-}" ]] && { sudo losetup -d "${IMG_LOOP}" 2>/dev/null || true; }
  IMG_LOOP=""
}

stage_image() {
  section "组装镜像（${BOARD}）"

  local iso uboot_bin
  iso="$(current_iso)"
  uboot_bin="${UBOOT_OUT_DIR}/u-boot-rockchip.bin"
  ROOTFS_DIR="${WORK_DIR}/img/rootfs"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log "dry-run：GPT + u-boot@s64 + ESP(${ESP_START_MIB}MiB,+${ESP_SIZE_MIB}MiB) + persistence(ext4)"
    log "dry-run：base ISO=${iso:-<待构建>}  U-Boot=${uboot_bin}"
    log "dry-run：unsquashfs base → 注入 board-assets/${BOARD} → depmod → mksquashfs(xz,262144)"
    [[ -d "${BOARD_ASSETS_DIR}" ]] && log "dry-run：板级资产存在：${BOARD_ASSETS_DIR}" \
      || log "dry-run：本板无 board-assets（纯主线板，如 e20c）→ 直接重打包 base"
    log "dry-run：产物 out/vyos-<version>-${BOARD_IMAGE_PREFIX}.img.zst  console=${BOARD_SERIAL_CONSOLE},${BOARD_SERIAL_BAUD}n8"
    return 0
  fi

  [[ -n "${iso}" ]] || fatal "无 base ISO，先跑 iso 阶段"
  [[ -f "${uboot_bin}" ]] || fatal "无 U-Boot 产物，先跑 uboot 阶段"

  mkdir -p "${MNT_DIR}"/{iso,root} "${WORK_DIR}/img"
  trap cleanup_image EXIT

  # --- 取版本（base ISO 根的 version.json 为唯一权威）-------------------------
  run sudo mount -t iso9660 -o ro,loop "${iso}" "${MNT_DIR}/iso"
  local version
  version="$(python3 -c "import json;print(json.load(open('${MNT_DIR}/iso/version.json'))['version'])")"
  log "VyOS 版本：${version}"

  local img="${WORK_DIR}/img/vyos-${version}-${BOARD_IMAGE_PREFIX}.img"

  # --- 磁盘：稀疏文件 → GPT → U-Boot 进保留区 ----------------------------------
  run rm -f "${img}"
  run truncate -s "${IMAGE_SIZE_GIB}G" "${img}"
  run parted -s "${img}" mklabel gpt \
    mkpart EFI fat32 "${ESP_START_MIB}MiB" "$((ESP_START_MIB + ESP_SIZE_MIB))MiB" \
    set 1 esp on \
    mkpart persistence ext4 "$((ESP_START_MIB + ESP_SIZE_MIB))MiB" 100%
  run dd if="${uboot_bin}" of="${img}" bs=512 seek=64 conv=notrunc,fsync status=none

  log "挂载 loop 设备"
  IMG_LOOP="$(sudo losetup --show -fP "${img}")"
  log "loop: ${IMG_LOOP}"

  run sudo mkfs.vfat -F 32 -n EFI "${IMG_LOOP}p1"
  run sudo mkfs.ext4 -q -L persistence "${IMG_LOOP}p2"

  # --- 持久层骨架（与官方 raw_image.py 同构）-----------------------------------
  run sudo mount "${IMG_LOOP}p2" "${MNT_DIR}/root"
  local vdir="${MNT_DIR}/root/boot/${version}"
  run sudo mkdir -p "${vdir}/rw" "${vdir}/work/work" "${MNT_DIR}/root/boot/efi"
  echo "/ union" | sudo tee "${MNT_DIR}/root/persistence.conf" >/dev/null

  # --- C2：解包 base squashfs → 注入本板资产 → depmod → 重打包 ------------------
  run sudo rm -rf "${ROOTFS_DIR}"
  log "unsquashfs base filesystem.squashfs → ${ROOTFS_DIR}"
  run sudo unsquashfs -d "${ROOTFS_DIR}" "${MNT_DIR}/iso/live/filesystem.squashfs"

  if [[ -d "${BOARD_ASSETS_DIR}" ]]; then
    log "注入板级资产：${BOARD_ASSETS_DIR} → rootfs"
    # -K/--keep-dirlinks 关键：VyOS rootfs 是 usrmerge，/lib→usr/lib（/bin /sbin 同）。
    # board-assets 里是真实 lib/ 目录（lib/modules/.../r8125.ko、lib/systemd/...），不带 -K
    # 的 rsync 会把 /lib 符号链接替换成真目录 → 孤立 /usr/lib 下的 ld-linux 与全部库
    # （chroot 跑不了 arm64 二进制、且重打包出的 rootfs 不可启动）。-K 让接收端的符号链接
    # 目录被当作其指向的目录，内容经 /lib→usr/lib 落到 usr/lib，符号链接保持完好。
    run sudo rsync -aK "${BOARD_ASSETS_DIR}/" "${ROOTFS_DIR}/"
    # depmod 收编注入的 out-of-tree 模块（host 侧，-b 指基目录；跨架构只解析符号表，OK）
    local kd krel
    for kd in "${ROOTFS_DIR}/lib/modules/"*/; do
      [[ -d "${kd}updates" ]] || continue
      krel="$(basename "${kd%/}")"
      log "depmod -b rootfs ${krel}（收编 updates/ 模块）"
      run sudo depmod -b "${ROOTFS_DIR}" "${krel}"
    done
  else
    log "本板无 board-assets（纯主线板）→ 直接重打包 base"
  fi

  # --- 板级静态 rootfs 覆盖（boards/<board>/rootfs/）---------------------------
  # 放“与板强相关、非编译产物”的静态文件（如 R5S 的网口命名 udev 规则，按本板实测
  # PCIe 路径钉名）。-K 同样保 usrmerge 符号链接。文件同名即覆盖 base 里的共享版本。
  if [[ -d "${BOARDS_DIR}/${BOARD}/rootfs" ]]; then
    log "注入板级 rootfs 覆盖：boards/${BOARD}/rootfs/ → rootfs"
    run sudo rsync -aK "${BOARDS_DIR}/${BOARD}/rootfs/" "${ROOTFS_DIR}/"
  fi

  # --- 板级 console 设备修正 ----------------------------------------------------
  # 共享 default_config 写死 console device ttyS0（RK3528 调试口=uart0=ttyS0）。
  # VyOS 首启 commit 时按 `system console device` 管 getty——设备与实际口不符会把
  # systemd 自动起的串口 getty 顶掉 → 串口无登录提示。故按本板 BOARD_SERIAL_CONSOLE
  # 修正（RK3568/R5S 调试口=uart2=ttyS2）。ttyS0 的板无操作。
  if [[ "${BOARD_SERIAL_CONSOLE}" != "ttyS0" ]]; then
    local cfgdef="${ROOTFS_DIR}/usr/share/vyos/config.boot.default"
    if [[ -f "${cfgdef}" ]]; then
      log "console device: ttyS0 → ${BOARD_SERIAL_CONSOLE}（config.boot.default）"
      run sudo sed -i "s/device ttyS0 {/device ${BOARD_SERIAL_CONSOLE} {/" "${cfgdef}"
    fi
  fi

  log "mksquashfs → ${vdir}/${version}.squashfs（comp xz, block 262144）"
  run sudo mksquashfs "${ROOTFS_DIR}" "${vdir}/${version}.squashfs" \
    -comp xz -b 262144 -noappend -no-progress

  # --- boot 文件（vmlinuz/initrd）从解包 rootfs 取 -----------------------------
  local f
  for f in "${ROOTFS_DIR}/boot/"*; do
    [[ -f "${f}" ]] && run sudo cp "${f}" "${vdir}/"
  done

  # 内核 DTB 一并放入版本目录（U-Boot EFI 默认传自己的控制 DT；这份留作调试/手动 fdt
  # 覆盖的后手，升级时随版本目录走）
  local dtb
  for dtb in "${ROOTFS_DIR}/usr/lib/linux-image-"*/rockchip/rk35*.dtb; do
    [[ -f "${dtb}" ]] && run sudo install -Dm644 "${dtb}" "${vdir}/dtbs/rockchip/$(basename "${dtb}")"
  done

  # 板级 DTB override：把本板内核 DTB 复制成固定名 /boot/<version>/dtb。
  # grub menuentry 模板（hooks/live/94-rockchip-grub-devicetree.chroot 注入的条件块）
  # 见到这个文件就 `devicetree` 加载它，让内核用我们随版本走的 DTB，不受板载残留旧
  # U-Boot 控制 DTB 影响。仅对设了 BOARD_DTB_OVERRIDE=1 的板生效。
  if [[ "${BOARD_DTB_OVERRIDE:-0}" == "1" ]]; then
    local kdtb
    for kdtb in "${ROOTFS_DIR}/usr/lib/linux-image-"*/"${BOARD_KERNEL_DTB}"; do
      [[ -f "${kdtb}" ]] || continue
      run sudo install -Dm644 "${kdtb}" "${vdir}/dtb"
      log "DTB override 启用：/boot/${version}/dtb ← ${BOARD_KERNEL_DTB}"
      break
    done
  fi

  # --- 在解包 rootfs 里 chroot：官方代码装 grub + 生成 grub.cfg.d -----------------
  run sudo mount --bind "${MNT_DIR}/root" "${ROOTFS_DIR}/mnt"
  run sudo mount "${IMG_LOOP}p1" "${ROOTFS_DIR}/mnt/boot/efi"
  run sudo mount --bind /dev "${ROOTFS_DIR}/dev"
  run sudo mount -t proc proc "${ROOTFS_DIR}/proc"
  run sudo mount -t sysfs sys "${ROOTFS_DIR}/sys"
  run sudo mount -t tmpfs tmpfs "${ROOTFS_DIR}/tmp"
  run sudo cp "${RESOURCES_DIR}/grub-setup.py" "${ROOTFS_DIR}/tmp/"

  # 显式给 PATH：宿主 sudo 的 secure_path 不含 /usr/sbin，而 Debian rootfs 里
  # grub-install 在 /usr/sbin，不给会 ENOENT。
  local chroot_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  run sudo chroot "${ROOTFS_DIR}" env PATH="${chroot_path}" \
    grub-install --target=arm64-efi \
    --no-nvram --removable --boot-directory=/mnt/boot --efi-directory=/mnt/boot/efi
  run sudo chroot "${ROOTFS_DIR}" env PATH="${chroot_path}" \
    python3 /tmp/grub-setup.py \
    --root-dir /mnt --version "${version}" \
    --console-type "${CONSOLE_TYPE}" --console-num "${CONSOLE_NUM}" \
    --console-speed "${BOARD_SERIAL_BAUD}"

  run sync
  cleanup_image
  trap - EXIT
  run sudo rm -rf "${ROOTFS_DIR}"

  # --- 压缩归档 -----------------------------------------------------------------
  local out="${OUT_DIR}/$(basename "${img}").zst"
  run zstd -T0 "-${ZSTD_LEVEL}" --force -o "${out}" "${img}"
  [[ "${KEEP_RAW_IMAGE}" == "1" ]] || run rm -f "${img}"

  section "完成：${out}"
  log "烧录：zstd -dc '${out}' | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress"
  log "串口：${BOARD_SERIAL_CONSOLE} @ ${BOARD_SERIAL_BAUD}n8；默认账户 vyos/vyos"
}
