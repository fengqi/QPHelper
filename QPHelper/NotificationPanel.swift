import AppKit
import SwiftUI

// 自定义悬浮通知面板：右上角弹出，卡片式布局，用户操作后才消失
// NSPanel 是 NSWindow 的子类，专为辅助面板设计（无标题栏、不抢占焦点）
// NSWindowDelegate 协议：允许监听面板关闭等窗口事件
final class NotificationPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var onDismiss: (() -> Void)?

    // computed property：检查面板是否正在显示
    var isShowing: Bool { panel != nil }

    func show(
        appName: String,
        icon: NSImage?,
        idleDuration: TimeInterval,
        // @escaping：标记闭包可能被延后调用（闭包被存储、异步回调等）
        // 默认闭包是 @noescape（同步执行），异步保留需要 @escaping，类似 Go 中把 func 存入 struct 字段
        onQuit: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onKeep: @escaping () -> Void,
        onExclude: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        close()
        self.onDismiss = onDismiss

        let contentView = PanelContentView(
            appName: appName,
            icon: icon,
            idleDuration: idleDuration,
            onQuit: { [weak self] in
                onQuit()
                self?.dismiss()
            },
            onRestart: { [weak self] in
                onRestart()
                self?.dismiss()
            },
            onKeep: { [weak self] in
                onKeep()
                self?.dismiss()
            },
            onExclude: { [weak self] in
                onExclude()
                self?.dismiss()
            },
            onActivate: {
                onActivate()
            }
        )

        // NSHostingView：在 AppKit 视图中嵌入 SwiftUI View 的桥梁
        // 类似 Flutter 的 PlatformView 或 React Native 的 Native Module
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame.size = hostingView.fittingSize
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 16
        hostingView.layer?.masksToBounds = true

        // NSPanel 配置：
        // - .nonactivatingPanel：不激活应用，不抢夺焦点
        // - .borderless：无边框（自定义外观）
        // - .buffered：双缓冲渲染
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false                    // 非不透明 → 允许透明（毛玻璃效果需要）
        panel.backgroundColor = .clear             // 透明背景
        panel.hasShadow = true                     // 窗口阴影
        panel.level = .floating                    // 浮动层级（在所有普通窗口之上）
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]  // 跟随所有 Space，不随 Space 切换消失
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false         // 关闭时不销毁窗口（我们手动管理生命周期）
        panel.delegate = self                      // 设置代理，监听窗口关闭事件

        positionAtTopRight(panel)

        // orderFront(nil)：将面板显示到屏幕最前面
        // 不同于 makeKeyAndOrderFront（会让面板成为 key window），.nonactivatingPanel 不能用后者
        panel.orderFront(nil)
        self.panel = panel
    }

    func close() {
        guard panel != nil else { return }
        onDismiss?()
        onDismiss = nil
        panel?.close()
        panel = nil
    }

    // NSWindowDelegate 回调：窗口关闭时触发
    func windowWillClose(_ notification: Notification) {
        if let d = onDismiss {
            onDismiss = nil
            panel = nil
            d()
        } else {
            panel = nil
        }
    }

    private func dismiss() {
        guard panel != nil else { return }
        onDismiss?()
        onDismiss = nil
        panel?.close()
        panel = nil
    }

    // 将窗口定位到屏幕右上角
    private func positionAtTopRight(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame     // 可见区域（排除菜单栏和 Dock 区域）
        let windowFrame = window.frame
        let x = screenFrame.maxX - windowFrame.width - 18
        let y = screenFrame.maxY - windowFrame.height - 18
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// 悬浮面板内容：图标 + 应用名 + 闲置时长 + 提示文字 + 操作按钮
// 卡片式布局，毛玻璃背景，16pt 连续圆角
private struct PanelContentView: View {
    let appName: String
    let icon: NSImage?
    let idleDuration: TimeInterval
    let onQuit: () -> Void
    let onRestart: () -> Void
    let onKeep: () -> Void
    let onExclude: () -> Void
    let onActivate: () -> Void

    // @State：View 内部的局部状态，变化时 View 重新渲染
    // 类似 React 的 useState
    @State private var retainHovered = false
    @State private var excludeHovered = false
    @State private var restartHovered = false
    @State private var quitHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                // 应用图标：点击打开该应用（onActivate）
                appIcon
                    .onTapGesture { onActivate() }

                VStack(alignment: .leading, spacing: 4) {
                    Text(appName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("已闲置 \(formatDuration(idleDuration))")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("要退出这个应用吗？")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)  // 允许垂直扩展（换行）
                }
            }

            Spacer(minLength: 12)  // 最小 12pt 间距

            HStack(spacing: 8) {
                Spacer()  // 将按钮推到右侧

                Button("保留") { onKeep() }
                    .buttonStyle(NotificationActionButtonStyle(isHovered: retainHovered, isPrimary: false))
                    // onHover：SwiftUI 的鼠标悬停事件（macOS 独有）
                    .onHover { retainHovered = $0 }

                Button("排除") { onExclude() }
                    .buttonStyle(NotificationActionButtonStyle(isHovered: excludeHovered, isPrimary: false))
                    .onHover { excludeHovered = $0 }

                Button("重启") { onRestart() }
                    .buttonStyle(NotificationActionButtonStyle(isHovered: restartHovered, isPrimary: false))
                    .onHover { restartHovered = $0 }

                Button("退出") { onQuit() }
                    .buttonStyle(NotificationActionButtonStyle(isHovered: quitHovered, isPrimary: false))
                    .onHover { quitHovered = $0 }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 342, height: 112, alignment: .topLeading)
        .background(
            // .regularMaterial：系统毛玻璃材质（类似 iOS 的 UIVisualEffectView）
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            // 半透明白色描边：增强卡片边界感
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
            // contentShape：定义点击/拖拽的命中区域
            // RoundedRectangle：从 macOS 原生继承来的 shape，支持连续曲率圆角
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            // 点击卡片任意位置 = "保留"
            .onTapGesture(perform: onKeep)
    }

    // @ViewBuilder：允许返回条件分支的不同 View 类型
    // 类似 Swift 的 result builder 语法糖
    @ViewBuilder
    private var appIcon: some View {
        if let icon {
            // Image(nsImage:) 加载 NSImage（AppKit 图片格式）到 SwiftUI
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))  // 裁剪圆角
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)  // 边框
                )
        } else {
            // 占位：半透明圆角方块 + SF Symbol 图标
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.secondary.opacity(0.14))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "app")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
        }
    }

    // 秒 → 中文时长格式化
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(remainingMinutes) 分钟"
    }
}

// 胶囊按钮样式：hover 变黑底白字，默认玻璃质感
// ButtonStyle 协议：自定义 SwiftUI Button 的外观
// 类似 CSS 的 class 或主题系统中的样式定义
private struct NotificationActionButtonStyle: ButtonStyle {
    let isHovered: Bool    // 鼠标是否悬停
    let isPrimary: Bool    // 是否为主按钮（权重更大）

    // makeBody：实现 ButtonStyle 协议的唯一方法
    // configuration.label：按钮的内容（Text/Image 等）
    // configuration.isPressed：按钮是否正在被按下
    func makeBody(configuration: Configuration) -> some View {
        let isActive = isHovered || configuration.isPressed

        return configuration.label
            .font(.system(size: 12.5, weight: isPrimary ? .semibold : .regular))
            .foregroundStyle(isActive ? .white : (isPrimary ? .primary : .secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                // hover/按下时黑底，否则白色半透明
                Capsule(style: .continuous)  // Capsule = 胶囊形（两端半圆的矩形）
                    .fill(isActive ? Color.black.opacity(configuration.isPressed ? 0.45 : 0.35)
                                  : (isPrimary ? Color.white.opacity(0.18) : Color.white.opacity(0.04)))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(isActive ? 0 : (isPrimary ? 0.08 : 0.05)), lineWidth: 1)
            )
            .contentShape(Capsule(style: .continuous))
            // animation：状态变化时的过渡动画（.easeInOut = 缓入缓出）
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
