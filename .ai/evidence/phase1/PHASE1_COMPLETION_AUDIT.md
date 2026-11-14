# Phase 1 完成度审计

最近更新：2026-08-03 23:55 CST。

本审计以当前工作树、`PROMPTS.md`、`TODO.md`、`TEST_MATRIX.md`、`GOALS.md` 与现有证据文件为准。它只判断 Phase 1 是否达到原始验收边界，不把已完成的局部根因定位扩大成整阶段完成。

## 当前安全快照

- 当前仓库 HEAD 为 `7c831855efedceb1a72bd0b4c18da026593d0853`；工作树除未跟踪 `.ai/` 外没有业务代码改动。
- 当前 `/Applications/FlClash.app` 版本为 `0.8.93`；本轮重新识别 App/Core，各 1 个进程，未复用旧 PID。
- Xcode 固定为 16.4（16F6），macOS SDK 为 15.5。
- A1 完成后用户已手动恢复 TUN；preference 与 live 均为 `true/mixed`，`tun.inet6-address` 不存在。system proxy 偏好开启，HTTP/HTTPS/SOCKS enable 均开启且只指向 loopback，PAC 关闭。
- loopback 9090 controller 可达；tray title 关闭，`override_dns=false`，普通窗口可见，`AXEnhancedUserInterface=false`。
- 原始 `20260712.yaml` SHA-256 仍为 `fbe200b1e0206aedb4dd28f2eb4bfc491bfc6ebb613e74fc74ac685916f0f17a`。

上述运行态只是本轮快照；后续恢复必须重新识别 App/Core 与 live 状态。

## 逐项判定

| Phase 1 要求 | 判定 | 权威证据 / 缺口 |
|---|---|---|
| 精确锁定 FlClash、tray_manager、Mihomo SHA | 已证明 | `PHASE1_BASELINE.md` |
| 用上游未修改版本建立 macOS arm64 基线 | 已证明 | v0.8.93、Xcode 16.4、SDK 15.5 构建记录见 `PHASE1_BASELINE.md` |
| raw profile / effective config 白名单 diff | 已证明 | `EFFECTIVE_CONFIG_DIFF.md` 与 Microsoft function baseline；当前 raw/effective 规则 8055/8055 且顺序一致 |
| 本次 CPU 范围 | 已证明 | A1–A5 有标准证据；A6/A7 由用户延后，未验证且不计入本次门禁 |
| macOS 高 CPU 至少一条稳定复现路径 | 已证明 | A4 三轮 900 样本，App mean `34.270%`；页面 A→B→A 与 widget 诊断收敛到 TrafficUsage/DonutChart 动画 |
| macOS Apple TUN 原始服务矩阵 | **本次唯一未完成门禁** | 固定公共入口和 DNS/fallback 证据存在，但不能代替 Apple Account、App Store 下载、iCloud 同步、iMessage/APNs 的原生冒烟矩阵；见 `MACOS_APPLE_NATIVE_SERVICE_MATRIX.md` |
| Microsoft Web 至少一条稳定复现与单变量机制 | 已证明（macOS 代表域名） | TUN 内 DIRECT 失败、原生 DIRECT 成功；inet6/stack 排除，精确 DNS policy 恢复，见 Microsoft 两份 A/B/review 证据 |
| Windows Microsoft 实机矩阵 | 延后 / 未验证 | 用户明确排除在本次范围外；不视为通过，也不计入本次门禁 |
| Phase 1 期间不改业务代码 / 原始 YAML | 已证明 | `git status --short` 仅 `?? .ai/`；原始 YAML SHA 与记录一致 |

## 剩余执行顺序

1. **Apple 原生服务**：按 `MACOS_APPLE_NATIVE_SERVICE_MATRIX.md` 的明确开始/结束窗口测试 Apple Account、App Store 下载、iCloud 小文件同步、iMessage/APNs，并记录 Private Relay 当前状态。

## 阶段结论

本次范围仍为 **进行中**。CPU、Microsoft 与配置相关既有证据均保留，但不再扩展；A6/A7 与 Windows 实机矩阵已延后。本次只有 Apple 原生服务矩阵完成后才能宣告完成，且本次不进入产品代码修改。
