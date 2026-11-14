# FlClash 0.8.94 · othercat YAML 定制版 4

基于官方 `v0.8.94`（`7e7f1f89f363c31bbb7aa5af3f34a8b5c32a7a19`），
应用内部构建号为 `2026111504`。目标为 Apple Silicon macOS，以及 Windows 10/11 x64。
保留上游的系统要求及安装方式；Windows ARM64 不在本次构建范围内。

本版保留从配置到内核的字段传递修复：`tun.auto-detect-interface: false` 在读取、
重新载入后仍为 `false`。同时兼容旧内核 JSON 中的 `AutoDetectInterface` 名称。
配置未指定该字段时沿用上游内核默认值 `true`。修复适用于标准配置和脚本覆写后的配置。

显式提供 `tun.stack` 时同样保留 YAML 值；未提供时沿用应用界面的选择。
这允许配置携带 `stack: gvisor`，避免在原生载入时被桌面默认的 mixed 覆盖。
本机 Syncthing 实测：mixed 下认证公告请求超时，关闭 TUN 或改为 gVisor 后恢复；
IPv6 没有上游路由的情况另行记录，不以一次 IPv4 成功推断所有网络环境。

同时修复全量 TUN 与其他 VPN 的出口选择：开启自动识别时，先查询目标地址的系统路由，
识别系统动态下发的 VPN 路由；发现出口仍为本应用 TUN 时，继续使用上游的物理出口
回退和防回环检查。macOS 使用原生路由套接字，Windows 使用 `GetBestInterfaceEx`。
无需固定网卡名，不改动核心子模块，也不替换显式指定的节点出口网卡。

全量 TUN 应保留 `tun.auto-detect-interface: true`，配合 `route-exclude-address`、
DNS 和 DIRECT 规则提供 VPN 兼容。`false` 仍按 YAML 生效，但它关闭了自动绑定出口；
同时开启 `auto-route` 时需要另行提供有效出口或路由，否则可能发生回环断网。
第一版仅修复了字段传递，不能据此推断该组合可用于全量 TUN。

该选项控制内核是否自动绑定出口网卡。需要和实际 VPN、DNS、路由及代理规则一起配置；
客户端不会把某一家 VPN 或公司域名硬编码进产品。用户的节点、订阅和私人 YAML 不随发行物提供。

每份构建附带 `BUILD-INFO.json` 和 `SHA256SUMS`，可核对源码提交、平台和文件摘要。
产物名称中的 `othercat-yaml4` 用于区分官方版及此前版本。使用官方在线更新会替换本定制修复。

同一份 YAML 可以把旧版 Clash 能读取的节点、分组和 DNS 策略写在标准字段，
把额外桌面配置写在顶层 `x-flclash-desktop`。定制版在 macOS/Windows 的原生
校验及读取入口展开该字段，再交给上游配置解析器；没有扩展段的配置保持原有行为。
其他客户端只读取标准字段。旧版 Clash 不支持的节点类型不能直接放进标准 `proxies`。

扩展格式如下，示例使用虚构节点：

```yaml
proxies:
  - {name: shared, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: example}
proxy-groups:
  - {name: choose, type: select, proxies: [shared]}
dns:
  nameserver-policy:
    '+.example.com': https://dns.example/dns-query
x-flclash-desktop:
  proxies: # 追加桌面节点；名称不得与公共节点重复
    - {name: desktop, type: vless, server: example.net, port: 443, uuid: 00000000-0000-0000-0000-000000000000}
  proxy-order: [desktop, shared] # 可选，必须恰好覆盖全部合并后的节点
  proxy-groups: # 可选，整体替换公共分组，以保留桌面的成员、顺序及默认选择
    - {name: choose, type: select, proxies: [desktop, shared]}
  dns:
    nameserver-policy: # 按域名覆盖公共策略，保留其他 DNS 设置
      '+.example.com': [https://dns.example/dns-query, system]
```

扩展只支持以上四个字段；无效类型、重复节点及不完整的顺序表会明确报错，
不会静默丢弃。手机仍需按各自客户端配置系统 VPN；此扩展不为手机提供桌面 TUN 功能。
私有配置仅在本机验证，不上传到转换服务或源码仓库。

开发验证：

```sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test --reporter expanded
(cd core && CGO_ENABLED=0 go test -v . ./routeiface ./profilecompat)
dart setup.dart macos --env stable
# Windows 主机：dart setup.dart windows --env stable --targets zip
```

发行工具链沿用上游 CI 的 Flutter `3.44.4`、Go `1.26.4`。
macOS 使用 Xcode `26.3` 构建，运行系统下限由上游平台配置决定。
Windows CI 优先使用 Visual Studio 2026。构建成功与真实 VPN/Windows 10 实机验收分别记录在
[Issue #1](https://github.com/othercat/FlClash/issues/1)；未执行的验证不代表通过。

Windows 使用完整的免安装 ZIP。解压到固定目录后运行其中的 `FlClash.exe`，
保持同目录的 DLL、内核和 TUN 服务组件完整；首次开启 TUN 时按应用提示完成系统授权。

此前未完成的调查与脚本保存在
[`archive/20261114-unfinished-customization`](https://github.com/othercat/FlClash/tree/archive/20261114-unfinished-customization)。
