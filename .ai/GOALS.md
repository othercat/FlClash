# 项目目标与边界

## 项目基线

- 目标上游：`chen08209/FlClash`。
- 目标仓库：`othercat/FlClash`，跟踪上游 `chen08209/FlClash`。
- 当前参考 fork：`whusnoopy/FlClash`。
- 现用配置：`/Users/lirichard/Library/Mobile Documents/com~apple~CloudDocs/FIClash/20260712.yaml`。
- Phase 0 只完成 fork / clone / remote 与工作树基线确认；未开发业务代码。

## 总目标

建立一个可长期跟随上游、可在 macOS 和 Windows 上复现验证的 FlClash fork，解决或明确归因以下问题：

1. macOS 后台高 CPU / 高能耗，尤其是菜单栏 `NSStatusItem` 重绘和隐藏窗口后的无效轮询。
2. macOS 开启 TUN 后，Mac App Store、iMessage、iCloud 同步等 Apple 服务阻塞或延迟。
3. 开启 TUN 后 Microsoft 相关网站阻塞：已在 macOS 复现；Windows 平台特有行为仍待实机。Microsoft Store UWP 下载正常是既有 Windows 观察，不代表 Web 故障仅限 Windows。
4. 从 ClashX Pro 迁移来的大型配置存在重复、遮蔽、策略冲突和旧字段兼容风险。

## 关键原则

### 先归因，后修复

TUN 问题在证据不足时不能直接定义为 FlClash bug。必须依次区分：

1. FlClash UI/配置合成问题。
2. FlClash 内置 Mihomo 版本或 TUN 参数问题。
3. Mihomo 上游问题。
4. 当前 YAML 的规则顺序、DNS、Fake-IP、IPv6 或组选择问题。
5. 节点 UDP、QUIC、MTU、TLS/SNI 或运营商网络问题。

只有使用最小配置仍能复现，且切换单一变量能稳定改变结果时，才进入代码修复。

### CPU 修复采用分层策略

1. Dart 层：相同 tray title 不重复调用平台通道；关闭标题时不订阅每秒流量。
2. 生命周期层：窗口隐藏且标题关闭时，停止无人消费的 runtime/traffic IPC 与重解析。
3. 原生层：macOS `setTitle`、`setIcon`、`setToolTip`、菜单更新必须幂等，避免 `NSStatusItem` 重绘风暴。
4. 不直接把旧 `tray_manager` commit 覆盖到最新依赖；两条历史已经分叉，需按当前代码重新实现并测试。

### 配置与产品代码分离

- 通用 TUN 缺陷在产品代码中修。
- 当前用户专属域名/策略只在配置副本中修。
- 不把 Apple/Microsoft 全量绕过 TUN 当作默认产品修复。
- 不把动态云服务域名长期硬编码进 App；优先规则集或可维护的数据源。

## 非目标

- 本阶段不改变 UI 设计或整体架构。
- 不更换 Mihomo 内核，除非最小复现明确指向已在上游修复的内核缺陷。
- 不在首个 patch 中同时混入 CPU、TUN、规则清理三类变更。
- 不自动修改、上传或提交用户的代理节点信息。

## 完成标准

### 本次范围覆盖

- 用户于 2026-08-03 明确要求：本次剩余工作只处理 Apple 原生服务矩阵。
- A6 多显示器、A7 睡眠/唤醒与 Windows 实机矩阵延后；未验证、不视为通过，也不计入本次完成门禁。
- 本次完成声明只覆盖下方 macOS Apple 原生服务功能项，不扩大为完整项目或跨平台完成。

### macOS CPU

- 同一环境、同一配置下，隐藏窗口且 tray title 关闭后的 5 分钟平均 CPU 相比上游基线下降至少 80%。
- 目标机上 FlClash 主进程空闲平均 CPU 不高于 5%，并且采样中不再持续出现 `NSStatusItem _updateReplicants` / `_redrawReplicantSnapshot` 热路径。
- tray title 开关、窗口重新显示、多显示器和菜单操作均无回归。
- 本次目标不测试睡眠/唤醒能力：A7 延后，未执行且不视为通过，也不再作为本次 Phase 1/2 门禁。

### TUN

- macOS：App Store 浏览/下载、Apple Account、iCloud 同步、iMessage/APNs 均通过定义好的冒烟测试。
- Windows：Microsoft 登录、Bing、Microsoft 365/Office 网页、Azure CDN 类资源通过；Microsoft Store 下载保持正常。
- 能用最小配置证明修复来自哪一个变量，并保留 raw profile 与 effective config 的脱敏 diff。

### 配置

- 零未知策略目标、零重复节点/组名称，`MATCH` 保持最后。
- 14 个同条件不同策略冲突全部做出明确决策。
- 同目标精确重复和明显遮蔽规则被清理或记录保留原因。
- 原配置不被覆盖，清理后的副本通过当前内置 Mihomo 配置检查与实际流量验证。
