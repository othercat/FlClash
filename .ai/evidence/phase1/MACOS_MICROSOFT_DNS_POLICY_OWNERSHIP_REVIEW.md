# Microsoft DIRECT DNS policy ownership review

Review 时间：2026-08-03（Asia/Shanghai）  
状态：Phase 1 设计 review 已完成；未修改用户原始 YAML，也未重载正式 Core。推荐在独立配置副本中，用两个互斥 inline rule-provider 统一路由与 DNS ownership。

## 已证明的机制

正式 App 0.8.93 使用 Mihomo `7bdcd60da9db10b681d7507af96d4fad797f3774`。三域 A/B 已证明：

- `tun.inet6-address` 与 system/gVisor stack 不是故障变量；
- 主 DoH 返回可用 IPv4 后，当前 `fallback-filter` 触发 4 个不可用 fallback，聚合 DNS timeout；
- 保留 Fake-IP、全部 fallback 与 filter，只为精确域名增加复用 main DNS 的 `nameserver-policy`，DNS、Core DIRECT URLTest 与 TUN 内真实 HTTPS 全部恢复。

精确 Core 源码与当前 Mihomo 文档一致：

- `nameserver-policy` 在 main/fallback 之前匹配，命中后直接使用指定 resolver；
- `rule-set:<name>` 可引用 behavior 为 `domain` 或 `classical` 的 rule-provider；classical provider 中只使用域名类规则；
- policy matcher 按配置顺序返回第一个匹配；
- v0.8.93 已支持 `type: inline` rule-provider。

Context7 返回的 Mihomo 官方文档也明确说明 `nameserver-policy` 优先于通用 nameserver/fallback，并支持 `rule-set:`。本地精确 commit 源码是最终版本依据。

## 当前 ownership 问题

现有配置审计记录：

- “微软服务”约 153 条；
- “微软科学服务”约 17 条；
- 两个规则块交错；
- `bing.com`、`edge.skype.com` 由更早的“微软科学服务”规则胜出；
- `azureedge.net` 由更早的“全球直连”规则胜出，后面的“微软服务”规则失效。

因此不能把当前“微软服务”的全部后置规则机械复制进 DNS policy。路由的首匹配遮蔽不会自动作用于独立的 DNS policy；若 direct DNS 集合仍包含 `bing.com`，它会绕过 fallback，即使后续流量最终仍由“微软科学服务”代理，造成 ownership 漂移。

## 推荐的单一来源结构

在独立配置副本中建立两个互斥的 inline classical provider：

```yaml
rule-providers:
  microsoft-science:
    type: inline
    behavior: classical
    payload:
      - <现有“微软科学服务”的域名类规则，不带策略目标>

  microsoft-direct:
    type: inline
    behavior: classical
    payload:
      - <清理冲突后的普通 Microsoft 域名类规则，不带策略目标>

dns:
  nameserver-policy:
    'rule-set:microsoft-direct':
      - <与当前 main nameserver 相同的 resolver 1>
      - <与当前 main nameserver 相同的 resolver 2>

rules:
  - RULE-SET,microsoft-science,微软科学服务
  - RULE-SET,microsoft-direct,微软服务
  - <其余规则>
```

示例只表达结构，不包含用户 resolver、节点或完整域名清单。

关键约束：

1. 两个 provider 必须在 suffix containment 层面互斥，不只是字符串完全不重复。
2. `bing.com` 与 `edge.skype.com` 只属于 science provider。
3. `azureedge.net` 保持当前更早的“全球直连”ownership，除非配置清理阶段另行人工决定；它不应被自动塞进 Microsoft direct provider。
4. `nameserver-policy` 只引用 `microsoft-direct`，不引用宽泛 Microsoft/geosite 集合。
5. “微软服务”Selector 最终固定到 DIRECT；“微软科学服务”继续选择代理。
6. policy 使用已在 A/B 中验证成功的 main resolver 集合，不在同一变更中启用 `respect-rules`、新增 `direct-nameserver` 或替换 fallback。

这样路由和 DNS 共用同一个 `microsoft-direct` provider，不需要维护第二份 153 条 DNS 域名列表。

## FlClash effective-config 边界

`makeRealProfileTask()` 的行为是：

- raw `rule-providers` 会保留；HTTP provider 只会被重写本地 cache path，inline provider 不受影响；
- raw DNS 已启用且 FlClash“覆写 DNS”为 false 时，raw `nameserver-policy` 会保留；
- “覆写 DNS”为 true 时，FlClash 会用 App 的 DNS model 替换整个 raw `dns`，raw policy 会消失。

2026-08-03 当前白名单快照为 `override_dns=false`，所以配置副本中的 inline provider 与 raw policy 可以进入 effective config。该值不是永久事实；导入、切换配置或测试前必须重新核对。

这也是为什么首选“配置副本 + effective diff”，而不是立即修改 FlClash 产品代码。若未来要求在“覆写 DNS”开启时也保留 profile-specific policy，应另立产品需求，明确 merge 冲突规则并为 `makeRealProfileTask` 增加测试。

## 域名覆盖的维护来源

现有用户规则仍是语义基线，Microsoft 官方数据只作为候选更新源，不能自动覆盖用户的 science 分类。

Microsoft 官方说明：

- Microsoft 365 endpoint Web Service 提供最新 FQDN/IP 记录、版本和 changes 接口；
- endpoint 数据通常按月更新，也可能因事件在月中更新；
- `Optimize`、`Allow`、`Default` 是网络连通性类别，不等同于本配置的“普通服务/科学服务”语义；
- 该服务不覆盖所有 Microsoft 网络端点，consumer Microsoft、CDN 与第三方依赖仍可能需要单独维护。

官方来源：

- [Microsoft 365 IP Address and URL web service](https://learn.microsoft.com/en-us/microsoft-365/enterprise/microsoft-365-ip-web-service?view=o365-worldwide)
- [Managing Microsoft 365 endpoints](https://learn.microsoft.com/en-us/microsoft-365/enterprise/managing-office-365-endpoints?view=o365-worldwide)
- [Microsoft 365 URLs and IP address ranges](https://learn.microsoft.com/en-us/microsoft-365/enterprise/urls-and-ip-address-ranges?view=o365-worldwide)

后续维护工具应只生成候选 diff：

1. 检查官方 `/version`；版本变化时才获取 `/endpoints`；
2. 只抽取 FQDN/URL pattern，不把 IP 段混入 domain provider；
3. 先与 science provider 和其他已有 owner 做 suffix overlap 检查；
4. overlap 必须人工决策，默认不加入 direct；
5. 审核通过后更新 inline payload，并记录来源版本和集合 SHA；
6. Microsoft 365 feed 之外仍保留现有 consumer/account/web 基线。

不应让 FlClash App 在运行时直接抓取 Microsoft feed，也不应把动态端点硬编码进 Dart 产品代码。

## 实施前静态门禁

配置副本必须通过：

- science/direct provider 都只含域名类 classical rule；
- exact duplicate 为 0；
- 两个 provider 的 suffix containment overlap 为 0；
- DNS policy 只引用 direct provider；
- `MATCH` 仍为最后一条；
- 所有策略目标存在；
- raw/effective 中两个 provider payload SHA 相同；
- effective `nameserver-policy` 中存在且仅存在预期 Microsoft direct matcher；
- 不输出或保存 resolver、节点、订阅和 secret。

## live 验收矩阵

普通 Microsoft DIRECT：

- `www.microsoft.com`
- `login.live.com`
- `m365.cloud.microsoft`
- Outlook/Office Web 的至少一个真实入口
- 由页面触发的至少一个 Microsoft CDN 资源，但必须先确认其实际 owner

science 代理 ownership：

- `bing.com`
- `edge.skype.com`
- 从现有 17 条 science 规则中再选至少一个不含敏感信息的代表入口

每个入口都验证：

1. live `/rules` 命中预期组；
2. direct 域名命中 policy 后不再进入 fallback；
3. science 域名不命中 direct DNS policy，流量命中代理组；
4. TUN 开时真实 HTTP/1.1/TLS 成功；
5. TUN 关原生 DIRECT 作为 control；
6. Microsoft Store 现有正常行为不回归。

只有配置副本通过静态门禁、effective diff 和上述 live 矩阵后，才可替换当前配置。原始 `20260712.yaml` 必须保持不变。
