# macOS Apple 公共入口与原生功能基线

验证日期：2026-08-03（Asia/Shanghai）

## 范围与安全边界

- 运行对象为当前 `/Applications/FlClash.app` v0.8.93；每轮重新识别当前 App/Core，不复用历史 PID。
- 未修改业务代码、用户原始 YAML、节点选择或持久化策略组。
- 请求只访问 Apple 公共 HTTPS 入口，不携带登录 Cookie、账户信息或用户文件。
- 证据只保存 HTTP 状态、curl 阶段耗时、Core rule 类型、DIRECT/PROXY 分类和不含原文的 SHA-256 截断指纹；不保存解析地址、节点名、节点地址、规则 payload、controller secret 或完整日志。
- `macos_core_control.rb logs-domain` 在内存中解析 controller 日志，仅输出上述白名单字段。新增的 `logs-apple` 只接受固定 Apple 公共域名后缀并输出相同的脱敏分类字段；内置自测会拒绝 lookalike 域名和 IP。`/connections` 对尚未建立的 outbound 没有可用记录，因此最终以 `/logs` 的 dial 结果为准。

## 当前原配置基线：live TUN 开、system proxy 开

四个公共入口的首轮 IPv4/IPv6/默认路径结果：

| 入口 | 默认 TUN | 强制 IPv4 | 强制 IPv6 | 显式 system proxy |
|---|---|---|---|---|
| `www.apple.com/library/test/success.html` | HTTP 200 | HTTP 200 | HTTP 200 | HTTP 200 |
| `apps.apple.com` | HTTP 200 | HTTP 200 | HTTP 200 | HTTP 200 |
| `account.apple.com` | TLS timeout/error | TLS timeout/error | timeout | timeout |
| `www.icloud.com` | TLS timeout/error | timeout | timeout | TLS timeout/error |

随后对 `apps.apple.com`、`account.apple.com`、`www.icloud.com` 的默认 TUN 与显式 system proxy 路径各重复 3 次：

| 入口 | 默认 TUN | system proxy | 结论 |
|---|---:|---:|---|
| `apps.apple.com` | 2/3 完整成功；1/3 已收到 HTTP 200 后在完整传输前达到 12 秒上限 | 3/3 成功 | control 基本可达 |
| `account.apple.com` | 0/3 | 0/3 | 稳定停在 TLS/上游建连阶段 |
| `www.icloud.com` | 0/3 | 0/3 | 稳定停在 TLS/上游建连阶段 |

### 脱敏 Core route trace

| 入口 | rule 类型 | route | fingerprint 类型 / 值 | Core 结果 |
|---|---|---|---|---|
| `apps.apple.com` | `DomainSuffix` | connected chain | connected chain / `37b14d9dc26d0e1e` | connected |
| `account.apple.com` | `DomainSuffix` | selector target（最终选择需另查） | dial target / `f223faa96f229162` | dial timeout |
| `www.icloud.com` | `DomainSuffix` | selector target（最终选择需另查） | dial target / `c1076eecac8c58a7` | refused / timeout |

成功日志的 `using ...` 是完整 connected chain，而失败日志的 `dial ...` 只含尚未成功展开的 dial target；二者原材料不同，**不能横向比较**。早期据此认为三个入口使用不同目标组属于证据过度推断，现已撤回。

## 单变量对照：live TUN 关、system proxy 保持开

通过 loopback controller 只把 live TUN 从 `true/mixed` 改为 `false`。系统 HTTP/HTTPS/SOCKS proxy 保持启用；测试完成后 watchdog 恢复 live TUN `true/mixed`、关闭临时 controller，并验证 App/Core 各 1 个进程、持久化 TUN/system proxy 偏好和代理 enable 白名单均回到测试前状态。

| 入口 | FlClash system proxy | 原生直连（curl 明确忽略 proxy） | Core trace |
|---|---|---|---|
| `apps.apple.com` | HTTP 302，成功 | HTTP 302，成功 | 与 TUN 开时相同 connected-chain 指纹，connected |
| `account.apple.com` | 8 秒内未建立 TLS，失败 | TLS 成功并收到 HTTP 403 | 与 TUN 开时相同 dial-target 指纹，dial timeout |
| `www.icloud.com` | 8 秒内未建立 TLS，失败 | TCP/TLS 成功，随后对端关闭，curl 56 | 与 TUN 开时相同 dial-target 指纹，dial timeout |

HTTP 403 和 curl 56 都不代表对应 Apple 产品功能成功；它们只证明原生直连比 FlClash 代理路径推进到了更后的传输阶段。

## 规则目标与 Core URLTest 补充

只读 `/rules` 的有序简单域名规则扫描，与运行日志中的 `DomainSuffix` 类型一致：

| 入口 | rule payload 指纹 | rule target 指纹 | 关系 |
|---|---|---|---|
| `apps.apple.com` | `2265cbcc3ef24106` | `f223faa96f229162` | 与 Apple Account 相同 |
| `account.apple.com` | `2265cbcc3ef24106` | `f223faa96f229162` | 与 App Store 相同 |
| `www.icloud.com` | `98094d8ac24edb4c` | `c1076eecac8c58a7` | 独立规则与目标 |

因此 `apps.apple.com` 与 `account.apple.com` 并不是因为顶层规则目标不同而一成一败；它们在同一规则目标下表现出域名相关差异。iCloud 同时存在独立规则目标这一变量。

对两个目标 Selector 的只读摘要进一步确认：

| 域名 | target 类型 | 成员数 | 含 DIRECT | 当前选择 |
|---|---|---:|---|---|
| `apps.apple.com` / `account.apple.com` | selector | 10 | 是 | DIRECT |
| `www.icloud.com` | selector | 9 | 是 | DIRECT |

因此本轮失败不是代理节点选择导致：两个相关 Selector 当前都明确选择 DIRECT。失败边界应表述为 **FlClash Core 的 DIRECT 路径**，而不能写成“PROXY 出口失败”。失败日志只给出尚未展开成功的 selector dial target，不能从中直接读取最终 route class。

Core `/proxies/{name}/delay` 的只读 URLTest 结果：

| 测试 URL | DIRECT | 自身规则目标 | App Store 规则目标 |
|---|---|---|---|
| `apps.apple.com` | success | success | 同“自身规则目标” |
| `account.apple.com` | unavailable | unavailable | 与自身相同目标，unavailable |
| `www.icloud.com` | unavailable | unavailable | unavailable |

v0.8.93 的 `adapter/adapter.go` 明确使用 HTTP `HEAD` 实现 URLTest。由于 `account.apple.com` 的原生 curl `GET` 已能完成 TLS/HTTP，而 URLTest 通过 DIRECT 仍为 unavailable，说明这两个 Apple 入口不适合作为 URLTest 的产品通过/失败判据。URLTest 在本轮只用于无状态确认规则目标，不能替代真实 GET 或原生系统功能。

## 当前结论边界

### 公共入口

1. 已稳定复现 `account.apple.com` 与 `www.icloud.com` 通过当前 FlClash Core DIRECT 路径无法建立可用 HTTPS 会话；`apps.apple.com` 是同时间窗口、同 Apple Selector/DIRECT 选择下的成功 control。
2. 这两个固定公共入口在 live TUN 关闭、仅走 system proxy 时仍以相同 event-kind 指纹和 Core dial timeout 复现。因此，**仅就这组 curl 公共入口探测**，TUN 入站或 effective `tun.inet6-address` 不是充分解释。
3. `account.apple.com` 的原生直连能完成 TLS 并返回 HTTP，证明当时本机基础 DNS/TCP/TLS 与该固定入口总体可用；该 curl 失败边界在 Core DIRECT 的 DNS/地址选择/拨号路径与原生网络栈之间。
4. `apps.apple.com` 与 `account.apple.com` 命中同一个 `DomainSuffix` payload、同一个 Selector 且当前都选择 DIRECT，一成一败说明公共入口存在域名相关变量；iCloud 虽命中独立 Selector，但同样选择 DIRECT。

### 原生 Apple Account

1. 用户先在 TUN 开启状态观察到“系统设置 → Apple Account”超过 10 秒持续转圈；随后用户手动关闭 TUN，页面完成加载；再手动开启 TUN 后，已加载页面仍能加载／保持可用。
2. 这组时序是 **TUN 相关的高价值线索，但不是 A→B→A 因果闭环**。Apple Account 的请求可能由独立后台 daemon 发起，页面也可能复用缓存、既有连接或已完成的认证状态；“重新开启后仍能加载”既不能排除 TUN，也不能证明关闭 TUN 是唯一原因。
3. `account.apple.com`/`www.icloud.com` curl 的固定入口并不代表 System Settings 实际使用的完整后台域名集合，因此公共入口的 DNS fallback 结论不能直接外推为原生 Apple Account 根因。
4. 不再通过退出／重开 System Settings 试图“清缓存”：UI 进程生命周期与后台网络 daemon 没有已证明的一一关系。下一步只在观测到新的 Apple 后台事件时记录有效结果，再对实际命中的请求做 TUN/地址族单变量。
5. Mac App Store 下载、iCloud Drive 同步、iMessage/APNs 等其余原生功能尚未由用户执行，不能把公共入口或 Apple Account 单项观察冒充完整服务矩阵。

## Core DNS A 查询定位

当前 effective DNS 白名单结构：

- `nameserver-policy` 不存在；
- 主 `nameserver` 为 2 个 DoH；
- `fallback` 为 4 个上游：2 个 DoH、1 个 DoT、1 个 plain DNS；
- `fallback-filter.geoip=true`；
- `fallback-filter.ipcidr` 有 2 条；
- fallback domain/geosite filter 均为 0。

通过 v0.8.93 controller `/dns/query?type=A` 做 3 轮只读查询：

| 域名 | A 查询成功 | 错误分类 | 成功回答指纹稳定性 |
|---|---:|---|---|
| `apps.apple.com` | 3/3 | 无 | 3 轮相同 |
| `account.apple.com` | 0/3 | timeout / refused | 无可用回答 |
| `www.icloud.com` | 1/3 | timeout / refused | 仅一轮可用 |

上游级脱敏 trace：

- App Store：两个主 DoH 都发起 A 查询，其中一个及时返回 IPv4；没有启动 4 个 fallback，聚合查询成功。
- Apple Account：两个主 DoH 都发起查询，其中一个曾返回 IPv4；随后 4 个 fallback 全部启动，但本轮没有任一可用返回，聚合查询 timeout。
- iCloud：两个主 DoH 都能返回 IPv4，但仍启动 4 个 fallback；fallback 响应不稳定，缓存存在时可成功，否则 timeout/refused。
- DNS 上游仅用协议类别和截断指纹关联；未保存或输出服务器值。

这与 v0.8.93 `dns/resolver.go` 的 `Resolver.ipExchange` 完全一致：主回答的任一 IP 命中 `fallbackIPFilters` 时，Core 不使用主回答，而改为等待 fallback。当前没有 domain filter，因此失败域名启动 fallback 只能由 `geoip` 或两条 `ipcidr` 之一触发；fallback 上游无可用结果时，最终 A 查询失败。日志里偶尔出现主 DoH 的迟到回答不代表调用成功。

### 诊断分类

- 当前公共入口根因类别：**用户 DNS fallback 路径 + 当前 Core 的 fallback 连接/上游运行状态**。
- 不支持的类别：代理节点选择（相关 Selector 当前均为 DIRECT）、TUN 入站单独导致、FlClash 业务代码。
- 静态配置负责触发 fallback，但单凭静态配置不足以解释每次失败；需要区分长时间运行 Core 的 DNS client 状态和上游瞬时可达性。

## 新鲜 Core 的 DNS-only 隔离对照

从 v0.8.93 锁定的 Mihomo commit `7bdcd60da9db10b681d7507af96d4fad797f3774` 用 Go 1.24.0 构建独立 CLI；每个 variant 使用私有临时 home、复制只读 GeoIP 数据、关闭所有代理 listener，仅开放私有 Unix controller。测试后临时 runtime 自动删除。

两个 variant：

1. `original_dns`：复制当前 effective DNS block；
2. `without_fallback`：保留主 DoH 与其他 DNS 字段，只移除 `fallback` 和 `fallback-filter`。

每轮前调用 `/cache/dns/flush`，随后分别查询三个域名的 A 记录：

| variant | App Store | Apple Account | iCloud |
|---|---:|---:|---:|
| original DNS | 3/3 | 3/3 | 3/3 |
| without fallback | 3/3 | 3/3 | 3/3 |

虽然两者在该时间窗口都成功，但回答内容有稳定差异：

- App Store 两个 variant 的回答指纹相同；
- Apple Account 的 original/fallback 回答与 without-fallback 主 DoH 回答指纹不同；
- iCloud 的 original 回答只有 1 个 IPv4，而 without-fallback 主回答有 2 个 IPv4，指纹也不同。

这证明 `fallback-filter` 对 Apple Account/iCloud 确实替换了主 DoH 回答，而 App Store 不触发替换。fresh Core 的 original DNS 同时 3/3 成功，说明“存在 fallback 配置”本身不是充分失败条件；正式长时间运行 Core 的 fallback client/连接状态或当时上游可达性才决定是否出现 timeout/refused。

隔离 HTTPS 对照经过两次门禁后排除：FlClash 定制 Mihomo 的 `executor.ApplyConfig` 明确注释了静态 `updateListeners`，所以启动配置里的 mixed-port 不会生效；改用 controller `PATCH /configs` 后虽然 loopback listener ready，但 App Store control 与两个失败域名都在 1 ms 内被本地关闭、未进入 TLS/outbound。它不能区分 DNS variant，所有相关 curl 7/56 均不计入功能证据。脚本已收敛回可靠的 DNS-only 模式，不再调试该测试框架；临时 CLI/runtime 已删除。

## 正式 Core restart 后立即复测

用户于 2026-08-03 15:33（Asia/Shanghai）在 FlClash 普通窗口执行“重启核心”。只读进程核对结果：

- FlClash App PID 保持 `3094`，启动时间未变；
- FlClashCore 从 PID `3096` 更换为 `18368`；
- Core 重建后 App/Core 均保持恰好 1 个进程；
- 持久化 `tun=true/mixed`、`system proxy=true`，系统 HTTP/HTTPS/SOCKS enable 均自动恢复为 `1`。

重启后对每个公共入口同时执行显式 loopback system proxy 与绕过显式 proxy、由 TUN 捕获的 GET，各 3 轮；每次 connect timeout 8 秒、总 timeout 12 秒：

| 入口 | 显式 system proxy | TUN 捕获 | TLS 阶段 |
|---|---:|---:|---|
| `apps.apple.com` | 3/3 HTTP 200 | 3/3 HTTP 200 | 6/6 建立 TLS |
| `account.apple.com` | 0/3 | 0/3 | 6/6 未进入 TLS，curl 28/35 |
| `www.icloud.com` | 0/3 | 0/3 | 6/6 未进入 TLS，curl 28/35 |

因此，**重启正式 Core 本身没有修复 Apple Account/iCloud，也不能把旧 Core DNS client/连接状态卡死视为充分根因**。失败仍与 App Store control 稳定分离，并继续同时存在于 system proxy 与 TUN 两条入站。

同一状态下由用户执行原生功能验证：打开并刷新“系统设置 → Apple Account”，10 秒内页面持续转圈、未完成加载。随后用户手动关闭 TUN，页面完成加载；用户再手动开启 TUN 后，页面仍能加载。该时序使 TUN-specific 路径重新成为高优先级假设，但由于后台 daemon、缓存与既有连接均未被控制，它尚不满足稳定复现或因果闭环条件，也不能与 `account.apple.com` 固定公共入口直接等同。

早期尝试只读复测 controller DNS 时，“外部控制器”偏好虽变为 `true`，但 `lsof` 没有显示 `127.0.0.1:9090`，当时据此写成“Core 未建立 listener”。后续复核证明这个判断无效：在 controller API 与 `nc` 均确认 loopback 9090 可达时，同一条 `lsof` 仍然不输出监听行。由于重启前没有执行 config-aware controller 请求，现有证据既不能证明当时不可达，也不能证明“必须重启才生效”。

## 原生后台事件捕获

为避免把 System Settings UI 生命周期或固定 curl 入口当成后台行为，已启用只监听 loopback 9090 的 controller，并增加 `logs-apple`：原始日志只在内存解析，仅允许固定 Apple 公共域名后缀，输出域名、DNS/连接事件类别、DIRECT/未解析分类和错误类别；不输出解析地址、节点、secret 或完整日志。域名过滤与 DNS route 分类的内置自测已通过。

首轮时序：

- 15 秒无操作基线：0 个 Apple 日志匹配；
- 在请求用户执行 Apple Account 非修改性子页切换后的一个 5 秒窗口：50 个匹配、5 个公共域名、17 类脱敏事件；
- 随后 10 秒无操作窗口：0 个匹配。

该 5 秒事件 burst 中，`*.contacts.icloud.com.cn` 出现 Core DIRECT connected；`*.push.apple.com` / `*.courier.push.apple.com` 出现 A 查询、多个 DNS 上游类别参与和 TCP dial timeout。它已经证明原生后台实际域名集合与 `account.apple.com`/`www.icloud.com` 固定 curl 探针不同，而且同一短窗口内既有成功的 iCloud Contacts，又有失败的 Apple Push 路径。

用户后来说明错过了该次捕获提示窗口，无法确认 burst 与 UI 操作的时序。因此它永久只记为“无法归因的短时后台 burst”，不能声称由该 UI 操作触发，更不能据此判定 Apple Account 整体成功或失败。

经当前 TUN DNS 劫持的 `dig A` 对三域均为 3/3 `NOERROR`、单回答。由于 effective DNS 使用 fake-IP，这只证明 fake-IP 劫持能返回占位回答，不能证明 Core 已获得真实 upstream 地址，也不能推翻 HTTPS 未进入 TLS 的结果。

## 下一轮验收动作

- 当前 Apple 与 iCloud Selector 已经是 DIRECT，不再重复“切到 DIRECT”这一无效变量。
- DNS-only 隔离已完成：它证明 fallback 替换回答，但 fresh Core 的 original/no-fallback 都成功，不能伪称 no-fallback 已修复 HTTPS。
- 正式 Core restart 已完成且公共入口失败不变，不再重复把 restart 当作修复变量。
- 不再用退出／重开 System Settings 作为后台冷启动，也不再追问首轮 burst 的历史操作。loopback controller 与 `logs-apple` 已可用；若重测，使用明确的“操作前静默／操作窗口／操作后静默”结构，只有当轮操作窗口出现新事件才算有效触发。
- 当前正式 Core 在 `ipv6:false` 下的 live TUN 已确认没有 `inet6-address`，因此不再把文件 effective YAML 中的该字段列为当前 Apple 高优先 live 变量。捕获到真实后台域名后，应优先验证其 DNS fallback 路径；地址族只在 live config 或日志出现相应证据时再测。
- 若继续做 DNS 单变量，应直接验证实际后台请求的 fallback 路径；不能把固定公共入口、fake-IP `dig` 成功或 UI 生命周期冒充原生后台结果。

## 2026-08-04 Apple Account 有效功能轮次

用户在明确开始窗口内，从已打开的 Apple Account 主页面进入 iCloud 子页：10 秒后仍持续转圈；返回 Apple Account 主页面后再等 10 秒，仍持续转圈。全程未退出/重开 System Settings，未切换 TUN、代理、Selector、DNS 或 Core；结束后 preference/live TUN 仍为 `true/mixed`。

该 60 秒操作窗口捕获到 283 个 Apple 公共域名脱敏匹配、8 个域名、66 类事件。与静止页面基线相比，新增 iCloud mask/quota 类功能域名；主 DoH 能给出 IPv4，但同一功能链仍出现 fallback、TCP/UDP timeout/refused 与 unresolved dial target。另有中国区 iCloud/Apple 服务 DIRECT connected，说明部分成功连接不足以使页面完成加载。

本轮是有效的原生功能失败证据；完整逐项记录见 `MACOS_APPLE_NATIVE_SERVICE_MATRIX.md`。它不再依赖用户回忆旧 burst，也不把命令行旁证冒充功能结果。
