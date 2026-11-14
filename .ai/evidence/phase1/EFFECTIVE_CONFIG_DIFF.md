# raw profile / effective config 脱敏对比

采集时间：2026-08-03。采集方式：`scripts/sanitize_effective_config.dart` 白名单导出；未输出节点、provider、策略组、规则、secret、hosts 或 DNS 服务器值。

## 来源完整性

| 来源 | SHA-256 |
|---|---|
| 原始 `20260712.yaml` | `3feeb07812226578e90303d409ad1e90775e52042d5c254ee1f72e8f4faa380e` |
| FlClash 当前生成的 `config.yaml` | `5bd135cf2156a752443ed52daf9ceeb6bbb7fdf25d8a17c8b9fcde40a8e4a288` |

原始 profile SHA-256 与 `CONFIG_AUDIT.md` 的既有记录一致，说明本次只读采集没有改变原文件。

> 这是用户编辑 Microsoft 规则之前的历史完整性快照。用户随后主动修改了 raw profile；当前 SHA 与规则一致性记录见 `MACOS_MICROSOFT_FUNCTION_BASELINE.md`。不得再把本节旧 SHA 描述为当前文件未变化。

## 白名单差异

| 字段 | raw profile | effective config |
|---|---|---|
| 顶层 `ipv6` | `false` | `false` |
| `tun` | 不存在 | 存在 |
| `tun.enable` | 无 | `true` |
| `tun.stack` | 无 | `mixed` |
| `tun.auto-route` | 无 | `true` |
| `tun.auto-detect-interface` | 无 | 未显式设置 |
| `tun.strict-route` | 无 | 未显式设置 |
| `tun.mtu` | 无 | 未显式设置 |
| `tun.inet4-address` | 无 | 1 条 IPv4 地址（值已省略） |
| `tun.inet6-address` | 无 | 1 条 IPv6 地址（值已省略） |
| `tun.route-address` | 无 | 0 条 |
| `tun.route-exclude-address` | 无 | 0 条 |
| `tun.dns-hijack` | 无 | 1 条（值已省略） |

对应机器可读文件：

- `raw-profile-sanitized.json`
- `effective-config-sanitized.json`

## 当前结论边界

已证明 FlClash 在顶层 `ipv6: false` 时，仍向磁盘上的 effective YAML 注入 IPv6 地址；但这不等于 live TUN 使用了该地址。当前 Mihomo 精确版本的 `parseIPV6` 会在顶层 IPv6 关闭时清空 `Tun.Inet6Address`，live `/configs` 已确认 `tun.inet6-address` key 不存在、count 为 0。Microsoft 三域在该 live 状态下仍失败，因此 issue #1993 的 live inet6 假设已被本机 Microsoft 单变量否决。

文件层矛盾仍值得在配置合成设计中清理，但不能再作为当前 Microsoft 故障的高优先根因。Microsoft 已进一步定位到主 DoH 回答触发 `fallback-filter`、随后 fallback 无可用结果；详见 `MACOS_MICROSOFT_DNS_FALLBACK_AB.md`。

尚未证明：

- 该文件层矛盾是否会影响其他系统、IPv6 开启场景或不同 Mihomo 版本。
- Apple 原生后台故障是否与 Microsoft 使用同一 DNS fallback 路径。
- 最终 DNS policy 的域名覆盖和产品配置边界。

因此此证据不能单独触发 Phase 3 的 TUN IPv6 代码修改。Windows 仍需实机完成单变量复现和 rule trace；Apple 原生后台也必须独立验证，不能直接套用 Microsoft 三域结论。

## 用户编辑后的规则序列复核

用户修正 `cloud.microsoft` 规则并重新导入后，`compare_profile_effective_rules.rb` 证明：raw/effective 均为 8055 条规则，规则顺序 SHA 完全一致，sequence/multiset 相等，raw-only/effective-only 均为 0；正确 suffix 两边各 1 条且在唯一最后 `MATCH` 前。该结果只证明规则导入完整，不证明 TUN DIRECT 路径可用。详情见 `MACOS_MICROSOFT_FUNCTION_BASELINE.md`。
