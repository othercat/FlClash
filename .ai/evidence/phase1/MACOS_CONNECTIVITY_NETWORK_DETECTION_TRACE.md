# macOS connectivity / networkDetection 脱敏事件链

采集时间：2026-08-03 20:00–20:14（Asia/Shanghai）。  
状态：已排除高 CPU 采集窗口内的 connectivity 事件风暴和 7 个公开 IP 检测入口的请求风暴。后续 AX 状态探针证明 network detection 与 intranet IP 都已有脱敏 IP 值时，仪表盘 CPU 仍约 30%；因此本文不再把 loading 当根因。

## 版本与代码语义

- 当前运行产物为 FlClash `0.8.93`，锁定 `connectivity_plus 7.0.0`，不是当前 main 的 `7.2.0`。
- `connectivity_plus 7.0.0` 的 Dart 层对结果数组使用 `distinct((a, b) => a.equals(b))`，相同 connectivity 列表不会重复下发。
- 该版本 macOS `NWPathMonitor` adapter 只映射 Wi-Fi、cellular、wired Ethernet 和 other，不会生成 `ConnectivityResult.vpn`。
- 因此 `lib/application.dart` 中 `results.contains(ConnectivityResult.vpn)` 在 macOS 基本恒为 `false`。`_preHasVpn == hasVpn` 会在首次事件以及实际 connectivity 类型发生变化但 VPN 布尔值仍相同的时候触发检测；它仍是明显的条件错误候选，但不会由完全相同的原生重复事件无限触发。

以上结论来自当前版本锁定源码，不把 `connectivity_plus 7.2.0` 的行为外推到运行中的 0.8.93。

## 脱敏探针

新增 `.ai/scripts/macos_nwpath_event_probe.swift`：

- 使用 Xcode 16.4 (`16F6`) typecheck 和运行；
- 只输出 path signature 的类别与计数；
- 不输出 SSID、接口名称、IP、DNS server 或 route。

`macos_core_control.rb logs-network-detection` 同时只统计 FlClash `_checkIp()` 固定使用的 7 个公开域名，输出匹配计数和秒桶，不保存原始日志。

## 同实例观测

网络、TUN、系统代理和 tray title 均保持不变，只改变普通窗口页面。

| 场景 | 时长 | NWPath 更新 | 初始后 transition | 7 个检测入口日志 | FlClash CPU mean / max |
|---|---:|---:|---:|---:|---:|
| 当前页面的空闲对照 | 30s | 1（初始 Wi-Fi） | 0 | 0 | `3.60% / 17.10%` |
| 工具页 | 30s | 1（初始 Wi-Fi） | 0 | 0 | `3.22% / 19.80%` |
| 仪表盘页 | 60s | 1（初始 Wi-Fi） | 0 | 0 | `20.06% / 45.50%` |

仪表盘开始观测时的瞬时读数为 FlClash/Core `43.5%/0.5%`。60 秒内没有第二个 NWPath transition，也没有任一公开 IP 检测入口的 DNS、连接或错误日志；Core 平均约 `0.43%`。

页面切换只通过普通 FlClash 窗口的已允许 Accessibility label 完成，未对 tray 状态项执行 Accessibility press；每次操作后均恢复 `AXEnhancedUserInterface=false`。

## 结论边界

已证明：

1. 仪表盘高 CPU 在没有持续 connectivity 事件和没有重复 `_checkIp()` 网络请求时仍然存在。
2. 持续负载不是 Core、tray、connectivity 或 IP 检测请求风暴；后续 live 反证又排除了两个 `CommonCircleLoading` 分支。
3. `_preHasVpn == hasVpn` 仍可能在初始事件或真实网络类型变化时错误启动一次检测，但现有证据不支持把它写成持续高 CPU 的充分根因。

结合后续每秒 traffic → `TrafficUsage` → `DonutChart` 300ms 动画链，当前 CPU 根因已转向流量图表；详见 `MACOS_HIGH_CPU_LIVE_REPRO.md`。`_preHasVpn == hasVpn` 可以作为独立逻辑缺陷在后续覆盖首次／相同／变化事件，但不应与这次持续 CPU 修复强行绑定。
