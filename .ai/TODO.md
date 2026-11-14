# 可执行任务清单

## Phase 0：用户 review 与仓库准备

- [x] 用户 review `.ai` 全部文档并确认范围。
- [x] 用户决定 GitHub fork 的 owner/name。
- [x] 经用户明确授权后 fork `chen08209/FlClash`。
- [x] clone 到 `/Users/lirichard/AI/CLASH/FlClash/othercat/FlClash`，保留 `.ai`。
- [x] 配置 `origin` 为用户 fork，`upstream` 为 `chen08209/FlClash`。
- [x] 检查 `git status`，不得覆盖用户已有改动。
- [x] 读取仓库 `AGENTS.md`、`.agents/project.md`、`.agents/commands.md`、`.agents/rules.md`、`.agents/architecture.md`、`.agents/skills/core-platform/SKILL.md`。

验收：本地仓库处于明确 commit，remote 正确，工作树只含用户确认的 `.ai` 文件；不创建 commit。

Phase 0 执行记录（2026-08-03）：

- 本地 `main`、`origin/main` 与 `upstream/main` 均指向 `7c831855efedceb1a72bd0b4c18da026593d0853`。
- `origin` 已修正为 `https://github.com/othercat/FlClash.git`，`upstream` 已修正为 `https://github.com/chen08209/FlClash.git`。
- 修正前两个 remote 误指向 `Clash.Meta` / `mihomo`；已刷新远程引用并将本地 `main` 重新设为跟踪 `origin/main`。
- `core/Clash.Meta` submodule 指向 `80362fc1895dcf60b79b562896653046e0687413`。
- 工作树除用户确认的未跟踪 `.ai/` 外无其他改动；本阶段未 commit、push 或开 PR。

## Phase 1：锁定基线与复现

- [x] 记录 FlClash、tray_manager、Mihomo 的精确 SHA，禁止只记录 `main/latest`。
- [x] 使用上游未修改版本构建 macOS arm64 产物。
- [x] 完成本次 CPU 范围 A1–A5 并保存脱敏数据。A6 多显示器与 A7 睡眠/唤醒均由用户延后；未验证、不视为通过，也不计入本次门禁。
- [x] 从 FlClash 当前生成的 `config.yaml` 导出 effective config 的白名单脱敏版本。
- [ ] 完成本次唯一剩余门禁：macOS Apple 原生服务矩阵。Windows 实机矩阵由用户延后，未验证且不计入本次门禁。
- [x] 对比 raw profile 与 effective config，重点标记 IPv6/TUN 地址、stack、MTU、strict-route、DNS hijack。

验收：每个问题至少有一条稳定复现路径；没有复现的问题不得进入代码实现。

Phase 1 部分执行记录（2026-08-03）：

- 已锁定 current main、v0.8.94、v0.8.93、tray_manager 与 Mihomo 的精确 SHA，详见 `PHASE1_BASELINE.md`。
- 遵循用户的旧 macOS 兼容要求，只使用 Xcode 16.4；已从上游原版 v0.8.93 构建 deployment target macOS 11.0、SDK 15.5 的产物。
- v0.8.94 锁定的 `connectivity_plus 7.2.0` 上游文档要求 Xcode 26.1.1，且原生源码引用 Xcode 16.4 SDK 不包含的 `NWPath.isUltraConstrained`。该事实不得错误归因成用户说过相关结论。
- 持久 PTY network watchdog 曾完成 controller 生命周期、同值 TUN PATCH、真实 TUN off→timeout→on 的闭环；后续也发生过 UI cleanup 失败并由用户手动恢复。按用户决定，watchdog 仅用于降低网络实验断连概率，不再作为 Phase 1 门槛或继续打磨的目标。证据见 `evidence/phase1/MACOS_NETWORK_WATCHDOG.md`。
- `EFFECTIVE_CONFIG_DIFF.md` 保存的是用户编辑前的历史 SHA；用户随后主动增加/修正 Microsoft 规则，当前 raw SHA 已变化。当前 raw/effective 的 8055 条规则顺序完全相同，`cloud.microsoft` 正确规则两边各 1 条且 live 命中，导入没有丢失或重排。详见 `evidence/phase1/MACOS_MICROSOFT_FUNCTION_BASELINE.md`。
- 已完成 macOS Apple **固定公共入口**、规则目标和 Core DNS 定位：相关 Selector 都选择 DIRECT；A 查询 App Store 3/3 成功、Apple Account 0/3、iCloud 1/3。失败域名的主 DoH 回答触发 IP fallback filter 后，4 个 fallback 无可用回答，聚合查询 timeout/refused。该分类只适用于这组公共 curl 探测，不能外推为 System Settings 原生后台根因。详见 `evidence/phase1/MACOS_APPLE_FUNCTION_BASELINE.md`。
- fresh v0.8.93 DNS-only Core 的 original/no-fallback 两个 variant 均 3/3 成功，但回答指纹证明 Apple Account/iCloud 的主 DoH 结果被 fallback 替换；因此静态配置不是充分失败条件，正式 Core 的 fallback client/连接状态或上游瞬时可达性是剩余变量。
- 用户已重启正式 Core：App PID/启动时间保持不变，Core PID 更换，TUN 与系统代理自动恢复。重启后的 App Store 在 system proxy/TUN 两条路径均 3/3 成功，Apple Account 与 iCloud 均 0/3 且未进入 TLS；因此 restart 未修复问题，旧 Core 连接状态不是充分根因。
- 早期用 `lsof` 看不到 9090 就推断“Core 未建立 controller listener”属于无效门禁：当前 controller API 与 `nc` 均证明 loopback 9090 可达时，`lsof` 仍不显示监听行。由于重启前没有执行 config-aware 请求，不能证明 controller 当时不可达，也不能证明 restart 是生效必要条件。fake-IP 下的 `dig` 三域均成功，但不能代表真实 upstream 解析成功。
- 原生 Apple Account 时序：TUN 开时超过 10 秒持续转圈；用户手动关 TUN 后页面加载；再开 TUN 后页面仍能加载。该结果是 TUN-specific 高价值线索，但后台 daemon、缓存和既有连接未受控，尚不是 A→B→A 因果闭环。不再以退出／重开 System Settings 作为后台冷启动。
- 后台观测链已建立：15 秒无操作为 0；随后 5 秒窗口捕获到 iCloud Contacts DIRECT connected 与 Apple Push/Courier DNS 活动及 dial timeout；再后 10 秒无操作为 0。用户说明错过了捕获窗口，因此该 burst 永久记为无法归因的后台事件，不再要求回忆或补写 UI 关联。
- A2（TUN 开、窗口隐藏、tray title 关、空闲）已完成 3 轮标准采集：FlClash 总平均 `1.235%`、Core 总平均 `1.423%`，900 行 CSV 完整，三轮状态栏热符号均为 0。A2 与 A3 都未复现高 CPU，且 A2 均值并未低于 A3，当前证据不支持直接归因 tray title。
- A4（TUN 开、窗口显示、tray title 关、仪表盘空闲）已完成 3 轮标准采集：900 个有效样本，FlClash 总平均 `34.270%`、max `62.200%`，Core 总平均 `0.900%`、max `8.300%`；三轮 `_updateReplicants`、`_redrawReplicantSnapshot`、`NSStatusItem`、`MethodChannel`、`PlatformDispatcher` 均为 0。证据见 `evidence/phase1/macos-cpu/A4-20260803T140155Z.md`。
- A1 首次自动门禁在 `toggle-tun false` 阶段失败并由 watchdog 恢复；没有继续打磨。用户随后手动关闭 TUN，live 与偏好均确认 `false` 后完成 3×（120 秒预热 + 300 秒采样）：900 个有效样本，FlClash 总平均 `3.070%`、max `48.500%`，Core 总平均 `0.339%`、max `3.600%`；三轮旧 tray/dispatcher 热符号全为 0。证据见 `evidence/phase1/macos-cpu/A1-20260803T151445Z.md`；旧失败尝试保留为过程记录。
- A5（TUN 开、窗口隐藏、tray title 关、持续下载）已用仅绑定 loopback、显式经过 FlClash mixed listener 的 256 KiB/s 本地字节流完成三轮；无外网字节。FlClash 总平均 `3.694%`、Core `1.167%`，三轮旧 tray/dispatcher 符号全为 0。证据见 `evidence/phase1/macos-cpu/A5-20260803T143542Z.md`。
- A6 多显示器、A7 睡眠/唤醒与 Windows 实机矩阵均由用户延后；不执行、不视为通过，也不再计入本次门禁。
- 本次只剩 Apple 原生服务矩阵：功能结果优先、同一明确时间窗口的脱敏 Core/apsd 事件只作旁证。执行协议与结果见 `evidence/phase1/MACOS_APPLE_NATIVE_SERVICE_MATRIX.md`。
- Apple Account 已完成有效功能轮次并判定失败：iCloud 子页与返回主页面均在 10 秒后持续转圈；App Store、iCloud Drive、iMessage/APNs 与 Private Relay 状态仍待执行/记录。
- [x] 抓住新的高 CPU 现场并完成页面 A→B→A：工具页 20 秒平均 `2.51%`，仪表盘 `34.24%`，切回立即复现；Core 不升高。Xcode 16.4 profiler 证明主要为 Flutter raster/Main/Metal，非 NSStatusItem 热栈。详见 `evidence/phase1/MACOS_HIGH_CPU_LIVE_REPRO.md`。
- [x] 对仪表盘高 CPU 做 connectivity / 固定 IP 检测入口脱敏计数：60 秒内没有初始事件之后的 NWPath transition，也没有 7 个检测入口日志；已排除持续 connectivity／请求风暴。`_preHasVpn == hasVpn` 仍是一次性错误触发候选，不是已证明的持续根因。详见 `evidence/phase1/MACOS_CONNECTIVITY_NETWORK_DETECTION_TRACE.md`。
- [x] 用 AX 白名单状态探针复核两个 loading 分支：network detection 与 intranet IP 均为 `ip_redacted` 时，仪表盘仍 `30.02%` mean / `51.50%` max，已撤回 spinner 根因。
- [x] 在 v0.8.93 隔离 worktree 运行 `.ai/tests/dashboard_animation_probe_test.dart` 等价诊断：DonutChart 每次新 data list 启动约 300ms ticker，数值相同也会重启；LineChart 默认零时长。当前根因收敛为每秒 traffic → TrafficUsage → DonutChart 动画。
- [x] 证明 macOS Microsoft Web 故障不是 Windows-only：正确 `cloud.microsoft` 规则命中后，TUN 开 + 微软服务 DIRECT 失败；TUN 关原生 DIRECT 成功；恢复代理后 HTTP 200。故障已收敛到 TUN 内 DIRECT 路径。详见 `evidence/phase1/MACOS_MICROSOFT_FUNCTION_BASELINE.md`。
- [x] 完成 `tun.inet6-address` → stack → Fake-IP/DNS fallback 的 Microsoft 单变量：live inet6 已被 parser 清空；system/gVisor 均失败；保留 Fake-IP 时删除 fallback 可恢复；进一步保留全部 fallback、仅用精确 `nameserver-policy` 绕过错误 fallback 也能恢复三域 DNS、DIRECT URLTest 和真实 HTTPS。详见 `evidence/phase1/MACOS_MICROSOFT_DNS_FALLBACK_AB.md`。
- [x] 完成普通“微软服务”DNS policy ownership review：路由与 DNS 共用互斥的 inline classical provider，science/direct 集合必须做 suffix overlap 门禁；当前 `override_dns=false`，raw policy 可进入 effective config。详见 `evidence/phase1/MACOS_MICROSOFT_DNS_POLICY_OWNERSHIP_REVIEW.md`。

## Phase 2：macOS CPU 最小修复

- [ ] 首个 CPU patch 只给 `TrafficUsage` 的 DonutChart 传 `Duration.zero`，并补连续真实数值变化仍无 active ticker 的正式 widget test；不在首 patch 修改全局 timer/窗口/tray。review 见 `evidence/phase1/MACOS_CPU_MINIMAL_FIX_REVIEW.md`。
- [ ] 用同一 A→B→A 与隐藏窗口场景做 live 验收；只有局部零时长未达到至少 80% 降幅时，才进入第二层生命周期 profiling。
- [ ] DonutChart 的 List identity 比较作为独立通用组件 cleanup 评估；它不是解决真实流量每秒变化的充分修复。
- [ ] 将 `_preHasVpn == hasVpn` 作为独立逻辑问题验证；若确认写反，再覆盖首次事件、相同事件、真实变化事件，不与 DonutChart CPU patch 混在同一提交。
- [ ] 以 PR #2201 为参考，在当前 Dart 代码实现 tray title 幂等更新。
- [ ] tray title 关闭时停止订阅每秒 traffic，并只清空原生 title 一次。
- [ ] 在当前 tray_manager 原生代码增加第二层幂等保护，不回退到旧分叉实现。
- [ ] 增加 MethodChannel / provider 测试。
- [ ] 验证 title 开关、destroy/recreate、失败重试、多显示器。
- [ ] 单独评估 PR #2202 的隐藏窗口轮询优化；不要与第一 patch 强行合并。
- [ ] 若优化 request 解析，确认不会破坏后台日志/连接历史的产品预期。

验收：本次已完成的 A1–A5 数据与 Phase 2 review 保留；A6/A7 延后，不在本次验收范围。本次不进入产品 CPU 修改。

## Phase 3：TUN 根因修复

- [x] 对当前 macOS Microsoft 三域验证 issue #1993 的 `inet6-address` 假设：effective YAML 有地址，但 Mihomo parser 在 `ipv6:false` 时清空，live TUN 无 inet6，故障仍在。
- [x] 验证 `ipv6: false` 时文件 effective TUN 仍生成 IPv6 地址，但 live parsed listener 不保留该字段。
- [x] 完成 Microsoft stack 与 Fake-IP/DNS fallback 优先单变量；stack 不改变结果，保持 Fake-IP 并绕过错误 fallback 即可恢复。QUIC/UDP/MTU 仅在后续仍有非 DNS 故障时再测。
- [x] 选择最小 DNS 修复边界：保留 Fake-IP/fallback/filter，以两个互斥 inline provider 统一路由 ownership，并让 `nameserver-policy` 只引用普通 Microsoft direct provider；science provider 继续代理。
- [ ] 在 Phase 3/4 获得授权后创建独立配置副本，执行 provider overlap 静态门禁、raw/effective diff 和 Microsoft direct/science live 矩阵；不得覆盖原始 `20260712.yaml`。
- [ ] 若为 FlClash 配置合成问题，在 `Tun` model、配置 UI 或 `_makeRealProfileTask` 的正确边界修复。
- [ ] 若需要新增 Tun model 字段，运行 code generation，禁止手改 generated 文件。
- [ ] 若为 Mihomo 问题，先确认当前内核上游是否已有修复，再决定更新 submodule。
- [ ] macOS 与 Windows 分开提交逻辑和测试，除非共享根因已被证明。

验收：最小配置可证明修复变量；Apple 与 Microsoft 服务矩阵通过；Microsoft Store 无回归。

## Phase 4：配置清理（独立工作流）

- [ ] 不修改原始 `20260712.yaml`，创建带日期的副本。
- [ ] 对 14 组确定冲突逐项记录保留策略和理由。
- [ ] 删除同策略精确重复。
- [ ] 人工复核静态遮蔽候选。
- [ ] 评估 Apple 子组是否过度细分，以及 Microsoft 两组的唯一 ownership。
- [ ] 评估 6,795 条广告规则迁移到固定版本 rule-provider。
- [ ] 验证旧 `script.shortcuts`、`experimental.ignore-resolve-fail` 在当前 Mihomo 的作用。
- [ ] 使用当前内置 core 做配置检查和代表性 rule trace。

验收：生成独立 cleaned 文件、变更报告、回滚方法；原文件 SHA-256 不变。

## Phase 5：全量验证与交付

- [ ] `flutter pub get`。
- [ ] `flutter analyze --no-fatal-infos`。
- [ ] `flutter test --reporter expanded`。
- [ ] 显式运行 tray_manager/plugin 相关测试。
- [ ] 构建 macOS 与 Windows 测试产物。
- [ ] 记录已验证环境、已知限制和复现数据。
- [ ] 更新 README/CHANGELOG（仅在用户确认后）。
- [ ] 不自动 commit/push/PR；等待用户明确指令。
