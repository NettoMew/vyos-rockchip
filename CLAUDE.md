# CLAUDE.md — 项目向导（给 Claude Code 看的）

VyOS（rolling）→ Rockchip 板整盘镜像构建器：RK3528（e20c 真机验证通过，m28k 已验证）
+ RK3568（r5s 已实现待真机验证）。一个内核 + 一张 ISO 服务全 SoC 家族（主线"一个
内核带全 DTB/全 SoC"同构）；板间差异全在 `boards/<b>/board.conf` 声明 + overlay 数据投放。
哲学与隔壁 `../alpine` 同源：**声明式 board 轴 + 引擎零板级 if 分支**，但 VyOS 侧
全走官方机制 —— 我们对 vyos-build 的全部定制都是 `overlay/` 文件投放（flavor toml、
内核 kconfig 片段、内核补丁），利用 vyos-build 自身的 glob（`config/*.config`
自动 merge、`patches/kernel/*.patch` 自动应用），不打 vyos-build 的补丁。

## 入口 & 跑法
- `make e20c` 全链；`make e20c-dry` 秒级验证改动（不构建/不联网/不 sudo）。
- `make kernel` / `make iso`：板无关共享产物（RK3528 家族一个内核一张 ISO）。
- 缓存跳过逻辑：内核 deb 在 `work/vyos-build/packages/`、ISO 记录在
  `work/state/iso-path`、U-Boot 在 `work/uboot/<board>/`。`REBUILD_{KERNEL,ISO,UBOOT}=1` 强制。
  两道 sha256 输入指纹自动重建，免去"忘了 REBUILD_* 烧到旧镜像"：内核=补丁+config 片段
  （`kernel-inputs.sha256`）；ISO=overlay 全量（flavor/hook/includes，`iso-overlay.sha256`）
  + 内核 deb mtime。改 flavor/hook 直接 `make <board>` 即自动重建 ISO。
- 开箱默认配置由 flavor 的 `default_config` 字段提供（build-vyos-image 写成镜像的
  `/usr/share/vyos/config.boot.default`）：eth0/eth1 都 DHCP + 开 SSH，上电插网线即可 SSH 进，
  无需先接串口。不写 hw-id → 对任意 RK3528 双口板通用。**前提：两个口都被识别**（e20c
  已验证 r8169=eth0 + gmac=eth1）；若某板单口，config 配了不存在的 eth1 会让首启 commit 失败。

## 关键事实（改动前先核对）
- 内核版本以 `work/vyos-build/data/defaults.toml` 的 `kernel_version` 为准（6.18.x），
  与官方 arm64 仓库的包生态严格一致；官方仓库已有 arm64 全家桶（含 linux-image），
  但官方内核**缺 RK3528 启动驱动**（MMC_DW_ROCKCHIP / PCIE_ROCKCHIP_DW_HOST /
  NANENG combo PHY / MOTORCOMM_PHY）→ 这就是本地编内核的唯一原因，片段在
  `overlay/scripts/package-build/linux-kernel/config/70-rockchip-rk3528.config`。
- 本地内核 deb 放进 `packages/` 后由 build-vyos-image 当 packages.chroot 直装，
  压过仓库同名包 —— 不要动这个机制。
- 镜像布局：u-boot-rockchip.bin@sector64（rkbin TPL+BL31，RK3528 用
  bl31_v1.20 + ddr_1056MHz_v1.11）；ESP 从 16MiB 起（u-boot 占到 ~10MiB，别下调）；
  root 分区 label 必须是 `persistence`（live-boot 按 label 找持久层）。
- grub 结构由 squashfs chroot 内的 `resources/grub-setup.py` 调 `vyos.system.grub`
  生成（与官方 raw_image.py 同构）→ `add system image` 原生可用。改启动行为去
  vyos-1x 的模板找，别手写 grub.cfg。
- chroot 依赖宿主 qemu binfmt 带 F 标志；/dev 用**非递归 bind**（rbind+lazy umount
  会把宿主 devpts 拽掉，见 alpine 项目的血泪注释）。
- 串口：RK3528 = ttyS0 @ 1500000。flavor `rockchip.toml` 覆盖 arm64.toml 的 ttyAMA。

## 加板（m28k 已按此落地，引擎零改动）
`boards/<b>/board.conf`（声明）+ `boards/<b>/uboot/`（U-Boot 源投放，镜像树结构）+
`boards/<b>/overlay/.../patches/kernel/*.patch`（内核 DTS/补丁）。板级资产源头在
`../alpine/boards/m28k/`，已复制（非引用）。m28k 的 8 个补丁（含现做的 132 PCIe 节点 backport——6.18.34 的 rk3528.dtsi 没有 pcie 节点和 phy.h include，板级 DTS 引用 &pcie 必须先补）已验证在 6.18.34
按 ls 序干净应用；140 号"加 DTS"补丁是用 diff -ruN 现做的（alpine 用 hook cp，
我们走 patch glob）。内核输入有 sha256 指纹（work/state/kernel-inputs.sha256），
补丁/片段一变 stage_kernel 自动重编——别绕过这个机制手动摸 packages/。

## DTB override 机制（m28k PCIe 真机踩坑后加，2026-06-13）
VyOS arm64 走 U-Boot EFI，grub 默认不加载 devicetree → 内核用的是 **U-Boot 控制
DTB**，不是内核 deb 里的。坑：m28k 出厂 eMMC 残留旧 U-Boot（rc3），其 DTB
PCIe disabled，导致第二网口（PCIe RTL8111）起不来。修法 = 让内核改用我们随版本
走的 DTB：① `boards/<b>/board.conf` 设 `BOARD_DTB_OVERRIDE=1` → image.sh 把
`BOARD_KERNEL_DTB` 复制成 `/boot/<版本>/dtb`；② hook `94-rockchip-grub-devicetree.chroot`
给 vyos-1x 的 grub menuentry 模板插条件块 `[ -e /boot/<ver>/dtb ] && devicetree ...`
（改模板本身，VyOS 运行时重新生成 menuentry 也带，不会被抹）。e20c 不开（U-Boot
DTB 正常，且其内核 DTB 还没 pcie 引用）。**别手动改 grub.cfg.d——VyOS 启动的
"Update GRUB" 服务会重新生成抹掉，必须改模板。**
RK3528 PCIe backport 三件套（都在 boards/m28k overlay 的 patches/kernel）：132 加
pcie 节点 + phy.h include；**133 把 soc ranges 从 0xfe000000/0x2000000 扩成
0xfc000000/0x44000000**（否则 config/IO/MEM 翻译失败，dwc 报 "Missing config reg
space"）；6.18 dwc 无 rk3528、靠 compatible fallback rk3568。141 给 gmac1 固定
local-mac-address（RK3528 无 fused MAC，否则每启随机、DHCP IP 漂移）。

## AIC8800 Wi-Fi（m28k，2026-06-13 真机验证 wlan0 up）
驱动 radxa-pkg/aic8800@89f865b（SDIO）+ boards/m28k/aic8800/ 两补丁：0001=7.1 port
（alpine 来），0002=我做的 6.18 适配（9 个 cfg80211 ops wireless_dev→net_device +
体首 wdev=ndev->ieee80211_ptr、2 处 add_key/del_station 调用、cfg80211_new_sta/del_sta
传 ndev、tdls_discover_resp 加一层 .u）。`stage_aic8800`（lib/aic8800.sh，在 kernel 后、
iso 前）：用**同一棵 work/kernel 树**交叉编（LOCALVERSION=-vyos 对齐 vermagic；
CONFIG_SDIO_BT=n——D80 的 BT bringup 会 hang）→ `scripts/sign-file sha512` 用内核
signing_key 签（过 MODULE_SIG_FORCE，同树同 key）→ 模块+固件+modules-load.d 投放
includes.chroot。hook 96 在 chroot depmod。flavor 加 hostapd/wpasupplicant/iw/wireless-regdb。
BOARD_WIFI_AIC8800=1 启用。
**关键坑**：运行时手动 insmod 会 -110（SDIO 已 idle 超时），**必须开机早期
modules-load.d 加载**（SDIO 刚枚举时）——这是 alpine 一直用 modules-load.d 的原因。
验证过：开机加载 → fmacfw_8800d80_u02.bin 下载 → wlan0 up。AP(hostapd) 真机未验。
ISO 家族共享：aic8800 进共享 ISO，e20c 也会带（modules-load 加载 aicbsp 在无 chip 时
会超时几秒，待优化为 udev modalias 板自适应）。

## 网口命名固定 + LED + OLED（m28k，2026-06-13 实现待真机验证）
- **命名固定**：`overlay/.../includes.chroot/etc/udev/rules.d/60-rockchip-net.rules`
  按 driver 设 `VYOS_IFNAME`（`rk_gmac-dwmac`→`eth1`=LAN，`r8169`→`eth0`=WAN），
  VyOS 的 65-vyos-net.rules 走 `vyos_net_name` 的 predefined 路径采用它 → 不再随
  probe 顺序漂移。板无关（e20c 同样 gmac+r8169，一致受益）。**待验**：实测
  vyos_net_name 是否吃 VYOS_IFNAME。
- **pcie MAC 固定**：`includes.chroot/etc/systemd/network/10-rockchip-wan.link`
  设 r8169 MAC（gmac MAC 由 DTS 141 固定）。ISO 家族共享 → e20c 也被设此 MAC，
  多板同时部署需板级化（image.sh 注入，后续）。
- **LED**：`includes.chroot/usr/local/sbin/rockchip-leds.sh` + `rockchip-leds.service`
  （默认 enabled）。按网卡 driver 认 LAN(gmac)/WAN(pcie) 绑 netdev：white:lan→gmac、
  white:wan→pcie、stmmac-0:01 PHY 灯→gmac、green:status→heartbeat。**不依赖 eth 编号**
  （命名漂了也对）；缺对应 LED name 的板静默跳过。物理对应已实机确认：LAN=gmac=eth1。
- **OLED**：内核 `CONFIG_DRM_SSD130X=m`+`_I2C=m`（DTS oled@3c 在 140，DRM/fbdev
  已 =y）→ udev 按 OF modalias 自动加载 → /dev/fb0。`lib/oled.sh` 的 `stage_oled`
  把 alpine 的 oled-dash 静态交叉编译打成 `vyos-oled-dash_*.deb` 放 packages/ 进镜像，
  **systemd 服务默认 disabled**（无 wants symlink），手动 `systemctl enable --now oled-dash`。
  BOARD_OLED_DASH=1 启用。stage_oled 在 build.sh 的 aic8800 后、iso 前。

## NanoPi R5S（RK3568，2026-06-13 实现待真机验证）
纯主线，与 e20c 同属"声明即可"：主线 6.18.34 自带 `rk3568-nanopi-r5s.dts(i)`，U-Boot
有 `nanopi-r5s-rk3568_defconfig`，rkbin 有 rk3568 blob → **U-Boot/内核零补丁**。三网口：
gmac0(1G,RGMII+RTL8211F)=WAN + 2× RTL8125(2.5G,pcie3x1/3x2)=LAN。差异全声明在
`boards/r5s/board.conf` + 三处数据投放（引擎零 if 分支）：
- **SoC=rk3568** → `lib/env.sh` 的 rk3568 case 选 rk3568 rkbin glob。
- **串口 ttyS2**（DTS `chosen: serial2:1500000n8`，非 RK3528 的 ttyS0）→ board.conf
  `BOARD_SERIAL_CONSOLE=ttyS2`，env 派生 CONSOLE_NUM=2，grub-setup.py 自然吃。flavor 的
  `default_config` 仍写 `console device ttyS0`（家族共享 ISO，板无关）——R5S 上它是良性
  冗余：内核 `console=ttyS2` 由 grub 设，systemd-getty-generator 据此自动在 ttyS2 起
  serial-getty，串口登录照常；ttyS0 的 VyOS getty 落到未接的 uart0 无害。
- **PCIe3 PHY**：`config/71-rockchip-rk3568.config` 加 `CONFIG_PHY_ROCKCHIP_SNPS_PCIE3=y`
  （RK3528 的 70 片段已覆盖其余 Rockchip 启动/网卡件，SoC 无关）。两个 RTL8125 挂 pcie3，
  缺此 PHY 则不 link。RK3528 无 pcie3 → 死代码零副作用。
- **RK809 PMIC（真机首测踩坑，2026-06-14）**：71 片段还必须加 `CONFIG_MFD_RK8XX=y`
  `CONFIG_MFD_RK8XX_I2C=y` `CONFIG_REGULATOR_RK808=y` `CONFIG_COMMON_CLK_RK808=y`。R5S 的
  rk809（i2c@fdd40000/pmic@20）regulator 供 gmac0(WAN)/sdmmc0(SD)/sdhci(eMMC)/io-domains
  电；缺驱动则 rk809 不 probe → 这些全 **deferred probe** → live-boot 找不到根设备死循环
  （首测就卡这）。必须 =y（MMC 是根，不能赌 initrd 模块序）。RK3528 用别的 PMIC，inert。
  **教训：移植新 RK 型号先确认其 PMIC 驱动在内核里。**
- **r8125 驱动**（用户指定，OpenWrt 同款，性能/特性优于主线 r8169）：`lib/r8125.sh` 的
  `stage_r8125`（与 aic8800 同构，kernel 后 iso 前，须 `KERNEL_BUILD_MODE=cross`）clone
  `openwrt/rtl8125@9.016.01`(commit a9197034) → 同棵 work/kernel 树交叉编 `r8125.ko`
  （`make M= modules`，obj-m flat 布局）→ 内核 key 签名 → 投放 includes.chroot +
  `modules-load.d/r8125.conf`。BOARD_R8125=1 启用。**r8169↔r8125 共存**靠内核补丁
  `patches/kernel/150-r8169-yield-rtl8125-ids-to-r8125.patch`（家族级，全局 overlay）从
  r8169 PCI 表移除 RTL8125 ID（0x8125/0x3000）→ r8125 独占绑定，无 driver_override/解绑
  竞态。RK3528 板无 RTL8125 不受影响。若 9.016.01 对 6.18 编译报 net API，放
  `boards/r5s/r8125/*.patch` 适配（如 aic8800 的 0002）。
- **DTB override 开**（BOARD_DTB_OVERRIDE=1）：三口全经 PCIe，确保用含 pcie3 的内核 6.18 DTB
  而非可能偏旧的 U-Boot 控制 DTB（同 m28k 思路）。
- **命名/LED 三板不变式**：命名规则确立 **eth0=WAN、eth1(+eth2)=LAN** 对三板一致
  （rk3528 是 pcie=WAN/gmac=LAN，R5S 是 gmac0=WAN/RTL8125=LAN，最终 eth 角色相同）。
  60-rockchip-net.rules 追加 R5S 按 **PCIe 控制器平台路径**钉名（driver 无关，不受
  r8169↔r8125 影响；地址 RK3528 不存在故正交）：`fe2a0000.ethernet`→eth0、
  `fe280000.pcie`→eth1、`fe270000.pcie`→eth2（通用 gmac 规则先给 R5S gmac0 赋 eth1，
  路径规则后覆盖回 eth0）。**rockchip-leds.sh 已重写为按接口名绑灯**（eth0→WAN 灯、
  eth1→LAN/LAN-1、eth2→LAN-2，灯名 white:* / 大写 按板族择一存在），彻底去掉按 driver
  的 LAN/WAN 判断 → 三板共用零分支。**待真机确认**：物理 LAN-1/LAN-2 端口↔pcie3x1/3x2
  顺序（不对就在 60-rules 对调那两行的路径）；gmac0 WAN MAC 是否 efuse 稳定（不稳再加
  板级 .link，注意 10-rockchip-wan.link 只匹配 r8169，对 R5S 不生效）。

## C2 板级资产隔离：板无关 base ISO + 每板 host 侧注入（2026-06-13）
**问题**：ISO 家族共享 + packages/ 累积 → m28k 编的 oled deb / aic8800 .ko 会被打进
所有板的镜像（r5s 也带 oled、e20c 误载 aic8800 超时）。**C2 解法**（极致优雅、单 ISO 不变）：
- **base ISO 板无关**：aic8800/r8125/oled 三个阶段不再写共享 `includes.chroot/packages`，
  改产到 `work/board-assets/<board>/`（env 的 `BOARD_ASSETS_DIR`，镜像 rootfs 目录结构）。
  `stage_overlay` 末尾清掉历史遗留的板级注入（pre-C2 残留），保证 base 干净。
- **image 阶段 host 侧注入**（`lib/image.sh`，无 qemu）：`unsquashfs` base 的
  filesystem.squashfs → `rsync` 注入本板 board-assets → `depmod -b`（收编 updates/ 模块）
  → `mksquashfs -comp xz -b 262144` 重打包成该板 squashfs 进持久层 → grub 在解包目录里
  chroot 安装。每板镜像只带自己的资产，内核+base 各算一次，host 原生几分钟。
- **阶段序**：`deps sources overlay builder kernel iso aic8800 r8125 oled uboot image`
  —— iso 产板无关 base（`make iso` 即止于此）；aic8800/r8125/oled 在其后产 board-assets
  （需 cross 内核树）；image 注入。iso 指纹（`iso_overlay_digest`）只看 overlay/+boards/*/overlay，
  不含板级资产（其变化由 image 每次重新注入接住）。
- **host 依赖**：squashfs-tools（unsquashfs/mksquashfs）、depmod（kmod）。
- **遗留**：flavor 的 wifi apt 包（hostapd/wpasupplicant/iw/wireless-regdb）仍在 base
  共享（apt 包，chroot 内装，搬到每板需 image 阶段 apt，过重）；它们 inert 无害,暂留。

## build-type=release（2026-06-13，修 lb build 失败）
`build-vyos-image` 默认 `--build-type development` → 塞 gdb/strace/vim + **vyos-1x-smoketest**，
后者 postinst 会拉测试容器（docker blob），网络抖动即 `EOF`→postinst 退 1→`lb build` 失败
（实测报错）。`lib/iso.sh` 固定传 **`--build-type release`**（只多一段 EULA includes，
对路由成品镜像更干净更瘦，且去掉那次 docker 拉取）。

## CI：GitHub Actions 原生 arm64（.github/workflows/build.yml）
`runs-on: ubuntu-24.04-arm`（原生 arm64，**无 qemu** → lb build 不再被仿真拖，相对本地 x86 提速
5–10×）。**仅手动触发**（`workflow_dispatch`，选板型；故意不挂 push 触发，免每次提交白跑）。
- **跳过 `deps` 阶段**：它的 qemu-binfmt 检查在原生 arm64 上会误报 fatal（原生不需要 binfmt）；
  依赖改用 apt 装。`KERNEL_BUILD_MODE=cross`（r8125/aic8800 要宿主侧内核树）。
- **官方 `vyos/vyos-build:current` 是单架构 amd64**（没有 arm64 变体——其 manifest 是单个 v2
  manifest，不是多架构 manifest list）。arm64 runner 上 `docker pull --platform linux/arm64`
  只会拿到那唯一的 amd64，`builder.sh` 判出不对会回退「用 `work/vyos-build/docker` 的 Dockerfile
  本地原生构 arm64 容器」——结果正确但白拉一趟。故 CI 里设 **`BUILDER_PULL=0`** 直接走本地构建。
- **三道 actions/cache**：① `work/src`（u-boot/rkbin 等克隆，省下载）；② `work/kernel`+输入指纹
  （内核片段/补丁没变就跳过重编，且这棵已编树供 r8125/aic8800 编 out-of-tree 模块）；③ 本地构的
  arm64 builder 容器镜像（`docker save|zstd`，key=`builder-<arch>-vN`，vyos-build Dockerfile
  变了就 bump 版本刷新）。**base ISO 不缓存**：每次全新 lb build（VyOS rolling 包集会动，求新鲜）。
- 产物 `out/*.img.zst` 传 artifact。手动跑：`gh workflow run build-image -R <owner>/vyos-rockchip -f board=r5s`。

## 内核两种构建模式（KERNEL_BUILD_MODE）
container（默认）= 官方 build.py 进 arm64 容器；cross = 宿主机交叉 bindeb-pkg
（复刻 build-kernel.sh 语义：同补丁序、同 config 片段、同证书链、同版本号；
不带 BUILD_TOOLS=perf——它在 arm64 有并行竞态且镜像不装）。cross 树在
work/kernel/（host 属主），每次全新解包保证确定性。6.18 kbuild 的 debian/rules 已 debhelper 化 → 宿主机需 debhelper（Arch 走 AUR），且必须 DPKG_FLAGS=-d（Arch 无 dpkg 包数据库，checkbuilddeps 必误报）。迭代 DTS 用
`KERNEL_BUILD_MODE=cross make m28k`（指纹机制会自动触发重编）。

## 真机调试已踩过的坑（2026-06-13，e20c 首跑）
- **console speed 1500000 不在 vyos-1x 白名单**（只到 115200）→ 首次 commit 在
  system_console 校验失败 → 串口只见 "Configuration error"、网卡名卡在 e2/e3
  （e2/e3 是 vyos_net_name 的中间名，coldplug 换名在 configure 阶段，属下游症状）。
  修复 = `overlay/.../hooks/live/93-rockchip-console-speed.chroot`（chroot hook 把
  1500000 sed 进编译产物 node.def），改动 hook 后需 `REBUILD_ISO=1`。
- 良性噪音别误判：`mounting /dev/mmcblk1 on /live/persistence failed`（live-boot
  探整盘）、`biosdevname error`（arm64 无此工具，有 eth 兜底）、`password changed
  in future` + rsyslog 首次失败（无 RTC 时钟回拨，chrony 联网后自愈）、
  `GPT alternate header not at end`（镜像小于卡容量）。
- 事后取证手法：持久层 `/boot/<版本>/rw/var/log/journal` 用
  `journalctl -D <dir>` 直接在 PC 上读；commit 细节看 rw 层 `var/log/vyatta/cfg-std*.log`；
  配置在 `rw/opt/vyatta/etc/config/config.boot`。

## 验证
- 改完：`bash -n lib/*.sh scripts/build.sh` + `make e20c-dry`。
- 镜像抽查：`zstd -dc out/X.img.zst | sudo losetup -fP --show …`，看 p2 的
  `/boot/<版本>/`、`persistence.conf`、`boot/grub/grub.cfg.d/`、ESP 的 BOOTAA64.EFI。
- 首跑风险点：U-Boot EFI bootflow 真机验证；qemu 仿真下 ISO 构建耗时数小时属正常。
