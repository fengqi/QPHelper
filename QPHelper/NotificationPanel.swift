import AppKit
import SwiftUI

// 自定义悬浮通知面板：右上角弹出，不自动消失，卡片式布局
final class NotificationPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var onDismiss: (() -> Void)?

    var isShowing: Bool { panel != nil }

    func show(
        appName: String,
        icon: NSImage?,
        idleDuration: TimeInterval,
        onQuit: @escaping () -> Void,
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

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame.size = hostingView.fittingSize
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 16
        hostingView.layer?.masksToBounds = true

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        positionAtTopRight(panel)

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

    private func positionAtTopRight(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowFrame = window.frame
        let x = screenFrame.maxX - windowFrame.width - 18
        let y = screenFrame.maxY - windowFrame.height - 18
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// 悬浮面板内容：通知卡片风格，上排图标+文字，下排操作按钮
private struct PanelContentView: View {
    let appName: String
    let icon: NSImage?
    let idleDuration: TimeInterval
    let onQuit: () -> Void
    let onKeep: () -> Void
    let onExclude: () -> Void
    let onActivate: () -> Void

    @State private var retainHovered = false
    @State private var excludeHovered = false
    @State private var quitHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Spacer()

                Button("保留") { onKeep() }
                    .buttonStyle(NotificationActionButtonStyle(isHovered: retainHovered, isPrimary: false))
                    .onHover { retainHovered = $0 }

                Button("排除") { onExclude() }
                    .buttonStyle(NotificationActionButtonStyle(isHovered: excludeHovered, isPrimary: false))
                    .onHover { excludeHovered = $0 }

                Button("退出") { onQuit() }
                    .buttonStyle(NotificationActionButtonStyle(isHovered: quitHovered, isPrimary: false))
                    .onHover { quitHovered = $0 }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 342, height: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onKeep)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        } else {
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
private struct NotificationActionButtonStyle: ButtonStyle {
    let isHovered: Bool
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isActive = isHovered || configuration.isPressed

        return configuration.label
            .font(.system(size: 12.5, weight: isPrimary ? .semibold : .regular))
            .foregroundStyle(isActive ? .white : (isPrimary ? .primary : .secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? Color.black.opacity(configuration.isPressed ? 0.45 : 0.35)
                                  : (isPrimary ? Color.white.opacity(0.18) : Color.white.opacity(0.04)))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(isActive ? 0 : (isPrimary ? 0.08 : 0.05)), lineWidth: 1)
            )
            .contentShape(Capsule(style: .continuous))
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
