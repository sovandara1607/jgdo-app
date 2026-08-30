import AppKit
import SwiftUI

/// A brief, non-interactive overlay that flashes a "snap target" tile where
/// windows are about to land, then fades out. Click-through and never steals
/// focus. Content is SwiftUI (`SnapPreviewContentView`), matching the Liquid
/// Glass material used by the rest of the app's panels — this used to be a
/// hand-drawn flat blue `NSBezierPath` rectangle.
final class SnapPreviewOverlay {
    static let shared = SnapPreviewOverlay()

    private var window: NSWindow?
    private var hideTimer: Timer?
    private let state = SnapPreviewState()
    /// Invalidates stale fade completions. Without this, a rapid second snap
    /// could be ordered out by the completion handler from the first snap.
    private var presentationGeneration = 0
    /// True while a live ⌘-drag is driving the overlay — suppresses the
    /// auto-fade timer so it stays up for as long as the drag lasts.
    private var isPersistent = false

    private init() {}

    /// Show a ghost tile for the snap. Frames are in AppKit screen coordinates
    /// (origin bottom-left). `secondary` is the paired window's destination, if any.
    /// `indicator`, if present, is a short on-tile label like "2/3" or "70%".
    /// Auto-fades after a brief flash — used for the hotkey/preset snap paths.
    func show(primary: CGRect, secondary: CGRect?, indicator: String? = nil, on screen: NSScreen) {
        isPersistent = false
        // Discrete, one-off snap — animate the tile settling into position.
        present(primary: primary, secondary: secondary, guide: nil, highlight: nil, indicator: indicator,
                animate: true, on: screen, animateEntrance: true)
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: 0.85, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
        hideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Show/update a ghost tile that stays up until `hidePersistent()` is
    /// called — used while a ⌘-drag is in progress, or while the ⌃⌥←/→
    /// hold-and-release layout overlay is cycling steps. `secondary`, if
    /// present, is a second ghost tile (e.g. the auto-fill partner window's
    /// preview) shown alongside the primary one. `guide`, if present, is a
    /// thin divider bar (AppKit coords) marking a shared resize boundary.
    /// `highlight`, if present, is a dashed outline (AppKit coords) around a
    /// window the user has explicitly Tab-picked as the alignment target.
    ///
    /// Deliberately NOT animated: this fires on nearly every mouse-move tick
    /// during a live drag, and animating a value that's continuously
    /// retargeted every ~16ms means the animation never has time to settle —
    /// it's perpetually chasing, which reads as lag/wobble rather than
    /// smoothness. Direct, instant tracking is what actually feels smooth here.
    func showPersistent(primary: CGRect, secondary: CGRect? = nil, guide: CGRect?,
                         highlight: CGRect? = nil, indicator: String? = nil, on screen: NSScreen) {
        let wasPersistent = isPersistent
        isPersistent = true
        hideTimer?.invalidate()
        hideTimer = nil
        present(primary: primary, secondary: secondary, guide: guide, highlight: highlight, indicator: indicator,
                animate: false, on: screen, animateEntrance: !wasPersistent)
    }

    /// Ends a persistent (drag-driven) preview. No-op if one isn't showing.
    func hidePersistent() {
        guard isPersistent else { return }
        isPersistent = false
        fadeOut()
    }

    private func present(primary: CGRect, secondary: CGRect?, guide: CGRect?, highlight: CGRect?, indicator: String?,
                          animate: Bool, on screen: NSScreen, animateEntrance: Bool) {
        let win = window ?? makeWindow()
        window = win
        presentationGeneration += 1
        win.setFrame(screen.frame, display: false)

        // Convert global frames → window-local (offset by the screen origin).
        // SwiftUI reacts to these changes on its own, so there's no manual
        // needsDisplay/redraw step like the old NSView-drawn version needed.
        state.animate = animate
        state.primary = localRect(primary, on: screen)
        state.secondary = secondary.map { localRect($0, on: screen) }
        state.guide = guide.map { localRect($0, on: screen) }
        state.highlight = highlight.map { localRect($0, on: screen) }
        state.indicator = indicator

        let wasVisible = win.isVisible && win.alphaValue > 0.05
        win.orderFrontRegardless()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animateEntrance, !wasVisible, !reduceMotion else {
            // Repeated hotkeys should morph the existing preview instead of
            // blinking it out and replaying the entrance on every key press.
            win.alphaValue = 1
            return
        }
        win.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 1
        }
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentViewController = NSHostingController(rootView: SnapPreviewContentView(state: state))
        return w
    }

    private func fadeOut() {
        guard let win = window else { return }
        presentationGeneration += 1
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            win.orderOut(nil)
            return
        }
        let generation = presentationGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak win] in
            guard let self, generation == self.presentationGeneration else { return }
            win?.orderOut(nil)
        })
    }

    /// Converts a global AppKit frame into this screen-sized overlay and
    /// clips cross-screen/partially off-screen targets to visible bounds.
    private func localRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        guard rect.width > 1, rect.height > 1 else { return .zero }
        let translated = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let localBounds = CGRect(origin: .zero, size: screen.frame.size)
        let clipped = translated.intersection(localBounds)
        return clipped.isNull || clipped.width <= 1 || clipped.height <= 1 ? .zero : clipped
    }
}
