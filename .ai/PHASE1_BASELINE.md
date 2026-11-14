# Phase 1 基线记录

状态：进行中。仓库、隔离构建、effective config 白名单 diff、macOS CPU A1–A5、Apple 公共入口与正式 Core restart 后复测已完成。标准 A4 将仪表盘高 CPU 稳定量化为 `34.270%` mean；CPU 最小 patch review 已确定为 `TrafficUsage` 局部零时长。macOS Microsoft 三域已定位到 DNS fallback/filter 路径，policy bypass 与 ownership review 均已完成。本次唯一剩余门禁是 Apple 原生服务矩阵；A6/A7、配置副本实施与 Windows 实机复现均延后，未验证且不视为通过。

## 安全边界

- 2026-08-03 曾对正在运行的 `/Applications/FlClash.app` 做一次 Accessibility 菜单探测，随后 FlClash 调试实例崩溃并导致 Codex 通讯中断。崩溃报告与精确 submodule 源码已将原因定位到 `tray_manager` 对 `NSApp.currentEvent!` 的强制解包；详见 `evidence/phase1/MACOS_ACCESSIBILITY_CRASH.md`。该次操作记为无效测试，不计入任何基线结论。
- 禁止再用 Accessibility `press` 操作菜单栏状态项。普通窗口和网络开关仍可在真实功能复现需要时操作，但要尽量启用短 timeout 恢复、通过日志核验，并接受实际断连后由用户手动恢复。
- 用户手动恢复的可能是 `/Applications/FlClash.app` 的新实例；每次恢复通讯后必须重新识别 App/Core PID 和 live 状态，不能沿用旧进程上下文。
- 隔离构建产物没有启动、没有复制到 `/Applications`，也没有读取或修改用户原始 YAML。
- 一次 `flutter -v` 构建把调用进程的环境变量带入本地工具日志。后续构建改用 `env -i` 白名单环境且不再使用 verbose；日志中出现的凭据值未写入 `.ai`，相关凭据应轮换。

## 精确版本

| 对象 | SHA / 版本 | 用途 |
|---|---|---|
| 当前 `main` | `7c831855efedceb1a72bd0b4c18da026593d0853` | 仓库同步基线 |
| 上游标签 `v0.8.94` | `7e7f1f89f363c31bbb7aa5af3f34a8b5c32a7a19` | 当前稳定版依赖核对 |
| 上游标签 `v0.8.93` | `45015f856b44cb52cca755c04c885d73c45ae6b9` | 当前已安装故障版本的可复现构建基线 |
| v0.8.93 `tray_manager` | `6163dc8f62f6f177a85072b0e1e2eee76fed54f0` | submodule |
| v0.8.93 Mihomo | `7bdcd60da9db10b681d7507af96d4fad797f3774` | `core/Clash.Meta` submodule |
| v0.8.93 `flutter_distributor` | `cdeeef2d8f8325bb6ae0bc86b39f56e4325d1a58` | submodule |
| v0.8.94/current `tray_manager` | `da2d83dd1cc3c9709bf708ff827ad9072504ce52` | `pubspec.lock` resolved ref |
| v0.8.94/current Mihomo | `80362fc1895dcf60b79b562896653046e0687413` | `core/Clash.Meta` submodule |

## Xcode 16.4 与 `connectivity_plus 7.2.0`

用户没有说过“0.8.94 在 Xcode 16.4 上不可构建”。此前把本机构建结果归因给用户属于错误表述，现已撤回。

可以确认的事实仅为：**FlClash v0.8.94 的未修改 lockfile 在本机使用 Xcode 16.4 / macOS 15.5 SDK 构建时，会在 `connectivity_plus 7.2.0` 的原生源码处失败。**证据链如下：

1. [FlClash v0.8.94 `pubspec.lock`](https://github.com/chen08209/FlClash/blob/v0.8.94/pubspec.lock#L244-L251) 锁定 `connectivity_plus 7.2.0`。
2. [`connectivity_plus 7.2.0` 官方 README](https://github.com/fluttercommunity/plus_plugins/blob/connectivity_plus-v7.2.0/packages/connectivity_plus/connectivity_plus/README.md#requirements) 同时声明 `macOS >= 10.14` 和 `Xcode >= 26.1.1`。
3. [该版本官方 Swift 源码](https://github.com/fluttercommunity/plus_plugins/blob/connectivity_plus-v7.2.0/packages/connectivity_plus/connectivity_plus/ios/connectivity_plus/Sources/connectivity_plus/PathMonitorConnectivityProvider.swift#L29-L30) 调用 `NWPath.isUltraConstrained`。
4. Xcode 16.4 的 macOS 15.5 SDK 中没有该成员；本机最小 `swiftc -typecheck` 稳定得到 `value of type 'NWPath' has no member 'isUltraConstrained'`。
5. macOS 26 SDK 将该成员声明为 `@available(macOS 26.0, iOS 26.0, ...)`。插件源码只写了 `#available(iOS 26.0, *)`，并未对 macOS SDK 编译条件做隔离。

这证明的是上游插件的**构建工具要求**，不是 FlClash 官方主动放弃旧 macOS，也不代表产物最低运行系统必须是 macOS 26。为了遵守 Xcode 16.4 约束且不在 Phase 1 修改业务依赖，隔离基线选用上游原版 v0.8.93；该版本锁定 `connectivity_plus 7.0.0`。

## macOS 隔离构建

构建工作树：`/tmp/flclash-phase1-v0.8.93-45015f85`（detached、未修改上游业务源码）。

| 工具 | 版本 |
|---|---|
| Xcode | 16.4 (`16F6`) |
| macOS SDK | 15.5 |
| Flutter | 3.41.9 (`00b0c91f06`) |
| Dart | 3.11.5 |
| Go | 1.24.0 |
| Rust stable | 1.95.0，arm64/x86_64 target |

构建过程中只修正了本机工具环境：Go module mirror 固定为公开镜像；Rust 的 `cargo` 与 `rustc` 固定为同一个 rustup stable toolchain。未修改 FlClash 源码。

构建前 detached worktree 为 clean；`setup.dart`/CocoaPods 在构建过程中自动重写了临时 worktree 的 `macos/Podfile.lock`，这是当前唯一 tracked post-build 变化。主工作树未受影响，仍只包含未跟踪的 `.ai/`。

产物校验：

| 项目 | 结果 |
|---|---|
| App | `build/macos/Build/Products/Release/FlClash.app`，155 MiB |
| DMG | `dist/FlClash-0.8.93-macos-arm64.dmg`，60 MiB |
| App version/build | `0.8.93` / `2026052901` |
| 主程序架构 | universal `arm64` + `x86_64` |
| FlClashCore 架构 | `arm64` |
| deployment target | macOS 11.0 |
| linked SDK | macOS 15.5 |
| DMG SHA-256 | `e6b02b88b59c76158a84012337edb7c14fc2a212a706f664c8929497e2da88b5` |
| 主程序 SHA-256 | `3dc5e1751fda63cd3fa5fddf63f4acf0da09a8200a12adaa0ea47036d37d47f8` |
| Core SHA-256 | `7b3a10b2c89ea4a14fbca227be161ffb3d153057a164539ced45c61e33017337` |

## 可复制采集工具

- `scripts/macos_recovery_watchdog.sh`：早期进程级 fallback；不能恢复 live 网络状态，不用于真实网络切换。
- `scripts/macos_network_recovery_watchdog.sh`：网络实验的 best-effort 短 timeout 保护；尝试恢复 live Core TUN、系统代理 enable 白名单、临时 controller、窗口和 AX 状态，但不是绝对恢复保证，也不再作为 Phase 1 门禁。
- `scripts/macos_cpu_capture.sh`：只读采集 FlClash 与 FlClashCore CPU；默认严格执行 2 分钟预热、5 分钟采样、3 次重复，并仅保留已知公开热符号计数。
- `scripts/macos_flclash_state_snapshot.swift`：只输出 CPU 场景需要的开关布尔值、仪表盘 widget 存在性、TUN stack 和窗口计数，不输出完整 SharedPreferences。
- `scripts/macos_dashboard_loading_probe.swift`：只把 network detection / intranet IP 的普通窗口 AX 状态分类为 `loading_candidate`、`timeout`、`no_network` 或 `ip_redacted`，不输出实际 IP；不执行任何 press。
- `scripts/macos_flclash_window.swift`：通过 `NSRunningApplication` 隐藏／恢复普通窗口，不调用 tray Accessibility action。
- `scripts/macos_core_control.rb`：本地 controller 快照、脱敏日志、DNS/URLTest 和一次性 Microsoft 内存 A/B 工具；强制拒绝非本机 controller，secret 不进入 argv、文件或输出；配置 variant 和 Selector 都在 `ensure` 中恢复。TUN PATCH 仍要求存活且 ready/risk 已打开的 network watchdog。
- `scripts/macos_nwpath_event_probe.swift`：只输出 NWPath signature 类别与更新／transition 计数，不输出 SSID、接口名、IP、DNS server 或 route；使用 Xcode 16.4 typecheck。
- `scripts/macos_public_service_probe.rb`：固定公开 Microsoft 入口的 HTTP/1.1 GET 探测；绕过代理环境，只输出阶段、HTTP code、耗时和 effective hostname，不保存页面、header、Cookie、解析地址或 URL path/query。
- `scripts/compare_profile_effective_rules.rb`：只比较 raw/effective 规则数量、顺序 hash、multiset、`cloud.microsoft` 规则存在性与 `MATCH` 位置，不输出完整规则或策略名称内容。
- `scripts/macos_flclash_tray_real_click.swift`：只通过真实 `CGEvent` 操作已唯一识别的 tray 状态项；新增 `click-open` 用于恢复普通窗口，仍禁止 Accessibility press。
- `scripts/sanitize_effective_config.dart`：白名单导出顶层 IPv6、TUN、DNS 结构；节点、provider、规则、secret、DNS 服务器值全部省略。
- `scripts/windows_phase1_capture.ps1`：Windows 只读采集模板；不写注册表、不改 DNS、不关防火墙，当前标记为“未实机验证”。
- `.ai/tests/dashboard_animation_probe_test.dart`：DonutChart / LineChart 生命周期诊断；在精确 v0.8.93 隔离 worktree 的既有 package config 上运行，不修改产品测试目录。

network watchdog 曾完成 controller 生命周期、同值 TUN PATCH 和真实 live TUN off→timeout→on 三类闭环；后续也发生一次 UI cleanup 失败，旧 fallback 停止 App/Core 后未自动 reopen，最终由用户手动恢复。因此它只作为降低断连概率的辅助，后续不再安排破坏性 fallback 验证。详见 `evidence/phase1/MACOS_NETWORK_WATCHDOG.md`。

CPU 采集不依赖 GNU `ps`：Homebrew Core 的 `procps 4.0.6` formula 明确 `depends_on :linux`，无法作为 macOS 官方安装方案，`coreutils` 也不包含 `ps`。脚本使用 macOS `/bin/ps -p ... -o %cpu=` 采集 CPU，并用 `/bin/ps -M -p ...` 统计线程；5 秒只读集成测试已验证 CSV 的 CPU/线程 6 列输出。查询 formula 时 Homebrew 临时开启的 developer mode 已恢复为 disabled。

## macOS CPU A3

2026-08-03 按 `TEST_MATRIX.md` 完成 A3：TUN 开、窗口隐藏、tray title 开、空闲。采样前和每轮开始前均对白名单状态做硬校验；采样脚本本身不切换网络或 UI。开始前通过 `NSRunningApplication.hide()` 隐藏窗口，结束后恢复到原来的窗口可见状态，没有经过 tray Accessibility 回调。

证据：`evidence/phase1/macos-cpu/A3-20260803T032015Z.csv` 与同名 `.md`。

| 轮次 | FlClash mean / max | FlClashCore mean / max | `_updateReplicants` | `_redrawReplicantSnapshot` | `NSStatusItem` |
|---|---:|---:|---:|---:|---:|
| 1 | 1.016% / 3.700% | 1.661% / 13.100% | 0 | 0 | 7 |
| 2 | 0.948% / 3.700% | 1.166% / 8.900% | 0 | 0 | 4 |
| 3 | 0.935% / 3.600% | 1.212% / 6.200% | 1 | 0 | 8 |
| 总计 | 0.967% / 3.700% | 1.346% / 13.100% | — | — | — |

CSV 共 900 行，全部为 6 列且两进程线程数均为正。三次原始 `sample` 只在私有临时目录短暂存在；汇总公开热符号计数后已删除。该场景下没有复现主进程高 CPU 或持续的 `NSStatusItem` 重绘风暴，因此不能把历史 PR 的 CPU 修复直接当作当前根因结论。

## macOS CPU A2

2026-08-03 按 `TEST_MATRIX.md` 完成 A2：TUN 开、窗口隐藏、tray title 关、空闲。用户用真实鼠标取消 tray 菜单“网速统计”，普通 FlClash 窗口随后通过其唯一 `AXCloseButton` 关闭；没有对 tray 状态项执行 Accessibility press，也没有切换网络。

证据：`evidence/phase1/macos-cpu/A2-20260803T080245Z.csv` 与同名 `.md`。

| 轮次 | FlClash mean / max | FlClashCore mean / max | `_updateReplicants` | `_redrawReplicantSnapshot` | `NSStatusItem` |
|---|---:|---:|---:|---:|---:|
| 1 | 1.167% / 8.600% | 1.280% / 11.200% | 0 | 0 | 0 |
| 2 | 1.178% / 7.100% | 1.511% / 16.900% | 0 | 0 | 0 |
| 3 | 1.359% / 7.700% | 1.476% / 8.500% | 0 | 0 | 0 |
| 总计 | 1.235% / 8.600% | 1.423% / 16.900% | — | — | — |

CSV 共 900 行，每轮 300 行，全部为 6 列且两进程线程数均为正。三轮前后状态均为 TUN `true/mixed`、tray title false、FlClash 窗口隐藏、controller false。A2 同样未复现高 CPU；其总均值还略高于不同时间窗口的 A3，因此当前数据不支持把 tray title 开启认定为历史高 CPU 的充分根因。

## macOS 高 CPU 新现场：仪表盘页面

2026-08-03 17:33 后用户报告 FlClash CPU 再次升高。首次读数 FlClash/Core 为 `31.4%/0.6%`。隐藏或关闭普通窗口都不能停止主进程 `4%–55%` 的周期性脉冲，Core 大部分时间低于 `1%`。

Xcode 16.4 Time Profiler 两轮 10 秒聚合均把主要 CPU 定位到 `io.flutter.raster`、Main Thread、Dart isolate 与 Metal/CA 提交；普通窗口不在屏幕上的一轮仍有 `4097` 个约 1 ms running samples，其中 raster `2141`、Main `1415`。该轮 `TrayManagerPlugin.setTitle` 和 `NSStatusItem`/replicant 热栈均为 0。

同实例、同网络状态只切页面的 20 秒对照：

| 页面 | FlClash mean / max | Core 行为 |
|---|---:|---|
| 工具 | `2.51% / 9.6%` | 未同步升高 |
| 仪表盘 | `34.24% / 55.1%` | 未同步升高 |

后续 60 秒脱敏捕获只有探针初始 NWPath 状态，没有后续 transition，7 个固定 IP 检测入口日志为 0；同期仪表盘 FlClash 仍平均 `20.06%`、最大 `45.50%`。更关键的是，AX 状态探针确认 network detection 与 intranet IP 都已有脱敏 IP 值时，仪表盘 20 秒仍为 `30.02%` mean / `51.50%` max，因此 loading spinner 假设已撤回。

v0.8.93 精确代码每秒调用 `updateTraffic()`；`TrafficUsage` 每次为 DonutChart 构造新 data list，DonutChart 用 identity 判断并无条件重启默认 300ms 动画。v0.8.93 隔离 worktree 的 widget 诊断证明：普通更新和等值新 list 都会保持约 300ms active ticker；LineChart 默认零时长。新增诊断又证明 DonutChart 显式 `Duration.zero` 后连续真实数值变化不保留 ticker。该 30% duty cycle 与 raster/Metal 现场吻合，是当前高置信直接执行链。首个 Phase 2 patch 只应在 `TrafficUsage` 局部传零时长，不修改一秒 timer、公共 DonutChart 或窗口/tray 生命周期。`_preHasVpn == hasVpn` 保留为独立逻辑候选。详见 `evidence/phase1/MACOS_HIGH_CPU_LIVE_REPRO.md`、`MACOS_CONNECTIVITY_NETWORK_DETECTION_TRACE.md` 与 `MACOS_CPU_MINIMAL_FIX_REVIEW.md`。

暂停前页面已留在低 CPU“工具”页，最后 App/Core 读数约 `1.0%/0.9%`。

## macOS Microsoft/TUN DIRECT

用户把规则修正为 `DOMAIN-SUFFIX,cloud.microsoft,微软服务` 后，raw/effective 都是 8055 条规则且顺序完全相同，live `/rules` 也证明 `m365.cloud.microsoft` 正确命中。导入没有丢失或重排规则。

用户要求普通“微软服务”DIRECT，只有“微软科学服务”代理。TUN 开时把微软服务临时改 DIRECT，Microsoft Account 0/3 正常完成，用户同时确认 `www.microsoft.com` 无法打开；恢复原代理选择后三个公开入口均 HTTP 200。用户随后确认 TUN 关闭后的 macOS 原生 DIRECT 可以成功。因此故障已经收敛到 TUN 内 DIRECT 路径，代理仅是可用性对照，不是最终修复。

TUN 恢复后 Core DIRECT URLTest 对 `www.microsoft.com`、`login.live.com`、`m365.cloud.microsoft` 全部 unavailable，而 matched 代理路径全部 success；Core A 查询三域各 3 次全部 timeout/refused。详见 `evidence/phase1/MACOS_MICROSOFT_FUNCTION_BASELINE.md`。

后续单变量已完成：effective YAML 中虽有 1 条 `tun.inet6-address`，但当前 Mihomo 在 `ipv6:false` 时将其清空，live `/configs` 不存在该字段；`system` 与 `gvisor` stack 均不恢复。正式 Core 日志证明主 DoH 已返回 IPv4，但 `fallback-filter` 启动 4 个 fallback 后没有可用结果，聚合 DNS timeout。删除 fallback 的内存隔离 variant 全部恢复；更小的 variant 保留 Fake-IP、4 个 fallback 和原 filter，仅为三个精确测试域名增加复用 main DNS 的 `nameserver-policy`，DNS、Core DIRECT URLTest 和 TUN 内真实 HTTP/1.1 均成功。所有 Selector、DNS 与 TUN 状态已恢复。

ownership review 已选择自包含方案：把普通/science Microsoft 域名整理为两个互斥的 inline classical provider，路由分别引用对应 provider，DNS policy 只引用 direct provider并复用已验证的 main resolver。现有 FlClash 在 `override_dns=false` 时会保留 raw policy；当前白名单快照正是 false。Microsoft 官方 endpoint service 仅作为候选更新源，不能自动覆盖 science/consumer 分类。详见 `evidence/phase1/MACOS_MICROSOFT_DNS_FALLBACK_AB.md` 与 `MACOS_MICROSOFT_DNS_POLICY_OWNERSHIP_REVIEW.md`。

## 偏好隔离与超时恢复边界

- `CFFIXED_USER_HOME` + 独立 `HOME` 能重定向 `NSHomeDirectory`、Application Support 和 Cache 搜索路径，但不能单独隔离 `UserDefaults`：测试标记仍经 `cfprefsd` 写到真实用户的 Preferences 域。
- 该测试只使用专用域 `com.openai.flclash.phase1.isolation.019fc553`，不含用户数据；标记和残留空 plist 均已精确删除。
- 仓库 Debug 配置使用 `com.follow.clash.debug`，Release/已安装版本使用 `com.follow.clash`。`shared_preferences_foundation` 使用 bundle ID 对应的 `UserDefaults` domain，`path_provider_foundation` 也在 Application Support 下附加 bundle ID，因此 Debug bundle 是可行的偏好与数据隔离边界。
- 只读白名单快照确认当前 Release 偏好 `autoRun=false`。源码显示重启时仅在 `autoRun=true` 时调用启动路径；所以现有 watchdog 的“杀掉测试进程并 reopen 正式 App”不能保证恢复到测试前的实际运行／代理状态。
- Mihomo `/configs` PATCH 已在本地 loopback controller 上完成同值和真实 off→on 验证。App 与 Core 的随机 Unix IPC 仍不复用；临时 controller 通过普通 Flutter 窗口开启，恢复后关闭。
- `launchd` worker 因 macOS TCC 明确没有 Accessibility 权限而被否决；需要短 timeout 保护时使用由 Codex/终端专用持久 PTY 托管的前台 worker。worker 存活期间禁止修改 watchdog/helper 文件。实际断连后不继续调试 watchdog，由用户手动恢复。

## 当前完成度与尚未完成

- A2/A3 已完成且当时未复现高 CPU。A4 随后严格执行 3×（120 秒预热 + 300 秒采样）：FlClash `34.270%` mean / `62.200%` max，Core `0.900%` mean / `8.300%` max，900 个样本字段与线程数完整，CSV SHA-256 为 `976b5da2ddc1243f294bb9d9e1d19f341c4705fca9088cbebc1f855195fb4148`；三轮旧 tray/dispatcher 符号均为 0。证据见 `evidence/phase1/macos-cpu/A4-20260803T140155Z.md` 与同名 CSV。
- A1 首次 watchdog-controlled TUN-off 门禁失败且已恢复；没有继续调试。用户随后手动关闭 TUN，Codex 重新确认 preference/live 均为 false 后完成标准三轮：900 个有效样本，FlClash `3.070%` mean / `48.500%` max，Core `0.339%` mean / `3.600%` max，三轮旧 tray/dispatcher 符号全为 0。CSV SHA-256 为 `42910673cfd568be66e79d76fd72034dccf9dab5969ac638713ea6bdc9aa7f02`。证据见 `evidence/phase1/macos-cpu/A1-20260803T151445Z.md` 与同名 CSV；旧失败记录保留在 `A1-20260803T142609Z-attempt.md`。
- A5 使用仅绑定 loopback 的本地字节流，curl 显式连接 FlClash mixed listener并限速 256 KiB/s；没有外网字节。三轮 900 个有效样本：FlClash `3.694%` mean / `44.100%` max，Core `1.167%` mean / `15.900%` max，三轮旧 tray/dispatcher 符号全为 0。CSV SHA-256 为 `bd8893ccb1d74c73d6645ced29daf527ab5bb928830222c2a293c2779a118a3b`。证据见 `evidence/phase1/macos-cpu/A5-20260803T143542Z.md` 与同名 CSV。
- A6 多显示器、A7 睡眠/唤醒与 Windows 实机矩阵均由用户明确延后：本次不执行、不视为通过，也不计入当前门禁。
- macOS Apple 公共入口已完成第一组单变量对照：失败在 live TUN 关闭、仅走 system proxy 时仍然存在。相关 Selector 当前都选择 DIRECT。正式 Core A 查询复现 App Store 3/3 成功、Apple Account 0/3、iCloud 1/3；失败域名触发 IP fallback filter 后 fallback 无可用回答。fresh v0.8.93 DNS-only Core 的 original/no-fallback 两个 variant 又都 3/3 成功，但回答指纹证明 Apple Account/iCloud 确实被 fallback 替换。
- 用户手动 restart 正式 Core 后，App 进程保持且 Core 进程更换，TUN/system proxy 自动恢复；App Store 在 system proxy/TUN 两条路径均 3/3 HTTP 200，Apple Account/iCloud 两条路径均 0/3 且未进入 TLS。restart 未修复这些公共入口，旧 Core 连接状态不是充分根因。早期 `lsof` 看不到 9090 就推断 controller listener 不存在已被撤回：当前 API/`nc` 可达时 `lsof` 仍无行，且重启前没有 config-aware 请求，不能判断动态更新是否已生效。详见 `evidence/phase1/MACOS_APPLE_FUNCTION_BASELINE.md`。
- 用户观察到“系统设置 → Apple Account”在 TUN 开时超过 10 秒持续转圈，手动关 TUN 后加载，再开 TUN 后仍能加载。由于 System Settings UI 与后台 daemon、缓存和既有连接不一一对应，该结果是 TUN-specific 线索，不是稳定因果复现；其余 Apple 原生服务仍待验证。
- 后台观测已捕获一个短时 Apple event burst：iCloud Contacts DIRECT connected，同时 Apple Push/Courier 出现 DNS 活动与 dial timeout；其前 15 秒、其后 10 秒静默窗口均为 0。用户后来说明错过了捕获提示窗口，因此永久记为无法归因的后台事件，不再追问回忆。
- macOS Microsoft Web 已完成 TUN 开/关、live inet6、stack、Fake-IP/DNS fallback 与保留 fallback 的精确 policy bypass。代表性三域根因已定位到正式 Core 的 fallback/filter 路径；普通/science Microsoft 互斥 inline provider ownership 已完成 review，尚待在独立配置副本中实施并验证更多入口。
- Windows Microsoft 服务矩阵尚未实机执行。
- Windows 只读脚本和空白矩阵已准备，见 `evidence/phase1/WINDOWS_MATRIX.md`；全部结果仍标记“未实机验证”。
- raw profile/effective config 白名单 diff 已生成。顶层 `ipv6: false` 与文件 effective `tun.inet6-address` 的矛盾存在，但 live parser 会清空该字段，已证明不是当前 Microsoft 三域故障变量；其他平台／IPv6 场景仍需分别验证。
- 未达到“每个问题至少一条稳定复现路径”的 Phase 1 验收条件，因此不得进入 Phase 2/3 产品代码修改。
