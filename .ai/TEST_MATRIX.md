# 验证与复现矩阵

## 通用要求

当前范围覆盖（2026-08-03）：用户明确要求本次只处理 **B. macOS Apple 服务**。A6/A7 与 C. Windows Microsoft 服务保留为未来矩阵定义，但本次不执行、不视为通过，也不计入完成门禁。

- raw profile 和 effective config 分开保存、分开脱敏。
- 所有对比只改变一个变量。
- 固定网络、节点、策略组选择和测试时间窗口。
- 日志不得含节点地址、UUID、密码、订阅 URL、secret、Cookie 或 Apple/Microsoft 账号。
- 每次记录：FlClash commit、tray_manager commit、Mihomo commit/version、OS build、CPU 架构、网络类型。

## A. macOS CPU / 能耗

### 场景矩阵

| 场景 | TUN | 窗口 | tray title | 业务流量 | 目的 |
|---|---|---|---|---|---|
| A1 | 关 | 隐藏 | 关 | 空闲 | UI/tray 最小基线 |
| A2 | 开 | 隐藏 | 关 | 空闲 | 当前主要故障场景 |
| A3 | 开 | 隐藏 | 开 | 空闲 | 验证真实标题更新成本 |
| A4 | 开 | 显示 | 关 | 空闲 | Flutter UI 与 tray 分离 |
| A5 | 开 | 隐藏 | 关 | 持续下载 | 验证高流量下 IPC/状态传播 |
| A6 | 开 | 隐藏 | 关 | 空闲 | 多显示器 + separate Spaces |
| A7 | 开 | 隐藏 | 关 | 空闲 | 睡眠/唤醒后 |

每个场景预热 2 分钟，采样 5 分钟，至少重复 3 次。记录 FlClash 与 FlClashCore 分开 CPU。

范围调整（2026-08-03）：用户明确本次目标不测试睡眠/唤醒能力。A7 保留为未来矩阵定义，但本次不执行、不视为通过，也不计入当前 Phase 1/2 门禁。

2026-08-03 触发链补充：仪表盘 60 秒高 CPU 窗口内，脱敏 NWPath 探针只收到初始 Wi-Fi 状态、无后续 transition，7 个固定 IP 检测入口日志为 0。随后 AX 白名单状态探针确认 network detection 与 intranet IP 都已有脱敏 IP 值时，仪表盘仍 `30.02%` mean / `51.50%` max，故 spinner 假设撤回。当前高置信链为每秒 `updateTraffic()` → `totalTrafficProvider` → `TrafficUsage` 新 data list → DonutChart 300ms `CustomPaint` 动画；v0.8.93 widget 诊断证明等值新 list 也会重启 ticker。最小修复 review 已选择只给该处 DonutChart 传 `Duration.zero`，连续真实数值变化诊断测试通过；详见 `evidence/phase1/MACOS_CPU_MINIMAL_FIX_REVIEW.md`。

标准矩阵进度：A1–A5 已完成。A1 在用户手动关闭 TUN、live/persistent 均确认 false 后完成三轮：FlClash `3.070%` mean / `48.500%` max，Core `0.339%` mean / `3.600%` max。A4 三轮共 900 个样本，FlClash `34.270%` mean / `62.200%` max，Core `0.900%` mean；A5 使用无外网字节的 loopback-through-Core 256 KiB/s 流量，FlClash `3.694%` mean、Core `1.167%` mean。A1/A4/A5 三轮旧 tray/dispatcher 符号全为 0。A6 当前无多显示器；A7 已从本次目标排除。

### 建议采样

```bash
pgrep -x FlClash
pgrep -x FlClashCore
top -l 10 -pid <FlClash_PID> -stats pid,command,cpu,time,threads
sample <FlClash_PID> 10 -file /tmp/flclash-main.sample.txt
```

采样文件仅本地分析；提交 issue 前先检查并脱敏路径、用户名和网络数据。

### 自动化断言

- 相同 title 连续更新只产生一次平台 `setTitle` 调用。
- `setTitle` 失败时不缓存失败值，下一次允许重试。
- `destroy()` 清空 title cache。
- tray title 关闭时 provider 不订阅每秒 traffic。
- 窗口恢复后 runtime/traffic 在一个周期内刷新。
- tray title 开启时，隐藏窗口仍保留标题所需流量更新。

## B. macOS Apple 服务

### 服务冒烟测试

| 服务 | 验证动作 | 成功标准 |
|---|---|---|
| Apple Account | 系统设置中刷新账户页，不重新登录 | 10 秒内完成加载，无反复 spinner |
| Mac App Store | 搜索、打开详情、下载一个免费小应用/更新 | 页面与下载均开始 |
| iCloud Drive | 创建小测试文件并等待同步 | 另一设备或 iCloud 状态可确认同步 |
| iMessage | 发送文本和小附件 | 发送状态及时完成 |
| APNs | 保持系统通知与 iMessage 接收 | TCP 5223/443 连接无持续重试 |
| Private Relay（若启用） | 单独记录开关状态 | 不与普通 iCloud 混为一个结论 |

本次逐项执行协议与权威功能结果记录在 `evidence/phase1/MACOS_APPLE_NATIVE_SERVICE_MATRIX.md`。公共 curl、DNS、URLTest 和日志仅作旁证，不能替代上表的实际动作。

### 单变量矩阵

1. TUN 关 / 系统代理开。
2. TUN 开 + 原 effective config。
3. `stack`: mixed → system → gVisor。
4. 顶层 IPv6 false，并确认 `tun.inet6-address` 空；再测试 IPv6 true 的完整双栈。
5. Fake-IP → redir-host，仅用于诊断。
6. Apple/iCloud 组固定 DIRECT；再固定同一个可用代理节点。
7. UDP 443/QUIC 允许与强制 TCP 回退对比。
8. MTU 默认 → 1500 → 1400，仅在 TLS/大响应卡住时测试。

必须查看 rule trace，确认测试连接实际命中预期组。Apple 官方域名和端口会更新，不以静态手写列表作为唯一判据。

## C. Windows Microsoft 服务

> 2026-08-03 更新：Microsoft Web 故障已在 macOS 复现，不能再只按 Windows 问题处理。macOS 已完成关键 control 与优先单变量：TUN 开 + “微软服务”DIRECT 失败，TUN 关原生 DIRECT 成功；live inet6 为空、system/gVisor 仍失败；最终定位到主 DoH 回答触发 `fallback-filter` 后 fallback 无可用结果。保留 Fake-IP 和全部 fallback、仅以精确 DNS policy 绕过该路径时，三域真实 HTTPS 均成功。ownership review 已选择互斥 inline provider：路由和 DNS 共用 direct provider，science provider 继续代理。详情见 `evidence/phase1/MACOS_MICROSOFT_FUNCTION_BASELINE.md`、`MACOS_MICROSOFT_DNS_FALLBACK_AB.md` 与 `MACOS_MICROSOFT_DNS_POLICY_OWNERSHIP_REVIEW.md`。

### 服务冒烟测试

| 服务 | 验证动作 | 成功标准 |
|---|---|---|
| Bing | 首页、搜索结果、图片/CDN | 页面资源完整 |
| Microsoft Account | 登录页加载到交互状态 | 无无限重定向/超时 |
| Microsoft 365 | Office/Outlook Web 基础页 | HTML、JS、登录域均可达 |
| Azure CDN | 由上述页面触发静态资源 | 无 `azureedge.net` 类超时 |
| Microsoft Store | 下载小应用 | 保持现有正常状态 |

### 单变量矩阵

1. TUN 关 / 系统代理开。
2. TUN 开 + 原 effective config。
3. 清空 `tun.inet6-address`，保持其他字段不变。
4. `stack`: mixed → system → gVisor。
5. `strict-route`: false/true；同步记录 Windows 多宿主 DNS 行为。
6. Fake-IP / redir-host。
7. `微软服务` 与 `微软科学服务` 分别验证 ownership。用户确认的目标语义是普通“微软服务”DIRECT、只有“微软科学服务”代理；可临时固定到代理做 control，但不能把微软全量代理当最终修复。
8. 暂时禁用浏览器 QUIC或用可控方式强制 TCP，判断 UDP 黑洞。
9. MTU 默认 → 1500 → 1400。

### macOS 已完成结果

- 第 3 项：文件 effective YAML 有 1 条 inet6 地址，但 live parsed TUN 在 `ipv6:false` 下 key 不存在；三域仍失败，已排除。
- 第 4 项：`system`、`gvisor` 均失败，恢复 `mixed`。
- 第 6 项：无需切换到 redir-host；保持 Fake-IP，仅绕过错误 fallback 即恢复三域 DNS、DIRECT URLTest 和真实 HTTPS。
- DNS 最小机制：保留原 4 个 fallback/filter，只为 3 个精确测试域名复用 main DNS 的 `nameserver-policy`，结果全部成功；这只证明机制，不是最终域名覆盖方案。
- 第 7 项的最终语义不变：普通“微软服务”DIRECT、只有“微软科学服务”代理。
- ownership 静态门禁：direct/science provider 的 exact duplicate 与 suffix containment overlap 均为 0；DNS policy 只引用 direct provider；raw/effective payload SHA 相同；当前“覆写 DNS”必须为 false。

### 建议只读诊断

```powershell
Get-NetAdapter
Get-NetIPConfiguration
Get-NetRoute -AddressFamily IPv4
Get-NetRoute -AddressFamily IPv6
Resolve-DnsName login.live.com
Resolve-DnsName www.bing.com
curl.exe -I --http1.1 https://www.bing.com/
```

不要自动写注册表、关闭防火墙或修改系统 DNS。涉及这些变更时必须单独说明风险并由用户确认。

## D. 配置回归

### 静态检查

- YAML 可解析。
- 当前 Mihomo `-t`/等价配置检查通过。
- target、group member、provider 引用完整。
- `MATCH` 唯一且最后。
- 同条件不同 target 为 0。

### 行为检查

- 为 14 个冲突条件构造 rule trace 断言。
- Apple、Microsoft、OpenAI、直连、广告拦截各选代表域名。
- 对 `PROCESS-NAME`、IP CIDR 和 Fake-IP 分别验证，不能只测浏览器域名。
- 对配置解析时间、启动耗时和常驻内存做清理前后对比。
