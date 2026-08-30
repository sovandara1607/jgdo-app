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

    /// True while the system's Reduce Motion accessibility setting is on —
    /// checked live (not cached) each time an animation is about to start,
    /// since it can change while the app is running.
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Physical spring constants approximating SwiftUI's
    /// `.spring(response: 0.25, dampingFraction: 0.88)` — derived once via
    /// the standard response/damping-ratio → mass/stiffness/damping
    /// conversion (ω0 = 2π/response, stiffness = ω0² for mass = 1, damping
    /// = 2·ζ·√stiffness) rather than computed at animation time. `duration`
    /// is set explicitly on the animation itself below rather than left to
    /// the spring's natural settling time, so the "very little bounce"
    /// spring feel never runs longer than the panel actually needs to open.
    private enum Spring {
        static let mass: CGFloat = 1
        static let stiffness: CGFloat = 631.7
        static let damping: CGFloat = 44.2
    }

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
        let finalOrigin = NSPoint(x: buttonFrame.midX - fitted.width / 2, y: buttonFrame.minY - gap - fitted.height)

        let reduceMotion = self.reduceMotion
        // Starts a few points ABOVE its resting position (screen coordinates
        // are unambiguously Y-up, unlike a layer transform's Y sign, which
        // depends on the view's flip state) and animates down into place —
        // reads as the panel extending down out of the icon above it,
        // without touching the layer's anchor point (recentering that onto
        // the top edge previously made hit-testing drift out of sync with
        // what was actually drawn once the content resized — switching
        // popover tabs, the clipboard section appearing/disappearing —
        // making some buttons unclickable; that regression isn't worth
        // reintroducing for a few pixels of polish).
        let travel: CGFloat = 7
        let startOrigin = reduceMotion ? finalOrigin : NSPoint(x: finalOrigin.x, y: finalOrigin.y + travel)
        setFrame(NSRect(origin: startOrigin, size: fitted), display: true)
        invalidateShadow()

        // Scale + fade "pop", plus the vertical settle above — more than a
        // bare opacity fade, but nowhere near AppKit's own "genie" zoom-in
        // (which read as flying in from far away). `animationBehavior =
        // .none` above still opts the window itself out of that; this
        // animates the content layer instead, which is the only way to get
        // a scale transition out of an `NSWindow`.
        hosting.view.wantsLayer = true
        let layer = hosting.view.layer!
        let startScale: CGFloat = reduceMotion ? 1 : 0.97
        layer.opacity = reduceMotion ? 1 : 0
        layer.transform = CATransform3DMakeScale(startScale, startScale, 1)

        makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()

        let duration: TimeInterval = reduceMotion ? 0.1 : 0.22

        if reduceMotion {
            // Scaling/sliding motion is exactly what Reduce Motion asks to
            // avoid — collapse to a short opacity-only fade, no spring, no
            // window-frame movement (`startOrigin == finalOrigin` above).
            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            layer.opacity = 1
            CATransaction.commit()
            return
        }

        let scaleSpring = CASpringAnimation(keyPath: "transform")
        scaleSpring.fromValue = NSValue(caTransform3D: layer.transform)
        scaleSpring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        scaleSpring.mass = Spring.mass
        scaleSpring.stiffness = Spring.stiffness
        scaleSpring.damping = Spring.damping
        scaleSpring.duration = duration
        layer.transform = CATransform3DIdentity
        layer.add(scaleSpring, forKey: "openScale")

        let opacitySpring = CASpringAnimation(keyPath: "opacity")
        opacitySpring.fromValue = 0
        opacitySpring.toValue = 1
        opacitySpring.mass = Spring.mass
        opacitySpring.stiffness = Spring.stiffness
        opacitySpring.damping = Spring.damping
        opacitySpring.duration = duration
        layer.opacity = 1
        layer.add(opacitySpring, forKey: "openOpacity")

        // The vertical settle is a window-frame move, a separate mechanism
        // from the layer transform above — AppKit's own animator proxy,
        // already used for exactly this kind of fade/slide elsewhere in the
        // app (the Command Palette's open animation). A plain `.easeOut`
        // curve here (rather than a second spring) is intentional: over
        // only ~7pt of travel a spring's overshoot wouldn't read as
        // anything but noise, and `NSAnimationContext` has no spring
        // timing function to give it anyway.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(NSRect(origin: finalOrigin, size: fitted), display: true)
        }
    }

    func performClose() {
        guard isVisible, !isClosing else { return }
        isClosing = true
        removeOutsideClickMonitor()
        onClose?()

        let reduceMotion = self.reduceMotion
        // Mirror the open "pop" with a quick shrink + fade, then actually
        // order the window out once it's finished — closing shouldn't be a
        // harder cut than opening was, but it IS faster: no spring here
        // (a bouncy close reads as sluggish, not polished), just a quick
        // linear-ish ease-in straight to gone.
        guard let layer = contentViewController?.view.layer else {
            orderOut(nil)
            contentViewController = nil
            isClosing = false
            return
        }
        let duration: TimeInterval = reduceMotion ? 0.08 : 0.15
        let finishClosing = { [weak self] in
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

        if !reduceMotion, let screen = self.screen ?? NSScreen.main {
            let travel: CGFloat = 4
            var raised = frame
            raised.origin.y = min(raised.origin.y + travel, screen.frame.maxY - raised.height)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().setFrame(raised, display: true)
            }
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock(finishClosing)
        layer.opacity = 0
        layer.transform = reduceMotion ? layer.transform : CATransform3DMakeScale(0.98, 0.98, 1)
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
