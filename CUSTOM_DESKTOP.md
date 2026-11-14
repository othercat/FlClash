# FlClash 0.8.94 · othercat YAML 定制版 1

基于官方 `v0.8.94`（`7e7f1f89f363c31bbb7aa5af3f34a8b5c32a7a19`），
应用内部构建号为 `2026111401`。目标为 Apple Silicon macOS，以及 Windows 10/11 x64。
保留上游的系统要求及安装方式；Windows ARM64 不在本次构建范围内。

本版修复从配置到内核的字段传递：`tun.auto-detect-interface: false` 在读取、
重新载入后仍为 `false`。同时兼容旧内核 JSON 中的 `AutoDetectInterface` 名称。
配置未指定该字段时沿用上游内核默认值 `true`。修复适用于标准配置和脚本覆写后的配置。

```yaml
tun:
  auto-detect-interface: false
```

该选项控制内核是否自动绑定出口网卡。需要和实际 VPN、DNS、路由及代理规则一起配置；
客户端不会把某一家 VPN 或公司域名硬编码进产品。用户的节点、订阅和私人 YAML 不随发行物提供。

每份构建附带 `BUILD-INFO.json` 和 `SHA256SUMS`，可核对源码提交、平台和文件摘要。
产物名称中的 `othercat-yaml1` 用于区分官方版。使用官方在线更新会替换本定制修复。

开发验证：

```sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test --reporter expanded
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
