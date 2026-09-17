# E52C 网络调优：VyOS 配置边界

核验日期：2026-09-16。对象为现场运行的 `2026.09.16-dae-btf1`、Linux
`6.18.50-vyos`、官方 r8125 `9.018.00`。现场仅检查运行状态、CLI 模板、已安装
实现和上游资料。前期部署由用户执行；22:11–22:22 +0800 经用户授权，执行了
LAN 短时 TCP 接收基线及 RPS/RFS 对照，并恢复原配置。未重编内核。
各阶段的部署、测试及限制分别记录如下。

## 结论

优先让 VyOS 管理其已有配置入口，不再用板级启动脚本重复管理相同设置。
精确 IRQ/XPS 分配和 DEBUG_PREEMPT 不存在已核验的等价 VyOS 配置命令，不能
编造官方语法，也不能把性能 profile 当作精确队列分配方案。

LAN 本机接收对照未证明稳定收益，保留原 RPS/RFS 配置。尚未完成有线转发或
代理负载对照，本文不宣称吞吐优化，也不把网络调优作为 WAN 断链修复。

## 已部署旧镜像存在两套配置来源

`overlay/data/live-build-config/includes.chroot/usr/local/sbin/rockchip-net-tune.sh`
在启动时强制设置 GRO/GSO/TSO/SG、RPS/RFS/XPS 和 CPU governor。
现场 `/usr/lib/python3/dist-packages/vyos/ifconfig/ethernet.py` 的 `update()`
在网口配置应用时重新设置各项 offload：配置节点不存在通常意味着关闭，而非保持现状。

所以配置提交可能覆盖启动脚本，重启后的脚本又可能覆盖配置。`commit-confirm`
只能回退 VyOS 配置，不能保证还原这些配置之外的运行参数。

不能只执行 `set ... offload rx` 就声称完成单变量实验：同次网口更新可能同时
关闭未写入配置的 GRO/GSO/TSO/SG/RPS/RFS。必须先完成配置归属迁移并建立新基线。

本地修正拆成两个独立变更：

1. 移除板级脚本对 VyOS 已管理功能的覆盖，配套配置迁移与回归测试。
2. 独立处理无官方配置入口的 IRQ 分配，消除跨接口计数和大小核混用问题。

第一项已由用户在 21:55 +0800 部署脚本和服务文件，文件摘要与语法复核通过；仅
daemon-reload，当时未重启服务或路由器。除删除重复的直接写入外，还删除自动
`ethtool -L`：支持此操作的其他驱动可能重建 RX 队列，间接清掉 VyOS 的 RPS/RFS。
保留驱动初始队列数；不新增 RSS 策略。第一项不改 IRQ；第二项候选见下。
XPS、UDP GRO forwarding 与 governor 仍保留现有行为，后者与 VyOS TuneD profile
的交集尚未处理。

升级前必须通过 VyOS 显式配置需要保留的 GRO/GSO/SG/TSO/RPS/RFS；不配置就遵循
VyOS 的关闭语义。没有自动修改 config.boot，也不在镜像中替用户打开这些节点。
RFS 每队列容量的迁移差异见下文。新脚本不是可直接复制到未迁移设备的一键优化。

第二项候选已由用户于 22:06:16 +0800 重启调优服务应用，未重启路由器：选择在线 CPU 中最高 capacity 的组（至少三个在线 CPU 时
先排除 CPU0），每个接口独立轮转，接口起点依次偏移一位。保留全部 MSI-X 向量，
不猜测驱动中的 RX/TX/控制角色，不依赖忙闲计数，也不把 Linux IRQ 编号硬编码进
脚本。每口 IRQ 按编号数值排序；前一网口的预留向量数量不再影响后一网口。

未提供 cpu_capacity 时以 1024 回退，适用于同构平台；部分 CPU 缺少该字段时
不能据此证明已正确识别大小核，应检查启动日志并使用已有 IFACE_CPU 覆盖。
候选已验证现场亲和分配符合预期，但未进行新旧 IRQ 策略负载对照，不能宣称吞吐更高。集中大核也可能与 Mayami
加密线程竞争 CPU；必须通过同负载对照决定保留或回退。IRQ 亲和不会隔离 CPU。

15 项隔离回归已在 macOS 和 v2in0 Linux 通过，包含离线/非连续 CPU、调用进程
CPU 亲和受限、同构平台、CPU0 回退、IRQ 编号位数边界、旧式中断命名和预留向量
数量变化。Shell 语法及独立审查通过；这些均不替代真机吞吐测试。

第一项部署备份为 `/config/net-tune-backup-20260916-215512`，其中是尚会覆盖
offload/RPS/RFS 的旧脚本。第二项备份为
`/config/net-tune-before-irq-20260916-220533`；IRQ 回退优先使用这份已清理脚本的
备份，不要误恢复最初的配置覆盖问题。

## 现场配置确认与本地回归

21:43 +0800 只读确认：用户已保存两个网口的 GRO/GSO/SG/TSO/RPS/RFS，另外仅
LAN eth1 开启 RX checksum。Mayami 自 12:42 启动后 NRestarts=0。10 秒自然流量
采样中 RX/TX errors、softnet dropped/time_squeeze 均无增量；eth1 的
rx_mac_missed 增加 51。该样本不是压力测试，也不支持丢包已修复或性能已提高的结论。

22:07:30 +0800 起再次只读采样 10 秒：RPS 仍为 fe、RFS 仍为每队列 8192，
仅 eth1 RX checksum 开启，说明脚本运行没有覆盖这些 VyOS 设置。Mayami
NRestarts 仍为 0。两口 RX/TX errors、carrier_down_count 和各 CPU 的 softnet
dropped/time_squeeze 均无增量；eth1 rx_mac_missed 增加 83。两次自然流量的负载
不一致，不能由 51 与 83 的差异判断候选造成改善或退化；该计数仍须独立调查。

隔离回归：`python3 tests/net-tune.py`。先验证原有 IRQ override、XPS、governor
行为，再复现旧脚本覆盖关闭状态和 RFS 8192 的失败，修正后验证这些配置不再被改写。
测试使用临时 sysfs/procfs 和模拟 ethtool，不操作测试宿主或路由器的网络设置。

## LAN RPS/RFS 对照：保持原配置

2026-09-16 22:11–22:22 +0800，维护者授权自动执行。Mac 100.64.0.105 经
Wi-Fi/AP 接入 eth1，VyOS 100.64.0.1 本机运行临时 iperf3 服务，仅绑定 LAN
地址的 52017/TCP，设置最长运行时间，测试后停止。客户端为 iperf3 3.21，
服务端为 3.12。未安装软件，未改 WAN、IRQ、XPS、checksum 或内核。

客户端采用 `-P 4 -t 10 -O 2`，记录接收端吞吐；每种状态两轮。阶段之间恢复
原状态作漂移参照。B 仅关闭 LAN RFS；C 同时关闭 LAN RPS/RFS，验证完全不由
这两种机制分发的接收路径。改变配置通过官方 `script-template`、`sg vyattacfg`
和 `commit-confirm 5`，确认回退行为为 reload。恢复后先检查实际队列值，再
`confirm` 解除回退；全程不执行 save。

| 阶段 | LAN 状态 | 两轮接收吞吐（Mbps） | 中位数（Mbps） | 两轮 TCP 重传合计 | eth1 rx_mac_missed 增量合计 |
| --- | --- | --- | --- | --- | --- |
| A0 | RPS/RFS 开启 | 1294.8 / 1538.7 | 1416.7 | 0 | 201 |
| B | RPS 开启，RFS 关闭 | 1524.3 / 1085.3 | 1304.8 | 44 | 208 |
| A1 | 恢复原配置 | 1127.9 / 954.9 | 1041.4 | 277 | 156 |
| C | RPS/RFS 都关闭 | 1229.1 / 1269.0 | 1249.1 | 60 | 186 |
| A2 | 恢复原配置 | 1149.0 / 1223.5 | 1186.2 | 228 | 172 |

同一 A 状态的中位数从 1416.7 变为 1041.4，再到 1186.2 Mbps，已有明显
时间漂移。C 高于相邻 A 并不构成稳定收益证据；两轮样本不足，Wi-Fi、后台业务
和本机 TCP 服务进程调度均可能影响结果。C 两轮 softnet time_squeeze 合计增加
16，其他表内轮次为 0；这不是丢包计数，亦不能仅凭该差异认定关闭 RPS 有害。

所有表内轮次 RX/TX errors、softnet dropped、carrier_down_count 均无增量，
但 eth1 rx_mac_missed 持续增长且部分轮次存在 TCP 重传，不能写成“无丢包”。
全机 CPU 总忙时折算约 0.95–1.30 个核心；不同吞吐下不能直接将较低 CPU 占用
解释成效率提升。吞吐窗口排除预热，CPU/NIC 快照包含预热与采样开销，ping 窗口
也不完全重合，所以这些辅助值不作为精确每字节成本或尾延迟对照。

这是 **Wi-Fi→路由器本机 TCP 接收** 测试，不是 LAN→WAN 转发、DAE、代理或
2.5G 有线端口上限测试。当前结论仅为：没有充分证据保留关闭 RPS/RFS 的变更。

测试脚本有两次安全中止，均未把失败轮次计入表内：首次 `set -e` 被 VyOS CLI
函数内部的正常非零中间返回值触发，尚未提交配置；改用逐命令显式检查。另一次
sysfs 零掩码实际输出 `00`，字符串 `0` 比较失败；自动恢复后改为数值比较，
重新完成 C 阶段。原始记录保留，未把中止前的基线混入表内。

22:22 +0800 最终核验：

- 两口每个 RX 队列恢复 RPS=`fe`、RFS=`8192`；IRQ 仍是已部署的大核错位分配。
- `compare saved` 无差异，config.boot 的 SHA256 与测试前一致：
  `de5e4e045acbe4f07bd4472f31497238ac271551f74c077f98730a4a314660fc`。
- Mayami 仍为 PID 6650、active、NRestarts=0；两口 carrier_down_count 保持 72/2。
- commit-confirm.timer 已 inactive，临时 iperf 服务已停止，52017 无监听。
- 原始 JSON、配置输出和最终状态位于本地忽略目录
  `out/net-tune-20260916-rps/`；表内 A0/B/A1 来源 `retry/`，C/A2 来源 `c-check/`。

## 单 IP 内核直转验证（2026-09-17）

经维护者授权，于 00:01–00:03 +0800 临时将 `101.6.15.130/32 → Net.Direct`
放到首条 sniff 前。先校验候选配置，设置五分钟 systemd 自动恢复，再重启 Mayami。
启用 gateway modules + API 的当前版本拒绝整份配置热加载，因此没有绕过保护或
把 SIGHUP 当作已成功应用。两次受控重启分别用于应用候选、恢复原配置。

- 普通规则编译项从 0 IPv4 变为 1 IPv4，加自动节点规则后从 7 变为 8。
- Mac 源端口 52129 的原始 `100.64.0.105 → 101.6.15.130:443` 流出现
  `[OFFLOAD]`；下载完整 1,808,488 字节、HTTP 200。
- 传输中连续采样的 IPv4 flow-add 前计数曾保持 3455 包 / 333455 字节；
  这与原始 LAN 流的 OFFLOAD 状态共同支持快路径实际工作，不是仅凭计数不增长。
- 证明当前 `{eth1, pppoe0}` 软件 flowtable 可以承载该测试流，不需要先改接口。
  下载按 128 KiB/s 限速，未测吞吐收益或 CPU 节省百分比。
- 恢复后配置文件 SHA256 与原件相同，编译项回到 7，新连接重新进入 DAE 用户态。
  直连 HTTP 200、代理 HTTP 204，雷神两条加速会话恢复；物理 carrier 计数未增。
  计时器已解除，包含模块私有状态副本的临时目录已删除。

原因：当前 DAE 仅下放连续、可证明等价的 DIRECT 规则前缀；首条 sniff 是编译
屏障。不得为扩大覆盖率自动把整个 geoip-cn 提到 sniff/广告过滤之前，那会改变
配置语义。此实验只证明一条显式允许绕过这些处理的 IP 规则可走内核路径。

## WAN RX checksum 对照（2026-09-17）

00:29–00:38 +0800 期间完成 off → on → off 对照，使用 VyOS 官方
`set/delete interfaces ethernet eth0 offload rx`，每次开启采用 `commit-confirm 5`
并核验 reload 计时器。恢复实际 offload、队列配置及保存配置哈希后才 confirm。
没有 save、重启 Mayami、修改路由、IRQ、RPS/XPS 或内核。

所有阶段 IPv4 下载均返回 HTTP 200、1,808,488 字节。抓包只在 eth0 被动统计
来自指定镜像 IP 的入站 PPPoE 头部和 PACKET_AUXDATA，不保存业务包内容。
强化采样的结果如下，Counter 未输出的状态位计数按零解释：

| 阶段 | RX checksum | IPv4 skb / AUXDATA 数 | IPv6 skb / AUXDATA 数 | CSUM_VALID | 抓包丢失 |
| --- | --- | --- | --- | --- | --- |
| A0 | off | 1288 / 1288 | 22 / 22 | 0 | 0 |
| B | on | 1287 / 1287 | 21 / 21 | 0 | 0 |
| A1 | 恢复 off | 1287 / 1287 | 22 / 22 | 0 | 0 |

CSUMNOTREADY、辅助数据截断亦为零。此处是接收栈 skb 样本，不是精确物理帧数；
GRO 保持开启。CSUM_VALID 表示内核暴露的校验状态，不独自证明硬件来源，缺失
也不能证明硬件完全没有校验或后续不会软件校验。**结论仅为：该样本未观察到
开启 RX checksum 带来已完成校验的状态标记，缺少保留变更的收益证据。**

IPv6 验证边界：客户端和路由器的普通 curl -6 都被 DAE sniff 后按域名重新拨号，
实际仍主要走上游 IPv4，最初两组记录不能算真实 IPv6 下载验证。随后使用无 SNI
TLS 保留 IPv6 目的地址，仍验证证书链并在发送 HTTP 前手动核验镜像主机名，
成功得到真实 IPv6 TLS/HTTP 响应；但 GET 在三阶段均返回 403，未完成 IPv6
文件下载。22/21/22 包只支持有限的 IPv6 连通性和元数据观察，不能推断批量吞吐。

检查到的 IPv4/IPv6 校验、头错误和丢弃计数均无增量；eth0 RX/TX errors 和
rx_mac_missed 无增量，两口 carrier_down_count 不变。eth1 rx_mac_missed 仍有
增长，不能称整个网络无丢包。限速下载和短样本不能用于比较峰值性能；本轮未测
每字节 CPU 成本。

结果：恢复 eth0 RX checksum=off；Mayami 保持 PID 21102，未重启。原始记录
位于忽略目录 `out/wan-rx-20260917/`，强化采样为 `verified-v6/`；其中 IPv6
下载失败被保留，脚本的 COMPLETE 只表示测试流程和恢复完成，不表示所有测试通过。

## 独立路由热更新：审查完成，尚未实现

当前 whole-Box reload guard 是保护 API 监听器和 gateway module 生命周期，不应
直接删除。`Router.ResetRules` 也不能直接公开为线上热更新：它没有完整的新规则
Start/旧规则 Close 生命周期，失败不完整回退 rule-set registry，并会丢失生成规则
前缀。仅原子替换 slice 不足以保护仍在读取旧规则对象的连接。

后续实现应限定为 `route.rules` 更新事务：预先构建验证候选，保留生成规则前缀；
先撤除旧 BPF DIRECT，再发布新规则，最后重建快路径；旧 reader 退出后才能关闭
旧规则。失败语义、多 DAE 并发更新和 UDP 已有流行为须有回归测试。首版不同时
支持 rule-set registry、默认出站、DNS 或监听器更新。本轮未改 Mayami 产品代码，
未部署未经验证的热更新功能。

## 官方配置能力

以下是已核验的语法参考，不是可整段执行的迁移脚本。`eth0`、`eth1` 分别为现场
WAN、LAN；不要把示例接口名套到其他设备。

| 项目 | 官方入口 | 本机行为与限制 |
| --- | --- | --- |
| RX checksum | `set interfaces ethernet eth0 offload rx` | 支持；删除节点关闭。需验证 PPPoE、IPv4/IPv6 与代理路径 |
| GRO/GSO/SG/TSO | `set interfaces ethernet eth0 offload gro`，其余末项换为 `gso`、`sg`、`tso` | 已存在；迁移应逐项保留当前需要的功能，而非依赖启动脚本 |
| RPS | `set interfaces ethernet eth0 offload rps` | 无值开关；本机开启时为 CPU 1–7，即 `fe`，不接受自定义大核 mask |
| RFS | `set interfaces ethernet eth0 offload rfs` | 无值开关；本机按 `32768 / RX队列数` 设置每队列容量 |
| 软件 flowtable | `set firewall flowtable FT0 offload software` | 已有 FT0，不需要重复创建或改成 hardware；规则、接口和命中须分别核验 |
| 性能 profile | `set system option performance network-throughput` | 本机有效名称；不是静态 IRQ 亲和设置 |
| 精确 IRQ / XPS | 未发现当前 Ethernet/System CLI 的等价入口 | 不建议借任务计划或 post-config 脚本伪装成官方参数 |
| DEBUG_PREEMPT | 无运行时配置入口 | 编译期内核选项，需独立候选内核对照 |

RFS 迁移不是参数完全不变：旧镜像中的板级脚本每队列设置 4096，VyOS 对四个 RX 队列
开启 RFS 时会设置 8192。全局 `rps_sock_flow_entries=32768` 已由 VyOS 自身的
`/etc/sysctl.d/30-vyos-router.conf` 提供，无需重复新增 sysctl 文件。调整全局值也
不会改变当前 `set_rfs()` 中固定的每接口计算基数。

## IRQ 与队列

CPU 0–3 的 capacity 为 397，CPU 4–7 为 1024。修改前 WAN RX IRQ 分配到 CPU
4–7，LAN 分配到 CPU 1–4。旧脚本枚举每口全部 32 个 MSI-X 向量，使用跨接口
全局轮转计数；未用于当前数据队列的向量也消耗位置，导致 LAN 大部分 RX 落到小核。

本地候选不增加驱动专用向量解析。只解决 CPU 候选池和跨接口分配污染，尚未做
RX/TX completion 专用配对。按现场向量顺序，预期 WAN RX 为 CPU 4/5/6/7，LAN
RX 为 CPU 5/6/7/4；TX 向量也落在这四个大核上。其他硬件的队列角色顺序不保证
相同。TX completion 的位置不由 XPS mask 设置。

官方 r8125 原包 `src/r8125_n.c:7787–7870` 只有 `get_channels`，没有
`set_channels`。旧镜像中的脚本尝试通过 `ethtool -L` 开满 RX 队列会失败并被静默忽略；
最大 RX 8、实际 RX 4 不意味着应立即修改驱动开启八队列。

## 性能 profile 不能替代 IRQ 修正

官方网页仍显示旧枚举 `throughput`、`latency`；本机 CLI 模板和
`system_option.py` 实际接受 `network-throughput`、`network-latency` 等名称。
实际模板优先于滚动文档中的旧示例。

本机 `network-throughput` 继承 `throughput-performance`，除了 performance
governor，还调整 TCP 缓冲上限、脏页和磁盘预读等。`network-latency` 涉及忙轮询、
THP、TCP Fast Open 和启动参数。均不是一次只改 IRQ 的实验。本机 governor 已是
performance，本轮没有启用这些 profile。

## 后续实验顺序

1. 先统一配置归属，记录新的可重启基线。迁移本身不计为性能优化结果。
2. 单独比较 IRQ 分配；固定其余变量。
3. 通过官方 RPS 开关先测 LAN，再测 WAN。不追求大核专用 mask，除非官方能力
   已证实不足且另行接受板级定制。RFS 与 RPS 分开测试。
4. XPS 独立观察与对照；当前两个 TX 队列同为 `fe`，不是独占 CPU 映射。
5. 构建仅关闭 DEBUG_PREEMPT 的候选内核，保留 DEBUG_INFO/BTF 和 DAE 全部前提。
6. RX checksum 按接口单独对照；不要同时改 flowtable。
7. 对明确走内核转发的长连接验证 flowtable，不能用本机代理吞吐替代。

各阶段分别记录直连转发/代理、上传/下载、单流/多流的吞吐、CPU 开销、延迟、
重传与丢包增量。出现 WAN carrier flap 的轮次作废。没有收益或正确性退化则不保留。

现场已观察到 conntrack `[OFFLOAD]`，但短时间采样没有证明持续高负载命中。
`flow add` 规则计数是规则经过量，不是快路径命中量。结合固定流的 OFFLOAD 状态、
conntrack 包/字节同步和 forward 慢路径计数判断。软件 TC ingress 在 Netfilter
ingress 前，flowtable 不会抢在 DAE TC 前面处理已被接管的数据包。

## 用户执行与回退

配置由维护者或其授权的自动化在维护窗口执行。先检查 `compare`，不要把其他未提交修改一起提交。
明确设置 `set system config-management commit-confirm action reload`，核对
`commit-confirm 5` 的实际提示为 reload；保持 TTL 管理入口可用。
确认连通性与指标后再 `confirm`、`save`，不要把确认命令紧接测试提交自动连跑。

本机 CLI help 仍写默认 reboot，但已安装 `config_mgmt.py` 只有在 action 明确等于
`reboot` 时才选重启分支；不要依赖旧帮助推断默认值。显式 action 与执行提示为准。
reload 也可能影响网络，不是不中断保证；它不会回滚镜像、内核或自定义脚本状态。

官方只读查看入口已核验：

```text
show interfaces ethernet eth0 physical offload
show interfaces ethernet eth1 physical offload
```

## 依据

- [VyOS Ethernet](https://docs.vyos.io/en/rolling/configuration/interfaces/ethernet.html)
- [VyOS system option](https://docs.vyos.io/en/rolling/configuration/system/option.html)
- [VyOS 配置脚本](https://docs.vyos.io/en/rolling/automation/command-scripting.html)
- [VyOS CLI 与 confirmed commit](https://docs.vyos.io/en/rolling/cli.html)
- [Linux RSS/RPS/RFS/XPS](https://docs.kernel.org/networking/scaling.html)
- [Linux flowtable](https://docs.kernel.org/networking/nf_flowtable.html)
- [Linux 6.18 DEBUG_PREEMPT](https://github.com/torvalds/linux/blob/v6.18/lib/Kconfig.debug#L1346-L1357)

版本特定事实另以现场 CLI 模板、`vyos/ifconfig/ethernet.py`、`system_option.py`、
`config_mgmt.py`、`/usr/lib/tuned/*/tuned.conf` 和实际内核配置相互核对；未复制用户
完整配置、账号、密钥或业务连接明细。
