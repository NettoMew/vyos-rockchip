#!/usr/bin/env python3
# resources/grub-setup.py — 在 VyOS squashfs chroot 内运行（python3 与 vyos-1x
# 均来自镜像自身，版本天然匹配）。生成官方 grub.cfg.d 结构并注册版本，调用序列
# 与 vyos-build 的 raw_image.py / vyos-1x 安装器完全同构，故 `add system image`
# 与 `set system image default-boot` 开箱即用。
#
# 用法（root_dir 为未来根分区在 chroot 内的挂载点）：
#   python3 grub-setup.py --root-dir /mnt --version 2026.06.13-0001-rockchip \
#       --console-type ttyS --console-num 0 --console-speed 1500000

import argparse

import vyos.template
from vyos.system import grub


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument('--root-dir', required=True)
    p.add_argument('--version', required=True)
    p.add_argument('--console-type', default='ttyS')
    p.add_argument('--console-num', default='0')
    p.add_argument('--console-speed', default='115200')
    p.add_argument('--timeout', default='5')
    args = p.parse_args()

    root = args.root_dir
    boot_settings = {
        'timeout': args.timeout,
        'console_type': args.console_type,
        'console_num': args.console_num,
        'console_speed': args.console_speed,
        'bootmode': 'normal',
    }

    print(f'I: writing GRUB configuration structure to {root}')
    grub.create_structure(root)
    vyos.template.render(f'{root}/{grub.GRUB_DIR_MAIN}/grub.cfg', grub.TMPL_GRUB_MAIN, {})
    grub.common_write(root)
    grub.vars_write(f'{root}/{grub.CFG_VYOS_VARS}', boot_settings)
    grub.modules_write(f'{root}/{grub.CFG_VYOS_MODULES}', [])
    grub.write_cfg_ver(1, root)
    vyos.template.render(f'{root}/{grub.CFG_VYOS_MENU}', grub.TMPL_GRUB_MENU, {})
    vyos.template.render(f'{root}/{grub.CFG_VYOS_OPTIONS}', grub.TMPL_GRUB_OPTS, {})

    print(f'I: registering image version {args.version}')
    grub.version_add(args.version, root)
    grub.set_default(args.version, root)
    grub.set_console_type(args.console_type, root)

    # 让 GRUB 按字母序读取配置片段（与官方 raw 镜像一致）
    grub.sort_inodes(f'{root}/{grub.GRUB_DIR_VYOS}')
    grub.sort_inodes(f'{root}/{grub.GRUB_DIR_VYOS_VERS}')

    print('I: GRUB configuration complete')


if __name__ == '__main__':
    main()
