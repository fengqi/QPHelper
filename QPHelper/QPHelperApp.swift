import SwiftUI
import ServiceManagement

// @main = Go/Java 的 main() 函数，标记程序入口点
@main
struct QPHelperApp: App {
    // @NSApplicationDelegateAdaptor：将 AppDelegate 注册为 NSApp 的 delegate
    // delegate 模式类似 Java 的 listener/callback：系统在特定生命周期回调 AppDelegate 的方法
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // body 是 App 协议的约定属性，返回应用的"场景"集合
    // SwiftUI 的 App 场景：WindowGroup（多窗口）、MenuBarExtra（菜单栏）、DocumentGroup（文稿应用）等
    var body: some Scene {
        // MenuBarExtra：macOS 13+ 原生菜单栏图标组件
        // 不需要 WindowGroup，应用不会显示 Dock 图标（配合 LSUIElement = YES）
        MenuBarExtra {
            // 点击菜单栏图标后弹出的下拉菜单内容
            MenuView(monitor: appDelegate.monitor)
        } label: {
            // 菜单栏上显示的图标
            // renderingMode(.template)：让图标作为模板着色，自动适配亮色/暗色模式
            Image("StatusBarIcon").renderingMode(.template)
                .frame(width: 22, height: 22)
        }
    }
}

// NSApplicationDelegate：应用生命周期回调（类似 Android 的 Application.ActivityLifecycleCallbacks）
// NSObject：所有 ObjC 类的基类，类似 Java 的 Object
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = AppMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory 策略：不显示 Dock 图标，纯菜单栏/后台运行模式
        // 等价于 Info.plist 中 LSUIElement = YES
        NSApp.setActivationPolicy(.accessory)
        monitor.start()

        // 首次启动自动注册开机启动
        // UserDefaults = Android SharedPreferences / Go 内嵌 key-value store
        // SMAppService.mainApp.register()：将本应用加入系统「登录项」列表
        if !UserDefaults.standard.bool(forKey: "didSetupLaunchAtLogin") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetupLaunchAtLogin")
        }
    }
}
