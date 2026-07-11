import AppKit
import CoreGraphics
import ApplicationServices
import QuartzCore
import os

/// Visible in Console.app (filter by process "JgDo") — this feature has no
/// UI of its own to inspect, so logging is the only practical way to see
/// what the hit-test/classification/geometry pipeline is actually doing on a
/// machine we can't drive directly.
private let dragLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "JgDo", category: "drag")

/// Detects ⌘-held window drags/resizes and drives:
///  - Feature 1, Snap Into Available Space: ghost preview while dragging,
///    snaps into the leftover space on release.
///  - Feature 2, Resize Adjacent Windows: neighbors sharing an edge resize
///    live, in lockstep, while that edge is dragged.
///
/// macOS has no direct "another app's window is being moved/resized"
/// callback, so this is built from a listen-only global mouse event tap
/// (never blocks input) plus Accessibility polling of the hit-tested
/// window's live frame on every drag tick.
final class WindowDragController {
    // Static weak ref accessed from the @convention(c) tap callback — safe:
    // the callback fires on the main run loop (see HotkeyManager).
    nonisolated(unsafe) static weak var live: WindowDragController?

    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var tapSource: CFRunLoopSource?
    private var retryTimer: Timer?

    private let windowService = WindowManagerService()
    private var commandHeld = false
    private var session: DragSession?
    private var activeAnimator: SnapAnimator?
    /// Most recent drag cursor position — Tab presses don't carry a mouse
    /// location, so this lets Tab-handling know where the cursor is relative
    /// to whichever window it just picked as the alignment target.
    private var lastCursorPoint: CGPoint = .zero

    private struct DragSession {
        let axWindow: AXUIElement
        let pid: pid_t
        /// The dragged window's own CGWindowID, resolved once at mouseDown by
        /// matching pid + bounds against a single fetchWindows() call. Used to
        /// exclude *only this window* from obstacles/neighbors — excluding by
        /// pid alone was wrong whenever the same app has more than one window
        /// open (e.g. two Finder windows), since that silently excluded the
        /// other, untouched window too. Falls back to pid-based exclusion if
        /// the correlation fails for some reason.
        let windowID: CGWindowID?
        let originalFrame: CGRect
        var mode: SnapEngine.DragMode?
        var lastLiveFrame: CGRect
        var lastAvailableRect: CGRect?
        /// Captured once, the first tick resize-mode is detected — the fixed
        /// "before the drag" frames of every other on-screen window, plus
        /// their already-resolved AXUIElements. Using a frozen snapshot
        /// (rather than re-fetching every tick) means the per-tick math is
        /// always absolute (original + total delta), never incremental, so
        /// there's no drift and no "neighbor moved away from its matched
        /// edge" failure after the first tick — and it means applying a
        /// resize never needs another full window-list fetch, which was
        /// causing visible lag/jumps under the old per-tick refetch.
        var neighborSnapshots: [SnapEngine.WindowSnapshot]?
        var neighborAXWindows: [CGWindowID: AXUIElement]?
        var firedResizeHaptic = false
        /// True once the `DragTargetPickerOverlay` has been shown for this
        /// gesture — it's positioned once near the drag's start and left in
        /// place, not repositioned every tick.
        var pickerShown = false
    }

    // MARK: Public

    func start() {
        WindowDragController.live = self
        createTap()
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        tapSource = nil
        session = nil
        activeAnimator = nil
        SnapPreviewOverlay.shared.hidePersistent()
        DragTargetPickerOverlay.shared.hide()
        WindowDragController.live = nil
    }

    // MARK: Tap creation (listen-only — never blocks or modifies input)

    private func createTap() {
        guard AXIsProcessTrusted() else { scheduleRetry(); return }

        let mask = CGEventMask(
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
        )

        let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                switch type {
                case .leftMouseDown:
                    WindowDragController.live?.handleMouseDown(event)
                case .leftMouseDragged:
                    WindowDragController.live?.handleMouseDragged(event)
                case .leftMouseUp:
                    WindowDragController.live?.handleMouseUp(event)
                case .flagsChanged:
                    WindowDragController.live?.handleFlagsChanged(event)
                case .keyDown:
                    WindowDragController.live?.handleKeyDown(event)
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    if let t = WindowDragController.live?.tap {
                        CGEvent.tapEnable(tap: t, enable: true)
                    }
                default:
                    break
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: nil
        )

        guard let newTap else {
            dragLog.error("CGEvent.tapCreate returned nil — drag-to-snap will not function")
            scheduleRetry()
            return
        }
        tap = newTap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        dragLog.debug("event tap created and enabled")
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            self?.createTap()
        }
    }

    // MARK: Event handling — nonisolated, runs on main thread via main run loop

    nonisolated private func handleMouseDown(_ event: CGEvent) {
        let point = event.location
        DispatchQueue.main.async { WindowDragController.live?.beginTracking(at: point) }
    }

    nonisolated private func handleMouseDragged(_ event: CGEvent) {
        let point = event.location
        let held = event.flags.contains(.maskCommand)
        DispatchQueue.main.async { WindowDragController.live?.updateTracking(at: point, commandHeld: held) }
    }

    nonisolated private func handleMouseUp(_ event: CGEvent) {
        let point = event.location
        DispatchQueue.main.async { WindowDragController.live?.endTracking(at: point) }
    }

    nonisolated private func handleFlagsChanged(_ event: CGEvent) {
        let held = event.flags.contains(.maskCommand)
        DispatchQueue.main.async { WindowDragController.live?.commandHeld = held }
    }

    nonisolated private func handleKeyDown(_ event: CGEvent) {
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return } // ignore auto-repeat
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // Bridge to NSEvent so typed characters come out correctly across
        // keyboard layouts/shift state, instead of hand-mapping keycodes.
        let typed = NSEvent(cgEvent: event)?.characters
        DispatchQueue.main.async { WindowDragController.live?.handlePickerKey(code: code, typed: typed) }
    }

    // MARK: Session driving

    private func beginTracking(at point: CGPoint) {
        session = nil
        guard AppSettings.dragSnapEnabled || AppSettings.adjacentResizeEnabled else {
            dragLog.debug("mouseDown at \(point.x, format: .fixed(precision: 0)),\(point.y, format: .fixed(precision: 0)) — both features disabled in Settings")
            return
        }
        guard let hit = WindowManagerService.hitTestWindow(at: point) else {
            dragLog.debug("mouseDown at \(point.x, format: .fixed(precision: 0)),\(point.y, format: .fixed(precision: 0)) — AX hit-test found no window (nil elementRef, or no ancestor with AXWindow role)")
            return
        }
        guard hit.pid != NSRunningApplication.current.processIdentifier else {
            dragLog.debug("mouseDown hit JgDo's own window — ignoring")
            return
        }
        guard let frame = WindowManagerService.axFrame(of: hit.window) else {
            dragLog.debug("mouseDown hit pid \(hit.pid) but AXPosition/AXSize read failed")
            return
        }

        // One-time correlation: find which of this pid's on-screen windows is
        // the one we just hit-tested, by closest bounds match to the AX frame.
        let candidates = windowService.fetchWindows().filter { $0.pid == hit.pid }
        let windowID = candidates
            .min { boundsDelta($0.bounds, frame) < boundsDelta($1.bounds, frame) }
            .map(\.windowID)

        lastCursorPoint = point
        session = DragSession(axWindow: hit.window, pid: hit.pid, windowID: windowID, originalFrame: frame,
                               mode: nil, lastLiveFrame: frame, lastAvailableRect: nil,
                               neighborSnapshots: nil, neighborAXWindows: nil, firedResizeHaptic: false,
                               pickerShown: false)
        dragLog.debug("""
            drag session started: pid=\(hit.pid) windowID=\(windowID ?? 0, format: .decimal) \
            (correlated against \(candidates.count) windows for that pid) \
            frame=\(frame.debugDescription)
            """)
    }

    private func boundsDelta(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private func updateTracking(at point: CGPoint, commandHeld: Bool) {
        self.commandHeld = commandHeld
        lastCursorPoint = point
        guard var s = session else { return }
        defer { session = s }

        guard commandHeld else {
            if s.mode != nil {
                SnapPreviewOverlay.shared.hidePersistent()
                DragTargetPickerOverlay.shared.hide()
                s.lastAvailableRect = nil
                s.pickerShown = false
            }
            return
        }

        guard let liveFrame = WindowManagerService.axFrame(of: s.axWindow), liveFrame != s.lastLiveFrame else { return }
        s.lastLiveFrame = liveFrame

        if s.mode == nil {
            s.mode = SnapEngine.classify(originalFrame: s.originalFrame, liveFrame: liveFrame)
            if let m = s.mode {
                dragLog.debug("classified as \(String(describing: m)) — original=\(s.originalFrame.debugDescription) live=\(liveFrame.debugDescription)")
            }
        }
        guard let mode = s.mode else { return }

        switch mode {
        case .move:
            guard AppSettings.dragSnapEnabled else { return }
            guard let (screen, bounds) = screenAndBounds(forCGPoint: point) else { return }
            let allWindows = windowService.fetchWindowBounds()
                .filter { isOtherWindow($0.windowID, pid: $0.pid, session: s) }

            // The searchable "align next to…" list is shown for the whole
            // gesture (positioned once, not repositioned every tick). By
            // default its selection auto-tracks whichever window is nearest
            // the cursor; typing/Tab/arrows (handled in handleKeyDown) pin an
            // explicit choice instead. Either way, `selectedCandidate` is
            // always the single source of truth for "which window to align
            // against" — no more separate cursor-vs-explicit branching.
            let picker = DragTargetPickerOverlay.shared
            picker.state.setCandidates(allWindows.map {
                DragTargetPickerState.Candidate(windowID: $0.windowID, pid: $0.pid,
                                                 appName: $0.appName, title: $0.title, bounds: $0.bounds)
            })
            picker.state.autoSelectNearest(to: point)
            if !s.pickerShown {
                picker.show(near: point, on: screen)
                s.pickerShown = true
            }

            var anchor = point
            var highlightRect: CGRect?
            if let target = picker.state.selectedCandidate {
                let side = SnapEngine.nearestSide(of: target.bounds, to: point)
                anchor = SnapEngine.anchorPoint(adjacentTo: target.bounds, side: side, in: bounds)
                highlightRect = target.bounds
            }

            let obstacles = allWindows.map { $0.bounds }
            let rect = SnapEngine.availableSpace(at: anchor, obstacles: obstacles, in: bounds)
            guard rect.width > 40, rect.height > 40 else {
                dragLog.debug("move: \(obstacles.count) obstacles, anchor=\(anchor.debugDescription) → rect too small (\(rect.debugDescription)), skipping this tick")
                // Don't hide the overlay here — this is frequently just a
                // transient single-tick blip (e.g. cursor passing over an
                // obstacle edge mid-drag), and fully fading the window out
                // and back in on every blip was the visible flicker/"buggy"
                // feeling reported during live drags. Leave the last good
                // tile showing; `lastAvailableRect = nil` still correctly
                // means "don't snap" if the mouse is released right now.
                s.lastAvailableRect = nil
                return
            }
            if s.lastAvailableRect == nil || !rect.approximatelyEqual(to: s.lastAvailableRect!) {
                dragLog.debug("""
                    move: \(obstacles.count) obstacles \(obstacles.map(\.debugDescription)), \
                    anchor=\(anchor.debugDescription) → rect=\(rect.debugDescription) (screen bounds=\(bounds.debugDescription))
                    """)
                if s.lastAvailableRect != nil { fireHaptic() }
                s.lastAvailableRect = rect
                SnapPreviewOverlay.shared.showPersistent(
                    primary: appKitFrame(fromCG: rect), guide: nil,
                    highlight: highlightRect.map(appKitFrame(fromCG:)), on: screen
                )
            }

        case .resize:
            guard AppSettings.adjacentResizeEnabled else { return }
            guard let (screen, _) = screenAndBounds(forCGPoint: point) else { return }
            if s.neighborSnapshots == nil {
                // Resolved once for the whole gesture — every subsequent tick
                // reuses these AXUIElements directly instead of re-fetching
                // the full window list (which was the source of the
                // laggy/out-of-sync resizing).
                let candidates = windowService.fetchWindows()
                    .filter { isOtherWindow($0.windowID, pid: $0.pid, session: s) }
                s.neighborSnapshots = candidates.map { SnapEngine.WindowSnapshot(windowID: $0.windowID, frame: $0.bounds) }
                var axMap: [CGWindowID: AXUIElement] = [:]
                for info in candidates {
                    if let ax = windowService.axWindow(for: info) { axMap[info.windowID] = ax }
                }
                s.neighborAXWindows = axMap
            }
            let edgeMoves = SnapEngine.movedEdges(from: s.originalFrame, to: liveFrame)
            let resizes = SnapEngine.neighborResizes(
                originalFrame: s.originalFrame, edgeMovements: edgeMoves,
                others: s.neighborSnapshots ?? [], tolerance: 3
            )
            guard !resizes.isEmpty else { return }
            applyNeighborResizes(resizes, axWindows: s.neighborAXWindows ?? [:])
            if !s.firedResizeHaptic { fireHaptic(); s.firedResizeHaptic = true }
            if let guide = resizeGuideRect(edgeMoves: edgeMoves, liveFrame: liveFrame) {
                SnapPreviewOverlay.shared.showPersistent(primary: .zero, guide: appKitFrame(fromCG: guide), on: screen)
            }
        }
    }

    /// Drives the `DragTargetPickerOverlay`'s selection/search while a move
    /// drag is in progress: Tab/arrows move the highlighted candidate,
    /// Delete removes the last search character, and any other typed
    /// character is appended to the search text. Mutating `picker.state`
    /// here is enough — the next `updateTracking` tick (or the immediate
    /// refresh below) recomputes the anchor/rect from whatever is selected.
    private func handlePickerKey(code: Int64, typed: String?) {
        guard AppSettings.dragSnapEnabled else { return }
        guard let s = session, commandHeld, s.mode == .move else { return }

        let picker = DragTargetPickerOverlay.shared
        switch code {
        case 48, 125: picker.state.moveSelection(1)     // Tab, ↓
        case 126:     picker.state.moveSelection(-1)    // ↑
        case 51:      picker.state.backspaceSearch()    // ⌫
        default:
            guard let typed, !typed.isEmpty,
                  typed.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) else { return }
            picker.state.appendSearchText(typed)
        }
        refreshMovePreview(session: s)
    }

    /// Recomputes and redraws the ghost preview immediately from the
    /// picker's current selection, without waiting for the next mouse-move
    /// tick — so picking a new target via keyboard feels instant.
    private func refreshMovePreview(session s: DragSession) {
        guard let (screen, bounds) = screenAndBounds(forCGPoint: lastCursorPoint) else { return }
        guard let target = DragTargetPickerOverlay.shared.state.selectedCandidate else { return }

        let allObstacles = windowService.fetchWindowBounds()
            .filter { isOtherWindow($0.windowID, pid: $0.pid, session: s) }
            .map { $0.bounds }
        let side = SnapEngine.nearestSide(of: target.bounds, to: lastCursorPoint)
        let anchor = SnapEngine.anchorPoint(adjacentTo: target.bounds, side: side, in: bounds)
        let rect = SnapEngine.availableSpace(at: anchor, obstacles: allObstacles, in: bounds)

        var updated = s
        updated.lastAvailableRect = rect.width > 40 && rect.height > 40 ? rect : nil
        session = updated
        fireHaptic()
        SnapPreviewOverlay.shared.showPersistent(
            primary: appKitFrame(fromCG: rect), guide: nil,
            highlight: appKitFrame(fromCG: target.bounds), on: screen
        )
    }

    private func endTracking(at point: CGPoint) {
        dragLog.debug("drag session ended: hadSession=\(self.session != nil) mode=\(String(describing: self.session?.mode))")
        defer { session = nil }
        SnapPreviewOverlay.shared.hidePersistent()
        DragTargetPickerOverlay.shared.hide()
        guard let s = session, commandHeld, s.mode == .move, let target = s.lastAvailableRect,
              let (screen, _) = screenAndBounds(forCGPoint: point) else { return }
        fireHaptic()
        animateSnap(of: s.axWindow, pid: s.pid, from: s.lastLiveFrame, to: target, on: screen)
    }

    // MARK: Applying results

    private func applyNeighborResizes(_ resizes: [SnapEngine.NeighborResize], axWindows: [CGWindowID: AXUIElement]) {
        for resize in resizes {
            guard let axWin = axWindows[resize.windowID] else { continue }
            WindowManagerService.setAXFrame(resize.newFrame, of: axWin)
        }
    }

    /// True if `windowID`/`pid` refers to a window other than the one being
    /// dragged in `session` — matched by windowID when we have it (so a
    /// second window from the *same* app is correctly still treated as an
    /// obstacle/neighbor), falling back to pid if correlation failed.
    private func isOtherWindow(_ windowID: CGWindowID, pid: pid_t, session: DragSession) -> Bool {
        if let draggedID = session.windowID { return windowID != draggedID }
        return pid != session.pid
    }

    private func animateSnap(of axWindow: AXUIElement, pid: pid_t, from start: CGRect, to end: CGRect, on screen: NSScreen) {
        activeAnimator = SnapAnimator(axWindow: axWindow, from: start, to: end, duration: 0.18, screen: screen) { [weak self] in
            self?.activeAnimator = nil
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    private func fireHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    // MARK: Geometry helpers

    /// The screen under a CG (top-left origin) point, plus that screen's
    /// visible frame converted into the same CG coordinate space.
    private func screenAndBounds(forCGPoint point: CGPoint) -> (NSScreen, CGRect)? {
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let appKitPoint = CGPoint(x: point.x, y: mainH - point.y)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) ?? NSScreen.main else { return nil }
        let vf = screen.visibleFrame
        let bounds = CGRect(x: vf.minX, y: mainH - vf.maxY, width: vf.width, height: vf.height)
        return (screen, bounds)
    }

    private func appKitFrame(fromCG cg: CGRect) -> CGRect {
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: cg.minX, y: mainH - cg.maxY, width: cg.width, height: cg.height)
    }

    /// A thin guide rect (CG coords) along the dragged window's moving edge —
    /// the exact boundary shared with any neighbors being resized alongside it.
    private func resizeGuideRect(edgeMoves: [SnapEngine.EdgeMovement], liveFrame: CGRect) -> CGRect? {
        guard let move = edgeMoves.first else { return nil }
        let thickness: CGFloat = 4
        switch move.edge {
        case .left, .right:
            let x = move.edge == .right ? liveFrame.maxX : liveFrame.minX
            return CGRect(x: x - thickness / 2, y: liveFrame.minY, width: thickness, height: liveFrame.height)
        case .top, .bottom:
            let y = move.edge == .bottom ? liveFrame.maxY : liveFrame.minY
            return CGRect(x: liveFrame.minX, y: y - thickness / 2, width: liveFrame.width, height: thickness)
        }
    }

    deinit { stop() }
}

private extension CGRect {
    func approximatelyEqual(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) < tolerance && abs(minY - other.minY) < tolerance
            && abs(width - other.width) < tolerance && abs(height - other.height) < tolerance
    }
}

// MARK: - Smooth snap animation for a foreign AXUIElement

/// AX position/size sets teleport instantly — there's no NSAnimationContext
/// hook into a window we don't own. To still get a fluid, native-feeling
/// snap, this interpolates the frame itself over `duration` via a
/// `CADisplayLink` (vsync-paced, so it tracks 120Hz on ProMotion-class
/// displays) and repeatedly calls `WindowManagerService.setAXFrame`.
private final class SnapAnimator {
    private var link: CADisplayLink?
    private let axWindow: AXUIElement
    private let start: CGRect
    private let end: CGRect
    private let duration: CFTimeInterval
    private let startTime: CFTimeInterval
    private let completion: () -> Void

    init(axWindow: AXUIElement, from start: CGRect, to end: CGRect, duration: CFTimeInterval,
         screen: NSScreen, completion: @escaping () -> Void) {
        self.axWindow = axWindow
        self.start = start
        self.end = end
        self.duration = duration
        self.startTime = CACurrentMediaTime()
        self.completion = completion
        let link = screen.displayLink(target: self, selector: #selector(step))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func step(_ link: CADisplayLink) {
        let t = min(1, (CACurrentMediaTime() - startTime) / duration)
        let eased = 1 - pow(1 - t, 3)   // ease-out cubic
        let frame = CGRect(
            x: start.minX + (end.minX - start.minX) * eased,
            y: start.minY + (end.minY - start.minY) * eased,
            width: start.width + (end.width - start.width) * eased,
            height: start.height + (end.height - start.height) * eased
        )
        WindowManagerService.setAXFrame(frame, of: axWindow)
        if t >= 1 {
            link.invalidate()
            self.link = nil
            completion()
        }
    }
}
