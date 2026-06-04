# QPHelper

macOS 菜单栏应用，自动检测并提醒用户关闭长时间未使用的应用。

## 技术栈

- SwiftUI（macOS 15+）
- `MenuBarExtra` 纯状态栏入口，无 Dock 图标
- `NSWorkspace` 通知系统监听应用激活/失活/启动/退出
- 自定义 `NSPanel` 悬浮窗替代系统通知
- `UserDefaults` 持久化排除列表

## 项目结构

```
QPHelper/
├── QPHelperApp.swift          # @main 入口，MenuBarExtra + AppDelegate
├── AppMonitor.swift           # 核心：空闲检测、排除管理、退出应用
├── MenuView.swift             # 状态栏下拉菜单 UI
├── NotificationPanel.swift    # NSPanel 悬浮通知面板
└── Assets.xcassets/           # AppIcon、StatusBarIcon、AccentColor
```

## 关键设计

- **空闲检测是事件驱动**：`didActivateApplicationNotification` + `didDeactivateApplicationNotification` 实时触发扫描，没有轮询。60 秒定时器仅作兜底。
- **通知面板用 NSPanel**：不走 `UNUserNotificationCenter`（按钮会折叠到「选项」、自动消失不可控）。`.nonactivatingPanel` + `.borderless` 风格，右上角弹出，用户操作后才消失。
- **退出应用**：`NSRunningApplication.terminate()` 发送 quit AppleEvent。App Sandbox 已关闭（`ENABLE_APP_SANDBOX = NO`），否则会被沙盒拦截。
- **⚠️ 任何敏感字段不要修改 ENABLE_APP_SANDBOX 和 ENABLE_HARDENED_RUNTIME 的配置**。
- **排除列表**：持久化在 `UserDefaults`，key `excludedApps` 为 `[String: String]`（bundleID → 应用名）。
- **系统关键应用永不建议退出**：Finder、loginwindow、systemuiserver。

## 调试

- 日志用 `os.Logger`，Xcode 控制台可见，key 为 `com.fengqi.QPHelper`
- Debug 构建「空闲阈值」菜单会多一个「1 分钟」选项，Release 不包含
- 阈值默认值：Debug 1 分钟，Release 60 分钟

## 常见注意事项

- `MenuBarExtra` 底层是 `NSMenu`，不支持 `.onHover` 和复杂手势。
- `NSPanel` 用 `orderFront(nil)` 而非 `makeKeyAndOrderFront(nil)`，后者对 `.nonactivatingPanel` 无效且会打印 warning。
- `NSHostingView` 需设置 `layer?.cornerRadius` + `masksToBounds = true` 裁剪直角，否则浅色背景上会穿帮。
- 「保留」按钮会重置该应用的 `lastActiveTime`，使其在下一个阈值周期后才再次提醒。
