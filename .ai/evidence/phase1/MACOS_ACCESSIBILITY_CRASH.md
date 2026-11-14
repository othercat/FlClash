# macOS Accessibility 托盘探测崩溃

状态：已定位。此记录只保留系统版本、异常类型、公开符号和对应开源代码；不复制用户路径、环境变量或配置内容。

## 事件

- 时间：2026-08-03 10:17:24（本地时间）。
- 被测程序：FlClash 0.8.93，build `2026052901`。
- 系统：macOS 15.7.7 (`24G720`)。
- 触发操作：Codex 通过 macOS Accessibility 对当前菜单栏状态项执行 `press`。
- 结果：FlClash 退出，Codex 通讯随之中断；用户随后手动恢复。

该操作不属于有效 Phase 1 场景，不计入 A1–A7 或 TUN 结果。

## 崩溃报告白名单证据

- exception：`EXC_BREAKPOINT (SIGTRAP)`。
- termination：`SIGNAL`, code `5`, `Trace/BPT trap: 5`。
- faulting thread：thread 0 / main queue。
- 顶层公开符号：`tray_manager` 的
  `specialized TrayManagerPlugin.statusItemButtonClicked(sender:) + 284`。
- 后续调用栈依次包含 AppKit 的 `performClick`、
  `NSStatusBarButtonCell performClick`、`accessibilityPerformPress`、
  `NSAccessibilityMockStatusBarItem` 与 HIServices Accessibility 调用。

因此，这次 SIGTRAP 与 Accessibility 模拟托盘点击直接对应，不是
FlClashCore、TUN、系统代理或网络请求栈中的崩溃。

## 精确源码对应

FlClash v0.8.93 锁定的 `tray_manager` submodule SHA 为
`6163dc8f62f6f177a85072b0e1e2eee76fed54f0`。该版本的 macOS 回调包含：

```swift
@objc func statusItemButtonClicked(sender: NSStatusBarButton) {
    let event = NSApp.currentEvent!
    // ...
}
```

Accessibility 的 `press` 不是鼠标事件。结合主线程顶部函数和
`EXC_BREAKPOINT`，可将直接原因定位为该回调强制解包
`NSApp.currentEvent`；当 Accessibility action 没有 current event 时触发
Swift trap。函数中另一个强制解包 `methodName!` 受 `methodName != nil` 条件保护，
不符合这次调用路径。

公开源码：
[`TrayManagerPlugin.swift`](https://github.com/leanflutter/tray_manager/blob/6163dc8f62f6f177a85072b0e1e2eee76fed54f0/packages/tray_manager/macos/Classes/TrayManagerPlugin.swift#L81-L82)

## 后续约束

- 不再对用户正在运行的 FlClash 实例执行 Accessibility 托盘点击。
- 继续只用日志、进程与已脱敏 effective config 做只读诊断。
- 如以后修复此独立插件缺陷，应将 `currentEvent` 改为安全可选处理并补充
  Accessibility action 回归；它不作为当前 Phase 1 基线修改的一部分。
