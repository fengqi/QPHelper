import AppKit
import Combine
import OSLog
import UserNotifications

// os.Logger：Apple 推荐的日志 API，输出可在 Xcode 控制台和 Console.app 查看
private let logger = Logger(subsystem: "com.fengqi.QPHelper", category: "AppMonitor")

// ObservableObject 协议：让 SwiftUI 视图能监听这个对象的数据变化
// @Published 标记的属性一旦改变，会通知所有观察它的 View 自动刷新
final class AppMonitor: ObservableObject {
    @Published var idleApps: [IdleAppInfo] = []       // 当前超时空闲的应用列表
    @Published var idleThresholdMinutes: Int = 10      // 空闲阈值（分钟），默认 10 分钟
    @Published var monitoredAppCount: Int = 0           // 当前正在监控的前台应用数量
    @Published var excludedApps: [String: String] = [:] // 用户排除的应用 [BundleID: 应用名]，持久化在 UserDefaults

    // [bundleID: 最后活跃时间]，记录每个应用上次被使用的时间点
    private var lastActiveTime: [String: Date] = [:]
    // 已经发送过通知的应用集合，避免对同一个应用反复弹通知
    private var notifiedApps: Set<String> = []
    // 保底定时器，用于补充事件驱动扫描
    private var timer: Timer?
    // Combine 订阅的回收袋，持有所有订阅防止被释放
    private var cancellables = Set<AnyCancellable>()
    // 本应用的 Bundle ID，扫描时排除自己
    private let myBundleID = Bundle.main.bundleIdentifier ?? ""

    // 系统关键应用名单，这些应用即使空闲也不会建议退出
    // com.apple.finder = Finder（桌面和文件浏览器）
    // com.apple.loginwindow = 登录界面
    // com.apple.systemuiserver = 右侧菜单栏进程
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
    }

    // init()：构造函数，对象创建时自动调用
    init() {
        // Combine 数据流：监听 idleThresholdMinutes 的变化
        // $idleThresholdMinutes：@Published 属性的投影，类型是 Publisher（发布者）
        // dropFirst()：跳过首次值（初始值 10 不需要触发清理）
        // sink：订阅，每当值变化时执行闭包
        // store(in: &cancellables)：把订阅放入回收袋，防止被释放
        $idleThresholdMinutes
            .dropFirst()
            .sink { [weak self] _ in
                // [weak self]：弱引用，防止循环引用导致内存泄漏
                self?.notifiedApps.removeAll()  // 阈值变了，清除已通知记录
                self?.checkIdleApps()           // 重新扫描
            }
            .store(in: &cancellables)

        // 从 UserDefaults 加载用户之前排除的应用列表 [BundleID: 应用名]
        excludedApps = UserDefaults.standard.dictionary(forKey: "excludedApps") as? [String: String] ?? [:]
    }

    // 判断一个应用是否应该被跟踪（排除自身和用户手动排除的应用）
    private func shouldTrack(_ bundleID: String) -> Bool {
        bundleID != myBundleID && excludedApps[bundleID] == nil
    }

    // 请求系统通知权限，并注册通知上的按钮类别
    func requestNotificationPermission() {
        // 创建"退出"按钮，.foreground 表示点击后会激活本应用
        let quitAction = UNNotificationAction(identifier: "QUIT_APP", title: "退出", options: .foreground)
        // 创建"保留"按钮
        let keepAction = UNNotificationAction(identifier: "KEEP_APP", title: "保留", options: .foreground)
        // 创建一个通知类别，把两个按钮绑定在一起
        let category = UNNotificationCategory(
            identifier: "APP_IDLE",
            actions: [quitAction, keepAction],
            intentIdentifiers: [],
            options: []
        )
        // 注册类别到系统通知中心
        UNUserNotificationCenter.current().setNotificationCategories([category])
        // 弹出权限请求对话框（仅首次）
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // 开始监控：注册系统事件监听器 + 初始化运行中应用的时间戳
    func start() {
        // 初始化：给当前所有正在运行的前台应用设一个"当前时间"作为初始活跃时间
        // NSWorkspace.shared.runningApplications：获取所有运行中的应用
        // activationPolicy == .regular 表示前台应用（有 Dock 图标，有窗口）
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, app.activationPolicy == .regular else { continue }
            lastActiveTime[bundleID] = Date()
        }

        // 注册四个系统事件监听
        let nc = NSWorkspace.shared.notificationCenter
        // ① 应用被激活（切到前台）→ 重置空闲计时
        nc.addObserver(self, selector: #selector(handleActivation),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // ② 应用失去激活（退到后台）→ 开始计时空闲
        nc.addObserver(self, selector: #selector(handleDeactivation),
                       name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        // ③ 新应用启动 → 加入跟踪
        nc.addObserver(self, selector: #selector(handleLaunch),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        // ④ 应用退出 → 清理跟踪数据
        nc.addObserver(self, selector: #selector(handleTerminate),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // 保底定时器：每 60 秒兜底扫描一次，防止极端情况下事件丢失
        // Timer.scheduledTimer：创建一个重复定时器
        // withTimeInterval: 60：每 60 秒触发一次
        // repeats: true：重复执行
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkIdleApps()
        }

        logger.info("监控已启动，当前跟踪 \(self.lastActiveTime.count) 个前台应用")
        checkIdleApps()
    }

    // MARK: - 工作空间事件处理
    // @objc：让 Swift 方法可以被 Objective-C 的 selector 机制调用
    // NotificationCenter 的 addObserver 需要 selector，所以必须加 @objc

    // 应用被激活（切到前台）
    @objc private func handleActivation(_ notification: Notification) {
        // NSWorkspace.applicationUserInfoKey：从通知的 userInfo 字典中取出 NSRunningApplication
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              shouldTrack(bundleID) else { return }
        // 更新最后活跃时间 = 现在
        lastActiveTime[bundleID] = Date()
        // 用户重新使用了这个应用，撤销已发送的通知标记并删除通知中心中的通知
        notifiedApps.remove(bundleID)
        removeDeliveredNotification(for: bundleID)
        logger.debug("▶ 前台切换: \(app.localizedName ?? bundleID, privacy: .public)")
        checkIdleApps()
    }

    // 应用失去激活（退到后台）
    @objc private func handleDeactivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              shouldTrack(bundleID) else { return }
        // 退到后台的时刻 = 空闲计时起点
        lastActiveTime[bundleID] = Date()
        logger.debug("▷ 退到后台: \(app.localizedName ?? bundleID, privacy: .public)，开始计时空闲")
        checkIdleApps()
    }

    // 有新应用启动
    @objc private func handleLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              shouldTrack(bundleID) else { return }
        // 只有首次出现才记录，避免覆盖已有数据
        if lastActiveTime[bundleID] == nil {
            lastActiveTime[bundleID] = Date()
        }
        logger.debug("◎ 应用启动: \(app.localizedName ?? bundleID, privacy: .public)")
    }

    // 有应用退出
    @objc private func handleTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }
        // 不管是否被排除，都清理跟踪数据（应用已经退出了）
        lastActiveTime.removeValue(forKey: bundleID)
        notifiedApps.remove(bundleID)
        removeDeliveredNotification(for: bundleID)
        if shouldTrack(bundleID) {
            logger.debug("◉ 应用退出: \(app.localizedName ?? bundleID, privacy: .public)")
        }
    }

    // MARK: - 空闲检测（核心逻辑）

    private func checkIdleApps() {
        let now = Date()
        // 将分钟阈值转为秒：TimeInterval 本质就是秒数（Double）
        let threshold = TimeInterval(idleThresholdMinutes * 60)
        var idle: [IdleAppInfo] = []
        var regularAppCount = 0

        // 遍历所有正在运行的应用
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  app.activationPolicy == .regular,      // 只关心前台应用（排除后台/状态栏应用）
                  bundleID != myBundleID,                  // 排除本应用自身
                  !systemCriticalApps.contains(bundleID),  // 排除系统关键应用
                  excludedApps[bundleID] == nil            // 排除用户手动排除的应用
            else { continue }

            regularAppCount += 1

            // 计算空闲时长：当前时间 - 最后活跃时间
            // ?? 是 nil 合并运算符：左边为 nil 时用右边的值
            let lastActive = lastActiveTime[bundleID] ?? now
            let idleDuration = now.timeIntervalSince(lastActive)

            if idleDuration >= threshold {
                // 添加到空闲列表
                idle.append(IdleAppInfo(
                    bundleIdentifier: bundleID,
                    appName: app.localizedName ?? bundleID,
                    lastActive: lastActive,
                    idleDuration: idleDuration
                ))

                // 如果还没给这个应用发过通知，发送一次
                if !notifiedApps.contains(bundleID) {
                    sendNotification(for: app, idleDuration: idleDuration)
                    notifiedApps.insert(bundleID) // 标记已通知，避免重复弹窗
                }
            }
        }

        // 更新 @Published 属性，触发 View 刷新
        idleApps = idle
        monitoredAppCount = regularAppCount

        // 清理：已退出空闲状态的应用从 notifiedApps 中移除
        let idleIDs = Set(idle.map(\.bundleIdentifier))
        // formIntersection 取交集：保留既在 notifiedApps 也在 idleIDs 里的元素
        notifiedApps.formIntersection(idleIDs)

        if !idle.isEmpty {
            let names = idle.map { "\($0.appName)(\(self.formatBriefDuration($0.idleDuration)))" }.joined(separator: ", ")
            logger.info("🔔 空闲应用: \(names, privacy: .public)")
        }
    }

    // MARK: - 系统通知

    private func sendNotification(for app: NSRunningApplication, idleDuration: TimeInterval) {
        // UNMutableNotificationContent：通知的内容模型
        let content = UNMutableNotificationContent()
        content.title = "应用空闲提醒"
        content.body = "\"\(app.localizedName ?? "未知应用")\" 已 \(formatDuration(idleDuration)) 未使用"
        // userInfo：携带自定义数据，通知按钮点击时可以取出来用
        content.userInfo = ["bundleID": app.bundleIdentifier ?? ""]
        // categoryIdentifier：关联之前注册的按钮类别（"退出"+"保留"）
        content.categoryIdentifier = "APP_IDLE"
        content.sound = .default

        // UNNotificationRequest：通知请求
        // trigger: nil 表示立即发送，不延迟
        let request = UNNotificationRequest(
            identifier: "idle-\(app.bundleIdentifier ?? UUID().uuidString)",
            content: content,
            trigger: nil
        )
        // 发送通知
        UNUserNotificationCenter.current().add(request)
        logger.notice("📬 推送通知: \(app.localizedName ?? "未知应用", privacy: .public)")
    }

    // 从系统通知中心删除指定应用的已投递通知
    // 通知 identifier 格式为 "idle-<bundleID>"，在 sendNotification 中定义
    private func removeDeliveredNotification(for bundleID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["idle-\(bundleID)"])
    }

    // 处理用户点击通知按钮的回调
    func handleNotificationResponse(_ response: UNNotificationResponse) {
        // 只有点击"退出"按钮才执行退出逻辑
        guard response.actionIdentifier == "QUIT_APP",
              let bundleID = response.notification.request.content.userInfo["bundleID"] as? String else {
            logger.debug("用户选择保留应用")
            return
        }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
        logger.info("👆 用户点击退出: \(name, privacy: .public)")
        quitApp(bundleIdentifier: bundleID)
    }

    // MARK: - 排除应用

    // 将应用加入排除列表，持久化到 UserDefaults
    func excludeApp(bundleID: String, appName: String) {
        excludedApps[bundleID] = appName
        UserDefaults.standard.set(excludedApps, forKey: "excludedApps")
        // 清除该应用的跟踪数据和已有通知
        lastActiveTime.removeValue(forKey: bundleID)
        notifiedApps.remove(bundleID)
        removeDeliveredNotification(for: bundleID)
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
        // runningApplications(withBundleIdentifier:)：根据 Bundle ID 查找运行中的应用
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            // terminate()：发送 quit AppleEvent，相当于 Dock 右键 → 退出
            // 如果应用有未保存内容，它会自己弹确认对话框
            app.terminate()
        }
        // 清理相关跟踪数据，并移除通知
        lastActiveTime.removeValue(forKey: bundleIdentifier)
        notifiedApps.remove(bundleIdentifier)
        removeDeliveredNotification(for: bundleIdentifier)
        logger.info("❌ 已退出应用: \(bundleIdentifier, privacy: .public)")
    }

    // MARK: - 格式化工具方法

    // 将秒数格式化为中文时长，如 "30 分钟"、"1 小时 15 分钟"
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

    // 将秒数格式化为简短时长，如 "30m"、"1h"，用于日志
    private func formatBriefDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes)m"
        }
        return "\(minutes / 60)h"
    }
}
