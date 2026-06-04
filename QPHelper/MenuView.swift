import SwiftUI

struct MenuView: View {
    @ObservedObject var monitor: AppMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingsSection
            panelActionSection
            Divider()
            statusSection
            if !monitor.idleApps.isEmpty {
                idleAppsSection
            }
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

    private var statusSection: some View {
        Text("👁 监控中: \(monitor.monitoredAppCount) 个应用")
            .font(.system(size: 13))
            .fixedSize()
    }

    private var idleAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("空闲应用:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ForEach(Array(monitor.idleApps.prefix(10))) { app in
                idleAppRow(app)
            }
            if monitor.idleApps.count > 10 {
                Menu("... 还有 \(monitor.idleApps.count - 10) 个") {
                    ForEach(Array(monitor.idleApps.suffix(from: 10))) { app in
                        idleAppRow(app)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }

    private func idleAppRow(_ app: AppMonitor.IdleAppInfo) -> some View {
        Menu {
            Text("已空闲 \(formatIdleDuration(app.idleDuration))")
                .foregroundColor(.secondary)
            Divider()
            Button("退出") {
                monitor.quitApp(bundleIdentifier: app.bundleIdentifier)
            }
            Button("排除") {
                monitor.excludeApp(bundleID: app.bundleIdentifier, appName: app.appName)
            }
        } label: {
            HStack {
                appIcon(app.icon)
                Text(app.appName)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(formatIdleDuration(app.idleDuration))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func appIcon(_ nsImage: NSImage?) -> some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 12)).foregroundColor(.orange).frame(width: 16, height: 16)
            }
        }
    }

    private func appIcon(for bundleID: String) -> some View {
        let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
        return appIcon(icon)
    }

    private var excludedAppsSection: some View {
        let excludedList = Array(monitor.excludedApps.keys.sorted())

        return VStack(alignment: .leading, spacing: 4) {
            Text("已排除:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ForEach(Array(excludedList.prefix(10)), id: \.self) { bundleID in
                Menu {
                    Button("恢复") {
                        monitor.unexcludeApp(bundleID: bundleID)
                    }
                } label: {
                    HStack {
                        appIcon(for: bundleID)
                        Text(monitor.excludedApps[bundleID] ?? bundleID)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if excludedList.count > 10 {
                Menu("... 还有 \(excludedList.count - 10) 个") {
                    ForEach(Array(excludedList.suffix(from: 10)), id: \.self) { bundleID in
                        Menu {
                            Button("恢复") {
                                monitor.unexcludeApp(bundleID: bundleID)
                            }
                        } label: {
                            HStack {
                                appIcon(for: bundleID)
                                Text(monitor.excludedApps[bundleID] ?? bundleID)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
    }

    private var settingsSection: some View {
        Menu {
#if DEBUG
            Button(monitor.idleThresholdMinutes == 1 ? "1 分钟 ✓" : "1 分钟") { monitor.idleThresholdMinutes = 1 }
#endif
            Button(monitor.idleThresholdMinutes == 60 ? "1 小时 ✓" : "1 小时") { monitor.idleThresholdMinutes = 60 }
            Button(monitor.idleThresholdMinutes == 360 ? "6 小时 ✓" : "6 小时") { monitor.idleThresholdMinutes = 360 }
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
        if m < 60 { return "\(m) 分钟" }
        return "\(m / 60) 小时"
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

    private func formatIdleDuration(_ seconds: TimeInterval) -> String {
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
}
