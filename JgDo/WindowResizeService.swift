import AppKit
import ApplicationServices

final class WindowResizeService {
    static let shared = WindowResizeService()

    var targetApp: NSRunningApplication?

    /// Padding (in points) left around the screen edges and between tiled
    /// windows, so snapped windows don't sit flush against the bezel or each
    /// other. User-configurable (persisted in UserDefaults); 0 = edge-to-edge.
    var edgeGap: CGFloat {
        let v = UserDefaults.standard.double(forKey: AppSettings.edgeGapKey)
        return CGFloat(min(max(v, AppSettings.edgeGapRange.lowerBound),
                           AppSettings.edgeGapRange.upperBound))
    }

    private init() {}

    /// Returns the frame (AppKit coords) it actually applied — for edge-snap
    /// layouts that may be mid-cycle, that's *not* necessarily what
    /// `frame(for:on:)` would return, so callers that flash a ghost preview
    /// of the result (rather than a fixed preset) should use this directly.
    @discardableResult
    func resizeFrontmostWindow(to layout: WindowLayout) -> CGRect? {
        let app = targetApp ?? NSWorkspace.shared.frontmostApplication
        guard let app else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        let axWindow = ref as! AXUIElement

        let screen = screenForWindow(axWindow) ?? NSScreen.main ?? NSScreen.screens[0]
        let frame: CGRect
        if Self.cyclableLayouts.contains(layout) {
            frame = cycledFrame(for: layout, on: screen, axWindow: axWindow)
        } else {
            lastCycleLayout = nil   // any non-cyclable action breaks the cycle
            frame = targetFrame(for: layout, on: screen)
        }
        apply(frame: frame, to: axWindow, screen: screen)
        return frame
    }

    /// Public frame lookup used by the snap-preview overlay.
    func frame(for layout: WindowLayout, on screen: NSScreen) -> CGRect {
        targetFrame(for: layout, on: screen)
    }

    /// Resize the focused window of an arbitrary app (used by the switcher's pick).
    /// Returns true if a window was found and resized.
    @discardableResult
    func resize(app: NSRunningApplication, to layout: WindowLayout) -> Bool {
        resize(app: app, to: layout, fraction: 0.5) != nil
    }

    /// Resize the topmost on-screen window that does NOT belong to `frontPID`.
    /// This is the "any other visible window" partner for a dual snap. Tries each
    /// candidate in front-to-back order until one actually resizes (some apps
    /// expose no resizable focused window). Does not change focus.
    /// Returns true if a partner window was resized.
    @discardableResult
    func resizeOtherVisibleWindow(excluding frontPID: pid_t?, to layout: WindowLayout) -> Bool {
        resizeOtherVisibleWindow(excluding: frontPID, to: layout, fraction: 0.5) != nil
    }

    /// Same as `resizeOtherVisibleWindow(excluding:to:)`, but at an explicit
    /// fraction of the screen instead of always exactly half — used to keep
    /// a dual-snap partner complementary to the primary window's current
    /// edge-snap cycle step (see `complementFraction(for:)`). Returns the
    /// frame it actually applied (AppKit coords), for the ghost preview.
    @discardableResult
    func resizeOtherVisibleWindow(excluding frontPID: pid_t?, to layout: WindowLayout, fraction: CGFloat) -> CGRect? {
        let windows = WindowManagerService().fetchWindows()   // front-to-back, excludes JgDo
        var seenPIDs = Set<pid_t>()
        for window in windows where window.pid != frontPID {
            guard !seenPIDs.contains(window.pid) else { continue }
            seenPIDs.insert(window.pid)
            if let app = NSRunningApplication(processIdentifier: window.pid),
               let frame = resize(app: app, to: layout, fraction: fraction) {
                return frame
            }
        }
        return nil
    }

    /// A "step/total" cycle position indicator for `layout` (e.g. "2/3"), if
    /// it's currently mid-cycle — nil for a fresh press or a non-cyclable
    /// layout. For the ghost-preview overlay's on-tile label.
    func cycleIndicator(for layout: WindowLayout) -> String? {
        guard layout == lastCycleLayout else { return nil }
        return "\(lastCycleIndex + 1)/\(Self.cycleFractions.count)"
    }

    /// The complementary fraction to whatever the primary window's edge-snap
    /// cycle just landed on for `layout` (e.g. two-thirds → one-third), so a
    /// dual-snap partner can be kept flush against it instead of always
    /// snapping to a fixed half. Falls back to a plain half if `layout`
    /// isn't currently mid-cycle.
    func complementFraction(for layout: WindowLayout) -> CGFloat {
        guard layout == lastCycleLayout, let f = lastCycleFraction else { return 0.5 }
        return 1 - f
    }

    /// Resize the focused window of `app` to `layout` at a given fraction of
    /// the screen (0.5 = the plain preset for edge-anchored halves; ignored
    /// for non-cyclable layouts, which only ever have one size). Returns the
    /// frame it actually applied (AppKit coords), or nil if no window was found.
    @discardableResult
    private func resize(app: NSRunningApplication, to layout: WindowLayout, fraction: CGFloat) -> CGRect? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString,
                                            &ref) == .success, let ref else { return nil }
        let axWindow = ref as! AXUIElement
        let screen = screenForWindow(axWindow) ?? NSScreen.main ?? NSScreen.screens[0]
        let frame: CGRect
        if Self.cyclableLayouts.contains(layout) {
            let g = max(edgeGap, 0)
            let area = screen.visibleFrame.insetBy(dx: g, dy: g)
            frame = edgeFrame(for: layout, fraction: fraction, area: area, hg: g / 2)
        } else {
            frame = targetFrame(for: layout, on: screen)
        }
        apply(frame: frame, to: axWindow, screen: screen)
        return frame
    }

    // MARK: - Private

    private func screenForWindow(_ axWindow: AXUIElement) -> NSScreen? {
        var posRef: CFTypeRef?
        
        
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString,
                                            &posRef) == .success,
              let posRef else { return nil }
        var cgOrigin = CGPoint.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &cgOrigin)
        // CG coords: top-left origin. Convert to AppKit for NSScreen.
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let appKitPoint = CGPoint(x: cgOrigin.x, y: mainH - cgOrigin.y)
        return NSScreen.screens.first { $0.frame.contains(appKitPoint) }
    }

    private func targetFrame(for layout: WindowLayout, on screen: NSScreen) -> CGRect {
        let g = max(edgeGap, 0)
        // Inset the whole working area by the gap so nothing touches the edge…
        let area = screen.visibleFrame.insetBy(dx: g, dy: g)
        let (x, y, w, h) = (area.minX, area.minY, area.width, area.height)
        // …and pull each tile back by half a gap from any shared inner edge, so
        // the seam between two tiles is one full gap wide.
        let hg = g / 2
        switch layout {
        case .leftHalf:    return CGRect(x: x,         y: y,         width: w/2 - hg, height: h)
        case .rightHalf:   return CGRect(x: x+w/2+hg,  y: y,         width: w/2 - hg, height: h)
        case .topHalf:     return CGRect(x: x,         y: y+h/2+hg,  width: w,        height: h/2 - hg)
        case .bottomHalf:  return CGRect(x: x,         y: y,         width: w,        height: h/2 - hg)
        case .topLeft:     return CGRect(x: x,         y: y+h/2+hg,  width: w/2 - hg, height: h/2 - hg)
        case .topRight:    return CGRect(x: x+w/2+hg,  y: y+h/2+hg,  width: w/2 - hg, height: h/2 - hg)
        case .bottomLeft:  return CGRect(x: x,         y: y,         width: w/2 - hg, height: h/2 - hg)
        case .bottomRight: return CGRect(x: x+w/2+hg,  y: y,         width: w/2 - hg, height: h/2 - hg)
        case .maximize:    return area
        case .center:
            let cw = w * 0.6, ch = h * 0.6
            return CGRect(x: x+(w-cw)/2, y: y+(h-ch)/2, width: cw, height: ch)
        }
    }

    /// Repeated presses of the same edge-snap hotkey step the window through
    /// these fractions of the screen along that edge — e.g. ⌃⌥→ cycles
    /// right-half → right-two-thirds → right-third → back to right-half —
    /// instead of always landing on exactly half. The first press keeps
    /// today's exact-half behavior (index 0); only *repeating* the same
    /// hotkey advances further. Matches "map multiple window areas to the
    /// same key, and cycle between them."
    private static let cycleFractions: [CGFloat] = [0.5, 2.0 / 3.0, 1.0 / 3.0]
    private static let cyclableLayouts: Set<WindowLayout> = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]

    private var lastCycleLayout: WindowLayout?
    private var lastCycleIndex = 0
    /// The fraction the last cycle step landed on — exposed via
    /// `complementFraction(for:)` so a dual-snap partner can mirror it.
    private var lastCycleFraction: CGFloat?
    /// The frame (CG coords) we applied for the current cycle step — used to
    /// detect "is the window still exactly where I left it," i.e. whether
    /// this press is a genuine repeat or the cycle should restart at step 0.
    private var lastCycleCGFrame: CGRect?

    /// Computes the next step in the edge-snap cycle for `layout` (AppKit
    /// coords, consistent with `targetFrame`/`apply`). Advances only if the
    /// window's current frame still matches what the last cycle step left it
    /// at — any manual move/resize, window/app switch, or different hotkey
    /// resets the cycle back to plain half.
    private func cycledFrame(for layout: WindowLayout, on screen: NSScreen, axWindow: AXUIElement) -> CGRect {
        let g = max(edgeGap, 0)
        let area = screen.visibleFrame.insetBy(dx: g, dy: g)
        let hg = g / 2

        // A generous tolerance here on purpose: apps frequently don't apply
        // an AX frame with pixel precision (rounding, their own minimum
        // size, toolbar/inset adjustments), so comparing against the exact
        // frame we requested with a tight tolerance made the cycle silently
        // reset on almost every repeat press instead of advancing. This
        // still resets correctly if the user actually moved/resized the
        // window by a meaningful amount in between.
        let currentCG = WindowManagerService.axFrame(of: axWindow)
        let isContinuingCycle = layout == lastCycleLayout
            && currentCG != nil && lastCycleCGFrame != nil
            && approximatelyEqual(currentCG!, lastCycleCGFrame!, tolerance: 24)
        let index = isContinuingCycle ? (lastCycleIndex + 1) % Self.cycleFractions.count : 0
        let fraction = Self.cycleFractions[index]
        let frame = edgeFrame(for: layout, fraction: fraction, area: area, hg: hg)

        lastCycleLayout = layout
        lastCycleIndex = index
        lastCycleFraction = fraction
        let mainH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        lastCycleCGFrame = CGRect(x: frame.minX, y: mainH - frame.maxY, width: frame.width, height: frame.height)
        return frame
    }

    /// The frame (AppKit coords) for one of the four edge-anchored halves at
    /// an arbitrary fraction of the screen — shared by the cycling logic
    /// above and by the dual-snap partner, so both compute the exact same
    /// geometry a plain `fraction: 0.5` call would have.
    private func edgeFrame(for layout: WindowLayout, fraction: CGFloat, area: CGRect, hg: CGFloat) -> CGRect {
        switch layout {
        case .leftHalf:
            return CGRect(x: area.minX, y: area.minY, width: area.width * fraction - hg, height: area.height)
        case .rightHalf:
            let w = area.width * fraction - hg
            return CGRect(x: area.maxX - w, y: area.minY, width: w, height: area.height)
        case .topHalf:
            let h = area.height * fraction - hg
            return CGRect(x: area.minX, y: area.maxY - h, width: area.width, height: h)
        case .bottomHalf:
            return CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height * fraction - hg)
        default:
            return area   // never called for non-cyclable layouts
        }
    }

    private func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    /// Discrete size presets for the shrink/grow hotkeys, as a fraction of
    /// the screen's visible frame — descending, so "shrink" walks forward
    /// through the list and "grow" walks backward. Not a compounding scale
    /// of the window's current size (that felt arbitrary after a couple of
    /// presses) — every press lands on one of these exact percentages.
    private static let stepFractions: [CGFloat] = [0.9, 0.7, 0.5, 0.3]

    /// Steps the focused window down to the next-smaller preset percentage
    /// of the screen, centered on the screen. Returns the applied frame
    /// (AppKit coords) and a "70%"-style indicator, for the ghost preview.
    @discardableResult
    func shrinkFrontmostWindow() -> (frame: CGRect, indicator: String)? { stepToPresetFraction(smaller: true) }

    /// Steps the focused window up to the next-larger preset percentage of
    /// the screen, centered on the screen. Returns the applied frame
    /// (AppKit coords) and a "70%"-style indicator, for the ghost preview.
    @discardableResult
    func growFrontmostWindow() -> (frame: CGRect, indicator: String)? { stepToPresetFraction(smaller: false) }

    private func stepToPresetFraction(smaller: Bool) -> (frame: CGRect, indicator: String)? {
        let app = targetApp ?? NSWorkspace.shared.frontmostApplication
        guard let app else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        let axWindow = ref as! AXUIElement
        guard let frame = WindowManagerService.axFrame(of: axWindow) else { return nil }

        let screen = screenForWindow(axWindow) ?? NSScreen.main ?? NSScreen.screens[0]
        let mainH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let vf = screen.visibleFrame
        let area = CGRect(x: vf.minX, y: mainH - vf.maxY, width: vf.width, height: vf.height)   // CG coords

        // Find the preset closest to the window's current size (it may not
        // be exactly on a step, e.g. the user resized it by hand), then move
        // one step in the requested direction. `stepFractions` is descending,
        // so the first/last `where:` matches give the correct neighbor.
        let currentFraction = frame.width / area.width
        let epsilon: CGFloat = 0.02
        let nextFraction = smaller
            ? (Self.stepFractions.first { $0 < currentFraction - epsilon } ?? Self.stepFractions.last!)
            : (Self.stepFractions.last { $0 > currentFraction + epsilon } ?? Self.stepFractions.first!)

        let newWidth = area.width * nextFraction
        let newHeight = area.height * nextFraction
        let newFrameCG = CGRect(x: area.midX - newWidth / 2, y: area.midY - newHeight / 2,
                                 width: newWidth, height: newHeight)
        WindowManagerService.setAXFrame(newFrameCG, of: axWindow)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)

        let appKitFrame = CGRect(x: newFrameCG.minX, y: mainH - newFrameCG.maxY,
                                  width: newFrameCG.width, height: newFrameCG.height)
        let percent = Int((nextFraction * 100).rounded())
        return (appKitFrame, "\(percent)%")
    }

    /// Resizes the frontmost window of the second most recent app to the given layout.
    /// Called automatically when a paired resize hotkey fires (e.g. ⌃⌥← also moves the
    /// previous app to the right half).
    func resizePreviousApp(to layout: WindowLayout) {
        let recent = HUDState.shared.recentApps.filter { !$0.isTerminated }
        guard recent.count >= 2 else { return }
        let prevApp = recent[1]
        let axApp = AXUIElementCreateApplication(prevApp.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString,
                                            &ref) == .success, let ref else { return }
        let axWindow = ref as! AXUIElement
        let screen = screenForWindow(axWindow) ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = targetFrame(for: layout, on: screen)
        apply(frame: frame, to: axWindow, screen: screen)
    }

    private func apply(frame: CGRect, to axWindow: AXUIElement, screen: NSScreen) {
        // Convert AppKit frame (bottom-left origin) → CG coords (top-left origin)
        let mainH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgFrame = CGRect(x: frame.minX, y: mainH - frame.maxY, width: frame.width, height: frame.height)
        WindowManagerService.setAXFrame(cgFrame, of: axWindow)
    }
}
