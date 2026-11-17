# FlClash 0.8.94 · othercat 桌面定制版

基于官方 `v0.8.94`（`7e7f1f89f363c31bbb7aa5af3f34a8b5c32a7a19`），
最新 Mac 构建号为 `2026111702`，Windows 便携包仍为 `2026111504`。
目标为 Apple Silicon macOS，以及 Windows 10/11 x64。
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
该出口识别修复位于桌面桥接层，无需固定网卡名，也不替换显式指定的节点出口网卡。

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

## Fishport 桌面便携包

含 Fishport 的桌面版本在读取带有 `x-fishport-protocol: phantom` 的 SOCKS5 节点时，
由 FlClash 启动同包的普通用户进程 `FPPhantomCore`。在共享 YAML 中使用稳定的订阅节点 ID，
或官方订阅显示名中第一个竖线前的唯一名称。客户端在内存中为这些节点填写本次的回环端口、
证书指纹及随机口令，手动选择和 URL 测速使用同一套节点。官方库负责 Phantom 的实际 TCP 连接。
每台设备只从当前登录用户的主目录读取 UTF-8 文件。macOS 使用 `~/fishport-pass.txt`，
Windows 使用 `%USERPROFILE%\fishport-pass.txt`。第一行填写账号，第二行填写密码。
缺文件、不能读取、格式错误或官方拒绝账号时，节点卡片显示具体提示。点按或悬停可查看路径和填写方式。
新增或更正文件后客户端自动重试，登录成功后恢复正常的节点测速显示。
助手的设备状态位于 FlClash 应用数据目录，退出客户端时助手随之退出。

解压后运行 `FlClash.app` 或 `FlClash.exe`，自行导入个人 YAML。
Mac 包使用本地 ad-hoc 签名。Windows 包携带 x64 微软运行库。两端均无需 Python 或开机服务。

打包机使用与当前 Flutter 客户端匹配的构建目录。Apple Silicon 上从 `services/phantom`
执行 `CGO_ENABLED=1 GOARCH=arm64 go build -trimpath -o FPPhantomCore .`；
Windows x64 助手可用 `GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-H=windowsgui" -o FPPhantomCore.exe .` 构建。
打包输入目录包含对应助手、Fishport 1.2.52 的官方平台库（`libnfxcore.dylib` 或
`nfxcore.dll`）、官方的 `rd.bin`、`rs.bin`、`api-transport-bundle.b64` 与
`airport-id`。Windows 输入还包含 Microsoft VC++ x64 Redistributable 中的
`msvcp140.dll`、`vcruntime140.dll` 和 `vcruntime140_1.dll`。

在构建 Mac 上执行 `dart tool/package_fishport.dart --help` 查看参数。
指定 `--platform`、`--app`、`--runtime` 和新的 `--out` ZIP 路径。
打包器在临时目录里装配应用副本，交付 ZIP 仅含客户端及其运行组件。

## Mac 增强热点共享与旁路由

`2026111702` 提供两个独立的网络设置项，均默认开启；用户手动关闭的选择会保存。
条件未就绪时显示等待，节点切换、监听重新开启和核心重新连接会保留共享意图。

- **增强热点共享**：在 macOS 互联网共享和 FlClash TUN 就绪后，接入 Mac 热点的
  客户端可使用自动获得的网关与 DNS，沿用 FlClash 的节点和分流，无需填写 HTTP 代理。
- **旁路由模式**：自动识别当前私有局域网，也可选择本机地址。同一局域网的客户端
  将网关和 DNS 设置为页面显示的 Mac IP 地址即可使用；不要求开启 macOS 互联网共享。
  IPv4 可独立工作；局域网、TUN 和 DNS 均具备 IPv6 条件时提供 IPv6。客户端的 IPv6
  默认网关也必须指向 Mac，仅修改 IPv4 网关不会接管另一个路由器提供的 IPv6 路径。

两种模式复用原生核心，不依赖 Python 或额外开机服务，不接管路由器 DHCP/RA。
仅维护自身 PF anchors，保留 aTrust 规则和主机流量排除。运行时保持五秒恢复周期，
等待条件时降为六十秒检查；缓存共享配置与桥接信息并读取原生 PF/路由状态，减少
稳定状态的外部命令。自动测速只合并同节点、同测试契约下仍在进行的请求，不缓存
完成结果；手动测速及动态代理组保持独立，测速间隔和 lazy 设置不变。

核心子模块固定到 `othercat/Clash.Meta` 的已发布提交，集成分支为 `FlClash-custom`。
该分支保留本版实际验证的上游基线，不自动跟随其他上游分支。首次获取源码使用：

```sh
git clone --recurse-submodules https://github.com/othercat/FlClash.git
```

当前源码与 `2026111702` 已验证的 65 个改动文件摘要一致；447 项 Flutter 测试、
原生核心测试及共享/测速竞态检查通过。Mac 热点网页、用户切换到可用节点后的 App Store
更新及两种模式的 DNS 后端检查通过。新版 aTrust 连接共存/退出恢复、真实旁路由客户端、
IPv6 端到端及其他实体设备仍待验收，不能由编译或本机 DNS 检查推断通过。
Windows 包尚不包含本轮 Mac 网关功能。进展见 [#2](https://github.com/othercat/FlClash/issues/2)
和 [#3](https://github.com/othercat/FlClash/issues/3)，两项保持开放。
