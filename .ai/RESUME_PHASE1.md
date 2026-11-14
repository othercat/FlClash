# Phase 1 暂停与恢复交接

暂停时间：2026-08-03（Asia/Shanghai）  
状态：Phase 1 正在执行，未验收；仪表盘高 CPU 已收敛到每秒 traffic 更新驱动的 `TrafficUsage` / `DonutChart` 300ms 动画，最小修复 review 已选择局部 `Duration.zero`；Microsoft/TUN DIRECT 三域已定位到 DNS fallback/filter 路径，policy bypass 已闭环，互斥 inline provider ownership review 已完成。暂停在进入 Phase 2 业务代码或 Phase 3/4 配置副本实施前。  
工作目录：`/Users/lirichard/AI/CLASH/FlClash/othercat/FlClash`

## 恢复时的最高优先级约束

1. 只使用 Xcode 16.4 (`16F6`) / macOS 15.5 SDK；不要切到 Xcode 26。
2. 先读取根目录 `AGENTS.md`、它要求的 `.agents` 文件、`core-platform` skill，随后完整读取 `.ai` 文档，尤其是本文件、`PROMPTS.md`、`TODO.md`、`TEST_MATRIX.md` 和 `PHASE1_BASELINE.md`。
3. 当前只完成 Phase 1，不进入 Phase 2/3，不修改业务代码，不修改用户原始 YAML，不 commit、push 或开 PR。
4. 不读取或输出节点、服务器、UUID、密码、订阅 URL、secret、Cookie、证书、私钥或完整 SharedPreferences；所有证据只保留白名单字段。
5. 不再对菜单栏状态项执行 Accessibility `press`。v0.8.93 的 `tray_manager` 会强制解包 `NSApp.currentEvent!`，Accessibility press 会触发 `SIGTRAP`。
6. TUN、系统代理或其他可能中断 Codex 的网络切换，仍应尽量使用 `macos_network_recovery_watchdog.sh` 做短 timeout 恢复，并通过日志判断恢复结果；watchdog 只是降低断连概率，不再作为 Phase 1 开工门槛或需要继续打磨的独立成果。
7. 若 Codex 实际断连，用户看到第 3 次“重新连接”提示后手动恢复。恢复通讯后必须重新识别 `/Applications/FlClash.app` 当前 App/Core 进程、live TUN、系统代理和持久化偏好；不能假设仍是断连前 PID，也不能把断连期间未观测到的动作视为成功证据。

## 当前仓库与版本

- 当前 `main` / `origin/main` / `upstream/main`：`7c831855efedceb1a72bd0b4c18da026593d0853`。
- 上游 v0.8.94：`7e7f1f89f363c31bbb7aa5af3f34a8b5c32a7a19`。
- 上游 v0.8.93：`45015f856b44cb52cca755c04c885d73c45ae6b9`。
- v0.8.93 `tray_manager`：`6163dc8f62f6f177a85072b0e1e2eee76fed54f0`。
- v0.8.93 Mihomo：`7bdcd60da9db10b681d7507af96d4fad797f3774`。
- 主工作树没有业务代码变化；`git status --short` 仅显示未跟踪 `.ai/`。

## 已完成的 Phase 1 证据

### 构建

- 已用 Xcode 16.4、Flutter 3.41.9、Dart 3.11.5、Go 1.24.0、Rust 1.95.0 从未修改的 v0.8.93 构建 macOS 产物。
- deployment target macOS 11.0，linked SDK macOS 15.5。
- 详细 SHA 与构建结果见 `PHASE1_BASELINE.md`。
- v0.8.94 未修改 lockfile 在 Xcode 16.4 下会因 `connectivity_plus 7.2.0` 使用 SDK 26 的 `NWPath.isUltraConstrained` 而失败。这是本机证据和上游插件构建要求，不是用户说过的话，也不代表 FlClash 最低运行系统是 macOS 26。

### Effective config 白名单 diff

- `EFFECTIVE_CONFIG_DIFF.md` 的旧 SHA 是用户编辑前的历史快照；用户随后主动修改了 Microsoft 规则，不能再写“当前 raw SHA 未变化”。
- raw 顶层 `ipv6: false`，文件 effective config 仍存在 1 条 `tun.inet6-address`；但当前 Mihomo parser 会清空它，live `/configs` 中该 key 不存在、count 为 0。
- 文件层矛盾仍存在，但已证明不是当前 macOS Microsoft 三域根因。
- 当前 raw/effective 均为 8055 条规则，顺序 SHA 完全相同；`cloud.microsoft` 正确规则存在且位于唯一最后 `MATCH` 前，`.com` 错误规则不存在。
- 证据：`evidence/phase1/EFFECTIVE_CONFIG_DIFF.md`、`evidence/phase1/MACOS_MICROSOFT_FUNCTION_BASELINE.md`。

### macOS Microsoft 与 TUN DIRECT

- 用户要求的最终语义是：普通“微软服务”走 DIRECT，只有“微软科学服务”走代理。
- 用户已把规则修正为带引号的 `DOMAIN-SUFFIX,cloud.microsoft,微软服务`；raw/effective 规则数组 8055/8055 完全相同，live `/rules` 也证明 `m365.cloud.microsoft` 命中该组。导入没有丢规则或重排。
- TUN 开、微软服务临时改 DIRECT 后，`login.live.com` 0/3 正常完成，用户同时确认 `www.microsoft.com` 无法打开。
- 用户把组恢复到原代理选择后，`www.microsoft.com`、`login.live.com`、`www.office.com` 均返回 HTTP 200，但 TLS 仍约 6–7 秒；代理只是可用性对照，不是最终修复。
- 用户随后确认同一 Mac 在 TUN 关闭时原生 DIRECT 可以成功。结合 TUN 开 + Core DIRECT 失败，故障已收敛到 TUN 内 DIRECT 路径，不是运营商原生直连能力，也不是规则导入丢失。
- TUN 开时 Core DIRECT URLTest 对三个 Microsoft 域名均 unavailable，而 matched 代理路径分别成功；Core A 查询三域各 3 轮全部 timeout/refused。
- 优先单变量已完成：live inet6 本来就是空；`system`、`gvisor` stack 均失败；原配置主 DoH 返回 IPv4 后触发 `fallback-filter`，4 个 fallback 无可用结果并使聚合 DNS timeout。
- 删除 fallback 的内存隔离 variant 恢复三域 DNS、DIRECT URLTest 和真实 HTTPS；更小的 variant 保留 Fake-IP、全部 4 个 fallback 与 filter，只为三个精确域名增加复用 main DNS 的 `nameserver-policy`，同样全部恢复。
- 这证明故障机制是普通 Microsoft 域名进入了当前错误 fallback 路径；“删除全部 fallback”和“微软服务永久代理”都不是最终方案。下一步是设计可维护的普通 Microsoft DNS policy，且不能覆盖“微软科学服务”的代理 ownership。
- 证据：`evidence/phase1/MACOS_MICROSOFT_FUNCTION_BASELINE.md`、`evidence/phase1/MACOS_MICROSOFT_DNS_FALLBACK_AB.md`。

### macOS Apple 公共入口

- `apps.apple.com` 通过当前 Core DIRECT 成功；`account.apple.com` 与 `www.icloud.com` 通过 Core DIRECT 稳定 dial timeout。
- live TUN 关闭、system proxy 保持开启后，失败仍存在；`account.apple.com` 原生直连则完成 TLS 并返回 HTTP 403。
- `/rules` 证明 App Store 与 Apple Account 命中同一 `DomainSuffix` payload/Selector；iCloud 命中独立 Selector。两个 Selector 当前都明确选择 DIRECT。
- 成功日志的 connected-chain 指纹与失败日志的 dial-target 指纹不能横向比较；旧的“三个目标组不同”推断已撤回。
- 上述结论只适用于固定公共 curl 探测：它不支持把 TUN 入站单独定为这些固定入口的充分根因，但不能外推到 System Settings 实际后台请求。
- Core A 查询 3 轮结果：App Store 3/3 成功，Apple Account 0/3，iCloud 1/3。失败域名的主 DoH 曾返回 IPv4，但命中 `fallback-filter` 后 4 个 fallback 无可用回答，聚合查询 timeout/refused。
- fresh v0.8.93 DNS-only Core 中，original DNS 与 without-fallback 都是 3/3 成功；但 Apple Account/iCloud 的回答指纹不同，证明 fallback 确实替换主 DoH 回答。静态配置不是充分失败条件，正式 Core 的 fallback client/连接状态或当时上游可达性决定 timeout/refused。
- 隔离 mixed-listener HTTPS 对照已再次被 App Store control 的“本地立即关闭、未进入 outbound”门禁否决；脚本恢复为 DNS-only，临时 CLI/runtime 已删除，不要继续调试该测试框架。
- 用户已手动重启正式 Core：App 进程保持、Core 进程更换，TUN/system proxy 自动恢复；重启后的 App Store 两条路径均 3/3 成功，Apple Account/iCloud 两条路径均 0/3 且未进入 TLS。因此 restart 没有修复问题，旧 Core 连接状态不能作为充分根因。
- 早期 `lsof` 看不到 9090 就推断“Core 没有建立 listener”已撤回：当前 controller API 与 `nc` 均确认 loopback 9090 可达时，`lsof` 仍不显示监听。重启前没有 config-aware 请求，因此不能判断动态更新是否已经生效。fake-IP `dig` 三域均成功只代表占位回答，不能代表 upstream 解析成功。
- 原生 Apple Account 的用户观察为：TUN 开时超过 10 秒持续转圈；手动关 TUN 后加载；再开 TUN 后仍能加载。这是 TUN-specific 高价值线索，但后台 daemon、缓存与既有连接未受控，尚不是稳定因果闭环。不要再用退出／重开 System Settings 充当后台冷启动。
- `logs-apple` 后台链已可用：15 秒操作前静默为 0；随后 5 秒捕获 iCloud Contacts DIRECT connected 与 Apple Push/Courier DNS 活动及 dial timeout；操作后 10 秒再次为 0。用户后来说明是错过了提示的捕获窗口，因此该 burst 永久只记为“无法归因的后台事件”，不再要求用户回忆是否操作。
- 2026-08-04 已完成第一轮有效 Apple Account 功能矩阵：用户在明确开始提示后进入 iCloud 子页，10 秒仍转圈；返回 Apple Account 主页面，10 秒仍转圈。操作窗口新增 iCloud mask/quota 类域名，主 DoH 有 IPv4 回答但仍出现 fallback 与 TCP/UDP timeout/refused；另有部分 DIRECT connected。功能项判定为失败，详情见 `evidence/phase1/MACOS_APPLE_NATIVE_SERVICE_MATRIX.md`。
- 证据：`evidence/phase1/MACOS_APPLE_FUNCTION_BASELINE.md`。

### macOS CPU A1–A5 与新高 CPU 复现

- A1（TUN 关、窗口隐藏、tray title 关、空闲）已在用户手动关闭 TUN 后严格执行 3×（120 秒预热 + 300 秒采样）。preference 与 live TUN 均确认 false；900 个样本完整，FlClash 总平均 `3.070%`、max `48.500%`，Core 总平均 `0.339%`、max `3.600%`；三轮旧 tray/dispatcher 符号全为 0。CSV SHA-256 为 `42910673cfd568be66e79d76fd72034dccf9dab5969ac638713ea6bdc9aa7f02`。旧自动门禁失败记录仍保留，但不再代表 A1 未完成。

- A2（TUN 开、窗口隐藏、tray title 关、空闲）已严格执行 2 分钟预热 + 5 分钟采样、重复 3 次。
- A2 共 900 行有效 CSV：FlClash 总平均 `1.235%`、max `8.600%`；FlClashCore 总平均 `1.423%`、max `16.900%`；三轮 `_updateReplicants`、`_redrawReplicantSnapshot`、`NSStatusItem` 均为 0。
- A2 证据：`evidence/phase1/macos-cpu/A2-20260803T080245Z.md` 和同名 CSV。

- A3（TUN 开、窗口隐藏、tray title 开、空闲）已严格执行：2 分钟预热 + 5 分钟采样，重复 3 次。
- 900 行 CSV 全部 6 列有效，线程数均为正。
- FlClash 总平均 CPU `0.967%`，max `3.700%`。
- FlClashCore 总平均 CPU `1.346%`，max `13.100%`。
- `_updateReplicants` 三轮为 `0 / 0 / 1`；`_redrawReplicantSnapshot` 全部为 `0`。
- A2/A3 当时都没有复现高 CPU；A2 总均值还略高于 A3，不能据此把 tray title 认定为当前高 CPU 根因。
- 证据：`evidence/phase1/macos-cpu/A3-20260803T032015Z.md` 和同名 CSV。

- A4（TUN 开、窗口显示、tray title 关、仪表盘空闲）已严格执行 2 分钟预热 + 5 分钟采样、重复 3 次。
- 900 个样本完整：FlClash 总平均 `34.270%`、max `62.200%`；Core 总平均 `0.900%`、max `8.300%`。
- 三轮 `_updateReplicants`、`_redrawReplicantSnapshot`、`NSStatusItem`、`MethodChannel`、`PlatformDispatcher` 全为 0。
- A4 与此前 20 秒仪表盘 `34.24%` 高度一致，正式证明稳定负载不是短时尖峰；证据见 `evidence/phase1/macos-cpu/A4-20260803T140155Z.md` 和同名 CSV。
- A5（TUN 开、窗口隐藏、tray title 关、持续下载）使用 loopback-through-Core 256 KiB/s 本地字节流，无外网字节；三轮 FlClash 总平均 `3.694%`、Core `1.167%`，旧 tray/dispatcher 符号全为 0。证据见 `evidence/phase1/macos-cpu/A5-20260803T143542Z.md` 和同名 CSV。
- 用户进一步将本次剩余范围收窄为只处理 Apple 原生服务矩阵。A6 多显示器、A7 睡眠/唤醒与 Windows 实机矩阵均延后；未验证、不视为通过，也不计入本次门禁，后续不要再提示执行。

2026-08-03 17:33 后用户再次观察到现场高 CPU，并已形成稳定 A→B→A：

- FlClash 首次 `31.4%`，Core `0.6%`；关闭普通窗口后 FlClash 20 秒平均约 `25.97%`、最大 `55.3%`，所以“可见窗口”不是充分条件。
- Xcode 16.4 Time Profiler 显示主要 CPU 在 `io.flutter.raster`、Main Thread、Metal/CA 提交；`TrayManagerPlugin.setTitle` 只占 2 个 1 ms 样本，`NSStatusItem`/replicant 热栈为 0。
- 只从仪表盘切到工具页，20 秒平均从 `34.24%` 降到 `2.51%`；切回仪表盘立即恢复，Core 不同步升高。
- `connectivity_plus 7.0.0` 会过滤相同结果数组，macOS adapter 也不产生 VPN 类型。60 秒仪表盘高 CPU 捕获只有探针的初始 Wi-Fi path，没有后续 transition；7 个固定 IP 检测入口日志为 0。同期 FlClash 平均 `20.06%`、最大 `45.50%`，Core 平均约 `0.43%`。
- 后续 AX 白名单状态探针确认 network detection 与 intranet IP 均为 `ip_redacted`，不是 loading；此时仪表盘 20 秒仍 `30.02%` mean / `51.50%` max。因此 spinner 根因已经撤回。
- 当前高置信执行链：`SetupAction` 每秒 `updateTraffic()` → `totalTrafficProvider` → `TrafficUsage` 每次新建 data list → DonutChart 以 list identity 判定变化并启动默认 300ms `CustomPaint` 动画。即使数值相同，新 list 也重启 ticker。
- v0.8.93 隔离 worktree 的 widget 诊断验证普通更新和等值新 list 都会保持约 300ms ticker；LineChart 默认零时长。`_preHasVpn == hasVpn` 只保留为独立逻辑候选，不再作为本轮 CPU 根因。
- 证据：`evidence/phase1/MACOS_HIGH_CPU_LIVE_REPRO.md`、`evidence/phase1/MACOS_CONNECTIVITY_NETWORK_DETECTION_TRACE.md`。

### macOS `ps`

- Homebrew Core `procps` 仅支持 Linux，`coreutils` 不含 GNU `ps`，macOS 不能通过官方 brew 方案获得可用 `gps`。
- `macos_cpu_capture.sh` 已改用 `/bin/ps -p PID -o %cpu=` 和 `/bin/ps -M -p PID`，并与 `top` 做过只读对照。

### Accessibility 崩溃

- 2026-08-03 10:17 的崩溃为 `EXC_BREAKPOINT/SIGTRAP`。
- 主线程顶部是 `TrayManagerPlugin.statusItemButtonClicked(sender:)`，调用栈包含 `accessibilityPerformPress`。
- 精确源码存在 `let event = NSApp.currentEvent!`。
- 证据：`evidence/phase1/MACOS_ACCESSIBILITY_CRASH.md`。

## 超时恢复探索结果

### 已排除

- `CFFIXED_USER_HOME` 能隔离 Application Support/Cache 路径，但 `UserDefaults` 仍经 `cfprefsd` 写入真实用户域；专用测试域和残留空 plist 已全部删除。
- 当前 `FlClashCore` 不是 Mihomo CLI main：它只启动随机 Unix IPC，没有注册 `SIGHUP`。不要向它发送 HUP，默认行为可能直接终止进程。
- FlClash App/Core 的随机 Unix IPC 是单客户端连接，第二个恢复客户端不能与当前 App 并行复用。
- 现有 `macos_recovery_watchdog.sh` 只能恢复进程运行/停止状态，不能恢复 live TUN/代理/持久化开关，当前禁止用于真实网络切换。

### 已验证结果

- 普通 Flutter 窗口可通过 `AXEnhancedUserInterface` 临时展开语义树。
- `.ai/scripts/macos_flclash_ax_scan.swift` 只扫描 App 普通窗口，排除菜单栏状态项，并只输出固定公开标签。
- 已安全完成一次“仪表盘 → 工具 → 基本配置 → 仪表盘”导航，未发生崩溃，TUN/代理未变化。
- 在基本配置页已唯一找到 `外部控制器`：`role=AXButton`, `action=AXPress`。
- controller 生命周期、同值 TUN PATCH、真实 TUN off → timeout → on 曾完成闭环；详情见 `evidence/phase1/MACOS_NETWORK_WATCHDOG.md`。
- 后续一次 UI cleanup 失败触发旧 fallback，停止了 App/Core 且未自动 reopen，最终由用户手动恢复。这证明 watchdog 不能作为绝对恢复保证。
- fallback 代码虽已补充 reopen，但不再用正式实例做破坏性验证；后续把精力用于功能矩阵。

## 当前运行状态

最后一次只读核对：2026-08-03 23:42 CST。下列 PID 由该次重新识别获得，不是复用旧记录：

- FlClash 与 FlClashCore 各 1 个进程，均在运行。
- `auto_run=false`
- `silent_launch=true`
- `show_tray_title=false`
- `override_dns=false`；当前 raw DNS policy 可由 FlClash 保留，但恢复后仍需重新核对。
- `system_proxy_preference=true`
- `tun_preference=true`（A1 完成后已由用户手动恢复）
- `ipv6_preference=false`
- `tun_stack=mixed`
- `external_controller_preference=true`，loopback 9090 controller 可达。
- 主窗口可见，暂停时停在已验证低 CPU 的“工具”页；另有一个 54×54 的无内容 AXDialog/CGWindow，来源未定，不影响工具页 CPU 已降至约 `1%` 的结论。
- `AXEnhancedUserInterface=false`。
- 系统 HTTP/HTTPS/SOCKS proxy enable 均为 `1`，PAC enable 为 `0`。
- 最后一次现场核对：App/Core PID 为 `3094/69558`，A5 清理并恢复工具页后瞬时 CPU 约 `0.3%/0.7%`。PID 仅为当前快照，恢复时必须重新识别。
- 仪表盘 widget count 为 7，包含 network speed、traffic usage、network detection、intranet IP，不含 memory info；只记录存在性，不保存完整偏好。
- live TUN 为 `true/mixed`，`tun.inet6-address` 不存在；系统 HTTP/HTTPS/SOCKS proxy 均开启且只指向 loopback，PAC 关闭。
- Microsoft DNS A/B 已恢复原 DNS 和 33 个 Selector；目标 Selector 当前选择指纹与测试前相同且不是 DIRECT。
- Phase 1 逐项完成度见 `evidence/phase1/PHASE1_COMPLETION_AUDIT.md`：本次唯一剩余门禁是 Apple 原生服务矩阵；执行协议见 `evidence/phase1/MACOS_APPLE_NATIVE_SERVICE_MATRIX.md`。

恢复时必须重新只读核对，不能把这些值当成永久事实。

## 恢复后的下一步

1. 每次恢复通讯后，用 `git status --short`、状态快照、进程列表和系统代理白名单重新确认仓库与 live 状态；应用来源固定按当前 `/Applications/FlClash.app` 重新识别，不复用旧 PID。
2. CPU review 已完成，不要重复 connectivity、loading 或 profiler 捕获。若用户明确进入 Phase 2，首 patch 只给 `TrafficUsage` 的 DonutChart 传 `Duration.zero` 并补正式 widget test；不同时改 timer、公共 DonutChart、窗口/tray 或 `_preHasVpn`。live 降幅未达 80% 时才扩展生命周期 profiling。
3. Microsoft ownership review 已完成，不要重复 inet6、stack、规则导入或删除全部 fallback 实验。若用户明确进入 Phase 3/4，在独立配置副本中建立互斥 science/direct inline provider，路由与 DNS 共用 direct provider，执行 suffix overlap、effective diff 和 live 矩阵；不得修改原始 YAML。
4. Apple event burst 已无法与用户操作关联，不再追问回忆。后续若测 Apple 原生后台，必须先明确开始窗口并只记录当轮；不重复 restart，也不退出／重开 System Settings。
5. 网络开关实验尽量使用短 timeout worker；若仍断连，停止自动恢复调试，由用户手动恢复。恢复后先重建观测上下文，再继续下一轮，不能补写无法证明的结果。
6. A1–A5 已完成；A6/A7 与 Windows 实机矩阵均延后，后续不要再提示。本次只按 `MACOS_APPLE_NATIVE_SERVICE_MATRIX.md` 完成 Apple Account、App Store、iCloud Drive、iMessage/APNs 与 Private Relay 状态；功能结果优先，旁证不能替代实际动作。

## 恢复提示词

复制以下内容到新的 Codex 任务：

```text
继续执行 FlClash Phase 1。仓库位于：
/Users/lirichard/AI/CLASH/FlClash/othercat/FlClash

默认用中文。先读取并遵守根目录 AGENTS.md、它要求的 .agents 文件和 core-platform skill；随后完整读取 .ai 下的文档，尤其是：
- .ai/RESUME_PHASE1.md
- .ai/PROMPTS.md
- .ai/TODO.md
- .ai/TEST_MATRIX.md
- .ai/PHASE1_BASELINE.md
- .ai/evidence/phase1/MACOS_CONNECTIVITY_NETWORK_DETECTION_TRACE.md
- .ai/evidence/phase1/MACOS_MICROSOFT_DNS_FALLBACK_AB.md
- .ai/evidence/phase1/MACOS_CPU_MINIMAL_FIX_REVIEW.md
- .ai/evidence/phase1/MACOS_MICROSOFT_DNS_POLICY_OWNERSHIP_REVIEW.md

以当前工作树和 live 状态为准，不要只依赖旧对话。先做只读核对，再从 RESUME_PHASE1.md 的“恢复后的下一步”继续。

强制约束：只使用 Xcode 16.4，不使用 Xcode 26；不修改业务代码或原始 YAML；不 commit/push/PR；不输出任何节点、订阅、secret、密码、Cookie、证书或完整偏好。禁止对菜单栏 tray 执行 Accessibility press。TUN/系统代理切换尽量使用短 timeout 恢复并检查日志，但不要继续花精力打磨 watchdog；若实际断连，用户看到第 3 次重新连接提示后手动恢复。

当前 Phase 1 尚未完成。CPU 已稳定复现为仪表盘约 30%–34%、工具页约 2.5%；connectivity、7 个检测入口和两个 loading spinner 均已排除。当前高置信链是每秒 traffic 更新使 TrafficUsage 重建新 list，DonutChart 因 identity 比较每次运行 300ms CustomPaint 动画；v0.8.93 widget 诊断证明即使数值相同也会重启 ticker，LineChart 默认零时长。`_preHasVpn == hasVpn` 仅保留为独立逻辑候选。

标准 A1 与 A4 均已完成三轮 2 分钟预热 + 5 分钟采样：A1 的 900 个样本为 FlClash `3.070%` mean / `48.500%` max、Core `0.339%` mean；A4 为 FlClash `34.270%` mean / `62.200%` max、Core `0.900%` mean；旧 tray/dispatcher 符号全为 0。A1 使用用户手动关闭 TUN，不要重试或打磨旧自动 toggle。

A5 也已完成：loopback-through-Core 256 KiB/s、无外网字节，900 个样本；FlClash `3.694%` mean、Core `1.167%` mean。隐藏窗口下高流量只增加有限后台成本，不能解释 A4 的 34%。

CPU 最小修复 review 已完成：产品中 DonutChart 只有 TrafficUsage 一个调用点；只给该调用传 Duration.zero 即可消除 300ms ticker并保留每秒数据更新。精确 v0.8.93 诊断已证明连续真实数值变化也不再保留 ticker。未经明确 Phase 2 授权不修改业务代码。

Microsoft 三域已经按 inet6 → stack → Fake-IP/DNS fallback 完成单变量：live inet6 被 Mihomo parser 清空，system/gVisor 仍失败；主 DoH 有 IPv4 回答，但 fallback-filter 强制等待 4 个当前不可用的 fallback 而 timeout。保留 Fake-IP、全部 fallback/filter，仅为三个精确域名增加复用 main DNS 的 nameserver-policy 后，DNS、Core DIRECT URLTest 和 TUN 内真实 HTTPS 全部成功，并已恢复原配置/Selector。最终仍必须是普通“微软服务”DIRECT、只有“微软科学服务”代理；不要把删除全部 fallback、全量 Microsoft 代理或硬编码 3 个测试域名当最终修复。

Microsoft ownership review 已完成：独立配置副本应使用互斥的 microsoft-science/microsoft-direct inline classical provider，路由分别引用，nameserver-policy 只引用 direct provider并复用已验证的 main resolver；science 继续代理。当前 override_dns=false，raw policy 可进入 effective config。官方 Microsoft 365 feed 只生成候选 diff，不能自动覆盖 consumer/science 分类。

恢复后先重新识别 /Applications/FlClash.app 当前实例和 live 状态。最后快照为 TUN true/mixed、live inet6 absent、system proxy true、tray title false、override DNS false、AX=false；这些都必须重新核对。不要重复已经完成的 connectivity/loading 捕获、inet6/stack/no-fallback A/B 或两个 review。未经用户明确进入下一阶段，不修改业务代码或原始 YAML。
```
