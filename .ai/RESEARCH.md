# 研究记录

证据快照日期：2026-08-03。

## 仓库状态

| 对象 | 状态 |
|---|---|
| 上游 `chen08209/FlClash` | `main` 为 `7c831855efedceb1a72bd0b4c18da026593d0853`；最新稳定标签为 `v0.8.94`，指向 `7e7f1f89...` |
| `whusnoopy/FlClash` 远端 | `main` 为 `fec2af8dcb222d8089bc09aa10efab7ed4a1c2c3`，标签 `v0.8.93-fix.1` |
| 本地 `whusnoopy` checkout | `bc203ffce5cbcf72f666c49b882d1c7383e7c93f`，相对其 origin ahead 1 / behind 3 |
| `othercat/FlClash` | 已 fork / clone；`origin` 为 `othercat/FlClash`，`upstream` 为 `chen08209/FlClash`，Phase 0 HEAD 为 `7c831855efedceb1a72bd0b4c18da026593d0853` |

## `whusnoopy` CPU 修复的实质

两个 FlClash 修复 commit：

- [`bc203ff`](https://github.com/whusnoopy/FlClash/commit/bc203ffce5cbcf72f666c49b882d1c7383e7c93f)：基于 v0.8.92。
- [`fec2af8`](https://github.com/whusnoopy/FlClash/commit/fec2af8dcb222d8089bc09aa10efab7ed4a1c2c3)：基于 v0.8.93。

核心不是 Dart 业务代码改动，而是将 `plugins/tray_manager` 从 `6163dc8...` 切换到 [`ca201c0`](https://github.com/chen08209/tray_manager/commit/ca201c0146f49b87d2b8a2a5760fa228ad7cd29b)。该 tray commit：

- 移除加在 `statusItem.button` 上的自定义 `NSView` 路径。
- 改用原生 `statusItem.button.image` 与 `attributedTitle`。
- 缓存 `lastTitle`，相同标题直接返回。
- 仅在需要时更新图标位置。

`pubspec.lock` 和 `setup.dart` 的变化不是 CPU 根因，应避免在未来 patch 中一并照搬。

## 最新上游与旧修复不能直接替换

上游 v0.8.94 使用 `chen08209/tray_manager` 的 `main`。截至快照，该依赖 `main` 为 [`da2d83d`](https://github.com/chen08209/tray_manager/commit/da2d83dd1cc3c9709bf708ff827ad9072504ce52)，修复多显示器下的 `NSStatusItem` 重绘循环。

`ca201c0` 与 `da2d83d` 已分叉：比较结果为 `diverged`，`da2d83d` 一侧 ahead 9、behind 2。结论：

- 不能把 `ca201c0` 当成最新 tray manager 的祖先或直接 cherry-pick。
- 应在最新版原生实现上补幂等更新和测试，或在验证后选择可维护的固定依赖 commit。
- 上游 `pubspec.yaml` 依赖 `ref: main`，未来 fork 应评估是否 pin 到验证过的 SHA，以保证可复现构建。

## 上游仍存在的 CPU 热路径

当前 FlClash `lib/common/tray.dart` 在 macOS：

- `showTrayTitle == false` 时仍调用 `trayManager.setTitle('')`。
- `showTrayTitle == true` 时按流量更新调用 `setTitle`。
- `trayTitleStateProvider` 的监听由流量状态驱动。

相关上游 PR 均尚未合并：

- [#2201](https://github.com/chen08209/FlClash/pull/2201)：Dart 层 tray title 去重、关闭标题时停止订阅流量，并增加测试。
- [#2202](https://github.com/chen08209/FlClash/pull/2202)：隐藏窗口且标题关闭时暂停 runtime/traffic IPC、跳过 TUN request 解析、降低日志写入。
- [#2186](https://github.com/chen08209/FlClash/pull/2186)：上述内容的早期合并版，已被拆分 PR 取代。
- [#2271](https://github.com/chen08209/FlClash/pull/2271)：大范围性能重构，333 个文件且当前不可合并，不适合作为首个修复直接引入。

典型 issue：[#2033](https://github.com/chen08209/FlClash/issues/2033)、[#2029](https://github.com/chen08209/FlClash/issues/2029)、[#2141](https://github.com/chen08209/FlClash/issues/2141)、[#2263](https://github.com/chen08209/FlClash/issues/2263)。其中采样反复指向 `NSStatusItem` replicant 重绘。

## TUN 配置合成的关键发现

用户的 raw YAML 没有顶层 `tun` 和 `sniffer`。FlClash 会在 `lib/common/task.dart` 生成 effective config 时注入/覆盖 TUN 字段。因此只检查 `20260712.yaml` 无法知道实际运行参数。

当前 `Tun` model 主要暴露：

- `enable`
- `device`
- `auto-route`
- `stack`
- `dns-hijack`
- `route-address`

Mihomo 当前还支持 `auto-detect-interface`、`strict-route`、`mtu`、`inet6-address`、`route-exclude-address`、`udp-timeout` 等。诊断时必须从 FlClash 的配置预览或 core API 获取 effective config。

上游 FlClash issue [#1993](https://github.com/chen08209/FlClash/issues/1993) 与 Windows TUN 下部分网站不可达高度相关，报告者通过清空 `tun.inet6-address` 恢复网络。本机 Microsoft 单变量已经证明当前现象不同源：文件 effective YAML 虽有 inet6 地址，但当前 Mihomo 在 `ipv6:false` 时会清空它，live `/configs` 没有该 key，而故障仍存在。该 issue 对其他平台／IPv6 场景仍可参考，不能再作为本机 Microsoft 首要假设。

## 外部协议事实

- [Mihomo TUN 文档](https://wiki.metacubex.one/en/config/inbound/tun/)：`mixed` 为 TCP system + UDP gVisor；Windows 的 `strict-route` 会增加防止多宿主 DNS 泄漏的防火墙规则；macOS/Windows 不能自动劫持发往局域网 DNS 的请求。
- [Mihomo DNS 文档](https://wiki.metacubex.one/en/config/dns/)：`respect-rules` 需要正确配置 `proxy-server-nameserver`；Fake-IP filter 有独立匹配逻辑。
- [Apple 企业网络要求](https://support.apple.com/en-gb/101555)：Apple 服务涉及动态主机、CNAME、TCP 443、APNs TCP 5223，以及部分 UDP 443 服务；不能只用浏览器首页判断。
- [Microsoft 365 endpoint Web Service](https://learn.microsoft.com/en-us/microsoft-365/enterprise/microsoft-365-ip-web-service?view=o365-worldwide)：Microsoft 365 云端点持续更新，官方提供 version/endpoints/changes 接口；该数据不覆盖所有 Microsoft 网络端点，不能替代 consumer/science 人工 ownership。

## 当前根因优先级

### CPU

2026-08-03 现场复现后优先级已更新，旧的 tray-first 假设不能继续放在首位：

1. **高置信直接执行源**：每秒 traffic 更新使 `TrafficUsage` 重建新的 DonutChart data list，identity 比较每次都重启 300ms `CustomPaint` 动画。标准 A4 三轮共 900 秒样本为 `34.270%` mean / `62.200%` max，Core仅 `0.900%` mean，三轮旧 tray/dispatcher 符号全为 0；工具页立即归低。v0.8.93 widget 诊断又证明等值新 list 也会启动约 300ms ticker，而 LineChart 默认零时长。最小 patch review 已选择仅在 `TrafficUsage` 传 `Duration.zero`；连续真实数值变化诊断证明不会保留 ticker。
2. **已撤回的候选**：network detection / intranet IP 的 `CommonCircleLoading`。后续 AX 只输出状态类别并确认两者均为 `ip_redacted`，CPU 仍高，因此 spinner 不是当前根因。
3. **独立逻辑候选但非本轮 CPU 根因**：`lib/application.dart` 在 `_preHasVpn == hasVpn` 时触发新 IP 检测，疑似 equality 写反。运行版本 `connectivity_plus 7.0.0` 会过滤完全相同的结果，且 macOS adapter 不产生 VPN 类型；60 秒高 CPU 中没有初始状态之后的 NWPath transition，也没有 7 个检测入口请求。
4. **已确认但非本轮主热点**：tray title 关闭时仍订阅每秒 traffic 并调用 `setTitle('')`。Time Profiler 第一轮只命中 2 个约 1 ms 样本，第二轮为 0，且没有 NSStatusItem/replicant 热栈。
5. 中优先：标准 A5 用 256 KiB/s loopback-through-Core 持续流量测得隐藏窗口 App `3.694%` mean，对比 A2 空闲 `1.235%` 增加约 2.46 个百分点；Core `1.167%`。这证明 IPC/状态传播存在低水平额外成本，但远不足以解释 A4 的 `34.270%`。首 patch 仍先用局部零时长消除当前 ticker，后台 IPC 优化独立评估。

详细证据见 `evidence/phase1/MACOS_HIGH_CPU_LIVE_REPRO.md` 与 `evidence/phase1/MACOS_CPU_MINIMAL_FIX_REVIEW.md`。

### TUN

1. **已定位的 macOS Microsoft 根因**：主 DoH 返回可用 IPv4，但 `fallback-filter` 触发 4 个当前不可用的 fallback，聚合 DNS timeout，进而使 TUN 内 DIRECT 失败。
2. `inet6-address` 已通过 live parsed config 排除，system/gVisor stack 均失败；保持 Fake-IP 和全局 fallback、只用精确 `nameserver-policy` 绕过错误 fallback 时，三域 DNS、DIRECT URLTest 与真实 HTTPS 全部成功。
3. Microsoft raw/effective 8055 条规则顺序完全相同，正确 `cloud.microsoft` 规则已 live 命中；当前不再把“导入丢规则”列为优先假设。
4. ownership review 已完成：普通/science Microsoft 分成两个互斥 inline classical provider，路由分别引用，DNS policy 只引用 direct provider；当前 `override_dns=false` 可保留 raw policy。3 个测试域名仍只是机制验证。
5. 后续若仍有非 DNS 失败，再测试 UDP/QUIC 与 MTU/PMTUD；当前三域无需靠这些变量恢复。
6. 低优先：UWP loopback。用户已明确 Microsoft Store 下载正常，且 macOS Web 已复现，现象不符合 Windows-only loopback 限制。

ownership 细节与 Microsoft 官方动态端点维护边界见 `evidence/phase1/MACOS_MICROSOFT_DNS_POLICY_OWNERSHIP_REVIEW.md`。
