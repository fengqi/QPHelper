import AppKit
import Combine
import OSLog
import ServiceManagement

#if DEBUG
private let logger = Logger(subsystem: "com.fengqi.QPHelper", category: "AppMonitor")
#endif

// 弹框时附带的动作
enum PanelAction: String, CaseIterable {
    case none = "无"
    case activate = "打开应用"
}

final class AppMonitor: ObservableObject {
    @Published var idleApps: [IdleAppInfo] = []
#if DEBUG
    @Published var idleThresholdMinutes: Int = 1
#else
    @Published var idleThresholdMinutes: Int = 60
#endif
    @Published var monitoredAppCount: Int = 0
    @Published var excludedApps: [String: String] = [:]
    @Published var panelAction: PanelAction = .none

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

    private var lastActiveTime: [String: Date] = [:]
    private var notifiedApps: Set<String> = []
    private var currentPanelBundleID: String?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let myBundleID = Bundle.main.bundleIdentifier ?? ""
    private let panel = NotificationPanel()
    private var isAway = false

    private let systemCriticalApps: Set<String> = [
        "com.apple.finder",
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
    ]

    struct IdleAppInfo: Identifiable {
        let id = UUID()
        let bundleIdentifier: String
        let appName: String
        let lastActive: Date
        let idleDuration: TimeInterval
    }

    init() {
        $idleThresholdMinutes.dropFirst().sink { [weak self] _ in
            self?.notifiedApps.removeAll()
            self?.checkIdleApps()
        }.store(in: &cancellables)

        excludedApps = UserDefaults.standard.dictionary(forKey: "excludedApps") as? [String: String] ?? [:]

        if let raw = UserDefaults.standard.string(forKey: "panelAction"),
           let action = PanelAction(rawValue: raw) {
            panelAction = action
        }

        $panelAction.dropFirst().sink {
            UserDefaults.standard.set($0.rawValue, forKey: "panelAction")
        }.store(in: &cancellables)
    }

    private func shouldTrack(_ bundleID: String) -> Bool {
        bundleID != myBundleID && excludedApps[bundleID] == nil
    }

    func start() {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, app.activationPolicy == .regular else { continue }
            lastActiveTime[bundleID] = Date()
        }

        let nc = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, Selector)] = [
            (NSWorkspace.didActivateApplicationNotification, #selector(handleActivation)),
            (NSWorkspace.didDeactivateApplicationNotification, #selector(handleDeactivation)),
            (NSWorkspace.didLaunchApplicationNotification, #selector(handleLaunch)),
            (NSWorkspace.didTerminateApplicationNotification, #selector(handleTerminate)),
            (NSWorkspace.screensDidSleepNotification, #selector(handleAway)),
            (NSWorkspace.willSleepNotification, #selector(handleAway)),
            (NSWorkspace.screensDidWakeNotification, #selector(handleReturn)),
            (NSWorkspace.didWakeNotification, #selector(handleReturn)),
        ]
        for (name, sel) in events {
            nc.addObserver(self, selector: sel, name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleAway), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleReturn), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkIdleApps()
        }

        logInfo("监控已启动，当前跟踪 \(self.lastActiveTime.count) 个前台应用")
        checkIdleApps()
    }

    // MARK: - Workspace Events

    @objc private func handleActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier, shouldTrack(bundleID) else { return }
        lastActiveTime[bundleID] = Date()
        notifiedApps.remove(bundleID)
        logDebug("▶ 前台切换: \(app.localizedName ?? bundleID)")

        if bundleID == currentPanelBundleID {
            panel.close()
            currentPanelBundleID = nil
        }
        checkIdleApps()
    }

    @objc private func handleDeactivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier, shouldTrack(bundleID) else { return }
        lastActiveTime[bundleID] = Date()
        checkIdleApps()
    }

    @objc private func handleLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier, shouldTrack(bundleID) else { return }
        if lastActiveTime[bundleID] == nil { lastActiveTime[bundleID] = Date() }
    }

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

    @objc private func handleAway(_ notification: Notification) {
        guard !isAway else { return }
        isAway = true
        if currentPanelBundleID != nil {
            panel.close()
            currentPanelBundleID = nil
        }
        logInfo("💤 用户离开，暂停计时")
    }

    @objc private func handleReturn(_ notification: Notification) {
        guard isAway else { return }
        isAway = false
        let now = Date()
        for key in lastActiveTime.keys { lastActiveTime[key] = now }
        notifiedApps.removeAll()
        logInfo("👁 用户回来，已重置全部计时")
        checkIdleApps()
    }

    // MARK: - Idle Detection

    private func checkIdleApps() {
        guard !isAway else { return }
        let now = Date()
        let threshold = TimeInterval(idleThresholdMinutes * 60)
        var idle: [IdleAppInfo] = []
        var regularAppCount = 0

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  app.activationPolicy == .regular,
                  !app.isActive,
                  bundleID != myBundleID,
                  !systemCriticalApps.contains(bundleID),
                  excludedApps[bundleID] == nil
            else { continue }

            regularAppCount += 1
            let lastActive = lastActiveTime[bundleID] ?? now
            let idleDuration = now.timeIntervalSince(lastActive)

            if idleDuration >= threshold {
                idle.append(IdleAppInfo(
                    bundleIdentifier: bundleID,
                    appName: app.localizedName ?? bundleID,
                    lastActive: lastActive,
                    idleDuration: idleDuration
                ))

                if !notifiedApps.contains(bundleID) && !panel.isShowing {
                    showPanel(for: idle.last!, withIcon: app.icon)
                    notifiedApps.insert(bundleID)
                }
            }
        }

        idleApps = idle
        monitoredAppCount = regularAppCount
        notifiedApps.formIntersection(Set(idle.map(\.bundleIdentifier)))

        if !idle.isEmpty {
            logInfo("🔔 空闲应用: \(idle.map { "\($0.appName)(\(formatBriefDuration($0.idleDuration)))" }.joined(separator: ", "))")
        }
    }

    // MARK: - Panel

    private func showPanel(for app: IdleAppInfo, withIcon icon: NSImage?) {
        if let old = currentPanelBundleID { notifiedApps.remove(old) }

        if panelAction == .activate {
            logInfo("⬆ 检测到空闲应用: \(app.appName) (\(app.bundleIdentifier))")
        }

        logInfo("📌 弹出面板: \(app.appName)")
        panel.show(
            appName: app.appName,
            icon: icon,
            idleDuration: app.idleDuration,
            onQuit: { [weak self] in self?.quitApp(bundleIdentifier: app.bundleIdentifier) },
            onKeep: { [weak self] in
                self?.lastActiveTime[app.bundleIdentifier] = Date()
                self?.notifiedApps.remove(app.bundleIdentifier)
            },
            onExclude: { [weak self] in self?.excludeApp(bundleID: app.bundleIdentifier, appName: app.appName) },
            onActivate: { [weak self] in
                guard let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
                if runningApp.isHidden { runningApp.unhide() }
                runningApp.activate()
                logInfo("⬆ 用户点击打开: \(app.appName)")
            },
            onDismiss: { [weak self] in self?.currentPanelBundleID = nil }
        )
        currentPanelBundleID = app.bundleIdentifier
    }

    // MARK: - Exclude

    func excludeApp(bundleID: String, appName: String) {
        excludedApps[bundleID] = appName
        UserDefaults.standard.set(excludedApps, forKey: "excludedApps")
        lastActiveTime.removeValue(forKey: bundleID)
        notifiedApps.remove(bundleID)
        if bundleID == currentPanelBundleID { panel.close(); currentPanelBundleID = nil }
        checkIdleApps()
        logInfo("🚫 已排除应用: \(appName)")
    }

    func unexcludeApp(bundleID: String) {
        let name = excludedApps.removeValue(forKey: bundleID) ?? bundleID
        UserDefaults.standard.set(excludedApps, forKey: "excludedApps")
        checkIdleApps()
        logInfo("✅ 已恢复监控: \(name)")
    }

    // MARK: - Quit

    func quitApp(bundleIdentifier: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            if app.terminate() {
                logInfo("❌ 已退出应用: \(bundleIdentifier)")
            } else {
                logError("⚠️ 退出失败: \(bundleIdentifier)")
            }
        }
        lastActiveTime.removeValue(forKey: bundleIdentifier)
        notifiedApps.remove(bundleIdentifier)
        currentPanelBundleID = nil
        checkIdleApps()
    }

    // MARK: - Helpers

    private func formatBriefDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}

// Log helpers — no-op in Release
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
private func logError(_ message: String) {
    logger.error("\(message, privacy: .public)")
}
