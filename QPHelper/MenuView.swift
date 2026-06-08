import SwiftUI

// View 协议：SwiftUI 中所有 UI 组件都必须遵循，要求实现 body 计算属性
// 类似 React 的 Component.render() 或 Flutter 的 Widget.build()
struct MenuView: View {
    // @ObservedObject：观察一个 ObservableObject，类似 Vue 的 watch
    // 当对象的 @Published 属性变化时，View 自动重新渲染
    @ObservedObject var monitor: AppMonitor

    var body: some View {
        // VStack：垂直布局容器，子视图从上到下排列
        // spacing: 8 子视图间距，alignment: .leading 左对齐
        VStack(alignment: .leading, spacing: 8) {
            settingsSection
            panelActionSection
            launchAtLoginSection
            Divider()
            trackedAppsSection
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

    // MARK: - 被监控应用列表（始终显示，空闲/非空闲视觉区分）

    private var trackedAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("👁 监控中: \(monitor.trackedApps.count) 个应用")
                .font(.system(size: 13))
                .fixedSize()

            let threshold = TimeInterval(monitor.idleThresholdMinutes * 60)
            let list = monitor.trackedApps

            ForEach(Array(list.prefix(10))) { trackedAppRow($0, threshold: threshold) }
            if list.count > 10 {
                Menu("... 还有 \(list.count - 10) 个") {
                    ForEach(Array(list.suffix(from: 10))) { trackedAppRow($0, threshold: threshold) }
                }
                .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // 单个监控应用的显示行
    private func trackedAppRow(_ app: AppMonitor.IdleAppInfo, threshold: TimeInterval) -> some View {
        let isIdle = app.idleDuration >= threshold
        return Menu {
            Text("已空闲 \(formatDuration(app.idleDuration))")
                .foregroundColor(.secondary)
            Divider()
            Button("退出") { monitor.quitApp(bundleIdentifier: app.bundleIdentifier) }
            Button("排除") { monitor.excludeApp(bundleID: app.bundleIdentifier, appName: app.appName) }
        } label: {
            HStack {
                AppIconView(bundleID: app.bundleIdentifier)
                Text(app.appName)
                    .font(.system(size: 13, weight: isIdle ? .medium : .regular))
                Spacer()
                Text(formatDuration(app.idleDuration))
                    .font(.caption)
                    .foregroundColor(isIdle ? .orange : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 已排除应用列表

    private var excludedAppsSection: some View {
        // 字典的 keys 排序后遍历
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

    // MARK: - 设置

    // 空闲阈值菜单：下拉选择预设时长
    // Debug 构建多一个 "1 分钟" 选项方便调试
    private var settingsSection: some View {
        Menu {
#if DEBUG
            Button(monitor.idleThresholdMinutes == 1  ? "1 分钟 ✓" : "1 分钟")   { monitor.idleThresholdMinutes = 1 }
#endif
            Button(monitor.idleThresholdMinutes == 30  ? "30 分钟 ✓" : "30 分钟")  { monitor.idleThresholdMinutes = 30 }
            Button(monitor.idleThresholdMinutes == 60  ? "1 小时 ✓" : "1 小时")   { monitor.idleThresholdMinutes = 60 }
            Button(monitor.idleThresholdMinutes == 120 ? "2 小时 ✓" : "2 小时")   { monitor.idleThresholdMinutes = 120 }
            Button(monitor.idleThresholdMinutes == 180 ? "3 小时 ✓" : "3 小时")   { monitor.idleThresholdMinutes = 180 }
            Button(monitor.idleThresholdMinutes == 360 ? "6 小时 ✓" : "6 小时")   { monitor.idleThresholdMinutes = 360 }
            Button(monitor.idleThresholdMinutes == 720 ? "12 小时 ✓" : "12 小时") { monitor.idleThresholdMinutes = 720 }
            Button(monitor.idleThresholdMinutes == 1440 ? "24 小时 ✓" : "24 小时") { monitor.idleThresholdMinutes = 1440 }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                Text("空闲阈值: \(thresholdLabel)")
            }
        }
    }

    // 计算当前阈值的中文标签
    private var thresholdLabel: String {
        let m = monitor.idleThresholdMinutes
        return m < 60 ? "\(m) 分钟" : "\(m / 60) 小时"
    }

    // 弹框动作菜单
    private var panelActionSection: some View {
        Menu {
            // ForEach 遍历 enum 的 allCases（类似 Java enum 的 values()）
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

    // 开机启动开关菜单
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

    // 退出本应用按钮
    private var quitButton: some View {
        Button {
            // NSApplication.shared.terminate(nil)：退出整个应用
            // 类似 Java 的 System.exit(0)
            NSApplication.shared.terminate(nil)
        } label: {
            HStack {
                Image(systemName: "power")
                Text("退出 QPHelper")
            }
            .frame(maxWidth: .infinity)  // 按钮撑满行宽
        }
        .buttonStyle(.borderless)        // 无边框按钮
        .foregroundColor(.secondary)     // 灰色文字
    }
}
