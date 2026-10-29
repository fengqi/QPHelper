import AppKit
import CoreAudio

// 音频播放检测器：通过 Core Audio 公开 API 判断哪些应用正在输出音频
//
// 原理：
//   1. kAudioHardwarePropertyProcessObjectList（'prs#'）列出所有连接到 HAL 的客户端进程
//      （HAL = Hardware Abstraction Layer，macOS 的音频硬件抽象层，类似 Linux 的 ALSA）
//   2. 对每个进程查 kAudioProcessPropertyIsRunningOutput（'piro'），
//      非 0 表示该进程至少有一条活跃的输出流（真的在出声）
//   3. 通过 PID 反查归属应用的 Bundle ID
//
// 这是纯属性查询，不需要麦克风/系统录音权限（那是创建 Process Tap 才需要的）。
// 查询走 coreaudiod（系统音频守护进程）跨进程通信，单次开销微秒级，可放心高频调用。
enum AudioPlayingDetector {
    /// 返回当前正在输出音频的应用 Bundle ID 集合
    /// 后台播放音乐的播放器会出现在这里，空闲检测应跳过它们
    /// 查询失败时返回空集合，调用方行为退化为原有的纯时间判定（fail-open）
    static func playingAppBundleIDs() -> Set<String> {
        // PID → Bundle ID 映射：AppKit 视角的应用（覆盖普通应用进程）
        var pidToBundle: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, app.processIdentifier > 0 else { continue }
            pidToBundle[pid_t(app.processIdentifier)] = bundleID
        }

        var result: Set<String> = []
        for pid in pidsOutputtingAudio() {
            // 优先从可执行路径反推宿主 .app：Chromium/Electron 应用的音频常由 Helper 进程输出，
            // AppKit 给 Helper 的 bundle ID 是 "xxx.helper"，和被跟踪的宿主应用 "xxx" 对不上；
            // 路径向上找最外层 .app 才能拿到正确的宿主 Bundle ID
            if let bundleID = bundleIDFromExecutablePath(pid: pid) {
                result.insert(bundleID)
            } else if let bundleID = pidToBundle[pid] {
                // proc_pidpath 失败（如权限问题）时退回 AppKit 映射
                result.insert(bundleID)
            }
        }
        return result
    }

    /// 返回当前至少有一条活跃输出流的进程 PID 集合
    private static func pidsOutputtingAudio() -> Set<pid_t> {
        // AudioObjectPropertyAddress = 属性查询三元组（selector 查什么，scope 查哪个方向，element 查哪个通道）
        // kAudioObjectPropertyElementMain = 主通道（macOS 12 前叫 kAudioObjectPropertyElementMaster）
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        // 两段式查询：先问数据多大（GetPropertyDataSize），再按实际大小取数（GetPropertyData）
        // 这是 C API 的惯用模式，类似 Go 里先 cap 后 copy
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size)
        guard status == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var processIDs = [AudioObjectID](repeating: AudioObjectID(0), count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &processIDs)
        guard status == noErr else { return [] }

        var result: Set<pid_t> = []
        for processID in processIDs {
            // 查该进程的 PID
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &pid) == noErr
            else { continue }

            // 查该进程是否在输出音频（UInt32，非 0 = 至少一条活跃输出流）
            // 只在真有数据送往输出设备时为 1，暂停后即变 0
            var outAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var runningOutput: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(processID, &outAddress, 0, nil, &runningSize, &runningOutput) == noErr,
                  runningOutput != 0
            else { continue }

            result.insert(pid)
        }
        return result
    }

    // proc_pidpath 缓冲区大小（libproc.h 中 PROC_PIDPATHINFO_MAXSIZE 的值）
    private static let pidPathBufferSize = 4 * 1024

    /// 通过进程可执行文件路径反推宿主应用的 Bundle ID
    /// 从可执行路径逐级向上找 .app 目录，保留最外层那个
    /// 例：/Applications/Spotify.app/Contents/Frameworks/Spotify Helper.app/Contents/MacOS/...
    ///   → 命中 Spotify Helper.app 后继续向上，最终保留 Spotify.app
    private static func bundleIDFromExecutablePath(pid: pid_t) -> String? {
        // proc_pidpath：把 PID 解析成可执行文件绝对路径（libproc.h，无需特殊权限）
        var buffer = [CChar](repeating: 0, count: pidPathBufferSize)
        guard proc_pidpath(pid, &buffer, UInt32(pidPathBufferSize)) > 0 else { return nil }
        let executablePath = String(cString: buffer)

        var url = URL(fileURLWithPath: executablePath)
        var outermostApp: URL?
        while url.path != "/" {
            if url.pathExtension == "app" { outermostApp = url }
            url = url.deletingLastPathComponent()
        }
        guard let appURL = outermostApp else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }
}
