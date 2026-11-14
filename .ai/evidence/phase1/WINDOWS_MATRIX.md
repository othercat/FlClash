# Windows Phase 1 采集表

状态：**未实机验证**。当前环境为 macOS；本表不包含推测结果。

Windows 主机上的只读采集命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .ai\scripts\windows_phase1_capture.ps1 -Scenario W1
```

脚本只记录网络结构计数、公开测试域名的 DNS 成功/失败、HTTP 状态与耗时、FlClash/FlClashCore 资源摘要；不记录 adapter 名称、MAC、IP、网关、DNS 返回地址、HTTP header/body 或任何 profile 内容。

## 单变量矩阵

每行开始前固定同一网络、同一节点、同一策略组选择。用户手动改变且只改变“变量”列，完成后手动恢复；脚本本身不做任何系统或 FlClash 写操作。

| ID | 基线 | 唯一变量 | Bing | Microsoft Account | Microsoft 365 | Azure CDN | Store | rule trace | 状态 |
|---|---|---|---|---|---|---|---|---|---|
| W1 | 系统代理 | TUN 关 | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 | 未实机验证 |
| W2 | 原 effective config | TUN 开 | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 | 未实机验证 |
| W3 | W2 | 仅清空 `tun.inet6-address` | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 | 未实机验证 |
| W4 | W2 | `stack=mixed` → `system` | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 | 未实机验证 |
| W5 | W2 | `stack=mixed` → `gVisor` | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 | 未实机验证 |
| W6 | W2 | `strict-route=false/未设` → `true` | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 | 未实机验证 |
| W7 | W2 | Fake-IP → redir-host | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 | 未实机验证 |
| W8 | W2 | 两个 Microsoft 组固定 DIRECT | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 | 未实机验证 |
| W9 | W8 | 两个 Microsoft 组固定同一代理 | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 | 未实机验证 |
| W10 | W2 | 浏览器 QUIC 暂停/强制 TCP | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 | 未实机验证 |
| W11 | W2 | MTU → 1500 | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 | 未实机验证 |
| W12 | W2 | MTU → 1400 | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 | 未实机验证 |

## 每行必须补充

- Windows 版本/build、CPU 架构、FlClash/tray_manager/Mihomo 精确 SHA。
- effective config 的白名单脱敏摘要。
- `Get-NetRoute` 的 IPv4/IPv6/default route 计数，不记录具体地址。
- 代表连接的 rule trace，节点名和服务器值脱敏。
- Microsoft Store 下载是否保持正常。
- 测试结束后原始开关是否恢复、网络是否恢复。

## 禁止项

- 不自动写注册表或系统 DNS。
- 不关闭 Windows Firewall。
- 不把 Microsoft 全量绕过 TUN 当作修复。
- 不在没有 rule trace 的情况下把失败归因给某个策略组。
