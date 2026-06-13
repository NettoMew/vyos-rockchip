# boards/r5s/r8125/

`stage_r8125`（`lib/r8125.sh`）按字典序 `git apply` 本目录下的 `*.patch` 到
`openwrt/rtl8125@9.016.01` 源树（编译前），用于把官方 r8125 适配到 VyOS 的内核
版本（当前 6.18.34）。

通常**无需补丁**：openwrt/rtl8125 的 9.016.01 已跟进较新内核。若 `make ... modules`
报 net API 不兼容（如 `netif_napi_add` 签名、`ndo_*` 变更），在此放一个最小适配补丁
（命名如 `0001-r8125-linux-6.18.patch`），与 `boards/m28k/aic8800/0002-*` 同样的思路。

补丁内容变化会经 `lib/iso.sh` 的 overlay 指纹触发 ISO 重建。
