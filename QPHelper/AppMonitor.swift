import AppKit
import Combine
import OSLog
import ServiceManagement

// os.Logger：Apple 推荐的日志 API，输出到 Console.app 和 Xcode 控制台
// 条件编译：Debug 构建启用 logger，Release 构建完全不生成日志代码
#if DEBUG
private let logger = Logger(subsystem: "com.fengqi.QPHelper", category: "AppMonitor")
#endif

// 弹框弹出时可附带执行的动作
enum PanelAction: String, CaseIterable {
    case none = "无"
    case activate = "打开应用"
}

// ObservableObject = Go 的可观察对象 / Java 的 Observable
// 遵循此协议的 class 会被 SwiftUI View 订阅，@Published 属性变化时 View 自动刷新
// 类似 Vue 的 reactive() 或 React 的 useState 机制，但在 class 上集中管理
final class AppMonitor: ObservableObject {
    // @Published：属性包装器，值变化时通知所有观察的 View 重新渲染
    // 内部原理是 Combine 框架的 Publisher，类似 RxJava 的 BehaviorSubject
    @Published var idleApps: [IdleAppInfo] = []       // 当前超时空闲的应用列表
#if DEBUG
    @Published var idleThresholdMinutes: Int = 1       // Debug 默认 1 分钟（方便调试）
#else
    @Published var idleThresholdMinutes: Int = 60      // Release 默认 60 分钟
#endif
    @Published var monitoredAppCount: Int = 0           // 当前正在监控的前台应用数量
    @Published var excludedApps: [String: String] = [:] // 用户排除的应用 [BundleID: 应用名]
    @Published var panelAction: PanelAction = .none     // 弹框时的附加动作

    // 开机启动开关，通过 SMAppService 读写
    // computed property：get/set 像 Java 的 getter/setter，但语法上像直接访问字段
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                logError("开机启动设置失败: \(error.localizedDescription)")
            }
        }
    }

    // [BundleID: Date] — 记录每个应用最后一次活跃的时间戳
    private var lastActiveTime: [String: Date] = [:]
    // 已经弹过面板的应用集合，避免对同一个应用反复弹出
    private var notifiedApps: Set<String> = []
    // 当前正在显示的面板对应的 BundleID（用于追踪是否需要关闭旧面板）
    private var currentPanelBundleID: String?
    // 兜底定时器：事件驱动之外的保底扫描（60 秒一次）
    private var timer: Timer?
    // Combine 订阅回收袋：持有所有订阅引用，防止被 GC 回收
    // Set<AnyCancellable> 类似 Go 中保存 context.CancelFunc 的数组
    private var cancellables = Set<AnyCancellable>()
    // 本应用的 Bundle ID，扫描时排除自身
    private let myBundleID = Bundle.main.bundleIdentifier ?? ""
    // 悬浮通知面板实例
    private let panel = NotificationPanel()
    // 用户是否处于离席状态（锁屏/休眠）
    private var isAway = false

    // 系统关键应用：这些应用永不建议退出
    // Finder = 桌面和文件浏览器（com.apple.finder）
    // loginwindow = 登录窗口
    // systemuiserver = 右侧菜单栏进程
    private let systemCriticalApps: Set<String> = [
        "com.apple.finder",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
    ]

    // 空闲应用信息
    // Identifiable：要求有 id 字段，SwiftUI 的 ForEach 需要 id 做 diff 追踪
    // 类似 RecyclerView 中的 stable ID 概念
    struct IdleAppInfo: Identifiable {
        let id = UUID()               // UUID() 生成随机唯一标识
        let bundleIdentifier: String   // 应用 Bundle ID，如 com.apple.Safari
        let appName: String            // 应用显示名，如 "Safari"
        let lastActive: Date           // 最后一次活跃的时间
        let idleDuration: TimeInterval  // 已空闲时长（秒），TimeInterval 是 Double 的类型别名
    }

    init() {
        // Combine 数据流：监听 idleThresholdMinutes 的变化
        // $idleThresholdMinutes：@Published 属性的投影，类型是 Publisher（发布者）
        // dropFirst()：跳过初始值（初始值不需要触发清理）
        // sink：订阅，类似 RxJava 的 subscribe
        // [weak self]：弱引用捕获，防止闭包持有 self 造成循环引用（类似 Android 的 WeakReference）
        // store(in: &cancellables)：订阅放入回收袋，防止被释放
        $idleThresholdMinutes.dropFirst().sink { [weak self] _ in
            self?.notifiedApps.removeAll()
            self?.checkIdleApps()
        }.store(in: &cancellables)

        // 从 UserDefaults 加载持久化的排除列表
        excludedApps = UserDefaults.standard.dictionary(forKey: "excludedApps") as? [String: String] ?? [:]

        // 加载弹框动作偏好
        if let raw = UserDefaults.standard.string(forKey: "panelAction"),
           let action = PanelAction(rawValue: raw) {
            panelAction = action
        }

        // 弹框动作变化时持久化
        $panelAction.dropFirst().sink {
            UserDefaults.standard.set($0.rawValue, forKey: "panelAction")
        }.store(in: &cancellables)
    }

    // 判断一个应用是否应该被跟踪（排除自身和用户手动排除的应用）
    private func shouldTrack(_ bundleID: String) -> Bool {
        bundleID != myBundleID && excludedApps[bundleID] == nil
    }

    // 开始监控：注册系统事件监听 + 初始化运行中应用的时间戳
    func start() {
        // 初始化：给当前所有前台应用设置"当前时间"作为初始活跃时间
        // activationPolicy == .regular = 前台应用（有 Dock 图标、有窗口的普通应用）
        // .prohibited = 后台服务，.accessory = 菜单栏应用
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, app.activationPolicy == .regular else { continue }
            lastActiveTime[bundleID] = Date()
        }

        // 注册系统事件监听
        // NSWorkspace.notificationCenter：macOS 工作空间事件总线的分布式通知中心
        // addObserver(_:selector:name:object:) = 注册事件回调
        // selector 是 ObjC 的消息传递机制，Swift 用 #selector 语法引用方法
        let nc = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, Selector)] = [
            (NSWorkspace.didActivateApplicationNotification, #selector(handleActivation)),
            (NSWorkspace.didDeactivateApplicationNotification, #selector(handleDeactivation)),
            (NSWorkspace.didLaunchApplicationNotification, #selector(handleLaunch)),
            (NSWorkspace.didTerminateApplicationNotification, #selector(handleTerminate)),
            // 锁屏和休眠事件：标记用户离开状态，暂停计时
            (NSWorkspace.screensDidSleepNotification, #selector(handleAway)),
            (NSWorkspace.willSleepNotification, #selector(handleAway)),
            (NSWorkspace.screensDidWakeNotification, #selector(handleReturn)),
            (NSWorkspace.didWakeNotification, #selector(handleReturn)),
        ]
        for (name, sel) in events {
            nc.addObserver(self, selector: sel, name: name, object: nil)
        }
        // 锁屏/解锁用分布式通知中心（DistributedNotificationCenter），跨进程传播
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleAway), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleReturn), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)

        // 兜底定时器：每 60 秒扫描一次，防止事件驱动的极端情况下漏检测
        // Timer.scheduledTimer 类似 Java 的 ScheduledExecutorService.scheduleAtFixedRate
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkIdleApps()
        }

        logInfo("监控已启动，当前跟踪 \(self.lastActiveTime.count) 个前台应用")
        checkIdleApps()
    }

    // MARK: - 工作空间事件处理
    // @objc：让 Swift 方法暴露给 ObjC 运行时（NotificationCenter 的 selector 机制需要）

    // 应用被激活（切到前台）→ 重置空闲计时
    @objc private func handleActivation(_ notification: Notification) {
        // NSWorkspace.applicationUserInfoKey：从通知的 userInfo 字典中取 NSRunningApplication 对象
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier, shouldTrack(bundleID) else { return }
        lastActiveTime[bundleID] = Date()
        notifiedApps.remove(bundleID)
        logDebug("▶ 前台切换: \(app.localizedName ?? bundleID)")

        // 如果当前正在显示该应用的面板，关闭面板（用户已经切回去了）
        if bundleID == currentPanelBundleID {
            panel.close()
            currentPanelBundleID = nil
        }
        checkIdleApps()
    }

    // 应用失去激活（退到后台）→ 记录失活时间作为空闲计时起点
    @objc private func handleDeactivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier, shouldTrack(bundleID) else { return }
        lastActiveTime[bundleID] = Date()
        checkIdleApps()
    }

    // 新应用启动 → 加入跟踪
    @objc private func handleLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier, shouldTrack(bundleID) else { return }
        // 只在首次出现时记录，避免覆盖已有数据
        if lastActiveTime[bundleID] == nil { lastActiveTime[bundleID] = Date() }
    }

    // 应用退出 → 清理所有跟踪数据
    @objc private func handleTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }
        lastActiveTime.removeValue(forKey: bundleID)
        notifiedApps.remove(bundleID)
        if bundleID == currentPanelBundleID {
            panel.close()
            currentPanelBundleID = nil
        }
    }

    // 用户离开（锁屏/休眠）→ 标记离席，关闭当前面板，暂停计时
    @objc private func handleAway(_ notification: Notification) {
        guard !isAway else { return }
        isAway = true
        if currentPanelBundleID != nil {
            panel.close()
            currentPanelBundleID = nil
        }
        logInfo("💤 用户离开，暂停计时")
    }

    // 用户回来（解锁/唤醒）→ 重置所有应用的计时
    // 锁屏期间时间流逝不代表应用闲置，全部重置避免误判
    @objc private func handleReturn(_ notification: Notification) {
        guard isAway else { return }
        isAway = false
        let now = Date()
        for key in lastActiveTime.keys { lastActiveTime[key] = now }
        notifiedApps.removeAll()
        logInfo("👁 用户回来，已重置全部计时")
        checkIdleApps()
    }

    // MARK: - 空闲检测（核心逻辑）

    private func checkIdleApps() {
        // 用户离开时不扫描（避免面板在锁屏时弹出）
        guard !isAway else { return }
        let now = Date()
        let threshold = TimeInterval(idleThresholdMinutes * 60)
        var idle: [IdleAppInfo] = []
        var regularAppCount = 0

        // 遍历所有运行中的应用，检测超时空闲
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  app.activationPolicy == .regular,      // 只关心前台应用
                  !app.isActive,                          // 当前激活的应用不判空闲
                  bundleID != myBundleID,                  // 排除本应用自身
                  !systemCriticalApps.contains(bundleID),  // 排除系统关键应用
                  excludedApps[bundleID] == nil            // 排除用户手动排除的应用
            else { continue }

            regularAppCount += 1

            // 计算空闲时长 = 当前时间 - 最后活跃时间
            // ?? 是 nil 合并运算符：左边为 nil 时用右边的值
            let lastActive = lastActiveTime[bundleID] ?? now
            let idleDuration = now.timeIntervalSince(lastActive)

            if idleDuration >= threshold {
                // 符合条件：加入空闲列表
                idle.append(IdleAppInfo(
                    bundleIdentifier: bundleID,
                    appName: app.localizedName ?? bundleID,
                    lastActive: lastActive,
                    idleDuration: idleDuration
                ))

                // 如果还没弹过面板且当前没有面板在显示，弹出新面板
                if !notifiedApps.contains(bundleID) && !panel.isShowing {
                    showPanel(for: idle.last!, withIcon: app.icon)
                    notifiedApps.insert(bundleID)
                }
            }
        }

        // 更新 @Published 属性，触发 UI 刷新
        idleApps = idle
        monitoredAppCount = regularAppCount

        // 取交集：移除已不在空闲列表中的应用的通知标记
        notifiedApps.formIntersection(Set(idle.map(\.bundleIdentifier)))

        if !idle.isEmpty {
            logInfo("🔔 空闲应用: \(idle.map { "\($0.appName)(\(formatBriefDuration($0.idleDuration)))" }.joined(separator: ", "))")
        }
    }

    // MARK: - 悬浮通知面板

    private func showPanel(for app: IdleAppInfo, withIcon icon: NSImage?) {
        // 如果有旧面板在显示，先清理
        if let old = currentPanelBundleID { notifiedApps.remove(old) }

        if panelAction == .activate {
            logInfo("⬆ 检测到空闲应用: \(app.appName) (\(app.bundleIdentifier))")
        }

        logInfo("📌 弹出面板: \(app.appName)")
        panel.show(
            appName: app.appName,
            icon: icon,
            idleDuration: app.idleDuration,
            // 闭包 = Go 的 func 字面量 / Java 的 lambda（() -> Void = 无参数无返回值）
            onQuit: { [weak self] in self?.quitApp(bundleIdentifier: app.bundleIdentifier) },
            onKeep: { [weak self] in
                // 用户点击"保留"：重置该应用的空闲计时，下个周期再提醒
                self?.lastActiveTime[app.bundleIdentifier] = Date()
                self?.notifiedApps.remove(app.bundleIdentifier)
            },
            onExclude: { [weak self] in self?.excludeApp(bundleID: app.bundleIdentifier, appName: app.appName) },
            onActivate: { [weak self] in
                // 点击面板图标/标题区域时打开该应用
                guard let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
                if runningApp.isHidden { runningApp.unhide() }
                runningApp.activate()
                logInfo("⬆ 用户点击打开: \(app.appName)")
            },
            onDismiss: { [weak self] in self?.currentPanelBundleID = nil }
        )
        currentPanelBundleID = app.bundleIdentifier
    }

    // MARK: - 排除应用

    // 将应用加入排除列表，持久化到 UserDefaults
    func excludeApp(bundleID: String, appName: String) {
        excludedApps[bundleID] = appName
        UserDefaults.standard.set(excludedApps, forKey: "excludedApps")
        lastActiveTime.removeValue(forKey: bundleID)
        notifiedApps.remove(bundleID)
        if bundleID == currentPanelBundleID { panel.close(); currentPanelBundleID = nil }
        checkIdleApps()
        logInfo("🚫 已排除应用: \(appName)")
    }

    // 将应用从排除列表移除，恢复监控
    func unexcludeApp(bundleID: String) {
        let name = excludedApps.removeValue(forKey: bundleID) ?? bundleID
        UserDefaults.standard.set(excludedApps, forKey: "excludedApps")
        checkIdleApps()
        logInfo("✅ 已恢复监控: \(name)")
    }

    // MARK: - 退出应用

    func quitApp(bundleIdentifier: String) {
        // runningApplications(withBundleIdentifier:)：根据 Bundle ID 查找运行中的应用
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            // terminate()：发送 quit AppleEvent，相当于 Dock 右键 → 退出
            // 如果应用有未保存内容，macOS 会由该应用自己弹出确认对话框
            if app.terminate() {
                logInfo("❌ 已退出应用: \(bundleIdentifier)")
            } else {
                logError("⚠️ 退出失败: \(bundleIdentifier)")
            }
        }
        // 清理跟踪数据
        lastActiveTime.removeValue(forKey: bundleIdentifier)
        notifiedApps.remove(bundleIdentifier)
        currentPanelBundleID = nil
        checkIdleApps()
    }

    // MARK: - 工具

    // 简短格式化（用于日志）：如 90s → "1m"，3600s → "1h"
    private func formatBriefDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}

// 日志辅助函数 — Release 构建中编译为空操作（不生成任何日志代码）
// #if DEBUG 条件编译：类似 Go 的 build tags 或 Java 的 @Profile
private func logInfo(_ message: String) {
#if DEBUG
    logger.info("\(message, privacy: .public)")
#endif
}
private func logDebug(_ message: String) {
#if DEBUG
    logger.debug("\(message, privacy: .public)")
#endif
}
// logError 保留：Release 中仍然输出错误日志
// 使用独立 Logger，不受 #if DEBUG 限制
private let errorLogger = Logger(subsystem: "com.fengqi.QPHelper", category: "AppMonitor")
private func logError(_ message: String) {
    errorLogger.error("\(message, privacy: .public)")
}
