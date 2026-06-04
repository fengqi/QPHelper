import AppKit
import Combine
import OSLog

private let logger = Logger(subsystem: "com.fengqi.QPHelper", category: "AppMonitor")

// 弹框时附带的动作
enum PanelAction: String, CaseIterable {
    case none = "无"
    case activate = "打开应用"
}

// ObservableObject 协议：让 SwiftUI 视图能监听这个对象的数据变化
// @Published 标记的属性一旦改变，会通知所有观察它的 View 自动刷新
final class AppMonitor: ObservableObject {
    @Published var idleApps: [IdleAppInfo] = []       // 当前超时空闲的应用列表
#if DEBUG
    @Published var idleThresholdMinutes: Int = 1      // 空闲阈值，Debug 默认 1 分钟方便测试
#else
    @Published var idleThresholdMinutes: Int = 60     // 空闲阈值，Release 默认 1 小时
#endif
    @Published var monitoredAppCount: Int = 0           // 当前正在监控的前台应用数量
    @Published var excludedApps: [String: String] = [:] // 用户排除的应用 [BundleID: 应用名]，持久化在 UserDefaults
    @Published var panelAction: PanelAction = .none    // 弹框时附带的动作，持久化在 UserDefaults

    // [bundleID: 最后活跃时间]，记录每个应用上次被使用的时间点
    private var lastActiveTime: [String: Date] = [:]
    // 已经弹出过面板的应用集合，避免对同一个应用反复弹面板
    private var notifiedApps: Set<String> = []
    // 当前正在显示悬浮面板的应用 BundleID，nil 表示没有面板显示
    private var currentPanelBundleID: String?
    // 保底定时器，用于补充事件驱动扫描
    private var timer: Timer?
    // Combine 订阅的回收袋，持有所有订阅防止被释放
    private var cancellables = Set<AnyCancellable>()
    // 本应用的 Bundle ID，扫描时排除自己
    private let myBundleID = Bundle.main.bundleIdentifier ?? ""
    // 自定义悬浮通知面板
    private let panel = NotificationPanel()
    // 用户离开状态（锁屏/休眠）
    private var isAway = false

    // 系统关键应用名单，这些应用即使空闲也不会建议退出
    private let systemCriticalApps: Set<String> = [
        "com.apple.finder",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
    ]

    // 空闲应用信息结构体
    // Identifiable 协议：要求有 id 字段，SwiftUI 的 ForEach 需要用它唯一标识每个元素
    struct IdleAppInfo: Identifiable {
        let id = UUID()                         // 唯一标识，UUID() 生成随机唯一 ID
        let bundleIdentifier: String            // 应用 Bundle ID，如 com.apple.Safari
        let appName: String                     // 应用显示名，如"Safari"
        let lastActive: Date                    // 最后一次活跃的时间
        let idleDuration: TimeInterval           // 已空闲的时长（秒）
        let icon: NSImage?                      // 应用图标，nil 时界面用占位图标
    }

    // init()：构造函数，对象创建时自动调用
    init() {
        // Combine 数据流：监听 idleThresholdMinutes 的变化
        $idleThresholdMinutes
            .dropFirst()
            .sink { [weak self] _ in
                self?.notifiedApps.removeAll()  // 阈值变了，清除已通知记录
                self?.checkIdleApps()           // 重新扫描
            }
            .store(in: &cancellables)

        // 从 UserDefaults 加载用户之前排除的应用列表 [BundleID: 应用名]
        excludedApps = UserDefaults.standard.dictionary(forKey: "excludedApps") as? [String: String] ?? [:]

        // 从 UserDefaults 加载弹框动作
        if let raw = UserDefaults.standard.string(forKey: "panelAction"),
           let action = PanelAction(rawValue: raw) {
            panelAction = action
        }

        // 弹框动作变化时持久化
        $panelAction
            .dropFirst()
            .sink { UserDefaults.standard.set($0.rawValue, forKey: "panelAction") }
            .store(in: &cancellables)
    }

    // 判断一个应用是否应该被跟踪（排除自身和用户手动排除的应用）
    private func shouldTrack(_ bundleID: String) -> Bool {
        bundleID != myBundleID && excludedApps[bundleID] == nil
    }

    // 开始监控：注册系统事件监听器 + 初始化运行中应用的时间戳
    func start() {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, app.activationPolicy == .regular else { continue }
            lastActiveTime[bundleID] = Date()
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleActivation),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleDeactivation),
                       name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleLaunch),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleTerminate),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // 锁屏/休眠暂停计时
        nc.addObserver(self, selector: #selector(handleAway),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleAway),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleReturn),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleReturn),
                       name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleAway),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleReturn),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        // 保底定时器：每 60 秒兜底扫描一次，防止极端情况下事件丢失
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkIdleApps()
        }

        logger.info("监控已启动，当前跟踪 \(self.lastActiveTime.count) 个前台应用")
        checkIdleApps()
    }

    // MARK: - 工作空间事件处理

    // 应用被激活（切到前台）
    @objc private func handleActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              shouldTrack(bundleID) else { return }
        lastActiveTime[bundleID] = Date()
        notifiedApps.remove(bundleID)
        logger.debug("▶ 前台切换: \(app.localizedName ?? bundleID, privacy: .public)")

        // 如果当前面板就是这个应用，关闭面板
        if bundleID == currentPanelBundleID {
            panel.close()
            currentPanelBundleID = nil
        }

        checkIdleApps()
    }

    // 应用失去激活（退到后台）
    @objc private func handleDeactivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              shouldTrack(bundleID) else { return }
        lastActiveTime[bundleID] = Date()
        logger.debug("▷ 退到后台: \(app.localizedName ?? bundleID, privacy: .public)，开始计时空闲")
        checkIdleApps()
    }

    @objc private func handleLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              shouldTrack(bundleID) else { return }
        if lastActiveTime[bundleID] == nil {
            lastActiveTime[bundleID] = Date()
        }
        logger.debug("◎ 应用启动: \(app.localizedName ?? bundleID, privacy: .public)")
    }

    @objc private func handleTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }
        lastActiveTime.removeValue(forKey: bundleID)
        notifiedApps.remove(bundleID)

        // 如果退出的应用正在显示面板，关闭面板
        if bundleID == currentPanelBundleID {
            panel.close()
            currentPanelBundleID = nil
        }

        if shouldTrack(bundleID) {
            logger.debug("◉ 应用退出: \(app.localizedName ?? bundleID, privacy: .public)")
        }
    }

    // 锁屏/休眠：暂停计时
    @objc private func handleAway(_ notification: Notification) {
        guard !isAway else { return }
        isAway = true
        // 关闭当前面板
        if currentPanelBundleID != nil {
            panel.close()
            currentPanelBundleID = nil
        }
        logger.info("💤 用户离开，暂停计时")
    }

    // 解锁/唤醒：重置全部计时
    @objc private func handleReturn(_ notification: Notification) {
        guard isAway else { return }
        isAway = false
        let now = Date()
        for key in lastActiveTime.keys {
            lastActiveTime[key] = now
        }
        notifiedApps.removeAll()
        logger.info("👁 用户回来，已重置全部计时")
        checkIdleApps()
    }

    // MARK: - 空闲检测（核心逻辑）

    private func checkIdleApps() {
        guard !isAway else { return }
        let now = Date()
        let threshold = TimeInterval(idleThresholdMinutes * 60)
        var idle: [IdleAppInfo] = []
        var regularAppCount = 0

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  app.activationPolicy == .regular,
                  !app.isActive,                     // 当前前台应用永远不算空闲
                  bundleID != myBundleID,
                  !systemCriticalApps.contains(bundleID),
                  excludedApps[bundleID] == nil
            else { continue }

            regularAppCount += 1

            let lastActive = lastActiveTime[bundleID] ?? now
            let idleDuration = now.timeIntervalSince(lastActive)

            if idleDuration >= threshold {
                let info = IdleAppInfo(
                    bundleIdentifier: bundleID,
                    appName: app.localizedName ?? bundleID,
                    lastActive: lastActive,
                    idleDuration: idleDuration,
                    icon: app.icon
                )
                idle.append(info)

                // 还没通知过且当前没有面板显示（或有不同应用的面板需要替换）
                if !notifiedApps.contains(bundleID) && !panel.isShowing {
                    showPanel(for: info)
                    notifiedApps.insert(bundleID)
                }
            }
        }

        idleApps = idle
        monitoredAppCount = regularAppCount

        let idleIDs = Set(idle.map(\.bundleIdentifier))
        notifiedApps.formIntersection(idleIDs)

        if !idle.isEmpty {
            let names = idle.map { "\($0.appName)(\(self.formatBriefDuration($0.idleDuration)))" }.joined(separator: ", ")
            logger.info("🔔 空闲应用: \(names, privacy: .public)")
        }
    }

    // MARK: - 悬浮面板

    private func showPanel(for app: IdleAppInfo) {
        // 如果当前面板是另一个应用，关闭它
        if let oldBundleID = currentPanelBundleID {
            notifiedApps.remove(oldBundleID) // 允许被替换的应用后续重新弹出
        }

        // 如果设置了"打开应用"动作，仅记录日志，激活由面板点击触发
        if panelAction == .activate {
            logger.info("⬆ 检测到空闲应用: \(app.appName, privacy: .public) (\(app.bundleIdentifier, privacy: .public))")
        }

        logger.info("📌 弹出面板: \(app.appName, privacy: .public)")
        panel.show(
            appName: app.appName,
            icon: app.icon,
            idleDuration: app.idleDuration,
            onQuit: { [weak self] in
                self?.quitApp(bundleIdentifier: app.bundleIdentifier)
            },
            onKeep: { [weak self] in
                // 重置空闲计时，下个阈值周期后再次提醒
                self?.lastActiveTime[app.bundleIdentifier] = Date()
                self?.notifiedApps.remove(app.bundleIdentifier)
            },
            onExclude: { [weak self] in
                self?.excludeApp(bundleID: app.bundleIdentifier, appName: app.appName)
            },
            onActivate: { [weak self] in
                guard let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
                if runningApp.isHidden { runningApp.unhide() }
                runningApp.activate()
                logger.info("⬆ 用户点击打开: \(app.appName, privacy: .public)")
            },
            onDismiss: { [weak self] in
                self?.currentPanelBundleID = nil
            }
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

        // 如果排除的应用正在显示面板，关闭面板
        if bundleID == currentPanelBundleID {
            panel.close()
            currentPanelBundleID = nil
        }

        checkIdleApps()
        logger.info("🚫 已排除应用: \(appName, privacy: .public)")
    }

    // 将应用从排除列表中移除
    func unexcludeApp(bundleID: String) {
        let name = excludedApps.removeValue(forKey: bundleID) ?? bundleID
        UserDefaults.standard.set(excludedApps, forKey: "excludedApps")
        checkIdleApps()
        logger.info("✅ 已恢复监控: \(name, privacy: .public)")
    }

    // MARK: - 退出应用

    func quitApp(bundleIdentifier: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            if app.terminate() {
                logger.info("❌ 已退出应用: \(bundleIdentifier, privacy: .public)")
            } else {
                logger.error("⚠️ 退出失败: \(bundleIdentifier)，可能被沙盒拦截")
            }
        }
        lastActiveTime.removeValue(forKey: bundleIdentifier)
        notifiedApps.remove(bundleIdentifier)
        currentPanelBundleID = nil
        checkIdleApps()
    }

    // MARK: - 格式化工具方法

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes) 分钟"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "\(hours) 小时"
        }
        return "\(hours) 小时 \(remainingMinutes) 分钟"
    }

    private func formatBriefDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes)m"
        }
        return "\(minutes / 60)h"
    }
}
