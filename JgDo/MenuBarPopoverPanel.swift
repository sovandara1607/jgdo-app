import AppKit
import SwiftUI

/// A borderless-looking replacement for `NSPopover` used by the menu bar's
/// status and quick panels. `NSPopover` always draws a pointing arrow/tail
/// back to its anchor view with no supported way to suppress it; this panel
/// gets the same "floating rounded card" look other panels in the app use
/// (see `KeyablePanel` call sites) — no arrow, flush under and centered on
/// the status item — while still behaving like a transient popover: it
/// closes itself on any click outside its bounds (except back on the
/// anchor button, which the caller's own toggle logic handles) or when it
/// loses key status.
final class MenuBarPopoverPanel: NSPanel {
    /// Fired whenever the panel closes, for whatever reason (outside click,
    /// lost key status, or an explicit `performClose`) — mirrors
    /// `NSPopoverDelegate.popoverDidClose`.
    var onClose: (() -> Void)?

    private var outsideClickMonitor: Any?
    private weak var anchorButton: NSStatusBarButton?
    private var isClosing = false

    init() {
        // Plain `.borderless` (no `.titled`) — unlike the other panels in
        // AppDelegate this one doesn't need the native title-bar-corner
        // trick, since the SwiftUI content already draws its own rounded
        // card. It also sidesteps AppKit's default "genie" open animation
        // that `.titled` windows get on first `makeKeyAndOrderFront`, which
        // was reading as the popover flying in from somewhere else.
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        // Belt-and-suspenders: explicitly opt out of any window-level open/
        // close animation so showing/hiding is an instant snap, not a fade
        // or zoom.
        animationBehavior = .none
        isMovableByWindowBackground = false
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        // Native window shadow ON — unlike the other panels in AppDelegate,
        // this one's SwiftUI content no longer draws its own `.shadow()`
        // (see `GlassPopoverCard`): a SwiftUI shadow is pure visual overflow
        // that needs extra transparent window margin to render into, which
        // read as an ugly hard-edged box in light mode when that margin
        // wasn't generous enough. The native shadow is computed straight
        // from the window's actual alpha mask, so it always follows the
        // rounded card exactly with no margin bookkeeping needed.
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    var isShown: Bool { isVisible }

    /// Positions the panel flush under `button`, horizontally centered on it
    /// (rather than right-aligned), sized to `rootView`'s current fitting
    /// size.
    func show<Content: View>(relativeTo button: NSStatusBarButton, rootView: Content) {
        anchorButton = button
        isClosing = false
        let hosting = NSHostingController(rootView: rootView)
        contentViewController = hosting

        let fitted = hosting.view.fittingSize
        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // Flush against the bottom of the status item — no arrow, so no gap
        // is needed to make room for one.
        let gap: CGFloat = 1
        let origin = NSPoint(x: buttonFrame.midX - fitted.width / 2, y: buttonFrame.minY - gap - fitted.height)
        setFrame(NSRect(origin: origin, size: fitted), display: true)
        invalidateShadow()

        // A quick scale + fade "pop" — more than a bare opacity fade, but
        // nowhere near AppKit's own "genie" zoom-in (which read as flying in
        // from far away). `animationBehavior = .none` above still applies to
        // the window itself; this animates the content layer instead, which
        // is the only way to get a scale transition out of an `NSWindow`.
        // Deliberately left at the layer's default center anchor point —
        // recentering it on the top edge made hit-testing drift out of sync
        // with what was actually drawn after the content resized (switching
        // popover tabs, the clipboard section appearing/disappearing), which
        // was making some buttons unclickable.
        hosting.view.wantsLayer = true
        let layer = hosting.view.layer!
        layer.opacity = 0
        layer.transform = CATransform3DMakeScale(0.92, 0.92, 1)

        makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    func performClose() {
        guard isVisible, !isClosing else { return }
        isClosing = true
        removeOutsideClickMonitor()
        onClose?()

        // Mirror the open "pop" with a quick shrink + fade, then actually
        // order the window out once it's finished — closing shouldn't be a
        // harder cut than opening was.
        guard let layer = contentViewController?.view.layer else {
            orderOut(nil)
            contentViewController = nil
            isClosing = false
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            // Tears the SwiftUI content down now rather than leaving it
            // attached-but-hidden until the next `show()` replaces it —
            // views with their own `onAppear`/`onDisappear`-scoped timers
            // (the volume/brightness poll in `MonitorControlsTile` and
            // `MenuBarQuickPanel`) would otherwise keep polling in the
            // background for as long as the panel stays closed.
            self.contentViewController = nil
            self.isClosing = false
        }
        layer.opacity = 0
        layer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
        CATransaction.commit()
    }

    override func resignKey() {
        super.resignKey()
        performClose()
    }

    /// Closes on any click outside the panel, except on the anchor button
    /// itself — that click is left to reach the button's own action, which
    /// is what implements the open/close toggle (mirroring how a real
    /// `NSPopover` positioned on a status item behaves).
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if let button = self.anchorButton, let buttonWindow = button.window {
                let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
                if buttonFrame.contains(NSEvent.mouseLocation) { return }
            }
            self.performClose()
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    deinit {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
    }
}
