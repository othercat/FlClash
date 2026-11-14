# 可复制提示词

当前范围覆盖（2026-08-03）：用户明确要求本次剩余工作只处理 Apple 原生服务矩阵。A6 多显示器、A7 睡眠/唤醒和 Windows 实机矩阵延后；不得执行、不得写成通过，也不计入本次完成门禁。原提示词保留为未来完整项目模板。

## 总提示词（fork/clone 完成后使用）

```text
你现在位于我的 FlClash fork 根目录。请默认用中文工作。

目标：在保持上游架构和可持续同步能力的前提下，分阶段解决 macOS 高 CPU、macOS TUN 下 Apple 服务异常、Windows TUN 下 Microsoft 网站异常，并整理我的 ClashX Pro 迁移配置。

开始前必须：
1. 读取根目录 AGENTS.md 及其要求的 .agents 文件和 core-platform skill。
2. 完整读取 .ai/README.md、GOALS.md、RESEARCH.md、CONFIG_AUDIT.md、TEST_MATRIX.md、TODO.md。
3. 检查 git status、当前 commit、origin/upstream，不覆盖用户已有改动。
4. 不读取或输出节点服务器、UUID、密码、订阅 URL、secret、Cookie、证书等敏感信息；配置和日志一律脱敏。
5. 不 commit、push、开 PR，除非我另行明确要求。

执行方式：严格按 .ai/TODO.md 的 Phase 顺序，小步推进。先建立可重复基线与 effective config，再写代码。一次只处理一个根因，不把 CPU、TUN 和用户配置清理混在同一 patch。每个阶段先给简短计划，再执行测试并更新 .ai 中的证据和状态。

当前只执行尚未完成的最早 Phase。完成后汇报：改了哪些文件、证据、测试结果、仍不确定的点和下一阶段建议，然后停下等待 review。
```

## Prompt A：只建立仓库与基线，不改代码

```text
读取并遵守仓库 AGENTS.md 与 .ai 全部文档。现在只执行 .ai/TODO.md 的 Phase 0 和 Phase 1：确认 remotes/SHA、依赖版本、构建环境，构建未修改的上游基线，并按 TEST_MATRIX 采集 macOS CPU 与 TUN effective config 证据。

不要修改业务代码，不要修改我的原始 YAML，不要 commit/push。所有输出必须脱敏。若 Windows 环境当前不可用，先把 Windows 可复制测试脚本和采集表准备好，并明确标记“未实机验证”，不要伪造结论。
```

## Prompt B：只修 macOS CPU

```text
读取仓库 AGENTS.md、core-platform skill 和 .ai 文档。只执行 Phase 2，不处理 TUN 或配置清理。

先用基线数据确认 FlClash 主进程的 NSStatusItem/tray title 热路径。对照 whusnoopy 的 ca201c0、最新 tray_manager da2d83d、FlClash PR #2201/#2202，但不要直接照搬旧分叉。优先实现：Dart title 去重、关闭 title 时取消流量依赖、原生层幂等保护、对应测试。隐藏窗口轮询优化作为独立可审查 patch。

修改后运行仓库要求的 analyze/test 和本次范围内的 TEST_MATRIX A1-A6。用户已明确将 A7 睡眠/唤醒排除在本次目标外：不得执行，也不得写成通过。不要提交 git commit。汇报 CPU 前后数据、采样热栈是否消失、功能回归和文件列表。
```

## Prompt C：只诊断 TUN，不写修复

```text
读取仓库 AGENTS.md、core-platform skill 和 .ai 文档。现在只做 TUN 根因诊断，不写产品代码。

先采集 raw profile 与 FlClash effective config 的脱敏 diff，重点检查 ipv6=false 与 tun.inet6-address/IPv6 route 是否矛盾，并复测 FlClash issue #1993 的单变量。随后按 TEST_MATRIX 分别验证 macOS Apple 服务和 Windows Microsoft 网站的 stack、Fake-IP、策略组命中、QUIC/UDP、MTU、strict-route。

不要通过关闭防火墙、写注册表、全量绕过 TUN 或修改生产配置来“试修”。每次只改变一个变量。最后给出证据表，将结论分类为 FlClash 配置合成、Mihomo、用户规则/DNS、节点/网络或未确定，然后停下等待 review。
```

## Prompt D：实现已经证明的 TUN 修复

```text
读取仓库 AGENTS.md、core-platform skill、.ai 文档以及上一阶段的 TUN 诊断报告。只有上一阶段已经用最小配置证明根因时才开始代码修改；否则停止并指出缺失证据。

在正确边界做最小修复：Tun model / 配置合成 / 平台 manager / Mihomo submodule 只能选择已被证据指向的部分。macOS 与 Windows 分开测试；如果新增 model/provider 字段，运行 build_runner，禁止手改 generated 文件。补充单元测试、配置 round-trip 测试和两平台冒烟清单。不要夹带 CPU 或用户 YAML 清理，不要 commit/push。
```

## Prompt E：只整理配置副本

```text
读取 .ai/CONFIG_AUDIT.md 和 TEST_MATRIX.md。对我的 20260712.yaml 只做脱敏、只读分析；先验证 SHA-256，绝不覆盖原文件。创建独立 cleaned 副本和一份 Markdown 变更报告。

逐项解决 14 个同条件不同策略冲突，删除同策略精确重复，人工复核遮蔽候选。Apple/iCloud 和 Microsoft 两组必须明确唯一 ownership 和规则先后顺序；不能根据猜测改变我的节点选择。评估广告域名是否迁移到固定版本 rule-provider，但不要引入会破坏离线启动的依赖。

最后用当前 FlClash 内置 Mihomo 检查 cleaned 配置，并给出代表性 rule trace。输出中禁止出现节点地址、UUID、密码、provider URL、secret 或私有 hosts。不要替换生产配置，不要 commit。
```
