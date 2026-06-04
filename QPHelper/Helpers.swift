import AppKit
import SwiftUI

// 共享格式化：秒 → 中文时长
func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes) 分钟" }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if remainingMinutes == 0 { return "\(hours) 小时" }
    return "\(hours) 小时 \(remainingMinutes) 分钟"
}

// 从运行中应用查找图标，未找到显示占位符
struct AppIconView: View {
    let bundleID: String

    var body: some View {
        let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
        Group {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 12)).foregroundColor(.orange).frame(width: 16, height: 16)
            }
        }
    }
}
