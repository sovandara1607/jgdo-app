import AppKit
import SwiftUI

@MainActor
final class ActionToastCenter {
    static let shared = ActionToastCenter()

    private var window: NSWindow?
    private var hideTimer: Timer?
    private let state = ToastState()

    private init() {}

    func show(_ message: String, icon: String? = nil, duration: TimeInterval = 1.6) {
        guard AppSettings.actionToastsEnabled else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let screen = CoordinateSpace.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens[0]

        let win = window ?? makeWindow()
        window = win
        state.message = message
        state.icon = icon

        let hosting = win.contentViewController as! NSHostingController<ToastView>
        // Forces the state mutation above to flush into a layout pass
        // before trusting the size — see the same fix in
        // `WindowLayoutSelectorOverlay.show`/`WindowActionHUD.show`.
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize
        let topInset: CGFloat = 46
        let origin = NSPoint(
            x: screen.frame.midX - fitted.width / 2,
            y: screen.frame.maxY - topInset - fitted.height
        )
        win.setFrame(NSRect(origin: origin, size: fitted), display: true)

        hideTimer?.invalidate()
        let wasVisible = win.isVisible

        if reduceMotion {
            win.alphaValue = 1
            win.orderFrontRegardless()
        } else if !wasVisible {
            win.alphaValue = 0
            win.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().alphaValue = 1
            }
        }


        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fadeOut() }
        }
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.contentViewController = NSHostingController(rootView: ToastView(state: state))
        return w
    }

    private func fadeOut() {
        guard let win = window, win.isVisible else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            win.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().alphaValue = 0
        }, completionHandler: { [weak win] in
            win?.orderOut(nil)
        })
    }
}

@Observable
private final class ToastState {
    var message: String = ""
    var icon: String?
}

private struct ToastView: View {
    let state: ToastState

    var body: some View {
        HStack(spacing: 7) {
            if let icon = state.icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(state.message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .panelCard()
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
