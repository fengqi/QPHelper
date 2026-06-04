import SwiftUI

// View 协议：SwiftUI 中所有 UI 组件都必须遵循的协议
// 要求实现 body 计算属性，返回界面的内容
struct MenuView: View {
    // @ObservedObject：观察一个 ObservableObject 对象
    // 当对象的 @Published 属性变化时，这个 View 自动重新渲染
    @ObservedObject var monitor: AppMonitor

    var body: some View {
        // VStack：垂直布局容器，子视图从上到下排列
        // alignment: .leading 左对齐，spacing: 8 子视图间距 8 点
        VStack(alignment: .leading, spacing: 8) {
            statusSection
            // if 在 SwiftUI 中可以直接控制视图的显示/隐藏
            if !monitor.idleApps.isEmpty {
                idleAppsSection
            }
            if !monitor.excludedApps.isEmpty {
                Divider()
                excludedAppsSection
            }
            Divider() // 水平分割线
            settingsSection
            Divider()
            quitButton
        }
        .padding()         // 四周加内边距
        .frame(width: 340) // 固定宽度 340 点
    }

    // 状态栏区域：显示"监控中: N 个应用"
    // some View：不透明返回类型，告诉编译器"我一定返回某个 View，但类型不重要"
    private var statusSection: some View {
        // HStack：水平布局容器，子视图从左到右排列
        HStack {
            // SF Symbol 图标，systemName 使用系统内置图标名
            Image(systemName: "eye")
            // 字符串插值：\(变量) 将变量值嵌入字符串
            Text("监控中: \(monitor.monitoredAppCount) 个应用")
                .font(.headline) // 标题字体
        }
    }

    // 空闲应用列表区域
    private var idleAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("空闲应用:")
                .font(.subheadline)
                .foregroundColor(.secondary) // 次级文字颜色（灰色）

            // ForEach：遍历数组，为每个元素生成一个 View
            // monitor.idleApps 是 [IdleAppInfo]，IdleAppInfo 遵循 Identifiable
            ForEach(monitor.idleApps) { app in
                idleAppRow(app) // 调用函数生成每一行
            }
        }
    }

    // 单个空闲应用的展示行，点击弹出子菜单"退出"/"排除"
    // 空闲时长显示在右侧，子菜单顶部也会显示完整时长信息
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

    // 将 NSImage 转为 SwiftUI Image，nil 时返回占位图标
    private func appIcon(_ nsImage: NSImage?) -> some View {
        Group {
            if let nsImage {
                Image(nsImage: nsImage).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 12)).foregroundColor(.orange).frame(width: 16, height: 16)
            }
        }
    }

    // 根据 Bundle ID 查找运行中应用的图标，未运行则返回占位图标
    private func appIcon(for bundleID: String) -> some View {
        let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
        return appIcon(icon)
    }

    // 已排除的应用列表，可在此恢复监控
    private var excludedAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("已排除:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ForEach(Array(monitor.excludedApps.keys.sorted()), id: \.self) { bundleID in
                // Menu 嵌套在 MenuBarExtra 中会渲染为子菜单，点击弹出操作项
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
    }

    // 设置区域：空闲阈值选择器
    private var settingsSection: some View {
        // Menu：图标和文字合为一行，点击弹出选项列表，当前选项带 ✓
        Menu {
            Button(monitor.idleThresholdMinutes == 1  ? "1 分钟 ✓" : "1 分钟")   { monitor.idleThresholdMinutes = 1 }
            Button(monitor.idleThresholdMinutes == 5  ? "5 分钟 ✓" : "5 分钟")  { monitor.idleThresholdMinutes = 5 }
            Button(monitor.idleThresholdMinutes == 10 ? "10 分钟 ✓" : "10 分钟") { monitor.idleThresholdMinutes = 10 }
            Button(monitor.idleThresholdMinutes == 20 ? "20 分钟 ✓" : "20 分钟") { monitor.idleThresholdMinutes = 20 }
            Button(monitor.idleThresholdMinutes == 30 ? "30 分钟 ✓" : "30 分钟") { monitor.idleThresholdMinutes = 30 }
            Button(monitor.idleThresholdMinutes == 60 ? "60 分钟 ✓" : "60 分钟") { monitor.idleThresholdMinutes = 60 }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                Text("空闲阈值: \(monitor.idleThresholdMinutes) 分钟")
            }
        }
    }

    // 退出本应用的按钮
    private var quitButton: some View {
        Button {
            // NSApplication.shared.terminate(nil)：退出整个应用
            NSApplication.shared.terminate(nil)
        } label: {
            HStack {
                Image(systemName: "power")
                Text("退出 QPHelper")
            }
            .frame(maxWidth: .infinity) // 按钮撑满宽度
        }
        .buttonStyle(.borderless)       // 无边框按钮
        .foregroundColor(.secondary)    // 灰色文字
    }

    // 将秒数格式化为中文时长，如 "30 分钟"、"2 小时 10 分钟"
    private func formatIdleDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60) // Int() 截断小数部分，只取整数分钟
        if minutes < 60 {
            return "\(minutes) 分钟"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60 // % 取余数
        if remainingMinutes == 0 {
            return "\(hours) 小时"
        }
        return "\(hours) 小时 \(remainingMinutes) 分钟"
    }
}
