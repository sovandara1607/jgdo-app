import AppKit
import SwiftUI

/// Floating, click-through panel showing the live "which window to align
/// next to" list during a ⌘-drag. It's positioned once near where the drag
/// started and left in place for the whole gesture (repositioning it on
/// every mouse-move would be distracting) — its content updates reactively
/// as `state` changes. Never becomes key: all interaction is driven by
/// `WindowDragController`'s own event tap, since stealing keyboard focus
/// mid native-window-drag would be reckless.
final class DragTargetPickerOverlay {
    static let shared = DragTargetPickerOverlay()
    let state = DragTargetPickerState()

    private var window: NSWindow?

    private init() {}

    func show(near point: CGPoint, on screen: NSScreen) {
        let win = window ?? makeWindow()
        window = win

        // Always reposition, even if the window still reads as visible from
        // a previous gesture (e.g. its fade-out hadn't finished yet before a
        // new drag started on a *different* screen) — otherwise it stays
        // frozen wherever it last appeared instead of following the drag to
        // whichever screen — main or secondary — it's actually happening on.
        let size = win.contentViewController?.view.fittingSize ?? NSSize(width: 280, height: 140)
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let appKitPoint = CGPoint(x: point.x, y: mainH - point.y)
        var x = appKitPoint.x + 28
        var y = appKitPoint.y - size.height / 2
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        y = min(max(y, screen.frame.minY + 8), screen.frame.maxY - size.height - 8)
        win.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        guard !win.isVisible else { return }   // only animate the fade-in once
        win.alphaValue = 0
        win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 1
        }
    }

    func hide() {
        state.reset()
        guard let win = window, win.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            win.animator().alphaValue = 0
        }, completionHandler: { [weak win] in
            win?.orderOut(nil)
        })
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.ignoresMouseEvents = true
        w.hasShadow = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentViewController = NSHostingController(rootView: DragTargetPickerView(state: state))
        return w
    }
}
