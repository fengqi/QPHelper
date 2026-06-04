import SwiftUI
import UserNotifications

// @main 标记整个程序的入口点，等同于其他语言的 main() 函数
@main
struct QPHelperApp: App {
    // @NSApplicationDelegateAdaptor 将 AppDelegate 注册为 NSApp 的委托对象
    // 委托模式：系统在特定生命周期时刻（启动、退出等）回调 AppDelegate 的方法
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // body 是 App 协议要求的计算属性，返回应用的"场景"集合
    var body: some Scene {
        // MenuBarExtra：SwiftUI 原生的菜单栏图标场景（macOS 13+）
        // 不需要 WindowGroup，应用不会显示窗口和 Dock 图标
        MenuBarExtra {
            // 点击状态栏图标后弹出的菜单内容
            MenuView(monitor: appDelegate.monitor)
        } label: {
            // 状态栏上显示的图标，renderingMode(.template) 让图标适配亮色/暗色模式
            Image("StatusBarIcon").renderingMode(.template)
        }
    }
}

// AppDelegate：应用生命周期和系统通知的接收者
// 遵循 NSObject（OC 兼容）、NSApplicationDelegate（应用事件）、
//   UNUserNotificationCenterDelegate（通知交互事件）
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let monitor = AppMonitor()

    // 应用完成启动后调用，是初始化的最佳时机
    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory 策略：不显示 Dock 图标，纯后台/菜单栏应用
        NSApp.setActivationPolicy(.accessory)

        let center = UNUserNotificationCenter.current()
        center.delegate = self // 设置通知代理为自己，才能收到通知按钮点击事件
        monitor.requestNotificationPermission() // 请求通知权限+注册通知按钮
        monitor.start() // 开始监听应用切换事件
    }

    // 用户点击了通知上的按钮（"退出"或"保留"）
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        monitor.handleNotificationResponse(response)
        completionHandler() // 必须调用，告诉系统"已处理完毕"
    }

    // 应用在前台时收到通知是否也要弹出横幅
    // 菜单栏应用通常不在"前台"，这个方法主要是兜底
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound]) // 前台也弹横幅+声音
    }
}
