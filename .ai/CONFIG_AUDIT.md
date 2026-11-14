# `20260712.yaml` 脱敏静态审查

## 审查对象

- 路径：`/Users/lirichard/Library/Mobile Documents/com~apple~CloudDocs/FIClash/20260712.yaml`
- 修改时间：2026-07-16 13:42:59 +0800
- 大小：469,076 bytes
- SHA-256：`3feeb07812226578e90303d409ad1e90775e52042d5c254ee1f72e8f4faa380e`

本报告不记录节点名称、服务器、端口、UUID、密码、provider URL、controller secret 或私有 hosts。

## 结构摘要

| 项目 | 结果 |
|---|---:|
| proxies | 128（VLESS 54、Shadowsocks 73、VMess 1） |
| proxy groups | 41 |
| proxy providers | 1 |
| rule providers | 0 |
| inline rules | 8,054 |
| DNS | 启用，Fake-IP，IPv6 关闭 |
| Fake-IP filters | 59 |
| top-level TUN | 不存在 |
| sniffer | 不存在 |
| non-empty secret | 存在，已隐藏 |

配置仍带有 ClashX Pro 风格的 `experimental.ignore-resolve-fail` 和 `script.shortcuts`。它们是否仍参与当前 Mihomo 行为必须用内置 core 的配置检查和运行日志确认，不能仅凭解析成功下结论。

## 已通过的静态完整性检查

- 节点名称无重复。
- 策略组名称无重复。
- 所有规则 target 均能解析到已定义组或内置策略。
- 所有策略组成员引用均有效。
- 唯一 `MATCH` 位于第 8,054 条，即最后一条。

## 规则规模与维护性

- `DOMAIN-SUFFIX` 7,269 条。
- `DOMAIN` 463 条。
- `DOMAIN-KEYWORD` 54 条。
- IP CIDR 170 条。
- PROCESS-NAME 91 条。
- 6,795 条规则指向 `全球拦截`。

大量内联广告域名不一定导致本次 TUN 故障，但会增加配置解析、审查和更新成本。后续可评估改成可固定版本、可校验、支持离线回退的 `rule-provider`；这应作为独立优化，不与 TUN 首个修复混合。

## 重复与遮蔽统计

- 同一条件重复出现：104 组。
- 其中同一条件指向不同策略：14 组。
- 因此至少 90 组是同策略精确重复。
- 简单域名后缀/关键字静态遮蔽候选：166 条。
- 简单 CIDR 包含遮蔽候选：6 条。

“遮蔽候选”是保守静态启发式结果，需要人工确认；“同条件不同策略”则是确定的首匹配冲突，后出现的规则不会生效。

## 14 组确定冲突

Mihomo 规则自上而下首个匹配生效。下表的“当前胜出”即较早规则的策略。

| 条件 | 位置（rules 数组） | 当前胜出 | 后续失效策略 |
|---|---:|---|---|
| `DOMAIN-SUFFIX,intercomcdn.com` | 6843 / 7741 | 全球拦截 | OpenAI |
| `DOMAIN-SUFFIX,intercom.io` | 6844 / 7743 | 全球拦截 | OpenAI |
| `DOMAIN,bag.itunes.apple.com` | 7182 / 7188 | AppleFitness | AppleBooks |
| `DOMAIN,gateway.icloud.com` | 7206 / 7221 | AppleNews+ | iCloud |
| `DOMAIN,gspe1-ssl.ls.apple.com` | 7207 / 7256 | AppleNews+ | Apple |
| `DOMAIN-SUFFIX,icloud.com` | 7225 / 7271 | iCloud | Apple |
| `DOMAIN-SUFFIX,icloud-content.com` | 7233 / 7273 | iCloud | Apple |
| `DOMAIN-SUFFIX,icloud.com.cn` | 7237 / 7272 | 全球直连 | Apple |
| `DOMAIN-SUFFIX,apple.com.cn` | 7259 / 7263 | 全球直连 | Apple |
| `DOMAIN,edge.skype.com` | 7530 / 7575 | 微软科学服务 | 微软服务 |
| `DOMAIN-SUFFIX,bing.com` | 7531 / 7633 | 微软科学服务 | 微软服务 |
| `DOMAIN-SUFFIX,azureedge.net` | 7591 / 7631 | 全球直连 | 微软服务 |
| `DOMAIN-SUFFIX,identrust.com` | 7754 / 7984 | OpenAI | 全球直连 |
| `DOMAIN,statuse.digitalcertvalidation.com` | 7946 / 7985 | 通用代理 | 全球直连 |

这些冲突未必全部造成失败：若两个策略组运行时选择相同出口，现象会被掩盖；一旦组选择不同，结果就与配置作者的后置意图不一致。

## Apple 规则观察

- Apple 相关策略被拆成 `Apple`、`AppleDZ`、`AppleInternal`、`iCloud`、TV、Fitness、Music、Podcast、News、Books 等多个组。
- 这些组默认第一项大多为 `DIRECT`；`AppleDZ` 第一项为 `全球拦截`。
- iCloud 与 Apple 通用规则存在 5 组精确重叠；当前由更早的 iCloud 或直连规则胜出。
- `gateway.icloud.com` 当前被 AppleNews+ 抢先匹配，而 Apple 官方已将该主机用于更多服务场景，值得优先重新归类。
- `hkhkg*.icloud-content.com` 被直连，另一些区域 CDN 子域被通用代理，说明现有策略高度依赖地区和节点选择。
- Fake-IP filter 已覆盖部分 Apple 更新/时间域名，但没有覆盖全部 iCloud/App Store 域名；不能简单推断“Apple 应全部 real-ip”或“全部 fake-ip”。

## Microsoft 规则观察

- `微软服务` 153 条，`微软科学服务` 17 条，两个规则块交错。
- `bing.com` 与 `edge.skype.com` 当前优先走 `微软科学服务`。
- `azureedge.net` 当前优先走 `全球直连`，后面的 `微软服务` 规则永远不会生效。
- Fake-IP filter 覆盖 Microsoft 网络连通性检测与 Xbox 的部分域名，但这不能解释所有网页访问。
- Microsoft Store 正常而网站失败，意味着不能把问题归因为 UWP loopback；应优先验证 DNS、IPv6/TUN 地址、QUIC/UDP、MTU 和实际规则命中。

## raw profile 与 effective config 的差异

本文件没有 `tun`。FlClash 启动时会加入 TUN 配置，因此下列字段必须从“配置预览”或 core API 另行采集：

- `stack`
- `auto-route`
- `auto-detect-interface`
- `strict-route`
- `dns-hijack`
- `mtu`
- `inet6-address`
- `route-address` / `route-exclude-address`

没有 effective config 前，不应提交 Apple/Microsoft TUN 代码修复。

## 建议的配置整理顺序

1. 先复制为独立文件，记录源文件和副本 SHA-256。
2. 用当前 FlClash 内置 Mihomo 做语法检查。
3. 固定每个 Apple/Microsoft 策略组的测试出口，避免“组选择相同”掩盖冲突。
4. 对 14 组冲突逐一决定唯一 owner。
5. 删除 90 组同策略精确重复。
6. 人工复核 166 个域名遮蔽候选和 6 个 CIDR 候选。
7. 再评估把广告规则迁移至 version-pinned rule provider。
8. 用 rule trace 和服务冒烟测试验证，最后才替换生产配置。

