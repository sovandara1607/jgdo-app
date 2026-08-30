import AppKit
import SwiftUI

/// "Safari → Left Half" card shown briefly after a layout hotkey fires —
/// alongside `SnapPreviewOverlay`'s ghost tile, not instead of it. Same
/// click-through/non-activating/auto-fade shape as `ActionToastCenter`,
/// just richer content (icon + `LayoutPreviewIcon` diagram + label), styled
/// to match the ⌃⌥←/→ layout overlay's card (dark tint, accent border,
/// rounded) so every layout-hotkey confirmation reads as one visual family.
@MainActor
final class WindowActionHUD {
    static let shared = WindowActionHUD()

    private var window: NSWindow?
    private var hideTimer: Timer?
    private let state = HUDContentState()

    private init() {}

    func show(appIcon: NSImage?, appName: String, layout: WindowLayout, on screen: NSScreen) {
        guard AppSettings.windowActionHUDEnabled else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let win = window ?? makeWindow()
        window = win
        state.appIcon = appIcon
        state.appName = appName
        state.layout = layout

        let hosting = win.contentViewController as! NSHostingController<WindowActionHUDView>
        // Forces the pending state mutation above to actually flush into a
        // layout pass before trusting the size — reading `fittingSize`
        // immediately after mutating `state` isn't guaranteed to reflect
        // the new content otherwise (most visible the first time this
        // window is created, as a truncated/mispositioned card).
        hosting.view.layoutSubtreeIfNeeded()
        let fitted = hosting.view.fittingSize
        let origin = NSPoint(x: screen.frame.midX - fitted.width / 2, y: screen.frame.midY - fitted.height / 2)
        win.setFrame(NSRect(origin: origin, size: fitted), display: true)

        hideTimer?.invalidate()
        let wasVisible = win.isVisible

        if reduceMotion {
            win.alphaValue = 1
            win.orderFrontRegardless()
        } else {
            // A fresh appearance animates in; re-triggering while already
            // visible (rapid repeated presses) just updates content in place.
            if !wasVisible {
                win.alphaValue = 0
                win.setFrame(win.frame.offsetBy(dx: 0, dy: -4), display: false)
            }
            win.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().alphaValue = 1
                win.animator().setFrame(NSRect(origin: origin, size: fitted), display: true)
            }
        }

        hideTimer = Timer.scheduledTimer(withTimeInterval: AppSettings.windowActionHUDDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fadeOut() }
        }
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.contentViewController = NSHostingController(rootView: WindowActionHUDView(state: state))
        return w
    }

    private func fadeOut() {
        guard let win = window, win.isVisible else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            win.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().alphaValue = 0
        }, completionHandler: { [weak win] in
            win?.orderOut(nil)
        })
    }
}

@Observable
private final class HUDContentState {
    var appIcon: NSImage?
    var appName: String = ""
    var layout: WindowLayout = .leftHalf
}

private struct WindowActionHUDView: View {
    let state: HUDContentState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if let icon = state.appIcon {
                    Image(nsImage: icon).resizable()
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Text(state.appName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            LayoutPreviewIcon(layout: state.layout)
                .frame(width: 150, height: 92)
            Text(state.layout.rawValue)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(18)
        // Same dark-tinted, accent-bordered "system HUD" language as the
        // ⌃⌥←/→ layout overlay's card — this shows the exact same kind of
        // information (icon, name, diagram, layout name) for every OTHER
        // layout hotkey, so it should read as the same family of surface.
        .hudCard(cornerRadius: 20, shadowOpacity: 0.35)
        .fixedSize()
        // Transient, non-interactive confirmation — not a place VoiceOver
        // focus should land or announce mid-action.
        .accessibilityHidden(true)
    }
}
