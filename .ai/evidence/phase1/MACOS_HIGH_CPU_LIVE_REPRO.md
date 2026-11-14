# macOS 高 CPU 现场复现

采集时间：2026-08-03 17:33–21:10（Asia/Shanghai）。  
状态：已稳定复现并收敛到仪表盘每秒流量更新驱动的 `TrafficUsage` / `DonutChart` 300ms 动画；后续 live 状态反证了 network-detection loading 假设，connectivity 与 IP 检测请求风暴也已排除。

## 安全与环境

- 正式实例：`/Applications/FlClash.app`；采集期间 App/Core 各 1 个进程。
- 全部 Swift 与 Time Profiler 命令固定使用 Xcode 16.4 (`16F6`)。
- TUN `true/mixed`、system proxy 偏好 `true`、tray 流量标题 `false`；未修改网络或策略配置。
- 不保存 profiler 原始 trace。原始 trace 含本机环境元数据，只在 `/tmp` 中短暂用于本地聚合；本文只记录线程类别和计数。
- 没有对 tray 状态项执行 Accessibility press。恢复普通窗口时使用了带真实 `CGEvent` 的左键点击。

## 首次现场

- 用户报告 FlClash CPU 突然很高。
- 第一轮只读进程读数：FlClash `31.4%`，FlClashCore `0.6%`。
- 10 秒 `sample` 结束时：FlClash `20.2%`，FlClashCore `3.5%`。
- 热栈含 Dart/Flutter、Metal/AGX 与渲染提交；没有形成 `NSStatusItem`、`_updateReplicants` 或 `_redrawReplicantSnapshot` 热点。

因此高 CPU 明确来自 FlClash 主进程，不是 Core。

## 窗口隐藏／关闭不足以恢复

- 用 `NSRunningApplication.hide()` 隐藏普通窗口后，FlClash 仍在约 `6.5%–48.0%` 间脉冲。
- 通过普通窗口唯一 `AXCloseButton` 关闭窗口后采样 20 秒：平均约 `25.97%`，范围 `4.1%–55.3%`。
- Core 同期绝大多数读数低于 `1%`。

这证明“当前窗口可见”不是充分条件。进入故障状态后，仅隐藏或关闭普通窗口不会停止 Flutter 页面树中的工作。

## Xcode 16.4 Time Profiler

第一轮 10.37 秒：

- running samples：`2046`（每个约 1 ms）；
- `io.flutter.raster`：`998`；
- Main Thread：`837`；
- Dart isolate 栈：`445`；
- Metal/AGX 栈：`253`；
- `ResizeSynchronizer.performCommit`：`15`；
- `TrayManagerPlugin.setTitle`：`2`；
- `NSStatusItem`/replicant 类：`0`。

普通窗口不在屏幕上的第二轮 10 秒：

- running samples：`4097`；
- `io.flutter.raster`：`2141`；
- Main Thread：`1415`；
- Dart isolate 栈：`703`；
- Metal/AGX 栈：`537`；
- `ResizeSynchronizer.performCommit`：`28`；
- `TrayManagerPlugin.setTitle`：`0`；
- `NSStatusItem`/replicant 类：`0`。

大量 `CA::Transaction::commit`、Metal command buffer 和 display-link 活动证明这是持续帧生成／绘制，不是 Core 计算或 tray 原生调用本身占满 CPU。

## 页面 A→B→A 闭环

在同一 App/Core、同一 TUN/代理/tray 状态下，只切换页面：

| 页面 | 20 个 1 秒样本 | FlClash 平均 | FlClash 最大 |
|---|---:|---:|---:|
| 工具 | 20 | `2.51%` | `9.6%`（切页余波） |
| 仪表盘 | 20 | `34.24%` | `55.1%` |

- 仪表盘 → 工具：CPU 立即回落，后半段多为 `0.8%–1.8%`。
- 工具 → 仪表盘：CPU 立即恢复 `24%–55%` 的持续脉冲。
- Core 没有同步升高。

这是当前高 CPU 的稳定单变量复现路径。它推翻了“A2/A3 未复现，因此高 CPU 已解决”的任何表述；A2/A3 只能说明当时没有进入该页面状态。

## 标准 A4 长时复现

2026-08-03 随后按 `TEST_MATRIX.md` 完整执行 A4：TUN 开、普通窗口显示、tray title 关、仪表盘空闲；每轮预热 120 秒、采样 300 秒，共 3 轮。

| 轮次 | FlClash mean / max | Core mean / max |
|---|---:|---:|
| 1 | `33.618% / 58.900%` | `0.897% / 8.300%` |
| 2 | `33.729% / 62.200%` | `0.827% / 4.000%` |
| 3 | `35.462% / 62.200%` | `0.977% / 4.900%` |
| 总计 | `34.270% / 62.200%` | `0.900% / 8.300%` |

900 个 CSV 样本均为 6 列，三轮各 300 条且线程数为正。三轮 10 秒 sample 中 `_updateReplicants`、`_redrawReplicantSnapshot`、`NSStatusItem`、`MethodChannel`、`PlatformDispatcher` 计数全为 0。状态前后保持 TUN true、tray title false、窗口可见；采集脚本没有操作网络或 UI。

证据：`macos-cpu/A4-20260803T140155Z.md`、同名 CSV（SHA-256 `976b5da2ddc1243f294bb9d9e1d19f341c4705fca9088cbebc1f855195fb4148`）。标准 A4 与短时 A→B→A 给出相同均值，进一步证明稳定负载属于仪表盘 Flutter 路径而非瞬时尖峰。

## A5 隐藏窗口持续流量对照

A5 使用仅绑定 loopback 的本地字节流，curl 显式通过 FlClash mixed listener下载并限速 256 KiB/s，没有外网字节。TUN 开、窗口隐藏、tray title 关，三轮结果为：

- FlClash `3.678 / 3.973 / 3.433%`，总平均 `3.694%`；
- Core `1.046 / 1.056 / 1.400%`，总平均 `1.167%`；
- 三轮旧 tray/dispatcher 符号均为 0。

相对 A2 隐藏空闲 `1.235%`，持续流量使 App 增加约 2.46 个百分点，证明后台 traffic IPC/状态传播有成本；但它仍比 A4 仪表盘 `34.270%` 低约 30.6 个百分点，不能解释当前主故障。证据见 `macos-cpu/A5-20260803T143542Z.md` 与同名 CSV。

## 后续反证：不是 loading spinner

初次静态收敛曾把 network detection 的 `CommonCircleLoading` 当作最高优先候选。后续新增普通窗口 AX 探针，只输出 `loading / timeout / ip_redacted / no_network`，不输出实际 IP。当前同一正式实例的结果为：

- `network_detection_state=ip_redacted`
- `intranet_ip_state=ip_redacted`

即仪表盘默认存在的两个 `CommonCircleLoading` 分支都没有挂载。此时再次进入仪表盘采 20 个 1 秒样本，FlClash 仍为：

- mean `30.02%`
- min `6.90%`
- max `51.50%`

因此“network-detection loading spinner 是本轮直接根因”已被 live 反证并撤回。页面级 A→B→A 结论仍然成立。

## 当前高置信执行链：TrafficUsage / DonutChart

白名单偏好快照确认当前仪表盘共 7 个 widget，包含 `networkSpeed`、`trafficUsage`、`networkDetection` 和 `intranetIp`，不含 `memoryInfo`。v0.8.93 精确代码形成以下周期链：

1. `SetupAction._handleStart()` 建立 1 秒 `Timer.periodic`，每轮调用 `updateTraffic()`。
2. `updateTraffic()` 每轮写入新的 `trafficsProvider` 与 `totalTrafficProvider` 值。
3. `TrafficUsage` watch `totalTrafficProvider`，每次 build 都为 `DonutChart` 构造一个新的 data list。
4. `DonutChart.didUpdateWidget` 用 list identity 判断 `oldWidget.data != widget.data`；新 list 即使数值完全相同也会执行 `_animationController.forward(from: 0)`。
5. `DonutChart` 默认 duration 为 `commonDuration`，即 300ms；期间 `AnimatedBuilder` 每帧新建 `DonutChartPainter` 并 `CustomPaint` 两段圆弧。

这意味着每 1 秒更新会强制开启约 300ms 的 raster/Metal 动画窗口，和现场约 `30%` 的平均 CPU 及周期性 `6%–51%` 脉冲吻合。`NetworkSpeed` 的 `LineChart` 也每秒收到新 list，但其默认 duration 为 zero，只产生瞬时更新，不维持 300ms ticker。

`.ai/tests/dashboard_animation_probe_test.dart` 在保留依赖的 v0.8.93 隔离 worktree、Flutter 3.41.9 / Dart 3.11.5 下以 `--no-pub` 验证：

- 每次 data 更新后 DonutChart ticker 持续约 300ms；
- 数值相同、只重新创建 list 仍会重新启动 ticker；
- LineChart 默认零时长更新不保留 active ticker。

三条诊断断言全部通过。当前 main 因自身 `app_links` 已要求 Dart ≥3.12，不能用 Flutter 3.41.9 重新求解；未修改 lockfile，测试改在精确 v0.8.93 的既有 package config 上执行。

10 秒 `sample` 的 AOT Dart 符号不可见，无法直接点名 DonutChart，但仍统计到 329 行 Metal/AGX/CA 符号；原始 sample 未落盘。因此归因依据是 live 页面/非-loading 闭环、精确周期源码和 widget 生命周期测试的组合，不伪称 profiler 已符号化到 Dart 类名。

## connectivity 条件的独立问题

另行发现一个可疑的上游逻辑：

```dart
final hasVpn = results.contains(ConnectivityResult.vpn);
if (_preHasVpn == hasVpn) {
  ref.read(checkIpNumProvider.notifier).add();
}
_preHasVpn = hasVpn;
```

位置：`lib/application.dart`。它在 VPN 状态**没有变化**时触发新的 IP 检测，语义上更像把 `!=` 写成了 `==`。

后续已核对运行版本的 `connectivity_plus 7.0.0`：Dart stream 会对相同结果数组执行 `distinct`，macOS adapter 又不会生成 `ConnectivityResult.vpn`。60 秒仪表盘高 CPU 捕获中只有探针自己的 1 次初始 Wi-Fi path，没有后续 transition；7 个固定 IP 检测入口的 Core 日志匹配数为 0。同期 FlClash 平均 `20.06%`、最大 `45.50%`，Core 平均约 `0.43%`。

因此当前证据排除了“持续相同 connectivity 事件 → 持续 `_checkIp()` 请求”作为本轮 CPU 的运行中风暴。`==` 仍可能在首次事件或真实网络类型变化时错误启动一次检测，但与当前非-loading 时仍约 30% 的仪表盘 CPU 无关。详细事件链见 `MACOS_CONNECTIVITY_NETWORK_DETECTION_TRACE.md`。

另一个已确认但非本次主要热点的问题是：tray title 关闭时，`trayTitleStateProvider` 仍订阅每秒 traffic，并调用 `setTitle('')`。Time Profiler 只命中 2 ms/第一轮且第二轮为 0，不能把这次 `34%` 平均 CPU 归因给 tray。

## 当前状态与后续顺序

- 标准 A1 已补齐：TUN 关、窗口隐藏、tray title 关、空闲三轮共 900 个样本，FlClash `3.070%` mean / `48.500%` max，Core `0.339%` mean / `3.600%` max；三轮旧 tray/dispatcher 符号全为 0。它是低于 5% 的空闲均值基线，但不把离散峰值解释为修复证据。
- A1 完成后已恢复普通窗口；用户随后手动重新开启 TUN，preference/live 均确认 `true/mixed`，system proxy、controller、窗口与 AX 白名单状态均恢复。
- 普通窗口可见，AXEnhanced 已恢复 `false`。
- 恢复后先重新识别实例和状态，不复用本文 PID。
- connectivity 与固定检测入口的脱敏计数已完成；两个 loading 分支均已通过 AX 分类为 `ip_redacted`。
- 最小修复 review 已完成：首个 Phase 2 patch 只在 `TrafficUsage` 的 DonutChart 传 `Duration.zero`，保留一秒数据更新；连续真实数值变化诊断已证明不会保留 ticker。只有 live 降幅未达标时才扩展窗口/IPC 生命周期。详见 `MACOS_CPU_MINIMAL_FIX_REVIEW.md`。
- Phase 1 完成前不修改业务代码；确认触发链后再进入 Phase 2 最小修复。
