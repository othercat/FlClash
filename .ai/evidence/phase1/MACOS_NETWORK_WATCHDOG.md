# macOS Phase 1 network watchdog validation

验证日期：2026-08-03（Asia/Shanghai）

## 结论与当前使用边界

`.ai/scripts/macos_network_recovery_watchdog.sh` 已通过真实 live Core 恢复门禁。最终后端是 Codex/终端中的专用持久 PTY 前台进程，不是 `nohup` 或 `launchd`：

- worker 跨后续工具调用持续运行，不依赖模型继续发送命令；
- worker 保留当前 Codex Accessibility 责任链，能操作 FlClash 普通 Flutter 窗口；
- runtime 目录权限为 `0700`，状态与日志文件为 `0600`；
- runtime 只保留白名单布尔值、TUN stack 枚举、PID、计时值和安全事件，不保存 controller secret、完整配置、代理地址、bypass domain、节点或账户数据；
- TUN PATCH 需要同时满足 `controller_verified=true`、`risk_started=true`、watchdog PID 存活；
- controller 只允许 loopback/本地 Unix socket，secret 只经 `curl --config -` 的 stdin 使用，不进入参数、文件或输出。

持久 PTY 必须保持前台会话存活；关闭该执行会话会解除保护。每次启动后应从另一会话确认 `ready=true`，再开始网络实验。

2026-08-03 用户决定：不再为罕见 fallback 继续投入调试时间。后续 watchdog 只是 best-effort 的短 timeout 保护，不是不会断线的保证，也不是 Phase 1 的开工门槛。若 Codex 反复显示重新连接，用户在第 3 次提示后手动恢复；恢复后 Agent 必须重新识别 `/Applications/FlClash.app` 当前实例、Core PID 与 live 状态，不能复用本文记录的旧 PID。

## 被否决的后端

- 普通 `nohup`：会在宿主执行命令结束后被清理，不能跨工具会话存活。
- `launchctl submit`：能跨父命令存活，但脱离 Codex TCC 责任链后，AX 白名单扫描明确返回 `accessibility_permission=false`，无法恢复普通窗口中的持久化开关。因此没有把 launchd 方案冒充完整恢复。

## 最终通过的真实闭环

### Controller 生命周期，不打开 risk

- watchdog：`05:07:06Z` 启动，timeout 60 秒；
- `05:07:33Z`：loopback GET 证明 live TUN 与测试前一致；
- `05:08:07Z`：timeout；日志明确记录未打开 risk，跳过 TUN PATCH；
- `05:08:11Z`：系统代理偏好和 HTTP/HTTPS/SOCKS/PAC enable 白名单恢复；
- `05:08:18Z`：临时 external controller 关闭；
- `05:08:23Z`：窗口、页面、AX 与完整白名单验证通过。

### 同值 TUN PATCH

- watchdog：`05:12:22Z` 启动，timeout 60 秒；
- controller GET 与 `set-tun true --stack mixed` 均返回 `tun_enable=true`、`tun_stack=mixed`；
- `05:13:23Z` timeout 后，worker 自身执行 TUN 恢复并 GET 验证；
- `05:13:40Z`：完整白名单恢复通过。

### 真实 TUN off → timeout → on

- watchdog：`05:14:21Z` 启动，timeout 60 秒；
- `set-tun false` 后 controller GET 确认 `tun_enable=false`；系统 HTTP/HTTPS/SOCKS enable 保持 true，PAC false；
- `05:15:22Z` timeout 后，worker 将 live TUN 恢复为原来的 `true/mixed` 并 GET 验证；
- `05:15:38Z`：external controller 已关闭，9090 不监听，窗口可见、AX=false，持久偏好和代理 enable 白名单均为原值；
- FlClash / FlClashCore PID 在测试前后保持 `49168` / `49170`，没有依赖重启恢复。

## 调试中发现并修正的边界

- Mihomo `/configs` 返回的 stack 为 `Mixed`；helper 统一转小写后再与 FlClash 枚举比较。
- `AXUIElementSetAttributeValue` 可能返回失败码但最终状态已生效；helper 以最多 5 秒的最终状态轮询为准。
- Flutter 页面切换可能重置 `AXEnhancedUserInterface`；关键导航失败后会重新启用并重试。
- 曾在 worker 运行期间修改 watchdog 文件，导致 Bash 延迟读取新旧文件边界后退出。该轮在退出前已完成 live TUN 恢复并 GET 验证，随后由当前会话关闭 controller。最终通过的三轮均使用冻结脚本；今后 worker 存活期间禁止修改 watchdog/helper 文件。

## 05:43 fallback 失败事件

后续 tray menu 只读探索中，worker 在恢复 external controller 页面时失败。旧 fallback 随即停止 FlClash/Core 并清除代理，但没有重新打开测试前正在运行的 App。用户之后发现 FlClash 未运行并手动恢复；新进程 PID 为 `3094` / `3096`。该事件证明早期 fallback 只能恢复直连，不能恢复原运行状态，不能视为合格的 timeout 恢复。

处理结果：

- 立即停止后续网络/tray 实验；
- 手动关闭遗留 external controller，确认 9090 关闭、TUN/代理/窗口/AX 回到原状态；
- fallback 已改为：清除失效代理后，如果测试前 App/Core 正在运行，则固定从 `/Applications/FlClash.app` reopen，最多等待 60 秒，再重试 live TUN、UI、controller 和代理白名单恢复；
- 若重试仍失败，App/Core 保持已打开，日志明确记录 `recovery incomplete after restart`，不再把用户留在停止状态；
- 该新增 fallback 尚未通过故意杀进程的实机验证，且按用户决定不再安排这种破坏性验证。后续直接回到真实功能矩阵；若断连则接受用户手动恢复。
