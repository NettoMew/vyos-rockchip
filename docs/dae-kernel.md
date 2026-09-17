# DAE 内核契约与 BTF 故障复盘

记录日期：2026-09-16。本文区分配置意图、实际构建产物、虚拟机启动和真机运行证据。
完整配置以 [`73-dae.config`](../overlay/scripts/package-build/linux-kernel/config/73-dae.config)
为唯一维护来源，不另建第二套配置片段。

## 故障及根因

`2026.09.15-22dfa159-rockchip` 的 E52C 用户启动 Mayami 时出现：

```text
program tproxy_lan_egress_l2: apply CO-RE relocations:
load kernel spec: no BTF found for kernel version 6.18.50-vyos: not supported
```

交叉编译容器缺少 pahole，最终配置 `CONFIG_PAHOLE_VERSION=0`。
上游片段虽请求 `CONFIG_DEBUG_INFO_BTF=y`，合并后的 Kconfig 将其取消，ELF 无 `.BTF`。
编译和打包成功不等于功能配置生效，也不等于 DAE 可以加载。

`CONFIG_BPF_STREAM_PARSER` 同时缺失，不满足此次要求的兼容基线；但它不是已证明的第二个
直接故障原因。当前 Mayami 不使用 stream-parser attach，不能仅凭该项缺失就断言 SOCKMAP
必定不可用。此次 CO-RE 报错的直接根因是缺 BTF。

## 能力分组

| 能力 | 关键配置 | 对应路径 |
|---|---|---|
| BPF 加载与 JIT | BPF、BPF_SYSCALL、BPF_JIT | eBPF 程序、maps、SOCKMAP |
| 进程追踪 | CGROUPS、CGROUP_BPF | cgroup socket hooks，在 Initialize 阶段挂载 |
| TC 重定向 | NET_SCHED、NET_INGRESS、NET_EGRESS、NET_CLS_ACT、NET_SCH_INGRESS、NET_CLS_BPF | WAN/LAN direct-action TC |
| 独立网络空间 | NAMESPACES、NET_NS、VETH | netns 与 veth 投递路径 |
| 双栈策略路由 | INET、IPV6、IP_ADVANCED_ROUTER、IP_MULTIPLE_TABLES、IPV6_MULTIPLE_TABLES | IPv4/IPv6 监听及 mark/local 路由 |
| 运行环境 | PROC_FS、SYSFS、SYSCTL | cgroup/BPF/网络运行配置 |
| CO-RE 类型信息 | DEBUG_KERNEL、DEBUG_INFO、DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT、DEBUG_INFO_BTF | pahole 从 DWARF 生成 BTF |
| 兼容基线 | BPF_STREAM_PARSER、KPROBES、KPROBE_EVENTS、BPF_EVENTS | 保留上游及维护者要求，不宣称当前全部使用 |

禁止 DEBUG_INFO_NONE、DEBUG_INFO_REDUCED、DEBUG_INFO_SPLIT。
契约中 `=y` 必须内建；`=m` 接受模块或内建。必须发布并验证实际使用的模块，不能只看配置。

当前 TC 使用 direct-action，不因此额外要求 NET_ACT_BPF；BPF sk_assign 路径也不能等同于
iptables TPROXY target 的配置要求。IPv6 不是可随意删去的优化项，Mayami 创建双栈监听。

## 已落地的构建门禁

修复提交：

- `d19a451`：容器增加 pahole、声明能力契约、配置与包内 BTF/内核验收及回归。
- `48c6b66`：正确校验压缩 ARM64 内核载荷。

相关文件：

- [`docker/Dockerfile.host`](../docker/Dockerfile.host)：仅在容器安装 pahole。
- [`lib/kernel.sh`](../lib/kernel.sh)：`kernel_validate_config`、`kernel_validate_btf`、`kernel_validate_build`。
- [`tests/kernel-features.sh`](../tests/kernel-features.sh)：缺项、空输入、BTF、包损坏及 raw/gzip 载荷回归。
- [`tests/build-cache.sh`](../tests/build-cache.sh)：独立缓存回归使用最小能力 fixture。

接受内核包之前依次检查：

1. 最终 `.config` 满足契约，而非仅 grep 配置片段。
2. ELF 含非空 `.BTF` 段。
3. 实际 DEB 的配置满足契约，并与源码最终配置逐字节一致。
4. 实际 DEB 的内核载荷与构建出的 Image 一致；gzip 载荷先解压，损坏压缩流必须失败。
5. 检查失败不得发布该包，也不得拿旧包冒充本次成功。

## E52C 修复构建证据

| 项目 | 记录 |
|---|---|
| 镜像版本 | `2026.09.16-dae-btf1` |
| 源码提交 | `48c6b66aef51def25dffacef78adc8e35b180072` |
| 内核 release | `6.18.50-vyos`，此次修配置，不升 release |
| pahole | 1.30，CONFIG_PAHOLE_VERSION=130 |
| BTF | 非空且可解析，运行时 5,421,768 字节 |
| r8125 | 官方 `9.018.00-NAPI-RSS`，新内核同树重编、同签名密钥 |
| 构建宿主 | v2in0，专用项目目录与 Docker；未往宿主追加编译依赖 |
| 本次重编范围 | 仅 E52C，不是四板重新验收 |

ISO SHA256：

```text
b2826b9caa7b29a91515f640d681141c8d24eb6294aa812f1b0862f535a7344a
```

内核 DEB SHA256：

```text
eaaddd8e7e4ce8198fb9964ee1529d8700bd8cc5c588954e079c11c37e6ca9c8
```

实际 DEB 启动 ARM64 QEMU，虚拟 WAN/LAN 使用 veth，没有外部网络后端。
Mayami `2026.9.15-c418e20d` 完成 eBPF 加载、cgroup hooks、WAN/LAN TC 挂载、
TCP4/TCP6、双栈 UDP、ICMP4/ICMP6 监听与正常退出，日志最终为 `DAE_QEMU_PASS`。

成品验证覆盖 ISO 内部摘要、配置与 Image 一致性、TC/veth/r8125 模块架构、vermagic、
签名及 modules.dep；另验证压缩流、GPT 主备 CRC、U-Boot 嵌入内容、FAT/ext4、EFI、DTB
和同板 ISO/整盘 squashfs 一致性。基础 SBOM 不包含后注入板级资产，后者单独验证。

首次验收曾错误地把包内 Image.gz 与 raw Image 直接比较。修正校验器及回归后，重新验证
已构建的真实 DEB，再继续 ISO/r8125/U-Boot/镜像阶段；没有伪造内核缓存戳。
原始 build.log 末尾的旧校验失败应与最终 packaging/verification 成功日志一起解读。

维护工作站的 `out/2026.09.16-dae-btf1/` 保存 source.bundle、README、SHA256SUMS、
QEMU harness 和 evidence。该目录是本地成品归档，不是 Git checkout 保证包含的文件。

## 现场验收与尚未验证的边界

后续真机调查已确认 Suki 启动 `6.18.50-vyos`，`/sys/kernel/btf/vmlinux` 存在，
Mayami 可手动运行；修正缓存属主并完成单实例交接后，systemd 运行正常。
这补充了构建时尚未进行的现场证据，但没有证明 WAN 长期不再断链，也没有完成吞吐压测。

```bash
show version
uname -r
wc -c /sys/kernel/btf/vmlinux
sudo ethtool -i eth0
sudo journalctl -u mayami.service -b --no-pager -n 100
```

BTF 字节数只标识本次产物；后续版本不要求固定大小。除 BTF 外，还须实际加载程序和模块，
检查 cgroup 挂载、服务权限及网络路径。QEMU 不能证明 E52C PHY、PPPoE 或真实硬件转发稳定。

特别注意两个非内核故障：

- eth0/eth1 缺少 hw-id、eth2/eth3 却绑定 MAC 时，VyOS 后续命名解析可覆盖板级早期命名；
  应按实际物理口核对持久配置。TTL 排障时未插网线的 NO-CARRIER 不构成驱动缺陷证据。
- `cache.db: permission denied` 或 `gateway module directory is already managed` 分别指向
  文件权限和并发实例占锁，不能再次归因于 BTF。新镜像也不会自动包含手工安装的 Mayami。

发布升级使用完整 ISO，保留可回退镜像并单独备份应用状态；不要把补内核 DEB 当成完整的
VyOS 镜像升级流程。有关版本、容器边界和通用验收见 [维护与构建](maintenance.md)。
