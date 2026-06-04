import AppKit
import SwiftUI

// 自定义悬浮通知面板：模仿 macOS 通知的紧凑样式，右上角弹出，不自动消失
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
            }
        )

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame.size = hostingView.fittingSize

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

        panel.makeKeyAndOrderFront(nil)
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
        let x = screenFrame.maxX - windowFrame.width - 20
        let y = screenFrame.maxY - windowFrame.height - 20
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// 悬浮面板的 SwiftUI 内容：卡片式，右上角关闭按钮，按钮在右下角
private struct PanelContentView: View {
    let appName: String
    let icon: NSImage?
    let idleDuration: TimeInterval
    let onQuit: () -> Void
    let onKeep: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 36, height: 36)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\"\(appName)\" 已 \(formatDuration(idleDuration)) 未使用")
                            .font(.system(size: 14, weight: .medium))
                        Text("要退出这个应用吗？")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer(minLength: 8)

                HStack {
                    Spacer()
                    Button("保留") { onKeep() }
                        .buttonStyle(.plain)
                        .controlSize(.regular)
                        .foregroundColor(.secondary)
                    Button("退出") { onQuit() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .tint(.orange)
                }
            }
            .padding(16)

            // 右上角灰色关闭按钮
            Button { onKeep() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary.opacity(0.5))
            .padding(6)
            .help("关闭")
        }
        .frame(width: 360, height: 130)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onKeep) // 点击非按钮区域 = 关闭
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
