# macOS Apple 原生服务矩阵

状态：进行中。

最近更新：2026-08-04 00:29 CST。

## 本次范围

用户明确将本次剩余目标收窄为 **Apple 原生服务矩阵**。A6 多显示器、A7 睡眠/唤醒与 Windows 实机矩阵均延后：未验证、不视为通过，也不计入本次完成门禁。

本矩阵只验证当前 `/Applications/FlClash.app` v0.8.93、TUN 开启时的真实 macOS 功能。公共 curl 入口、Core DNS、URLTest 和日志不能代替原生功能结果；它们只作为同一明确操作窗口的脱敏旁证。

## 安全与判定规则

- 不修改 FlClash 业务代码、用户原始 YAML、Selector 或 DNS 配置。
- 不退出／重开 System Settings 充当后台冷启动，不清缓存，不重启 Core。
- 每项操作由用户在明确收到“现在开始”后手动执行；错过窗口的事件不补写关联。
- Core 原始日志只在内存解析；只保存 Apple 公共域名、事件类别、DIRECT/未解析分类与错误类别，不保存地址、节点、secret、账户、Cookie 或完整日志。
- `apsd` unified log 只保存分类计数、端口/地址族类别和脱敏模板指纹，不保存账户、设备标识、IP 或完整消息。
- 功能成功必须由对应产品动作证明；“有日志”“HTTP 200”“DNS 有回答”都不是功能成功。
- Private Relay 只记录用户当前状态，不切换开关。

## 当前运行前提

- App/Core 各 1 个进程；每轮必须重新识别，不复用本文 PID。
- TUN preference/live 均为 `true/mixed`，live `tun.inet6-address` 不存在。
- system proxy 偏好与 HTTP/HTTPS/SOCKS enable 均开启且只指向 loopback；PAC 关闭。
- loopback controller 可达；tray title 关闭；`override_dns=false`；普通窗口可见；`AXEnhancedUserInterface=false`。
- 原始 YAML SHA-256 为 `fbe200b1e0206aedb4dd28f2eb4bfc491bfc6ebb613e74fc74ac685916f0f17a`。

## 功能矩阵

| 服务 | 用户实际动作 | 成功标准 | 当前结果 | 旁证状态 |
|---|---|---|---|---|
| Apple Account | 已打开 Apple Account 时进入“iCloud”子页并返回，不退出 System Settings | 每个页面 10 秒内完成加载，无持续 spinner | **失败**：iCloud 子页 10 秒后仍转圈；返回主页面 10 秒后仍转圈 | 已完成有效捕获 |
| Mac App Store | 搜索一个公开免费 App、打开详情；再由用户选择一个免费下载或现有更新 | 搜索/详情完整；下载或更新实际开始 | 待执行 | 待捕获 |
| iCloud Drive | 用户在 iCloud Drive 创建一个无敏感内容的小测试文件 | 另一设备或明确 iCloud 同步状态确认到达 | 待执行 | 待捕获 |
| iMessage 发送 | 用户向自行选择的联系人/自己的其他设备发送文本和一个小附件 | 两项均显示发送完成 | 待执行 | 待捕获 |
| APNs / iMessage 接收 | 捕获窗口内由另一设备向本机发送一条新消息或触发一条已知通知 | 本机及时收到；无持续重试迹象 | 待执行 | 待捕获 |
| Private Relay | 用户只报告当前为开启、关闭或未配置 | 状态被单独记录，不与普通 iCloud 混合 | 待用户报告 | 不切换 |

## 每项捕获结构

1. 用户先把对应 App/页面准备好，但不执行目标动作，并回复“`<服务> 已就绪`”。
2. Codex 重新核对 App/Core、TUN、代理、controller 与 AX 白名单。
3. 15 秒操作前静默窗口。
4. Codex 明确发送“现在开始”，随后开启最长 60 秒的 `logs-apple` 捕获；用户立即执行目标动作并在本地观察功能结果。
5. 捕获结束后，用户只报告预定义的功能结果与大致耗时；不提供账户、联系人、文件名或通知内容。
6. 再记录 15 秒操作后静默窗口及同窗口 `apsd` 脱敏分类。
7. 只有本轮明确开始后的新事件才与该动作关联；没有事件时记录为“功能结果存在，但旁证未命中”，而不是伪造因果。

## 已有证据边界

- `MACOS_APPLE_FUNCTION_BASELINE.md` 已证明固定 `account.apple.com` / `www.icloud.com` 通过当前 Core DIRECT 路径失败，而 App Store 公共入口成功；它不能代替本矩阵。
- 既有 Apple Account “TUN 关后加载、再开后仍加载”只是 TUN-specific 线索，不是受控 A→B→A。
- 既有 iCloud Contacts/Push burst 因用户错过操作提示，永久记为无法归因，不计入本矩阵。

## Apple Account：有效功能轮次

执行时间：2026-08-04 00:25–00:29 CST。

### 功能结果

- 开始前用户已停在 Apple Account 主页面；未退出或重开 System Settings。
- 收到明确“现在开始”后，用户进入 iCloud 子页：**10 秒后仍持续转圈**。
- 用户随后返回 Apple Account 主页面：**10 秒后仍持续转圈**。
- 该轮未切换 TUN、代理、Selector、DNS 或 Core；结束后 preference/live TUN 仍为 `true/mixed`，system proxy/controller/窗口/AX 白名单状态未漂移。
- 因两个实际页面均未在 10 秒内加载，本轮 Apple Account 功能项明确判定为失败；任何日志中的单条成功连接都不能覆盖此功能结论。

### 操作前静止页面基线

- 15 秒 Core 捕获：53 个匹配、6 个 Apple 公共域名、28 类脱敏事件。
- 静止页面本身已出现 Apple Account / iCloud 后台活动：Apple Account 相关 DNS 有主 DoH IPv4 回答，但随后出现 fallback query timeout/refused 与 Core dial timeout；`setup.icloud.com` 同样出现主回答后 dial timeout。
- 同窗口也有中国区 iCloud Contacts 的 DIRECT connected，因此“部分 iCloud 连接成功”和“页面持续转圈”可以同时成立。
- `apsd` 20 秒窗口为 0 个事件；不能从该基线判断 APNs 状态。

### 明确操作窗口

- 60 秒 Core 捕获：283 个匹配、8 个 Apple 公共域名、66 类脱敏事件。
- 与静止页面相比，窗口内新增 `mask-h2.icloud.com`、`mask.icloud.com`、`quota.icloud.com` 等 iCloud 功能域名活动；主 DoH 可返回 IPv4，但仍出现 TCP/UDP timeout/refused 与 unresolved dial target。
- Apple Account 相关域名继续出现主回答后 fallback/dial timeout；与此同时，另一些 Apple 公共服务出现 DIRECT connected。该混合结果与用户看到的持续 spinner 一致，但不证明每个日志事件都由一次点击触发。

### 操作后窗口与 apsd 旁证

- 15 秒 Core 捕获：104 个匹配、10 个 Apple 公共域名、63 类脱敏事件。
- 中国区 iCloud availability/access/quota 域名出现 DIRECT connected；Apple Account / `setup.icloud.com` 仍同时出现 timeout/refused。
- 90 秒 `apsd` 查询有 1,023 条系统事件、40 类脱敏摘要，包含 courier/connect 尝试、少量 timeout 分类与错误级消息；低层 timeline 过滤器没有命中可判定的连接状态转换。因此该旁证不能单独判定 APNs 成败，也不替代 Apple Account 页面失败。

### 本轮结论边界

1. 这是第一次在用户明确收到开始提示后完成的 Apple Account/iCloud 页面功能轮次，能够作为原生服务矩阵的有效失败证据。
2. 失败不是“完全无 Apple 流量”：操作前、操作中和操作后均存在部分 DIRECT connected；真正可疑的是同一功能链内持续存在的 DNS fallback 与 dial timeout/refused。
3. 本轮只证明当前原配置、TUN 开启时 Apple Account/iCloud 设置页失败；尚未进行本矩阵中的 App Store、iCloud Drive 文件同步、iMessage/APNs 功能动作。

## 采集工具门禁

- `macos_core_control.rb self-test-apple-filter`：7 个域名过滤用例与 1 个事件脱敏检查通过。
- `macos_apsd_log_capture.rb self-test`：5 个脱敏/分类用例通过。
- 两脚本已去除 Ruby 2.7+ `filter_map` 依赖，使用 `/usr/bin/ruby 2.6.10` 完成语法、自测与 1 秒空窗口验证。
