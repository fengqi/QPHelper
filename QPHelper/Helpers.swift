import AppKit
import SwiftUI

// 共享格式化：秒 → 中文时长（如 90 → "1 分钟"，3660 → "1 小时 1 分钟"）
// 全局函数，类似 Java 的 static util method
func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)  // Int() 截断小数，只取整数分钟
    if minutes < 60 { return "\(minutes) 分钟" }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60  // % 取余数
    if remainingMinutes == 0 { return "\(hours) 小时" }
    return "\(hours) 小时 \(remainingMinutes) 分钟"
}

// 从运行中应用实时查找图标，未找到时显示占位符
// 不持有 NSImage 引用（每次渲染时查找），避免内存中未使用的图标积压
struct AppIconView: View {
    let bundleID: String

    var body: some View {
        // runningApplications(withBundleIdentifier:)：实时查找运行中的应用实例
        let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
        // Group：不改变布局的透明容器（类似 React Fragment <>...</>）
        Group {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                // 占位：SF Symbol 虚线应用图标 + 橙色
                Image(systemName: "app.dashed").font(.system(size: 12)).foregroundColor(.orange).frame(width: 16, height: 16)
            }
        }
    }
}
