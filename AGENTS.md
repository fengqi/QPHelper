# QPHelper

macOS 菜单栏应用，自动检测并提醒用户关闭长时间未使用的应用。

## 技术栈

- SwiftUI（macOS 15+）
- `MenuBarExtra` 纯状态栏入口，无 Dock 图标（`LSUIElement = YES`）
- `NSWorkspace` 通知系统监听应用激活/失活/启动/退出
- 自定义 `NSPanel` 悬浮窗替代系统通知
- `UserDefaults` 持久化排除列表、弹框动作
- `SMAppService` 开机启动

## 项目结构

```
QPHelper/
├── QPHelperApp.swift          # @main 入口，MenuBarExtra + AppDelegate
├── AppMonitor.swift           # 核心：空闲检测、排除管理、退出应用、离席处理
├── MenuView.swift             # 状态栏下拉菜单 UI
├── NotificationPanel.swift    # NSPanel 悬浮通知面板
├── Helpers.swift              # 共享工具函数（formatDuration, AppIconView）
└── Assets.xcassets/           # AppIcon、StatusBarIcon
```

## 共享组件

- `formatDuration(_:)` — Helpers.swift，秒 → "X 分钟" / "X 小时"
- `AppIconView(bundleID:)` — Helpers.swift，从运行中应用取图标，未找到显示占位符
- MenuView 和 NotificationPanel 均使用以上共享组件，不重复定义

## 关键设计

- **空闲检测是事件驱动**：`didActivateApplicationNotification` + `didDeactivateApplicationNotification` 实时触发扫描。60 秒定时器仅兜底。`!app.isActive` 确保前台应用永不误判。
- **通知面板用 NSPanel**：`.nonactivatingPanel` + `.borderless` 风格，右上角弹出，按钮平铺可见，用户操作后才消失。`NotificationActionButtonStyle` 胶囊按钮 + hover 效果。
- **退出应用**：`NSRunningApplication.terminate()`，Sandbox 已关闭。
- **锁屏/休眠**：暂停计时不弹面板；解锁/唤醒后重置全部 `lastActiveTime` 和 `notifiedApps`。
- **排除列表**：`UserDefaults` key `excludedApps`，`[String: String]`（bundleID → 应用名）。
- **系统关键应用永不建议退出**：Finder、loginwindow、systemuiserver。
- **图标内存**：`IdleAppInfo` 不持有 `NSImage`，图标通过 `AppIconView` 按需查找。
- **日志**：`logInfo`/`logDebug` 在 Release 构建中为 no-op，`logError` 保留。

## 调试

- Debug 构建「空闲阈值」菜单包含「1 分钟」选项，Release 不包含
- 阈值默认值：Debug 1 分钟，Release 60 分钟
- `orderFront(nil)` 而非 `makeKeyAndOrderFront`（后者对 `.nonactivatingPanel` 无效）

## 注释风格

- 面向 Go/Java 程序员，用类比解释 Swift 特有语法（如 `@Published` ≈ RxJava BehaviorSubject、`ObservableObject` ≈ Vue reactive）
- 每个文件、公开类型、公开方法必须有注释
- **已有注释不得删除**，只在逻辑变更时同步更新
- 日志辅助函数（`logInfo`/`logDebug`/`logError`）必须保留，不得移除或改写为裸 `print`/`NSLog`
- 日志中的 emoji 前缀（`▶`、`🔔`、`🚫`、`⚠️` 等）不得移除

## 注意事项

- `MenuBarExtra` 底层是 `NSMenu`，不支持 `.onHover` 和滚轮
- `NSMenu` 列表超出 10 条用「... 还有 N 个」子菜单展开
- `NSPanel` 的 `NSHostingView` 需设置 `layer?.cornerRadius` + `masksToBounds = true`
- 「保留」重置 `lastActiveTime`，下个阈值周期再提醒
- 「弹框动作: 打开应用」点击面板图标/名称区域打开对应应用
