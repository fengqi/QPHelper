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

    // 单个空闲应用的展示行，包含"退出"和"排除"两个操作按钮
    private func idleAppRow(_ app: AppMonitor.IdleAppInfo) -> some View {
        HStack {
            Image(systemName: "app.dashed")
                .foregroundColor(.orange) // 橙色图标

            VStack(alignment: .leading) {
                Text(app.appName)
                    .font(.system(size: 13, weight: .medium)) // 自定义字号和字重
                Text("空闲 \(formatIdleDuration(app.idleDuration))")
                    .font(.caption)              // 小号说明文字
                    .foregroundColor(.secondary)  // 灰色文字
            }

            Spacer() // 弹性空间：把左侧内容推到左边，右侧内容推到右边

            // 排除按钮：将此应用从监控列表中移除，不再弹出通知
            Button("排除") {
                monitor.excludeApp(bundleID: app.bundleIdentifier, appName: app.appName)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundColor(.secondary)

            Button("退出") {
                // 点击后调用 monitor 的 quitApp 方法退出该应用
                monitor.quitApp(bundleIdentifier: app.bundleIdentifier)
            }
            .buttonStyle(.borderedProminent) // 实心突出按钮样式
            .controlSize(.small)              // 小号按钮
            .tint(.orange)                    // 按钮颜色
        }
        .padding(.vertical, 2) // 垂直方向 2 点内边距
    }

    // 已排除的应用列表，可在此恢复监控
    private var excludedAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("已排除:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // 字典的 keys 转成排序后的数组再遍历
            ForEach(Array(monitor.excludedApps.keys.sorted()), id: \.self) { bundleID in
                HStack {
                    Image(systemName: "nosign")
                        .foregroundColor(.secondary)
                    Text(monitor.excludedApps[bundleID] ?? bundleID)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("恢复") {
                        monitor.unexcludeApp(bundleID: bundleID)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(.blue)
                }
            }
        }
    }

    // 设置区域：空闲阈值选择器
    private var settingsSection: some View {
        HStack {
            Image(systemName: "timer")
            Text("空闲阈值:")
            // Picker：下拉选择器
            // $monitor.idleThresholdMinutes：双向绑定
            // 用户选择 → 自动更新 monitor.idleThresholdMinutes
            // monitor.idleThresholdMinutes 变化 → 自动更新 Picker 显示
            Picker("", selection: $monitor.idleThresholdMinutes) {
                // .tag()：给每个选项赋一个 Int 值，对应 Selection 的类型
                Text("5 分钟").tag(5)
                Text("10 分钟").tag(10)
                Text("20 分钟").tag(20)
                Text("30 分钟").tag(30)
                Text("60 分钟").tag(60)
            }
            .pickerStyle(.menu)   // 下拉菜单样式
            .frame(maxWidth: 120) // 限制宽度
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
