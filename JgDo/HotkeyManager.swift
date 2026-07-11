import AppKit
import CoreGraphics
import ApplicationServices

final class HotkeyManager {
    // Static weak ref accessed from @convention(c) callback — safe: callback fires on main thread
    nonisolated(unsafe) static weak var live: HotkeyManager?

    nonisolated(unsafe) var onToggleSwitcher: (() -> Void)?
    nonisolated(unsafe) var onResize: ((WindowLayout) -> Void)?
    nonisolated(unsafe) var onClipboard: (() -> Void)?
    nonisolated(unsafe) var onCommandPalette: (() -> Void)?
    nonisolated(unsafe) var onShrinkWindow: (() -> Void)?
    nonisolated(unsafe) var onGrowWindow: (() -> Void)?

    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var tapSource: CFRunLoopSource?
    private var retryTimer: Timer?

    // Keycodes whose keyDown we consumed — their keyUp must be consumed too,
    // otherwise the frontmost app receives an orphan key-up and plays the
    // system "unhandled key" beep.
    nonisolated(unsafe) private var consumedKeys = Set<Int64>()

    // MARK: Public

    
    func start() {
        HotkeyManager.live = self
        createTap()
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        tapSource = nil
        consumedKeys.removeAll()
        HotkeyManager.live = nil
    }

    // MARK: Tap creation

    private func createTap() {
        guard AXIsProcessTrusted() else { scheduleRetry(); return }

        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) |
                               (1 << CGEventType.keyUp.rawValue))

        let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                switch type {
                case .keyDown:
                    return HotkeyManager.live?.handleKeyDown(event)
                        ?? Unmanaged.passRetained(event)
                case .keyUp:
                    return HotkeyManager.live?.handleKeyUp(event)
                        ?? Unmanaged.passRetained(event)
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    // The system can disable a tap under load; re-enable it.
                    if let t = HotkeyManager.live?.tap {
                        CGEvent.tapEnable(tap: t, enable: true)
                    }
                    return Unmanaged.passRetained(event)
                default:
                    return Unmanaged.passRetained(event)
                }
            },
            userInfo: nil
        )

        guard let newTap else { scheduleRetry(); return }

        tap = newTap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            self?.createTap()
        }
    }

    // MARK: Key handling — nonisolated, runs on main thread via main run loop

    nonisolated private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let code  = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // Look the combo up in the user-configurable shortcut table
        // (no match = not one of ours → pass through).
        guard let match = ShortcutStore.lookup
            .first(where: { $0.combo.matches(code: code, flags: flags) })
        else { return Unmanaged.passRetained(event) }

        let action: () -> Void
        switch match.action {
        case .toggleSwitcher:
            let cb = onToggleSwitcher; action = { cb?() }
        case .clipboardHistory:
            let cb = onClipboard; action = { cb?() }
        case .commandPalette:
            let cb = onCommandPalette; action = { cb?() }
        case .shrinkWindow:
            let cb = onShrinkWindow; action = { cb?() }
        case .growWindow:
            let cb = onGrowWindow; action = { cb?() }
        default:
            guard let layout = match.action.layout else {
                return Unmanaged.passRetained(event)
            }
            let cb = onResize; action = { cb?(layout) }
        }

        // Consume the matching keyUp too, and only fire on the initial press
        // (ignore auto-repeat) so holding a key doesn't spam the action.
        consumedKeys.insert(code)
        if !isRepeat { DispatchQueue.main.async { action() } }
        return nil
    }

    nonisolated private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if consumedKeys.contains(code) {
            consumedKeys.remove(code)
            return nil   // swallow the orphan key-up → no system beep
        }
        return Unmanaged.passRetained(event)
    }

    deinit { stop() }
}
