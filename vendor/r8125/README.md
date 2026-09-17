# Realtek r8125 原始源码包

- 文件：`r8125-9.018.00.tar.bz2`
- 版本：9.018.00；Realtek 下载页标注发布日期为 2026-07-03。
- 来源：[Realtek 官方网卡驱动下载页](https://www.realtek.com/Download/List?cate_id=584)，Linux r8125 下载项 3763。
- 获取方式：维护者从官网下载后提供原包；仓库按原字节保存，未修改归档内容。
- SHA256：`66291cb5d4d3b359cfa0c9ca902028d9ce0f76065887cb64b4052dce4a676ff8`

该摘要是此次对所提供文件实际计算的结果，用于锁定构建输入，**不是 Realtek 公布的摘要，也不是官网数字签名验证结果**。本次未执行包内的 `autorun.sh` 或安装目标；构建只使用 `src/` 下的 Kbuild，并由项目内核密钥签名模块。

源码文件标注 `SPDX-License-Identifier: GPL-2.0-only`，同时保留上游原有版权及许可说明；驱动不适用本仓构建脚本的 MIT 许可。GPL v2 正文附于同目录 `COPYING`，原始包保持不变。

构建保留 RSS / 多 TX 队列，默认关闭 ASPM、EEE、Giga Lite。9.018.00 的 Giga Lite 模块参数名是 `enable_giga_lite`，旧名 `eee_giga_lite` 不再注册；这些编译宏只设置模块参数默认值，不删除对应代码路径。新增默认开启的 DASH 与 PAGE_REUSE 在项目中显式关闭，以控制升级变量。

版本更新不代表已经修复任何特定设备的 WAN carrier 断链；需分别验证 R5S 和 E52C 的模块加载、网络功能及实际链路稳定性。
