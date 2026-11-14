# macOS 仪表盘高 CPU 最小修复 review

Review 时间：2026-08-03（Asia/Shanghai）  
状态：Phase 1 设计 review 已完成；尚未修改业务代码。首个实现应只关闭 `TrafficUsage` 的持续 donut 动画，不混入 tray、connectivity 或窗口后台轮询优化。

## 已证明的执行链

当前正式 App 0.8.93 的稳定复现为：

- 工具页 20 秒平均约 `2.51%`；
- 仪表盘 20 秒平均约 `34.24%`，切回立即复现；后续标准 A4 的 3×5 分钟总平均为 `34.270%`；
- network detection 与 intranet IP 均已有脱敏 IP 值，不处于 loading；
- 60 秒窗口内没有初始状态之后的 connectivity transition，也没有 7 个固定 IP 检测入口请求；
- Time Profiler 热点在 Flutter raster/Main/Metal，而不是 Core 或 `NSStatusItem`。
- 标准 A5 在窗口隐藏、256 KiB/s Core 流量下 App 平均仅 `3.694%`，说明后台 IPC 有约 2.46 个百分点增量，但不能解释可见仪表盘 `34.270%`。

精确代码链为：

1. `SetupAction._handleStart()` 每秒调用 `updateTraffic()`；
2. `updateTraffic()` 写入 `totalTrafficProvider`；
3. `TrafficUsage` 每次重建一个新的 `List<DonutChartData>`；
4. `DonutChart.didUpdateWidget()` 用 List identity 判断变化，并执行 `forward(from: 0)`；
5. 默认动画时长为 `commonDuration`，即 300ms；
6. 因而每秒约 30% 时间存在 active ticker 与连续 `CustomPaint`。

当前产品代码中 `DonutChart` 只有 `TrafficUsage` 一个正式调用点。`NetworkSpeed` 使用的 `LineChart` 默认时长为零，不会保留持续 ticker。

## 首个 patch 的边界

推荐只改：

- `lib/views/dashboard/widgets/traffic_usage.dart`
  - 给该处 `DonutChart` 显式传入 `duration: Duration.zero`。
- 增加聚焦 widget test：连续改变 donut 数值时，每次 pump 后都不存在 active ticker，同时图表和文字仍更新。

首个 patch 不改：

- `SetupAction` 的一秒 timer；运行时间、tray、network speed 与统计仍依赖这条数据链。
- 公共 `DonutChart.didUpdateWidget()` 的 List identity 判断。
- `WindowManager`、全局 `Render.pause()` 或隐藏窗口 IPC。
- tray title、`tray_manager` 或原生 macOS 代码。
- `_preHasVpn == hasVpn`；这是独立逻辑问题，应单独验证和提交。

这是最小边界的原因：

- 只把 List identity 改成语义比较，只能消除“数值未变化”的动画；有真实流量时累计值每秒变化，300ms 动画仍会每秒启动，不能解决稳定高 CPU。
- 停掉全局 traffic timer 会改变 runtime、tray、图表和统计语义，风险明显大于当前根因。
- 引入窗口可见性状态只能优化隐藏场景，不能解释或修复可见仪表盘的 30%–34%。
- 局部零时长仍会每秒重绘一次，但不再在随后 300ms 内逐帧重绘，且保留一秒更新频率。

## 诊断测试结果

`.ai/tests/dashboard_animation_probe_test.dart` 已在未修改的 v0.8.93 worktree、Flutter 3.41.9 下验证：

1. 默认 DonutChart 在每次数据更新后保持约 300ms active ticker；
2. 数值相同但重新创建的 List 也会重启 ticker；
3. LineChart 默认零时长，不保留 ticker；
4. DonutChart 显式 `Duration.zero` 后，连续三次真实数值变化均不保留 ticker。

第 4 项于 2026-08-03 使用 `--no-pub` 单独复测，通过。测试只位于 `.ai`，没有修改产品测试或业务代码。

## Phase 2 实现验收

自动测试：

- 新增正式 widget test，覆盖连续变化值而不只是等值重建；
- 每次更新后 `tester.hasRunningAnimations == false`；
- 流量文字及 donut painter 的新数据已经生效；
- 运行相关 targeted widget tests、`flutter analyze --no-fatal-infos`，并在依赖允许时运行完整 `flutter test --reporter expanded`。

macOS live 验收只使用 Xcode 16.4：

1. 使用相同 widget 布局和相近网络空闲条件重复“工具 → 仪表盘 → 工具”；
2. 标准 A4 的 3×5 分钟平均 CPU 相比 `34.270%` 基线至少下降 80%，目标不高于约 `6.85%`；
3. 工具与仪表盘平均值差距不超过 3 个百分点；
4. 隐藏／关闭窗口且当前页为仪表盘时，5 分钟空闲平均不高于 `5%`；
5. 流量总计在网络活动后 2 秒内更新；
6. Time Profiler 不再呈现每秒约 300ms 的 raster/Metal 连续活动；
7. 工具页、tray title 开关和 Core CPU 无回归。

若一行局部修改未达到上述 live 指标，再进入第二层 profiling；不能在首个 patch 中预先混入 timer、tray 或全局生命周期重构。
