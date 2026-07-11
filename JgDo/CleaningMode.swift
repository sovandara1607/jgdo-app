import AppKit
import SwiftUI
import CoreGraphics

// MARK: - Controller

/// Keyboard cleaning mode: swallows every key event system-wide while a
/// full-screen overlay shows a countdown. Unlock via the countdown ending,
/// the on-screen button (mouse still works), or the emergency combo ⌘⌥⎋.
@Observable
final class CleaningModeController {
    static let shared = CleaningModeController()

    // Read from the @convention(c) tap callback — main-thread only in practice.
    nonisolated(unsafe) static weak var live: CleaningModeController?

    private(set) var isActive = false
    private(set) var remaining = 0
    private(set) var total = 60

    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var tapSource: CFRunLoopSource?
    private var countdownTimer: Timer?
    private var panels: [NSPanel] = []

    private init() {}

    // MARK: Start / stop

    func start(duration: Int = 60) {
        guard !isActive else { return }
        guard AXIsProcessTrusted() else {
            presentTapFailureAlert(needsPermission: true)
            return
        }
        CleaningModeController.live = self
        // Never show "Keyboard Locked" unless the tap is actually swallowing
        // keys — a lock screen over a live keyboard is worse than no lock.
        guard createTap() else {
            CleaningModeController.live = nil
            presentTapFailureAlert(needsPermission: false)
            return
        }
        total = duration
        remaining = duration
        isActive = true
        showOverlays()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
    }

    // Uses the shared non-modal FloatingNoticeCenter instead of
    // NSAlert.runModal() — an app-modal alert freezes this whole menu-bar
    // accessory app (including the menu bar icon itself) until dismissed,
    // and can even appear without key focus since there's no regular window.
    private func presentTapFailureAlert(needsPermission: Bool) {
        if needsPermission {
            FloatingNoticeCenter.shared.showPermissionRequest(
                title: "Accessibility Permission Required",
                message: "Cleaning mode needs Accessibility access to block key presses.\n\nGo to System Settings → Privacy & Security → Accessibility and enable JgDo.",
                settingsURLString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        } else {
            FloatingNoticeCenter.shared.show(
                title: "Couldn't Lock the Keyboard",
                message: "The system refused the keyboard event tap, so cleaning mode was not started.",
                primaryTitle: "OK", secondaryTitle: nil,
                onPrimary: {}
            )
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        countdownTimer?.invalidate()
        countdownTimer = nil
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        tapSource = nil
        CleaningModeController.live = nil
        hideOverlays()
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 { stop() }
    }

    // MARK: Event tap (swallow everything)

    /// Returns true only if the tap was created and enabled.
    private func createTap() -> Bool {
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) |
                               (1 << CGEventType.keyUp.rawValue) |
                               (1 << CGEventType.flagsChanged.rawValue))
        let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                guard let live = CleaningModeController.live else {
                    return Unmanaged.passRetained(event)
                }
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = live.tap { CGEvent.tapEnable(tap: t, enable: true) }
                    return Unmanaged.passRetained(event)
                }
                // Emergency unlock: ⌘⌥⎋
                if type == .keyDown,
                   event.getIntegerValueField(.keyboardEventKeycode) == 53,
                   event.flags.contains(.maskCommand),
                   event.flags.contains(.maskAlternate) {
                    DispatchQueue.main.async { CleaningModeController.shared.stop() }
                }
                return nil   // swallow every key while cleaning
            },
            userInfo: nil
        )
        guard let newTap else { return false }
        tap = newTap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    // MARK: Overlays (one per screen)

    private func showOverlays() {
        hideOverlays()
        for screen in NSScreen.screens {
            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentViewController = NSHostingController(
                rootView: CleaningModeView(controller: self)
            )
            panel.setFrame(screen.frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 1
            }
            panels.append(panel)
        }
    }

    private func hideOverlays() {
        let closing = panels
        panels = []
        for panel in closing {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
    }

    deinit { countdownTimer?.invalidate() }
}

// MARK: - Overlay view

struct CleaningModeView: View {
    let controller: CleaningModeController

    private var progress: Double {
        guard controller.total > 0 else { return 0 }
        return Double(controller.remaining) / Double(controller.total)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
            VStack(spacing: 28) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor,
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: progress)
                    VStack(spacing: 4) {
                        Image(systemName: "bubbles.and.sparkles")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.secondary)
                            .symbolEffect(.pulse, options: .repeating)
                        Text("\(controller.remaining)")
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy, value: controller.remaining)
                    }
                }
                .frame(width: 180, height: 180)

                VStack(spacing: 6) {
                    Text("Keyboard Locked")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Wipe away — every key press is ignored.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Button {
                    controller.stop()
                } label: {
                    Text("Unlock Now")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                Text("Emergency unlock: ⌘ ⌥ ⎋")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}
