# macOS Microsoft TUN DIRECT DNS fallback 单变量

采集时间：2026-08-03 20:15–20:37（Asia/Shanghai）。  
状态：代表性 Microsoft 域名的故障变量已定位到正式 Core 的 DNS `fallback-filter` / fallback 可达路径；`inet6-address`、TUN stack 和 Fake-IP 本身不是这组失败的必要条件。所有实验只临时重载内存配置，用户原始 YAML 未修改，结束后已恢复原 DNS、Selector 与 TUN 状态。

## 测试对象与安全边界

- 正式 `/Applications/FlClash.app` 0.8.93，Mihomo `7bdcd60da9db10b681d7507af96d4fad797f3774`。
- 全部 controller 请求只发往 loopback；secret 未出现在 argv 或输出。
- 只输出协议类别、数量、结果、HTTP code 和耗时，不输出 DNS server、IP、节点、组名、订阅或完整配置。
- 三个固定代表域名：`www.microsoft.com`、`login.live.com`、`m365.cloud.microsoft`。
- 最终业务语义保持：普通“微软服务”DIRECT，只有“微软科学服务”代理。

## 1. `inet6-address`：raw effective 与 live parsed 的区别

文件中的 effective YAML 包含 1 条 `tun.inet6-address`，但 live `/configs` 明确为：

- `tun_inet6_present=false`
- `tun_inet6_kind=none`
- `tun_inet6_count=0`

当前 Mihomo 精确源码在 `parseIPV6` 中，当顶层 `ipv6` 为 false 或本机 IPv6 校验失败时，会清空 `rawCfg.DNS.FakeIPRange6` 和 `rawCfg.Tun.Inet6Address`。`/configs` 返回的是 listener 已解析的 live TUN config，而不是文件原文。

在 live inet6 已为空的基线中，三个域名的 Core DIRECT URLTest 仍全部 unavailable。因此 issue #1993 的 live IPv6 TUN 地址假设对本次 macOS Microsoft 失败不成立。

## 2. TUN stack 单变量

保持 TUN 开启、live inet6 为空，只临时改变 stack：

| stack | `www.microsoft.com` | `login.live.com` | `m365.cloud.microsoft` |
|---|---|---|---|
| `system` | unavailable | unavailable | unavailable |
| `gvisor` | unavailable | unavailable | unavailable |

随后恢复 `true/mixed`。stack 不改变结果。

## 3. 正式 Core DNS 日志

原配置和清空 DNS cache 后各做一轮 A 查询，模式一致：

1. 主 DoH 返回可用 IPv4；
2. 回答命中 `fallback-filter`，Core 启动 4 个 fallback 查询；
3. fallback 协议类别为 plain、DoT、DoH、DoH；
4. 没有一个 fallback 返回可用聚合结果；
5. 整体 A 查询 timeout。

当前 DNS 白名单形状：

- main nameserver 2 个，均为 DoH；
- fallback 4 个：1 plain、1 DoT、2 DoH；
- `fallback-filter.geoip=true`，`ipcidr` 2 条，domain 0 条；
- `enhanced-mode=fake-ip`；
- `respect-rules=false`；
- `direct-nameserver` 0 个；
- `nameserver-policy` 0 个；
- main/fallback 均没有显式 proxy binding。

精确 Mihomo resolver 源码的顺序为：先匹配 `nameserver-policy`；否则查询 main；若 main IP 命中 fallback 条件，再等待并返回 fallback。没有 fallback 时才直接返回 main。

## 4. 删除 fallback 的隔离 A/B

从内存中的 effective config 深拷贝一个 variant，只删除 `dns.fallback` 与 `dns.fallback-filter`，不写磁盘。TUN 保持 `true/mixed`、inet6 为空、Fake-IP 保持不变。

- 三域 A 查询全部成功，IPv4 answer count 分别为 `1 / 8 / 1`；
- Core DIRECT URLTest 全部成功，代表性延迟约 `84 / 316 / 82ms`；
- 临时把共同 Microsoft Selector 设为 DIRECT 后，绕过代理环境的真实 HTTP/1.1：
  - Microsoft 首页：HTTP 200，TLS verify 0，约 `484ms`；
  - Microsoft Account：HTTP 200，TLS verify 0，约 `749ms`；
  - Microsoft 365：HTTP 200，TLS verify 0，约 `405ms`。

恢复原配置后，`www.microsoft.com` 的 Core DIRECT 再次 unavailable。该闭环证明 fallback/filter 是必要故障变量，但“删除全部 fallback”只是一种隔离手段，不是建议的最终配置。

## 5. 保留 fallback 的最小 policy bypass A/B

第二个内存 variant 完整保留 4 个 fallback、原 `fallback-filter` 和 Fake-IP，只为 3 个精确测试域名增加 `nameserver-policy`，并复用已经能返回主回答的 main nameserver。源码保证 policy 命中在 fallback 判断前直接返回。

结果：

| 域名 | A 查询 | IPv4 count | Core DIRECT URLTest |
|---|---|---:|---:|
| `www.microsoft.com` | success | 1 | success, `654ms` |
| `login.live.com` | success | 8 | success, `279ms` |
| `m365.cloud.microsoft` | success | 1 | success, `90ms` |

共同 Microsoft Selector 临时设为 DIRECT 后，TUN 内真实 HTTP/1.1：

| 目标 | 结果 | 总耗时 | TLS verify |
|---|---:|---:|---:|
| Microsoft 首页 | HTTP 200 | `7970ms` | 0 |
| Microsoft Account | HTTP 200 | `789ms` | 0 |
| Microsoft 365 | HTTP 200 | `386ms` | 0 |

这证明无需关闭 Fake-IP、无需改变 stack、无需删除全局 fallback；只要让这些普通 Microsoft 域名避开当前错误 fallback 路径，DIRECT 功能就恢复。

## 恢复核对

2026-08-03 20:37 CST 重新识别 live 状态：

- App/Core 各 1 个进程；PID 为当次新鲜读取值，不作为下次恢复依据；
- TUN `true/mixed`，live `inet6-address` 不存在；
- 系统 HTTP/HTTPS/SOCKS proxy 开启、PAC 关闭、启用 host 均为 loopback 且端口一致；
- controller 为 loopback TCP，默认 9090，可达；
- `show_tray_title=false`，主窗口可见，`AXEnhancedUserInterface=false`；
- 33 个 Selector 已恢复；Microsoft Selector 当前选择指纹与实验前相同，且不是 DIRECT。

## 结论与后续设计边界

代表性 Microsoft Web 失败的根因已经定位：主 DoH 有可用回答，但原 `fallback-filter` 强制等待当前正式 Core 中不可用的 fallback，导致 DNS timeout，随后 TUN 内 DIRECT 失败。

Phase 1 只证明修复机制，不修改用户 YAML。后续 ownership review 已选择两个互斥 inline classical provider：路由分别引用 science/direct provider，DNS policy 只引用 direct provider并复用已验证的 main resolver。当前 `override_dns=false`，raw policy 可进入 effective config。实现仍必须在独立配置副本中完成静态 overlap 门禁、effective diff 与 live 矩阵；详见 `MACOS_MICROSOFT_DNS_POLICY_OWNERSHIP_REVIEW.md`。
