import AppKit

// MARK: - Built-in layout presets

enum BuiltinLayout: String, CaseIterable, Identifiable {
    case codingMode       = "Coding Mode"
    case researchMode     = "Research Mode"
    case communicationMode = "Communication Mode"
    case split50_50       = "50 / 50"
    case split70_30       = "70 / 30"
    case split30_70       = "30 / 70"
    case tripleColumn     = "3 Columns"
    case grid2x2          = "2 × 2 Grid"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .codingMode:        return "chevron.left.forwardslash.chevron.right"
        case .researchMode:      return "books.vertical"
        case .communicationMode: return "bubble.left.and.bubble.right"
        case .split50_50:        return "rectangle.split.2x1"
        case .split70_30:        return "rectangle.lefthalf.inset.filled"
        case .split30_70:        return "rectangle.righthalf.inset.filled"
        case .tripleColumn:      return "rectangle.split.3x1"
        case .grid2x2:           return "rectangle.split.2x2"
        }
    }

    var description: String {
        switch self {
        case .codingMode:        return "60% left · 40% right"
        case .researchMode:      return "2 × 2 grid"
        case .communicationMode: return "70% left · 30% right"
        case .split50_50:        return "Two equal halves"
        case .split70_30:        return "Large left · small right"
        case .split30_70:        return "Small left · large right"
        case .tripleColumn:      return "Three equal columns"
        case .grid2x2:           return "Four equal quadrants"
        }
    }

    /// Number of windows this layout places
    var windowCount: Int {
        switch self {
        case .codingMode, .communicationMode,
             .split50_50, .split70_30, .split30_70: return 2
        case .researchMode, .grid2x2:               return 4
        case .tripleColumn:                          return 3
        }
    }

    /// Returns AppKit-coordinate frames on the given screen's visible area.
    func frames(on screen: NSScreen) -> [CGRect] {
        // Reserve a gap around edges and between tiles. Insetting the work area
        // by half a gap and each resulting tile by half a gap makes every seam
        // (and every outer margin) exactly one full gap wide.
        let hg = max(WindowResizeService.shared.edgeGap, 0) / 2
        let r = screen.visibleFrame.insetBy(dx: hg, dy: hg)
        let (x, y, w, h) = (r.minX, r.minY, r.width, r.height)
        let raw: [CGRect]
        switch self {
        case .codingMode:
            raw = [
                CGRect(x: x,         y: y, width: w * 0.6, height: h),
                CGRect(x: x + w*0.6, y: y, width: w * 0.4, height: h)
            ]
        case .communicationMode:
            raw = [
                CGRect(x: x,         y: y, width: w * 0.7, height: h),
                CGRect(x: x + w*0.7, y: y, width: w * 0.3, height: h)
            ]
        case .researchMode, .grid2x2:
            raw = [
                CGRect(x: x,         y: y + h/2, width: w/2, height: h/2),
                CGRect(x: x + w/2,   y: y + h/2, width: w/2, height: h/2),
                CGRect(x: x,         y: y,        width: w/2, height: h/2),
                CGRect(x: x + w/2,   y: y,        width: w/2, height: h/2)
            ]
        case .split50_50:
            raw = [
                CGRect(x: x,       y: y, width: w/2, height: h),
                CGRect(x: x + w/2, y: y, width: w/2, height: h)
            ]
        case .split70_30:
            raw = [
                CGRect(x: x,         y: y, width: w * 0.7, height: h),
                CGRect(x: x + w*0.7, y: y, width: w * 0.3, height: h)
            ]
        case .split30_70:
            raw = [
                CGRect(x: x,         y: y, width: w * 0.3, height: h),
                CGRect(x: x + w*0.3, y: y, width: w * 0.7, height: h)
            ]
        case .tripleColumn:
            raw = [
                CGRect(x: x,           y: y, width: w/3, height: h),
                CGRect(x: x + w/3,     y: y, width: w/3, height: h),
                CGRect(x: x + (w/3)*2, y: y, width: w/3, height: h)
            ]
        }
        // Pull each tile back by half a gap on all sides → uniform seams.
        return raw.map { $0.insetBy(dx: hg, dy: hg) }
    }
}

// MARK: - Layout engine

final class LayoutEngine {
    static let shared = LayoutEngine()
    private let service = WindowManagerService()
    private init() {}

    /// Applies the layout to the first `layout.windowCount` windows simultaneously.
    func apply(_ layout: BuiltinLayout, to windows: [WindowInfo]) {
        guard let screen = NSScreen.main else { return }
        let frames = layout.frames(on: screen)
        for (window, frame) in zip(windows.prefix(frames.count), frames) {
            service.applyFrame(frame, to: window, on: screen)
        }
    }

    /// Applies the layout to the N most recently active apps simultaneously.
    /// Uses HUDState.shared.recentApps for ordering (most recent first).
    func applyToRecentApps(_ layout: BuiltinLayout) {
        let recentApps = HUDState.shared.recentApps.filter { !$0.isTerminated }
        guard !recentApps.isEmpty, let screen = NSScreen.main else { return }
        let frames = layout.frames(on: screen)
        for (app, frame) in zip(recentApps.prefix(frames.count), frames) {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString,
                                                &ref) == .success, let ref else { continue }
            applyAXFrame(frame, to: ref as! AXUIElement, on: screen)
        }
        recentApps.first?.activate()
    }

    private func applyAXFrame(_ frame: CGRect, to axWindow: AXUIElement, on screen: NSScreen) {
        let mainH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        var origin = CGPoint(x: frame.minX, y: mainH - frame.maxY)
        var size   = CGSize(width: frame.width, height: frame.height)
        if let pv = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, pv)
        }
        if let sv = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sv)
        }
    }
}
