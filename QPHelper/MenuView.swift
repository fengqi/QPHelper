import SwiftUI

struct MenuView: View {
    @ObservedObject var monitor: AppMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsSection
            panelActionSection
            launchAtLoginSection
            Divider()
            statusSection
            if !monitor.idleApps.isEmpty { idleAppsSection }
            if !monitor.excludedApps.isEmpty {
                Divider()
                excludedAppsSection
            }
            Divider()
            quitButton
        }
        .padding()
        .frame(width: 340)
    }

    // MARK: - Status

    private var statusSection: some View {
        Text("👁 监控中: \(monitor.monitoredAppCount) 个应用")
            .font(.system(size: 13))
            .fixedSize()
    }

    // MARK: - Idle Apps

    private var idleAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("空闲应用:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ForEach(Array(monitor.idleApps.prefix(10))) { idleAppRow($0) }
            if monitor.idleApps.count > 10 {
                Menu("... 还有 \(monitor.idleApps.count - 10) 个") {
                    ForEach(Array(monitor.idleApps.suffix(from: 10))) { idleAppRow($0) }
                }
                .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func idleAppRow(_ app: AppMonitor.IdleAppInfo) -> some View {
        Menu {
            Text("已空闲 \(formatDuration(app.idleDuration))")
                .foregroundColor(.secondary)
            Divider()
            Button("退出") { monitor.quitApp(bundleIdentifier: app.bundleIdentifier) }
            Button("排除") { monitor.excludeApp(bundleID: app.bundleIdentifier, appName: app.appName) }
        } label: {
            HStack {
                AppIconView(bundleID: app.bundleIdentifier)
                Text(app.appName).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(formatDuration(app.idleDuration)).font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Excluded Apps

    private var excludedAppsSection: some View {
        let list = Array(monitor.excludedApps.keys.sorted())
        return VStack(alignment: .leading, spacing: 4) {
            Text("已排除:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ForEach(Array(list.prefix(10)), id: \.self) { bundleID in
                excludedAppRow(bundleID)
            }
            if list.count > 10 {
                Menu("... 还有 \(list.count - 10) 个") {
                    ForEach(Array(list.suffix(from: 10)), id: \.self) { bundleID in
                        excludedAppRow(bundleID)
                    }
                }
                .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func excludedAppRow(_ bundleID: String) -> some View {
        Menu {
            Button("恢复") { monitor.unexcludeApp(bundleID: bundleID) }
        } label: {
            HStack {
                AppIconView(bundleID: bundleID)
                Text(monitor.excludedApps[bundleID] ?? bundleID)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Menu {
#if DEBUG
            Button(monitor.idleThresholdMinutes == 1  ? "1 分钟 ✓" : "1 分钟")   { monitor.idleThresholdMinutes = 1 }
#endif
            Button(monitor.idleThresholdMinutes == 60  ? "1 小时 ✓" : "1 小时")  { monitor.idleThresholdMinutes = 60 }
            Button(monitor.idleThresholdMinutes == 360 ? "6 小时 ✓" : "6 小时")  { monitor.idleThresholdMinutes = 360 }
            Button(monitor.idleThresholdMinutes == 1440 ? "24 小时 ✓" : "24 小时") { monitor.idleThresholdMinutes = 1440 }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                Text("空闲阈值: \(thresholdLabel)")
            }
        }
    }

    private var thresholdLabel: String {
        let m = monitor.idleThresholdMinutes
        return m < 60 ? "\(m) 分钟" : "\(m / 60) 小时"
    }

    private var panelActionSection: some View {
        Menu {
            ForEach(PanelAction.allCases, id: \.self) { action in
                Button(monitor.panelAction == action ? "\(action.rawValue) ✓" : action.rawValue) {
                    monitor.panelAction = action
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cursorarrow.rays")
                Text("弹框动作: \(monitor.panelAction.rawValue)")
            }
        }
    }

    private var launchAtLoginSection: some View {
        let isOn = monitor.launchAtLogin
        return Menu {
            Button(isOn ? "关闭" : "关闭 ✓") { monitor.launchAtLogin = false }
            Button(isOn ? "开启 ✓" : "开启") { monitor.launchAtLogin = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bolt")
                Text(isOn ? "开机启动: 开启" : "开机启动: 关闭")
            }
        }
    }

    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            HStack {
                Image(systemName: "power")
                Text("退出 QPHelper")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
        .foregroundColor(.secondary)
    }
}
