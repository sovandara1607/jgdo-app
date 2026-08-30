import AppKit
import ApplicationServices

/// Owns the ⌃⌥←/→ layout overlay. Two modes, both user-visible in
/// Settings → Windows ("Apply Layout"):
///
/// **Instant (default)** — every non-repeat ⌃⌥← / ⌃⌥→ press is a complete,
/// independent gesture: applies right away, flashes the card + ghost
/// preview, both auto-fade. No holding required — same low-effort feel as
/// every other hotkey in the app. Repeated *presses* (not a held key)
/// continue the cycle, decided by whether the window's frame still matches
/// where the last press left it — the same continuation heuristic
/// `WindowResizeService`'s own edge-snap cycling already uses elsewhere.
///
///     idle → ⌃⌥← or ⌃⌥→ → apply + flash → idle
///          (a following press within the same frame continues the cycle)
///
/// **On release (opt-in)** — the original hold-and-preview gesture:
///
///     idle → (⌃⌥← or ⌃⌥→) → selecting → (more arrows) → selecting
///          → (⌃ or ⌥ released) → commit → idle
///          → (Escape)             → cancel → idle
///
/// Reuses existing systems throughout instead of introducing a parallel
/// window-management path: `WindowResizeService` computes and applies every
/// frame (the exact same geometry the preview and the real move both read
/// from), `SnapPreviewOverlay` is the desktop ghost-tile preview, and
/// `WindowLayoutSelectorOverlay` is the compact card — this file only
/// sequences them against `HotkeyManager`'s key events.
///
/// Whenever the applied step has a complementary side (every plain
/// half/fraction step; not the two display-change steps), the topmost
/// other visible window silently auto-fills it — the same dual-snap every
/// other layout hotkey already does — shown as a second ghost tile
/// alongside the primary, never as a popup. See `autoFillComplement`. The
/// dedicated ⌃⌥⇥ hotkey (`fillOtherSide`) opens an interactive search to
/// swap in a specific different window instead, entirely on request —
/// auto-popping that search after every press used to steal focus and
/// interrupt repeated presses used just to cycle fraction steps.
@MainActor
final class WindowLayoutSelectorController {
    private struct Session {
        let family: LayoutCycleFamily
        var index: Int
        let axWindow: AXUIElement
        let app: NSRunningApplication
        let screen: NSScreen
        /// AppKit-coords frame captured before anything moved — restored on
        /// Escape if "Apply Layout: Immediately" already moved the window
        /// for real mid-cycle. Unused in instant mode.
        let originalFrame: CGRect
    }

    /// The last thing ⌃⌥←/→ actually applied, in EITHER mode — the target
    /// for both instant mode's "did the window stay put since my last
    /// press" continuation check and the dedicated "fill other side"
    /// hotkey, which no longer needs a live hold-session to operate on.
    private struct LastPrimary {
        let family: LayoutCycleFamily
        let index: Int
        let axWindow: AXUIElement
        let app: NSRunningApplication
        let screen: NSScreen
        let appliedFrame: CGRect   // AppKit coords, what we last set it to
    }

    private var session: Session?
    private var lastPrimary: LastPrimary?
    private var lastStepTime: CFAbsoluteTime = 0
    /// OS auto-repeat can fire well past 10/sec while an arrow key is held;
    /// this is the fastest a held key is allowed to advance the cycle in
    /// "on release" mode. Instant mode ignores auto-repeat entirely (see
    /// `handleStep`), matching every other hotkey in the app.
    private let repeatThrottle: CFTimeInterval = 0.18

    /// The pre-this-feature behavior for ⌃⌥←/→ (single-shot dual-snap,
    /// exactly like every other layout hotkey) — used when "Show Layout
    /// Overlay" is off, so turning it off doesn't turn the shortcut off,
    /// just reverts it to how it always worked. Set by `AppDelegate` to the
    /// same closure `onResize` already uses for every other layout, so
    /// there's exactly one implementation of that behavior, not two.
    var legacyApply: ((WindowLayout) -> Void)?

    func attach(to mgr: HotkeyManager) {
        mgr.onLayoutCycleStep = { [weak self, weak mgr] family, isRepeat in
            guard let mgr else { return }
            self?.handleStep(family: family, isRepeat: isRepeat, mgr: mgr)
        }
        mgr.onLayoutCycleModifiersReleased = { [weak self, weak mgr] in
            guard let mgr else { return }
            self?.commit(mgr: mgr)
        }
        mgr.onLayoutCycleEscape = { [weak self, weak mgr] in
            guard let mgr else { return }
            self?.cancel(mgr: mgr)
        }
        mgr.onLayoutFillOtherSide = { [weak self] in
            self?.fillOtherSide()
        }
    }

    // MARK: - Step

    private func handleStep(family: LayoutCycleFamily, isRepeat: Bool, mgr: HotkeyManager) {
        guard AppSettings.layoutSelectorOverlayEnabled else {
            let layout: WindowLayout = family == .left ? .leftHalf : .rightHalf
            legacyApply?(layout)
            return
        }

        guard AppSettings.layoutSelectorApplyOnRelease else {
            handleInstantStep(family: family, isRepeat: isRepeat)
            return
        }

        if var current = session {
            // Once a session is open, ← and → both mean "move within the
            // active family's list" (previous/next), regardless of which
            // arrow started it — matches the overlay's own "← Previous
            // Next →" hint.
            let now = CFAbsoluteTimeGetCurrent()
            if isRepeat {
                guard now - lastStepTime >= repeatThrottle else { return }
            }
            lastStepTime = now
            advance(&current, by: family)
            session = current
            preview(current)
            return
        }

        beginSession(family: family, mgr: mgr)
    }

    /// Instant mode: no held-key tracking at all — each non-repeat press is
    /// a self-contained action. Continuation (advancing to the next step
    /// instead of restarting at step 0) is decided purely by whether the
    /// target window's frame still matches what the previous press left it
    /// at, same as `WindowResizeService`'s own edge-snap cycle heuristic.
    private func handleInstantStep(family: LayoutCycleFamily, isRepeat: Bool) {
        guard !isRepeat else { return }   // holding the key does nothing extra — press again instead

        let index: Int
        let axWindow: AXUIElement
        let app: NSRunningApplication
        let screen: NSScreen

        if let last = lastPrimary, last.family == family,
           let currentFrame = WindowManagerService.axFrame(of: last.axWindow),
           Self.approximatelyEqual(CoordinateSpace.appKit(fromCG: currentFrame), last.appliedFrame) {
            index = LayoutCycleFamily.steppedIndex(last.index, delta: 1, count: family.steps.count)
            axWindow = last.axWindow
            app = last.app
            screen = last.screen
        } else if let resolvedApp = NSWorkspace.shared.frontmostApplication,
                  let resolvedWindow = Self.focusedWindow(of: resolvedApp),
                  let resolvedScreen = Self.screen(for: resolvedWindow) {
            index = 0
            axWindow = resolvedWindow
            app = resolvedApp
            screen = resolvedScreen
        } else {
            return
        }

        let step = family.steps[index]
        // Grouped into one undo transaction — ⌃⌥Z restores both the
        // primary and the auto-filled partner together, not just
        // whichever was recorded last.
        WindowSnapUndo.shared.beginTransaction()
        applyStep(step, to: axWindow, on: screen)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)

        let appliedFrame = WindowManagerService.axFrame(of: axWindow).map { CoordinateSpace.appKit(fromCG: $0) }
            ?? .zero
        lastPrimary = LastPrimary(family: family, index: index, axWindow: axWindow, app: app,
                                   screen: screen, appliedFrame: appliedFrame)

        let secondaryFrame = autoFillComplement(for: step, excludingPID: app.processIdentifier, on: screen)
        WindowSnapUndo.shared.endTransaction()

        if AppSettings.placementPreviewEnabled, let (frame, previewScreen) = frameAndScreen(for: step, axWindow: axWindow, screen: screen) {
            SnapPreviewOverlay.shared.show(primary: frame, secondary: secondaryFrame, on: previewScreen)
        }
        WindowLayoutSelectorOverlay.shared.show(
            step: step, index: index, count: family.steps.count, family: family,
            appIcon: app.icon, appName: app.localizedName ?? "Window",
            otherWindows: PartnerWindowCandidate.others(excludingPID: app.processIdentifier),
            dim: AppSettings.layoutSelectorDimEnabled, autoHideAfter: AppSettings.windowActionHUDDuration,
            on: screen)
    }

    /// ← always steps back one, → always steps forward one, within
    /// whichever family the session started with — the arrow that opened
    /// the overlay only picks which list; it doesn't matter again after that.
    private func advance(_ s: inout Session, by pressed: LayoutCycleFamily) {
        let count = s.family.steps.count
        let delta = pressed == .left ? -1 : 1
        s.index = LayoutCycleFamily.steppedIndex(s.index, delta: delta, count: count)
    }

    private func beginSession(family: LayoutCycleFamily, mgr: HotkeyManager) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let axWindow = Self.focusedWindow(of: app),
              let screen = Self.screen(for: axWindow),
              let cgFrame = WindowManagerService.axFrame(of: axWindow) else { return }
        let s = Session(family: family, index: 0, axWindow: axWindow, app: app, screen: screen,
                         originalFrame: CoordinateSpace.appKit(fromCG: cgFrame))
        session = s
        lastStepTime = CFAbsoluteTimeGetCurrent()
        mgr.layoutCycleActive = true
        preview(s)
    }

    // MARK: - Preview / apply (hold-and-release mode)

    private func preview(_ s: Session) {
        let steps = s.family.steps
        let step = steps[s.index]
        if AppSettings.placementPreviewEnabled, let (frame, screen) = frameAndScreen(for: step, axWindow: s.axWindow, screen: s.screen) {
            let secondary = previewComplement(for: step, excludingPID: s.app.processIdentifier, on: screen)
            SnapPreviewOverlay.shared.showPersistent(primary: frame, secondary: secondary, guide: nil, indicator: nil, on: screen)
        }
        WindowLayoutSelectorOverlay.shared.show(
            step: step, index: s.index, count: steps.count, family: s.family,
            appIcon: s.app.icon, appName: s.app.localizedName ?? "Window",
            otherWindows: PartnerWindowCandidate.others(excludingPID: s.app.processIdentifier),
            dim: AppSettings.layoutSelectorDimEnabled, autoHideAfter: nil, on: s.screen)
    }

    private func applyStep(_ step: LayoutCycleStep, to axWindow: AXUIElement, on screen: NSScreen) {
        switch step.kind {
        case .layout(let layout, let fraction):
            WindowResizeService.shared.resize(axWindow, to: layout, fraction: fraction, on: screen)
        case .previousDisplay:
            WindowResizeService.shared.moveWindowToDisplay(axWindow, direction: .previous)
        case .nextDisplay:
            WindowResizeService.shared.moveWindowToDisplay(axWindow, direction: .next)
        }
    }

    /// Auto-fills the complementary side with the topmost other visible
    /// window whenever `step` is a plain half/fraction layout — so ⌃⌥←/→
    /// always leaves both windows placed, the same "dual snap" every other
    /// layout hotkey (`AppDelegate.applyLayoutImmediately`) already does.
    /// Silent and immediate — no popup, no focus steal — so it doesn't
    /// interrupt repeated presses while cycling through fraction steps.
    /// Returns the frame it applied (for the ghost tile), or nil for a
    /// step with no complement (the two display-change steps) or with
    /// nothing else open to fill it with.
    @discardableResult
    private func autoFillComplement(for step: LayoutCycleStep, excludingPID: pid_t, on screen: NSScreen) -> CGRect? {
        guard case .layout(let layout, let fraction) = step.kind, let complement = layout.complement else { return nil }
        return WindowResizeService.shared.resizeOtherVisibleWindow(
            excluding: excludingPID, to: complement, fraction: 1 - fraction, preferredScreen: screen)
    }

    /// Non-mutating counterpart of `autoFillComplement`, for the
    /// hold-and-release mode's live ghost preview — shows what the
    /// auto-fill partner will look like on release without moving it, so
    /// holding ⌃⌥←/→ and cycling steps already ghosts both sides, not just
    /// the primary until commit.
    private func previewComplement(for step: LayoutCycleStep, excludingPID: pid_t, on screen: NSScreen) -> CGRect? {
        guard case .layout(let layout, let fraction) = step.kind, let complement = layout.complement else { return nil }
        return WindowResizeService.shared.previewOtherVisibleWindow(
            excluding: excludingPID, to: complement, fraction: 1 - fraction, on: screen)
    }

    /// Opens the "pick a window for the other side" search — only on
    /// explicit request (the dedicated ⌃⌥⇥ hotkey, see `fillOtherSide`),
    /// never automatically: popping this up after every ⌃⌥←/→ press stole
    /// focus and interrupted repeated presses used just to cycle through
    /// fraction steps. The auto-fill above already handles the common
    /// case silently; this is for swapping in a specific different window
    /// instead of the auto-picked one.
    private func showPartnerSearch(step: LayoutCycleStep, excludingPID: pid_t, on screen: NSScreen) {
        guard case .layout(let layout, let fraction) = step.kind, let complement = layout.complement,
              !PartnerWindowCandidate.others(excludingPID: excludingPID).isEmpty else { return }
        let preselectPID = HUDState.shared.recentApps
            .filter { !$0.isTerminated && $0.processIdentifier != excludingPID }
            .first?.processIdentifier
        WindowLayoutPartnerSearchPanelController.shared.show(
            complement: complement, fraction: 1 - fraction,
            excludingPID: excludingPID, preselectPID: preselectPID, on: screen)
    }

    private func frameAndScreen(for step: LayoutCycleStep, axWindow: AXUIElement, screen: NSScreen) -> (CGRect, NSScreen)? {
        switch step.kind {
        case .layout(let layout, let fraction):
            return (WindowResizeService.shared.previewFrame(for: layout, fraction: fraction, on: screen), screen)
        case .previousDisplay:
            return WindowResizeService.shared.previewDisplayMove(of: axWindow, direction: .previous)
        case .nextDisplay:
            return WindowResizeService.shared.previewDisplayMove(of: axWindow, direction: .next)
        }
    }

    // MARK: - Commit / cancel (hold-and-release mode)

    private func commit(mgr: HotkeyManager) {
        guard let s = session else { return }
        let step = s.family.steps[s.index]
        // Grouped into one undo transaction — see `handleInstantStep`.
        WindowSnapUndo.shared.beginTransaction()
        applyStep(step, to: s.axWindow, on: s.screen)
        AXUIElementPerformAction(s.axWindow, kAXRaiseAction as CFString)
        let appliedFrame = WindowManagerService.axFrame(of: s.axWindow).map { CoordinateSpace.appKit(fromCG: $0) }
            ?? s.originalFrame
        lastPrimary = LastPrimary(family: s.family, index: s.index, axWindow: s.axWindow, app: s.app,
                                   screen: s.screen, appliedFrame: appliedFrame)
        autoFillComplement(for: step, excludingPID: s.app.processIdentifier, on: s.screen)
        WindowSnapUndo.shared.endTransaction()
        endSession(mgr: mgr)
    }

    private func cancel(mgr: HotkeyManager) {
        endSession(mgr: mgr)
    }

    /// The dedicated "search other side" hotkey. The complementary side is
    /// already auto-filled with the topmost other visible window the
    /// moment ⌃⌥←/→ applies (see `autoFillComplement`) — this hotkey is for
    /// explicitly searching for and swapping in a *different* window
    /// instead of the auto-picked one. Works after either mode's primary
    /// action, sourced from `lastPrimary` rather than a live hold-session,
    /// so it needs no CGEventTap-level key interception at all. No-ops on
    /// the two display-change steps (no complementary region) or if
    /// ⌃⌥←/→ hasn't been used yet this launch.
    private func fillOtherSide() {
        guard let last = lastPrimary else { return }
        showPartnerSearch(step: last.family.steps[last.index], excludingPID: last.app.processIdentifier, on: last.screen)
    }

    private func endSession(mgr: HotkeyManager) {
        session = nil
        mgr.layoutCycleActive = false
        SnapPreviewOverlay.shared.hidePersistent()
        WindowLayoutSelectorOverlay.shared.hide()
    }

    // MARK: - AX lookups

    private static func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private static func screen(for axWindow: AXUIElement) -> NSScreen? {
        guard let cgFrame = WindowManagerService.axFrame(of: axWindow) else { return NSScreen.main }
        let appKitPoint = CoordinateSpace.appKit(fromCG: CGPoint(x: cgFrame.minX, y: cgFrame.minY))
        return CoordinateSpace.screen(containing: appKitPoint) ?? NSScreen.main
    }

    /// Generous tolerance on purpose, same reasoning as
    /// `WindowResizeService.cycledFrame`'s own continuation check: apps
    /// rarely apply an AX frame with pixel precision, so a tight tolerance
    /// would make the "did it stay put" check fail on almost every press.
    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 24) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}
