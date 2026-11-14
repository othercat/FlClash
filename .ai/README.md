# FlClash 定制版规划索引

状态：Phase 0 已完成，Phase 1 进行中；已用 Xcode 16.4 完成上游 v0.8.93 隔离构建，macOS CPU A1–A5 已完成标准采样，Microsoft 代表域名的 TUN/DNS 根因已定位。本次剩余范围仅为 Apple 原生服务矩阵；A6 多显示器、A7 睡眠/唤醒和 Windows 实机矩阵均延后，未执行也不视为通过。尚未修改任何业务代码或用户原始 YAML。

本目录于 2026-08-03 预先建立在目标仓库路径下：

`/Users/lirichard/AI/CLASH/FlClash/othercat/FlClash/.ai`

当前 fork 为 `othercat/FlClash`，上游为 `chen08209/FlClash`。后续保留本目录，并按照文档分阶段执行。

## 文档

- [GOALS.md](GOALS.md)：目标、边界、根因判定门槛与验收标准。
- [RESEARCH.md](RESEARCH.md)：上游、`whusnoopy` fork、相关 issue/PR 和现有实现的证据。
- [CONFIG_AUDIT.md](CONFIG_AUDIT.md)：对 `20260712.yaml` 的脱敏静态审查。
- [TEST_MATRIX.md](TEST_MATRIX.md)：macOS CPU、Apple 服务、Windows Microsoft 服务测试矩阵。
- [TODO.md](TODO.md)：可直接交给 AI Agent 执行的阶段任务清单。
- [PROMPTS.md](PROMPTS.md)：review 后可复制使用的总提示词与分阶段提示词。
- [PHASE1_BASELINE.md](PHASE1_BASELINE.md)：精确 SHA、Xcode 16.4 构建证据、安全事故记录和采集工具。
- [RESUME_PHASE1.md](RESUME_PHASE1.md)：当前暂停点、运行状态、安全门进度和可复制恢复提示词。

## 安全约束

- YAML 含非空 `secret`、节点服务器、UUID/密码等敏感信息；任何日志、文档、issue、PR 和提示词都不得包含这些值。
- 只允许输出配置结构、统计、公开域名规则和已脱敏日志。
- 不直接修改 iCloud Drive 中的原始配置。配置整理阶段必须先生成独立副本并保留 SHA-256。
- 未经明确要求，不创建 GitHub fork、commit、push 或 PR。
