import AppKit
import CoreGraphics

struct WindowInfo: Identifiable, Hashable {
    let id = UUID()
    let windowID: CGWindowID
    let appName: String
    let windowTitle: String
    let pid: pid_t
    let icon: NSImage?
    let bounds: CGRect

    func hash(into hasher: inout Hasher) { hasher.combine(windowID) }
    static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool { lhs.windowID == rhs.windowID }
}
