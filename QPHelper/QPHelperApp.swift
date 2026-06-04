import SwiftUI

@main
struct QPHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(monitor: appDelegate.monitor)
        } label: {
            Image("StatusBarIcon").renderingMode(.template)
                .frame(width: 22, height: 22)
        }
    }
}

// AppDelegate：应用生命周期接收者
// 遵循 NSObject（OC 兼容）、NSApplicationDelegate（应用事件）
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = AppMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory 策略：不显示 Dock 图标，纯后台/菜单栏应用
        NSApp.setActivationPolicy(.accessory)
        monitor.start()
    }
}
