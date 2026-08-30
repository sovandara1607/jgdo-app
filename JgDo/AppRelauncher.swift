import AppKit

/// Quits and relaunches JgDo — needed because Screen Recording permission,
/// unlike Accessibility, doesn't take effect in an already-running process.
/// `CGPreflightScreenCaptureAccess()` keeps returning the old (denied)
/// answer until the app actually restarts, no matter how often it's
/// re-checked.
enum AppRelauncher {
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
