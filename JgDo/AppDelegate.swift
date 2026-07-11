import AppKit
import SwiftUI
import QuartzCore

// MARK: - HUD shared state

@Observable
final class HUDState {
    static let shared = HUDState()
    var frontApp: NSRunningApplication?
    var recentApps: [NSRunningApplication] = []
    var currentWindows: [WindowInfo] = []
    var searchText: String = ""
    var focusSearch: Bool = false
    var selectedIndex: Int = 0

    static let maxRows = 7

    private let service = WindowManagerService()
    private init() {}

    func updateForApp(_ app: NSRunningApplication) {
        frontApp = app
        currentWindows = service.fetchWindows().filter { $0.pid == app.processIdentifier }
    }

    func cleanRecentApps() {
        recentApps = recentApps.filter { !$0.isTerminated }
    }

    /// Recent live apps filtered by the search text (shared by the view and the
    /// keyboard handler so navigation and display stay in sync).
    var filteredApps: [NSRunningApplication] {
        let live = recentApps.filter { !$0.isTerminated }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return live }
        return live.filter { ($0.localizedName ?? "").lowercased().contains(q) }
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var hudPanel: NSPanel?
    private var clipboardPanel: NSPanel?
    private var commandPalettePanel: NSPanel?
    private var hotkeyManager: HotkeyManager?
    private var dragController: WindowDragController?
    private var workspaceObserver: Any?
    private var switcherKeyMonitor: Any?
    private var clipboardKeyMonitor: Any?
    private var commandPaletteKeyMonitor: Any?
    private var didRequestScreenRecordingAccess = false
    /// The app that was frontmost when the clipboard panel opened — focus
    /// returns to it so the picked item can be pasted in place.
    private var clipboardReturnApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupStatusPopover()
        setupHUDPanel()
        setupClipboardPanel()
        setupCommandPalettePanel()
        setupWorkspaceObserver()
        setupHotkeys()
        setupDragController()
        ClipboardService.shared.start()
        WorkflowInsightsService.shared.pruneOldEvents()
        // System monitoring is started on demand (only while the popover is open)
        // to keep background CPU/energy use at zero when idle.
        // Seed recent apps so dual-resize works from the very first hotkey press.
        // runningApplications is in arbitrary order — put the actual frontmost
        // app first so the first dual-snap picks the right partner.
        var running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
        if let front = NSWorkspace.shared.frontmostApplication,
           let idx = running.firstIndex(of: front) {
            running.remove(at: idx)
            running.insert(front, at: 0)
        }
        HUDState.shared.recentApps = Array(running.prefix(6))
        checkAccessibilityPermission()
    }

    private func checkAccessibilityPermission() {
        guard !AXIsProcessTrusted() else { return }
        // AXIsProcessTrusted() alone never registers the app with the OS —
        // without the prompt option, JgDo would never appear in System
        // Settings → Privacy & Security → Accessibility for the user to
        // enable, no matter how many times they open that pane.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            FloatingNoticeCenter.shared.showPermissionRequest(
                title: "Accessibility Permission Required",
                message: "JgDo needs Accessibility access to intercept keyboard shortcuts (⌃⌥+arrows, ⌥Space).\n\nGo to System Settings → Privacy & Security → Accessibility, then enable JgDo.\n\nShortcuts will activate automatically once permission is granted — no relaunch needed.",
                settingsURLString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        dragController?.stop()
    }

    // MARK: - Status bar (icon only; left-click = system status popover)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = NSImage(systemSymbolName: "rectangle.split.2x1",
                               accessibilityDescription: "JgDo")?
            .withSymbolConfiguration(config)
        button.action = #selector(toggleStatusPopover)
        button.target = self
    }

    private func setupStatusPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 440)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let rootView = StatusPopoverView()
            .environment(\.dismissPopover) { [weak popover] in popover?.performClose(nil) }
        popover.contentViewController = NSHostingController(rootView: rootView)
        statusPopover = popover
    }

    @objc func toggleStatusPopover() {
        guard let button = statusItem?.button, let popover = statusPopover else { return }
        hideHUD()
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Start sampling just before showing so values are ready, then it
            // keeps running until the popover closes (see popoverDidClose).
            SystemMonitor.shared.start()
            MonitorControlService.shared.refresh()
            WorkflowInsightsService.shared.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Floating HUD panel

    private func setupHUDPanel() {
        // A key-capable panel so the search field can receive keystrokes.
        // (.nonactivatingPanel alone never becomes key → typing wouldn't work.)
        let panel = KeyablePanel(
            // Matches the exact size `showHUD()` sets below — a transparent
            // panel that gets *resized* after its backing store already
            // exists can leave a stale ghost outline of the original frame
            // in the compositor, so this must never actually change size.
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = SwitcherHUD(
            onDismiss: { [weak self] in self?.hideHUD() },
            onPick: { [weak self] app in self?.pickApp(app) }
        )
        .environment(HUDState.shared)
        panel.contentViewController = NSHostingController(rootView: rootView)
        hudPanel = panel
    }

    /// Show the interactive app switcher, centered on the active screen.
    func showHUD() {
        guard let panel = hudPanel else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]

        // Reset the switcher to a clean state each time it opens.
        let state = HUDState.shared
        state.cleanRecentApps()
        state.searchText = ""
        state.selectedIndex = 0

        // Compact popup, centered (slightly above center) on the active screen.
        let pw: CGFloat = 560
        let ph: CGFloat = 560
        let x = screen.frame.minX + (screen.frame.width - pw) / 2
        let y = screen.frame.minY + (screen.frame.height - ph) / 2 + screen.frame.height * 0.08
        panel.setFrame(NSRect(x: x, y: y, width: pw, height: ph), display: true)
        // Panel was created at a placeholder size — without this, the shadow
        // mask AppKit cached at creation stays stale after the resize.
        panel.invalidateShadow()

        if !panel.isVisible { panel.alphaValue = 0 }
        // The switcher needs key focus so typing works.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        state.focusSearch = true

        installSwitcherKeyMonitor()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hideHUD() {
        removeSwitcherKeyMonitor()
        guard let panel = hudPanel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
        HUDState.shared.searchText = ""
    }

    @objc func toggleHUD() {
        if hudPanel?.isVisible == true { hideHUD() } else { showHUD() }
    }

    // MARK: - Switcher keyboard navigation

    /// Intercept navigation keys at the AppKit level. Handling them here (and
    /// returning nil to consume) means SwiftUI's text field never receives an
    /// "unhandled" arrow/Return key — which is what was triggering the system
    /// beep and blocking navigation. Typing keys are passed through untouched.
    private func installSwitcherKeyMonitor() {
        removeSwitcherKeyMonitor()
        switcherKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.hudPanel?.isVisible == true else { return event }
            switch event.keyCode {
            case 126: self.moveSelection(-1); return nil   // ↑
            case 125: self.moveSelection(1);  return nil   // ↓
            case 36, 76: self.pickSelected(); return nil   // Return / Enter
            case 53: self.hideHUD();          return nil   // Esc
            default: return event                          // typing → text field
            }
        }
    }

    private func removeSwitcherKeyMonitor() {
        if let m = switcherKeyMonitor {
            NSEvent.removeMonitor(m)
            switcherKeyMonitor = nil
        }
    }

    private func moveSelection(_ delta: Int) {
        let state = HUDState.shared
        let n = min(state.filteredApps.count, HUDState.maxRows)
        guard n > 0 else { return }
        state.selectedIndex = (state.selectedIndex + delta + n) % n
    }

    private func pickSelected() {
        let state = HUDState.shared
        let list = Array(state.filteredApps.prefix(HUDState.maxRows))
        guard list.indices.contains(state.selectedIndex) else { hideHUD(); return }
        pickApp(list[state.selectedIndex])
    }

    /// Activate the picked app and snap it side-by-side with the app you were on.
    private func pickApp(_ app: NSRunningApplication) {
        let svc = WindowResizeService.shared
        let partner = HUDState.shared.recentApps.first {
            !$0.isTerminated && $0.processIdentifier != app.processIdentifier
        }

        // Chosen app → left half, the app you were on → right half.
        svc.resize(app: app, to: .leftHalf)
        if let partner { svc.resize(app: partner, to: .rightHalf) }
        app.activate(options: [.activateIgnoringOtherApps])

        // Ghost preview of the resulting layout on the active screen.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let primary = svc.frame(for: .leftHalf, on: screen)
        let secondary = partner != nil ? svc.frame(for: .rightHalf, on: screen) : nil
        SnapPreviewOverlay.shared.show(primary: primary, secondary: secondary, on: screen)

        hideHUD()
    }

    // MARK: - Clipboard history panel (⌥V)

    private func setupClipboardPanel() {
        let panel = KeyablePanel(
            // Matches the exact size `showClipboardPanel()` sets below — see
            // the comment in `setupHUDPanel()` for why this must not change.
            contentRect: NSRect(x: 0, y: 0, width: 552, height: 560),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = ClipboardHistoryView(
            onDismiss: { [weak self] in self?.hideClipboardPanel() },
            onPick: { [weak self] item in self?.pickClipboardItem(item) }
        )
        panel.contentViewController = NSHostingController(rootView: rootView)
        clipboardPanel = panel
    }

    func showClipboardPanel() {
        guard let panel = clipboardPanel else { return }
        hideHUD()
        clipboardReturnApp = NSWorkspace.shared.frontmostApplication

        let service = ClipboardService.shared
        service.reload()
        service.searchText = ""
        service.selectedIndex = 0

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let pw: CGFloat = 552, ph: CGFloat = 560
        let x = screen.frame.minX + (screen.frame.width - pw) / 2
        let y = screen.frame.minY + (screen.frame.height - ph) / 2 + screen.frame.height * 0.06
        panel.setFrame(NSRect(x: x, y: y, width: pw, height: ph), display: true)
        panel.invalidateShadow()

        if !panel.isVisible { panel.alphaValue = 0 }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        service.focusSearch = true
        installClipboardKeyMonitor()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hideClipboardPanel() {
        removeClipboardKeyMonitor()
        guard let panel = clipboardPanel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
        ClipboardService.shared.searchText = ""
    }

    @objc func toggleClipboardPanel() {
        if clipboardPanel?.isVisible == true { hideClipboardPanel() } else { showClipboardPanel() }
    }

    /// Copy the picked item, hand focus back to the app the user came from,
    /// and paste it there. If the panel was opened from JgDo itself (or the
    /// origin app is gone), just leave the item on the pasteboard — a synthetic
    /// ⌘V would land nowhere useful.
    private func pickClipboardItem(_ item: ClipboardItem) {
        let service = ClipboardService.shared
        service.copyToPasteboard(item)
        hideClipboardPanel()
        guard let target = clipboardReturnApp, !target.isTerminated,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        target.activate(options: [.activateIgnoringOtherApps])
        // Small delay so the target app is key before ⌘V arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            service.sendPasteKeystroke()
        }
    }

    private func installClipboardKeyMonitor() {
        removeClipboardKeyMonitor()
        clipboardKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.clipboardPanel?.isVisible == true else { return event }
            let service = ClipboardService.shared
            let count = min(service.filteredItems.count, 60)
            switch event.keyCode {
            case 126:   // ↑
                guard count > 0 else { return nil }
                service.selectedIndex = (service.selectedIndex - 1 + count) % count
                return nil
            case 125:   // ↓
                guard count > 0 else { return nil }
                service.selectedIndex = (service.selectedIndex + 1) % count
                return nil
            case 36, 76:   // Return / Enter
                let items = Array(service.filteredItems.prefix(60))
                if items.indices.contains(service.selectedIndex) {
                    self.pickClipboardItem(items[service.selectedIndex])
                } else {
                    self.hideClipboardPanel()
                }
                return nil
            case 53:   // Esc
                self.hideClipboardPanel()
                return nil
            default:
                return event
            }
        }
    }

    private func removeClipboardKeyMonitor() {
        if let m = clipboardKeyMonitor {
            NSEvent.removeMonitor(m)
            clipboardKeyMonitor = nil
        }
    }

    // MARK: - Command Palette panel (⌘⌥Space) — window-level Spotlight-style switcher

    private func setupCommandPalettePanel() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = CommandPaletteView(
            onDismiss: { [weak self] in self?.hideCommandPalette() },
            onPick: { [weak self] window in self?.pickPaletteWindow(window) }
        )
        .environment(CommandPaletteState.shared)
        panel.contentViewController = NSHostingController(rootView: rootView)
        commandPalettePanel = panel
    }

    func showCommandPalette() {
        guard let panel = commandPalettePanel else { return }
        hideHUD()
        hideClipboardPanel()
        checkScreenRecordingPermission()

        let state = CommandPaletteState.shared
        state.reload()

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let pw: CGFloat = 720, ph: CGFloat = 480
        let x = screen.frame.minX + (screen.frame.width - pw) / 2
        let y = screen.frame.minY + (screen.frame.height - ph) / 2 + screen.frame.height * 0.06
        panel.setFrame(NSRect(x: x, y: y, width: pw, height: ph), display: true)
        panel.invalidateShadow()

        if !panel.isVisible { panel.alphaValue = 0 }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        state.focusSearch = true
        installCommandPaletteKeyMonitor()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hideCommandPalette() {
        removeCommandPaletteKeyMonitor()
        guard let panel = commandPalettePanel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
        WindowThumbnailService.clearCache()
    }

    @objc func toggleCommandPalette() {
        if commandPalettePanel?.isVisible == true { hideCommandPalette() } else { showCommandPalette() }
    }

    private func pickPaletteWindow(_ window: WindowInfo) {
        WindowManagerService().focusWindow(window)
        hideCommandPalette()
    }

    private func installCommandPaletteKeyMonitor() {
        removeCommandPaletteKeyMonitor()
        commandPaletteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.commandPalettePanel?.isVisible == true else { return event }
            let state = CommandPaletteState.shared
            switch event.keyCode {
            case 126: state.move(-1); return nil   // ↑
            case 125: state.move(1);  return nil   // ↓
            case 36, 76:                                 // Return / Enter
                if let window = state.selectedWindow { self.pickPaletteWindow(window) }
                else { self.hideCommandPalette() }
                return nil
            case 53: self.hideCommandPalette(); return nil   // Esc
            default: return event                             // typing → search field
            }
        }
    }

    private func removeCommandPaletteKeyMonitor() {
        if let m = commandPaletteKeyMonitor {
            NSEvent.removeMonitor(m)
            commandPaletteKeyMonitor = nil
        }
    }

    private func checkScreenRecordingPermission() {
        guard !didRequestScreenRecordingAccess else { return }
        didRequestScreenRecordingAccess = true
        guard !WindowThumbnailService.isAuthorized else { return }
        WindowThumbnailService.requestAccessIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !WindowThumbnailService.isAuthorized else { return }
            FloatingNoticeCenter.shared.showPermissionRequest(
                title: "Screen Recording Permission Needed",
                message: "Live window thumbnails in the Command Palette need Screen Recording access.\n\nGo to System Settings → Privacy & Security → Screen Recording, then enable JgDo. The palette still works without it — cards just show app icons instead of previews.",
                settingsURLString: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        }
    }

    // MARK: - Workspace observer (tracks recent apps; does NOT show HUD)

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            // Keep the recent-apps list up to date so dual-app resize knows the
            // previous app — but never auto-show the HUD on plain app switches.
            let state = HUDState.shared
            state.cleanRecentApps()
            state.recentApps.removeAll { $0.processIdentifier == app.processIdentifier }
            state.recentApps.insert(app, at: 0)
            if state.recentApps.count > 6 { state.recentApps.removeLast() }
            // Feed the workflow-insights engine (on-device only).
            WorkflowInsightsService.shared.recordActivation(of: app)
        }
    }

    // MARK: - Hotkeys

    private func setupHotkeys() {
        // `ShortcutStore.lookup` (the table HotkeyManager's tap matches key
        // combos against) is only populated inside ShortcutStore's private
        // init() — which only runs the first time `.shared` is *accessed*.
        // Until now, the only place in the app that touched `.shared` was
        // the Settings → Shortcuts tab, so every hotkey silently fell
        // through unmatched until that tab had been opened once. Touching
        // it here guarantees the table is ready before the tap starts.
        _ = ShortcutStore.shared

        let mgr = HotkeyManager()
        mgr.onToggleSwitcher = { [weak self] in
            DispatchQueue.main.async { self?.toggleHUD() }
        }
        // ⌥V opens the clipboard history.
        mgr.onClipboard = { [weak self] in
            DispatchQueue.main.async { self?.toggleClipboardPanel() }
        }
        // ⌘⌥Space opens the Spotlight-style command palette.
        mgr.onCommandPalette = { [weak self] in
            DispatchQueue.main.async { self?.toggleCommandPalette() }
        }
        // ⌃⌥⇧. (>) / ⌃⌥⇧, (<) step-resize the frontmost window in place.
        mgr.onShrinkWindow = {
            guard let (frame, indicator) = WindowResizeService.shared.shrinkFrontmostWindow() else { return }
            let screen = NSScreen.main ?? NSScreen.screens[0]
            SnapPreviewOverlay.shared.show(primary: frame, secondary: nil, indicator: indicator, on: screen)
        }
        mgr.onGrowWindow = {
            guard let (frame, indicator) = WindowResizeService.shared.growFrontmostWindow() else { return }
            let screen = NSScreen.main ?? NSScreen.screens[0]
            SnapPreviewOverlay.shared.show(primary: frame, secondary: nil, indicator: indicator, on: screen)
        }
        mgr.onResize = { layout in
            let svc = WindowResizeService.shared
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            // Snap the front window, then the topmost OTHER visible window to the complement.
            // `resizeFrontmostWindow` returns what it actually applied, which
            // may be mid-cycle for edge-snap layouts — not necessarily the
            // plain preset `frame(for:on:)` would report.
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let primary = svc.resizeFrontmostWindow(to: layout) ?? svc.frame(for: layout, on: screen)
            // Keep the partner complementary to whatever the primary's
            // edge-snap cycle just landed on (e.g. two-thirds → the partner
            // gets the remaining third), not always a fixed half.
            var secondary: CGRect?
            if let complement = layout.complement {
                secondary = svc.resizeOtherVisibleWindow(excluding: frontPID, to: complement,
                                                          fraction: svc.complementFraction(for: layout))
            }
            // Flash a ghost preview of where the windows land, with a "2/3"
            // step indicator if the edge-snap cycle is mid-sequence.
            SnapPreviewOverlay.shared.show(primary: primary, secondary: secondary,
                                            indicator: svc.cycleIndicator(for: layout), on: screen)
        }
        mgr.start()
        hotkeyManager = mgr
    }

    // MARK: - ⌘-drag snap + adjacent resize

    private func setupDragController() {
        let controller = WindowDragController()
        controller.start()
        dragController = controller
    }
}

// MARK: - Key-capable panel

/// An NSPanel that can become the key/main window even with a non-activating,
/// borderless-style mask — required so the switcher's text field accepts input.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Popover lifecycle (pause monitoring when closed)

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        SystemMonitor.shared.stop()
    }
}

// MARK: - Environment key (kept for compatibility)

struct DismissPopoverKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var dismissPopover: () -> Void {
        get { self[DismissPopoverKey.self] }
        set { self[DismissPopoverKey.self] = newValue }
    }
}
