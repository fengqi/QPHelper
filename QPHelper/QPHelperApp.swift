import SwiftUI
import ServiceManagement

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = AppMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        monitor.start()

        // 首次启动默认开启开机启动
        if !UserDefaults.standard.bool(forKey: "didSetupLaunchAtLogin") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetupLaunchAtLogin")
        }
    }
}
