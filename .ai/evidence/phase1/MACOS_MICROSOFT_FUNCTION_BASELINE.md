# macOS Microsoft 服务与 TUN DIRECT 基线

采集时间：2026-08-03。  
状态：已证明 macOS 故障属于 TUN 内 DIRECT 路径，规则导入没有丢失或重排；后续单变量已把代表性域名的根因定位到正式 Core 的 DNS `fallback-filter` / fallback 可达路径。

## 用户要求的策略语义

- 普通“微软服务”应走 `DIRECT`。
- 只有“微软科学服务”需要代理。
- 代理恢复仅用于恢复可用性和做对照，不是最终配置建议。

## `cloud.microsoft` 规则与导入一致性

用户最终在 raw profile 中加入了正确的带引号规则：

```yaml
- 'DOMAIN-SUFFIX,cloud.microsoft,微软服务'
```

此前的 `cloud.microsoft.com` 已删除。Microsoft 官方把 `cloud.microsoft` 作为 Microsoft 365 统一域名；`m365.cloud.microsoft` 实际命中该 suffix。

`.ai/scripts/compare_profile_effective_rules.rb` 对用户当前 raw profile 与 FlClash effective config 的结果：

- 两边 YAML 均可解析；
- raw/effective 规则数均为 `8055`；
- 非字符串规则均为 `0`；
- 规则顺序 SHA-256 均为 `febf4f77d9c1962b1a615a3b9a91c21ed6d1c93fb690011c7c612f4997b83f28`；
- sequence 和 multiset 都完全相等；
- raw-only/effective-only 均为 `0`；
- `cloud.microsoft` 正确规则两边各 1 条，错误 `.com` 规则两边均为 0；
- target 相同、规则位于唯一且最后的 `MATCH` 之前。

当前用户编辑后的 raw SHA-256 为 `fbe200b1e0206aedb4dd28f2eb4bfc491bfc6ebb613e74fc74ac685916f0f17a`；effective SHA-256 为 `e075bbf2e357cc3f1d797bc7a29513bcb0a382f6c59a3e2f6cee53c8859e58c7`。历史 `CONFIG_AUDIT.md` 和 `EFFECTIVE_CONFIG_DIFF.md` 中的旧 raw SHA 是编辑前快照，不应再描述为“当前未变化”。

结论：FlClash 导入／effective 生成没有使这批规则丢失或重排。单条规则仍可能被更早规则遮蔽，但本条已经通过 live `/rules` 证明命中“微软服务”。

## TUN 开：微软服务改为 DIRECT 后失败

当用户把“微软服务”临时指向 DIRECT：

- `login.live.com` 3/3 未完成正常 TLS/HTTP：两次 timeout，一次 curl 35 TLS error；
- 用户可见现象是连 `www.microsoft.com` 都无法打开；
- `m365.cloud.microsoft` 已由新增规则命中“微软服务”，不是继续落到 `MATCH`。

因此正确规则生效后，DIRECT 仍失败；“规则导入丢失”不是原因。

## 恢复代理后的可用性对照

用户恢复“微软服务”原选择后，live 选择指纹与测试前相同，并且不是 DIRECT。随后真实 HTTP/1.1 GET：

| 入口 | 结果 | TLS | 总耗时 |
|---|---:|---:|---:|
| `www.microsoft.com` | HTTP 200 | `7.324s` | `9.209s` |
| `login.live.com` | HTTP 200 | `6.445s` | `7.428s` |
| `www.office.com` | HTTP 200 | `6.605s` | `6.875s` |

代理路径能恢复基本访问，但 TLS 明显偏慢；这只是故障对照，不满足用户要求的 DIRECT 策略。

## TUN 关：macOS 原生 DIRECT 成功

用户完成同机、同网络对照并确认：**TUN 关闭后的 macOS 原生 DIRECT 能成功访问。**

结合 TUN 开 + 规则 DIRECT 失败，已可排除“本机当前网络／运营商完全无法直连微软”。故障范围收敛为 FlClash/Core 的 TUN 内 DIRECT 路径。

## Core 只读对照

TUN 恢复 `true/mixed`、策略组恢复代理后，直接对 Core 的 DIRECT outbound 做 URLTest：

| 域名 | Core DIRECT | 按规则命中 |
|---|---|---|
| `www.microsoft.com` | unavailable | success, `269ms` |
| `login.live.com` | unavailable | success, `518ms` |
| `m365.cloud.microsoft` | unavailable | success, `244ms` |

对应 Core `/dns/query` A 查询各 3 轮：

- `www.microsoft.com`：3/3 timeout；
- `login.live.com`：2 timeout + 1 refused；
- `m365.cloud.microsoft`：2 timeout + 1 refused。

该结果与 Apple 公共域名已经观察到的主 DoH/fallback timeout/refused 模式相似。URLTest 是 HEAD 类探测，不代表完整产品请求，但 DIRECT 与 matched 的分离非常清晰。

## 后续单变量结论

详细实验见 `MACOS_MICROSOFT_DNS_FALLBACK_AB.md`：

- effective YAML 文件虽然含 1 条 `tun.inet6-address`，但顶层 `ipv6:false` 会被当前 Mihomo parser 清空，live `/configs` 中该 key 不存在；在 live inet6 已为空时故障仍存在。
- `mixed → system → gvisor` 都无法使三个 Microsoft 域名的 Core DIRECT URLTest 成功，stack 已排除。
- 原配置中主 DoH 能返回 IPv4，但回答触发 `fallback-filter` 后，4 个未显式绑定出站的 fallback 均没有可用结果，聚合 A 查询 timeout；flush DNS cache 后模式不变。
- 临时删除 fallback 时，三域 DNS、Core DIRECT URLTest 和 TUN 内真实 HTTPS 全部成功；恢复原配置后失败复现。
- 更小的 A/B 完整保留 fallback、filter 和 Fake-IP，只为三个测试域名增加复用主 DNS 的精确 `nameserver-policy`，三域 DNS、DIRECT URLTest 和真实 HTTPS 仍全部成功。

这证明 Fake-IP 本身无需关闭，全局 fallback 也无需删除；代表性普通 Microsoft 域名只要绕过当前错误 fallback 路径即可恢复 DIRECT。

## 当前结论与待设计边界

已经证明：

1. 普通微软服务不必永久走代理；macOS 原生网络可 DIRECT。
2. 当前故障由 TUN 内 DIRECT 路径引入。
3. `cloud.microsoft` 规则已正确导入、排序并 live 命中。
4. 当前 Core DIRECT 的失败发生在 DNS：主 DoH 已有可用回答，但 `fallback-filter` 强制等待当前不可用的 fallback，最终 timeout。
5. `inet6-address` 与 stack 不是本组故障变量；保留 Fake-IP 和 fallback、仅用 `nameserver-policy` 绕过错误 fallback 已恢复真实 HTTPS。

尚未完成的是最终覆盖设计与跨平台验收：

- 不能只硬编码本次 3 个测试域名；需要为普通“微软服务”确定可维护的 DNS policy ownership。
- 不能用宽泛 Microsoft 集合吞掉“微软科学服务”的代理语义。
- 其他 Microsoft Web/CDN 入口和 Windows 实机仍需验证。
- Apple 是否同样采用此修复范围仍需独立证据，不能从 Microsoft 三域直接外推。

Phase 1 未修改用户 YAML。后续进入修复设计时应以“保留普通 Microsoft DIRECT，并让其 DNS 避开不可用 fallback”为起点；不要再重复 inet6/stack/规则导入实验，也不要把“微软服务改代理”当作修复。
