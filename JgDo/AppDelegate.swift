import AppKit
import SwiftUI
import QuartzCore
import Observation
import os

// MARK: - HUD shared state

@Observable
final class HUDState {
    static let shared = HUDState()
    var recentApps: [NSRunningApplication] = []
    var searchText: String = ""
    var focusSearch: Bool = false
    var selectedIndex: Int = 0

    static let maxRows = 7

    private let service = WindowManagerService()
    private init() {}

    /// Whichever app arrow-key navigation or search currently has
    /// highlighted — nil once filtering/typing leaves nothing selected.
    var selectedApp: NSRunningApplication? {
        let apps = filteredApps
        guard apps.indices.contains(selectedIndex) else { return nil }
        return apps[selectedIndex]
    }

    /// Live windows for `selectedApp`, for the switcher's preview panel.
    /// Computed (not cached) so it's always in sync with `selectedIndex`/
    /// `searchText` — previously this was a stored property a now-deleted
    /// `updateForApp(_:)` was supposed to refresh on every selection change,
    /// but nothing ever called it, so the preview silently never updated.
    var currentWindows: [WindowInfo] {
        guard let app = selectedApp else { return [] }
        return service.fetchWindows().filter { $0.pid == app.processIdentifier }
    }

    func cleanRecentApps() {
        recentApps = recentApps.filter { !$0.isTerminated }
    }

    var filteredApps: [NSRunningApplication] {
        let live = recentApps.filter { !$0.isTerminated }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return live }
        return live.filter { ($0.localizedName ?? "").lowercased().contains(q) }
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var statusPopover: MenuBarPopoverPanel?
    private var defaultStatusIcon: NSImage?
    private var hudPanel: NSPanel?
    private var clipboardPanel: NSPanel?
    private var commandPalettePanel: NSPanel?
    private let cheatSheetController = CheatSheetPanelController()
    private let scratchpadController = ScratchpadPanelController()
    private let organizeController = OrganizePanelController()
    private let windowParkingController = WindowParkingController()
    private let nlWorkspaceController = NLWorkspacePanelController()
    private let layoutPickerController = LayoutPickerPanelController()
    private let layoutSelectorController = WindowLayoutSelectorController()
    private let workspaceTemplatesController = WorkspaceTemplatesPanelController()
    private var workspaceObserver: Any?
    private var deactivateObserver: Any?
    private var switcherKeyMonitor: Any?
    private var clipboardKeyMonitor: Any?
    private var commandPaletteKeyMonitor: Any?
    private var didRequestScreenRecordingAccess = false
    /// The app that was frontmost when the clipboard panel opened — focus
    /// returns to it so the picked item can be pasted in place.
    private var clipboardReturnApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        // The status item and its click handler exist unconditionally — they're
        // how an unlicensed install reaches the activation window at all.
        setupStatusItem()
        setupStatusPopover()

        let proceedPastOnboarding: () -> Void = { [weak self] in
            if LicenseManager.shared.isPro {
                self?.startLicensedFeatures()
            } else {
                ActivationWindow.show { [weak self] in self?.startLicensedFeatures() }
            }
        }
        if AppSettings.hasCompletedOnboarding {
            proceedPastOnboarding()
        } else {
            OnboardingWindow.show(onFinished: proceedPastOnboarding)
        }
    }

    /// Everything that requires an active license: window snapping, the HUD,
    /// clipboard history, the command palette, hotkeys, drag-to-snap. JgDo has
    /// no free tier, so none of this runs until `LicenseManager.isPro` is true
    /// (either at launch, or the moment ActivationWindow succeeds).
    private func startLicensedFeatures() {
        setupHUDPanel()
        setupClipboardPanel()
        setupCommandPalettePanel()
        cheatSheetController.setup()
        scratchpadController.setup()
        organizeController.setup()
        nlWorkspaceController.setup()
        layoutPickerController.setup()
        workspaceTemplatesController.setup()
        setupWorkspaceObserver()
        LicenseFeatureCoordinator.shared.start { [weak self] mgr in
            self?.configureHotkeys(mgr)
        }
        WorkflowInsightsService.shared.pruneOldEvents()
        WorkspaceService.shared.restoreWorkspacesFlaggedForLaunch()
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
        PermissionMonitor.shared.refresh()
        guard !PermissionMonitor.shared.accessibilityTrusted else { return }
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
        if let obs = deactivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        // Symmetric with `startLicensedFeatures()` — used to only stop
        // `dragController` here, leaving hotkeys/clipboard-polling/battery
        // monitoring/cleaning-mode running until process teardown killed
        // them implicitly rather than explicitly.
        LicenseFeatureCoordinator.shared.stop()
        // Explicitly tears down any live SCStreams rather than letting
        // process teardown do it implicitly — ScreenCaptureKit streams are
        // OS-level capture sessions, worth stopping cleanly.
        FloatingWindowManager.shared.stopAll()
    }

    // MARK: - Status bar (icon only; left-click = system status popover)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        defaultStatusIcon = MenuBarIconRendering.loadStatusIcon()
        button.image = defaultStatusIcon
        button.imagePosition = .imageLeading
        // Left-click opens the full popover; right-click shows the quick
        // panel instead — handled manually (rather than `statusItem.menu`,
        // which would swallow left-clicks too) by branching on the event
        // that triggered `statusItemClicked`.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(statusItemClicked)
        button.target = self
        button.addSubview(badgeDotView)
        setupQuickPopover()
        applyMenuBarStatSetting()
        installMenuBarScrollMonitor()
        observeQuickStatusBadge()
    }

    /// Left-click opens the popover; right-click shows the quick panel.
    /// Both share one `action`/`target` (rather than `statusItem.menu`,
    /// which would swallow left-clicks into a menu too) — the current event
    /// on `NSApp` is how AppKit distinguishes which mouse button fired.
    @objc private func statusItemClicked() {
        let opening = statusPopover?.isShown != true && quickPopover?.isShown != true
        if opening { animateStatusIconPress() }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickPanel()
        } else {
            toggleStatusPopover()
        }
    }

    /// A small "press" reaction on the menu bar icon itself right as a panel
    /// opens — down slightly, spring back with a touch of overshoot, settle.
    /// Purely cosmetic (doesn't gate or delay the panel opening, which
    /// starts in the same call), so it costs nothing if Reduce Motion is on,
    /// in which case it's skipped entirely rather than just shortened —
    /// this is exactly the kind of icon bounce that setting exists to turn
    /// off.
    private func animateStatusIconPress() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let button = statusItem?.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }

        let keyframes = CAKeyframeAnimation(keyPath: "transform.scale")
        keyframes.values = [1.0, 0.88, 1.05, 1.0]
        // Roughly matches how far through the ~190ms total each step lands
        // — quick compress, springier release, short settle.
        keyframes.keyTimes = [0, 0.32, 0.7, 1.0]
        keyframes.duration = 0.19
        keyframes.timingFunctions = [
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        layer.add(keyframes, forKey: "statusIconPress")
    }

    // MARK: - Quick panel (right-click)

    private var quickPopover: MenuBarPopoverPanel?

    private func setupQuickPopover() {
        let popover = MenuBarPopoverPanel()
        popover.onClose = { SystemMonitor.shared.setQuickPanelVisible(false) }
        quickPopover = popover
    }

    private func showQuickPanel() {
        guard LicenseManager.shared.isPro, let button = statusItem?.button, let popover = quickPopover else {
            toggleStatusPopover()   // unlicensed installs only get the activation flow
            return
        }
        if popover.isShown { popover.performClose(); return }
        statusPopover?.performClose()
        // `pickClipboardItem` pastes back into whichever app was frontmost
        // when the panel opened — same bookkeeping the dedicated clipboard
        // panel does (see `showClipboardPanel`).
        clipboardReturnApp = NSWorkspace.shared.frontmostApplication
        SystemMonitor.shared.setQuickPanelVisible(true)
        MonitorControlService.shared.refresh()
        let rootView = MenuBarQuickPanel(
            onOpenSettings: { [weak self] in
                self?.quickPopover?.performClose()
                SettingsWindow.show()
            },
            onRestoreWorkspace: { [weak self] in
                guard let last = WorkspaceService.shared.workspaces.first else { return }
                WorkspaceService.shared.restore(last)
                self?.quickPopover?.performClose()
            },
            onToggleAlwaysOnTop: { [weak self] in self?.toggleAlwaysOnTopOnFrontmost() },
            onToggleWindowMemory: { [weak self] in self?.toggleWindowMemoryOnFrontmost() },
            onPickClipboardItem: { [weak self] item in
                self?.pickClipboardItem(item)
                self?.quickPopover?.performClose()
            },
            onQuit: { NSApp.terminate(nil) }
        )
        // Deliberately no `NSApp.activate` here (unlike the HUD/palette
        // panels) — keeps `NSWorkspace.shared.frontmostApplication` pointing
        // at whatever app the user was in, so "Toggle Always on Top" affects
        // that app's window, not JgDo's own popover.
        popover.show(relativeTo: button, rootView: rootView)
    }

    /// Shared by the ⌃⌥T hotkey and the quick panel's "Toggle Always on Top".
    private func toggleAlwaysOnTopOnFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let (frame, pinned) = AlwaysOnTopService.shared.toggleFocusedWindow(of: app) else { return }
        let appKitFrame = CoordinateSpace.appKit(fromCG: frame)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        SnapPreviewOverlay.shared.show(primary: appKitFrame, secondary: nil,
                                        indicator: pinned ? "Pinned" : "Unpinned", on: screen)
    }

    /// Shared by the quick panel's "Remember Window Position" row.
    private func toggleWindowMemoryOnFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let enabled = WindowMemoryService.shared.toggle(for: app)
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, let cgFrame = WindowManagerService.axFrame(of: ref as! AXUIElement) else { return }
        let appKitFrame = CoordinateSpace.appKit(fromCG: cgFrame)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        SnapPreviewOverlay.shared.show(primary: appKitFrame, secondary: nil,
                                        indicator: enabled ? "Remembering" : "Forgotten", on: screen)
    }

    // MARK: - Live stat label (menu bar text)

    /// Re-reads the Settings picker, tells `SystemMonitor` whether it needs
    /// to keep sampling on this reason alone (independent of the popover —
    /// see `SystemMonitor.reconcileRunning`), and (re)installs the
    /// observation that keeps the label live.
    func applyMenuBarStatSetting() {
        let stat = currentMenuBarStat
        SystemMonitor.shared.setMenuBarStatVisible(stat != .off)
        updateMenuBarStat()
        if stat != .off { observeSystemMonitor() }
    }

    private var currentMenuBarStat: MenuBarStat {
        MenuBarStat(rawValue: UserDefaults.standard.string(forKey: AppSettings.menuBarStatKey) ?? "") ?? .off
    }

    /// `@Observable`'s access-tracking hook — re-registers itself on every
    /// fire since `withObservationTracking` only observes ONE change, not a
    /// stream. This is the plain-AppKit equivalent of a SwiftUI view reading
    /// `SystemMonitor.shared.status` and re-rendering on change.
    private func observeSystemMonitor() {
        withObservationTracking {
            _ = SystemMonitor.shared.status
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.currentMenuBarStat != .off else { return }
                self.updateMenuBarStat()
                self.observeSystemMonitor()
            }
        }
    }

    private func updateMenuBarStat() {
        guard let button = statusItem?.button else { return }
        let status = SystemMonitor.shared.status
        switch currentMenuBarStat {
        case .off:
            button.image = defaultStatusIcon
            button.title = ""
        case .cpu:
            let pct = status.cpuPercent / 100
            button.image = MenuBarIconRendering.renderGaugeIcon(percent: pct)
            button.title = " " + String(format: "%.0f%%", status.cpuPercent)
        case .memory:
            button.image = MenuBarIconRendering.renderGaugeIcon(percent: status.memPercent)
            button.title = " " + String(format: "%.0f%%", status.memPercent * 100)
        }
        positionBadge()
    }

    // MARK: - Status bar icon (bundled logo or user-chosen replacement)

    /// Called by Settings after the user picks/resets the menu bar icon.
    func applyStatusIconSetting() {
        defaultStatusIcon = MenuBarIconRendering.loadStatusIcon()
        if currentMenuBarStat == .off {
            statusItem?.button?.image = defaultStatusIcon
        }
    }

    // MARK: - Status badge (Focus Mode / Cleaning / Always on Top)

    /// Small colored dot overlaid on the menu bar icon's bottom-right corner
    /// — glanceable state without opening anything. A plain `NSView`
    /// subview rather than baking it into the icon bitmap, so it stays
    /// correct across Light/Dark and doesn't need template-tint math.
    private lazy var badgeDotView: NSView = {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        v.wantsLayer = true
        v.layer?.cornerRadius = 3.5
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        v.isHidden = true
        return v
    }()

    private func positionBadge() {
        guard let button = statusItem?.button else { return }
        let d: CGFloat = 7
        badgeDotView.frame = NSRect(x: button.bounds.maxX - d - 1, y: 1, width: d, height: d)
    }

    /// Re-registers on every fire (see `observeSystemMonitor` for why) —
    /// reads all three services in one tracking pass so any of them
    /// changing recomputes the single badge dot's color/visibility.
    private func observeQuickStatusBadge() {
        withObservationTracking {
            _ = FocusModeService.shared.isActive
            _ = CleaningModeController.shared.isActive
            _ = AlwaysOnTopService.shared.pinnedWindowIDs
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusBadge()
                self?.observeQuickStatusBadge()
            }
        }
        updateStatusBadge()
    }

    private func updateStatusBadge() {
        positionBadge()
        let color: NSColor?
        if FocusModeService.shared.isActive {
            color = .systemPurple
        } else if CleaningModeController.shared.isActive {
            color = .systemBlue
        } else if !AlwaysOnTopService.shared.pinnedWindowIDs.isEmpty {
            color = .systemOrange
        } else {
            color = nil
        }
        badgeDotView.layer?.backgroundColor = color?.cgColor
        badgeDotView.isHidden = color == nil
    }

    // MARK: - Scroll-to-adjust (volume / brightness)

    private var menuBarScrollMonitor: Any?

    /// Scrolling over the menu bar icon nudges system volume; holding ⌥
    /// nudges display brightness instead — a local monitor (not a click
    /// action) because `NSControl.sendAction(on:)` only recognizes
    /// mouse-tracking event types, not `.scrollWheel`.
    private func installMenuBarScrollMonitor() {
        menuBarScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let button = self.statusItem?.button,
                  event.window == button.window, LicenseManager.shared.isPro else { return event }
            self.handleMenuBarScroll(event)
            return event
        }
    }

    private func handleMenuBarScroll(_ event: NSEvent) {
        let delta = Float(event.scrollingDeltaY)
        guard abs(delta) > 0.5 else { return }
        let step: Float = 0.03
        // scrollingDeltaY already accounts for the user's natural-scrolling
        // preference, so "scroll up" reliably means "increase" either way.
        let direction: Float = delta > 0 ? 1 : -1

        if event.modifierFlags.contains(.option) {
            let svc = MonitorControlService.shared
            guard svc.brightnessAvailable else { return }
            svc.setBrightness(min(max(svc.brightness + direction * step, 0), 1))
        } else {
            let svc = MonitorControlService.shared
            guard svc.volumeAvailable else { return }
            svc.setVolume(min(max(svc.volume + direction * step, 0), 1))
        }
    }

    private func setupStatusPopover() {
        let popover = MenuBarPopoverPanel()
        popover.onClose = { SystemMonitor.shared.setPopoverVisible(false) }
        statusPopover = popover
    }

    @objc func toggleStatusPopover() {
        guard LicenseManager.shared.isPro else {
            ActivationWindow.show { [weak self] in self?.startLicensedFeatures() }
            return
        }
        guard let button = statusItem?.button, let popover = statusPopover else { return }
        hideHUD()
        if popover.isShown {
            popover.performClose()
        } else {
            // Start sampling just before showing so values are ready, then it
            // keeps running until the popover closes (see the `onClose`
            // closure set in `setupStatusPopover`).
            SystemMonitor.shared.setPopoverVisible(true)
            SystemMonitor.shared.start()
            MonitorControlService.shared.refresh()
            WorkflowInsightsService.shared.refresh()
            quickPopover?.performClose()
            let rootView = StatusPopoverView()
                .environment(\.dismissPopover) { [weak popover] in popover?.performClose() }
            popover.show(relativeTo: button, rootView: rootView)
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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 440),
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
        // Native window shadow OFF — SwiftUI's own `.panelCard()` shadow is
        // the only one now. Having both caused a jagged double-shadow seam
        // at the rounded corners during the alpha fade-in (the native shadow
        // rasterizes against stale corner geometry mid-animation).
        panel.hasShadow = false
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
        let pw: CGFloat = 440
        let ph: CGFloat = 440
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

        // Chosen app → left half, the app you were on → right half —
        // grouped so ⌃⌥Z undoes both together.
        WindowSnapUndo.shared.beginTransaction()
        svc.resize(app: app, to: .leftHalf)
        if let partner { svc.resize(app: partner, to: .rightHalf) }
        WindowSnapUndo.shared.endTransaction()
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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
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
        // Native window shadow OFF — SwiftUI's own `.panelCard()` shadow is
        // the only one now. Having both caused a jagged double-shadow seam
        // at the rounded corners during the alpha fade-in (the native shadow
        // rasterizes against stale corner geometry mid-animation).
        panel.hasShadow = false
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
        let pw: CGFloat = 500, ph: CGFloat = 460
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

            // ⌘1–⌘9 jump straight to that row and paste it, without arrowing
            // down first — the digit itself still types normally into the
            // search field when ⌘ isn't held.
            if event.modifierFlags.contains(.command),
               let idx = Self.digitKeyToIndex[event.keyCode] {
                let items = Array(service.filteredItems.prefix(60))
                if items.indices.contains(idx) { self.pickClipboardItem(items[idx]) }
                return nil
            }

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

    /// ANSI virtual key codes for the digit row 1–9 → zero-based list index,
    /// for ⌘1–⌘9 clipboard quick-paste.
    private static let digitKeyToIndex: [UInt16: Int] = [
        18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8,
    ]

    // MARK: - Command Palette panel (⌘⌥Space) — window-level Spotlight-style switcher

    private func setupCommandPalettePanel() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
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
        // Native window shadow OFF — SwiftUI's own `.panelCard()` shadow is
        // the only one now. Having both caused a jagged double-shadow seam
        // at the rounded corners during the alpha fade-in (the native shadow
        // rasterizes against stale corner geometry mid-animation).
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = CommandPaletteView(
            onDismiss: { [weak self] in self?.hideCommandPalette() },
            onPick: { [weak self] window in self?.pickPaletteWindow(window) },
            onPickCommand: { [weak self] command in self?.pickPaletteCommand(command) },
            onPickFile: { [weak self] file in self?.pickPaletteFile(file) }
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
        let pw: CGFloat = 560, ph: CGFloat = 420
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
        FileSearchService.shared.stop()
        QuickLookCoordinator.shared.closePreview()
    }

    @objc func toggleCommandPalette() {
        if commandPalettePanel?.isVisible == true { hideCommandPalette() } else { showCommandPalette() }
    }

    private func pickPaletteWindow(_ window: WindowInfo) {
        // `>` quick action (see `CommandPaletteState.parsedCommand`) —
        // dispatch on the verb instead of the normal focus/launch logic.
        // `window.pid` is the REAL target app's pid for these rows (see
        // `actionGroups`), not a sentinel.
        if let cmd = CommandPaletteState.shared.parsedCommand {
            let service = WindowManagerService()
            switch cmd.action {
            case .quit:     service.quitApp(pid: window.pid)
            case .hide:     service.hideApp(window)
            case .minimize: service.minimizeWindow(window)
            case .float:    floatWindow(forAppPID: window.pid)
            }
            hideCommandPalette()
            return
        }
        // Negative pid = a "Launch ‹App›" suggestion, not a real window
        // (see `CommandPaletteState.launchGroups`).
        guard window.pid >= 0 else {
            if let url = CommandPaletteState.shared.launchTargetURL(forAppName: window.appName) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            hideCommandPalette()
            return
        }
        WindowManagerService().focusWindow(window)
        // Background-tab row (see `CommandPaletteState.expandTabs`) — switch
        // to that specific tab, best-effort, on top of the window focus above.
        if let tabElement = window.axTabElement {
            BrowserTabService.activate(tabElement)
        }
        hideCommandPalette()
    }

    /// A layout command row (see `CommandPaletteState.commandResults`) was
    /// picked — applies it to the target app's focused window via the same
    /// `WindowResizeService` a hotkey press already uses, then flashes the
    /// same ghost-tile confirmation `onResize` shows for hotkeys, so typing
    /// "safari left" and pressing ⌥← feel like the same action rather than
    /// two different features that happen to do similar things.
    private func pickPaletteCommand(_ command: CommandPaletteState.PaletteCommand) {
        guard let app = NSRunningApplication(processIdentifier: command.targetPID),
              let result = WindowResizeService.shared.resize(app: app, to: command.layout) else {
            hideCommandPalette()
            return
        }
        if let bundleID = app.bundleIdentifier {
            RecentCommandsStore.record(bundleID: bundleID, layout: command.layout)
        }
        if AppSettings.placementPreviewEnabled {
            SnapPreviewOverlay.shared.show(primary: result.frame, secondary: nil, on: result.screen)
        }
        WindowActionHUD.shared.show(appIcon: app.icon, appName: app.localizedName ?? command.targetAppName,
                                     layout: command.layout, on: result.screen)
        hideCommandPalette()
    }

    /// A File Search row (see `CommandPaletteState.fileResults`) was picked
    /// — open it with its default app, same as double-clicking it in
    /// Finder. Reveal/Copy Path/Copy URL live in the row's own context menu
    /// (`CommandPaletteView.fileRow`), not here.
    private func pickPaletteFile(_ file: FileSearchResult) {
        NSWorkspace.shared.open(file.url)
        hideCommandPalette()
    }

    // MARK: - Picture-in-Picture (⌃⌥⇧F, or `>float` in the Command Palette)

    @objc func floatFrontmostWindow() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        floatWindow(forAppPID: front.processIdentifier)
    }

    /// Resolves `pid`'s frontmost on-screen window and starts mirroring it —
    /// shared by the hotkey (frontmost app) and the `>float` quick action
    /// (a specific app picked by name/MRU).
    private func floatWindow(forAppPID pid: pid_t) {
        guard let target = WindowManagerService().fetchWindows().first(where: { $0.pid == pid }) else {
            AppLog.general.notice("Float: no window found for pid \(pid).")
            return
        }
        FloatingWindowManager.shared.float(window: target)
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
                if let file = state.selectedFile { self.pickPaletteFile(file) }
                else if let command = state.selectedCommand { self.pickPaletteCommand(command) }
                else if let window = state.selectedWindow { self.pickPaletteWindow(window) }
                else { self.hideCommandPalette() }
                return nil
            case 49:                                     // Space — Quick Look (Finder convention)
                if let file = state.selectedFile {
                    QuickLookCoordinator.shared.preview(file.url)
                    return nil
                }
                return event                               // no file selected → space types normally
            case 48:                                     // Tab / ⇧Tab — jump between app groups
                state.jumpGroup(event.modifierFlags.contains(.shift) ? -1 : 1)
                return nil
            case 13 where event.modifierFlags.contains(.command):   // ⌘W — close selected window
                if let window = state.selectedWindow, window.pid >= 0 {
                    WindowManagerService().closeWindow(window)
                    state.reload()
                }
                return nil
            case 46 where event.modifierFlags.contains(.command):   // ⌘M — minimize selected window
                if let window = state.selectedWindow, window.pid >= 0 {
                    WindowManagerService().minimizeWindow(window)
                    state.reload()
                }
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
        PermissionMonitor.shared.refresh()
        guard !PermissionMonitor.shared.screenRecordingAuthorized else { return }
        WindowThumbnailService.requestAccessIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PermissionMonitor.shared.refresh()
            guard !PermissionMonitor.shared.screenRecordingAuthorized else { return }
            FloatingNoticeCenter.shared.showPermissionRequest(
                title: "Screen Recording Permission Needed",
                message: "Live window thumbnails in the Command Palette need Screen Recording access.\n\nGo to System Settings → Privacy & Security → Screen Recording, then enable JgDo and restart it — this permission needs a restart to take effect. The palette still works without it — cards just show app icons instead of previews.",
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
            // Smart Layouts: re-derives its rolling-window signature from
            // the AppUsageEvent row WorkflowInsightsService just inserted
            // above — must run after it, not a second observer.
            SmartLayoutEngine.shared.recordActivation()
            // Per-app window memory: apply once per process lifetime.
            WindowMemoryService.shared.applyIfNeeded(app)
        }
        // Capture the outgoing app's window frame right as focus leaves it —
        // the natural moment its "final" position for this session is known.
        deactivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            WindowMemoryService.shared.capture(app)
        }
    }

    // MARK: - Shortcuts cheat sheet (⌃⌥/), Scratchpad (⌃⌥N), Window Parking (⌃⌥P), Organize (⌃⌥O)
    //
    // Each of these is self-contained (no cross-panel coordination needed,
    // unlike the HUD/clipboard/command-palette cluster above) — extracted
    // into its own controller (`CheatSheetPanelController`,
    // `ScratchpadPanelController`, `OrganizePanelController`,
    // `WindowParkingController`). These forwarders preserve the exact
    // method names hotkeys and `ContentView` (via `AppDelegate.shared?.…`)
    // already call.

    @objc func toggleCheatSheet() { cheatSheetController.toggle() }
    @objc func toggleScratchpad() { scratchpadController.toggle() }
    func toggleOrganizeWorkspace() { organizeController.toggle() }
    func toggleNLWorkspace() { nlWorkspaceController.toggle() }
    func toggleLayoutPicker() { layoutPickerController.toggle() }
    func showWorkspaceTemplates() { workspaceTemplatesController.show() }
    func parkFrontmostWindow() { windowParkingController.parkFrontmostWindow() }

    // MARK: - Hotkeys

    /// Wires callback closures onto `mgr` — construction, `start()`, and
    /// `stop()` all belong to `LicenseFeatureCoordinator` now (see
    /// `startLicensedFeatures()`), so this only configures behavior, it
    /// doesn't own the manager's lifecycle.
    private func configureHotkeys(_ mgr: HotkeyManager) {
        // `ShortcutStore.lookup` (the table HotkeyManager's tap matches key
        // combos against) is only populated inside ShortcutStore's private
        // init() — which only runs the first time `.shared` is *accessed*.
        // Until now, the only place in the app that touched `.shared` was
        // the Settings → Shortcuts tab, so every hotkey silently fell
        // through unmatched until that tab had been opened once. Touching
        // it here guarantees the table is ready before the tap starts.
        _ = ShortcutStore.shared

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
        // ⌃⌥⇧W — dedicated window-switcher trigger. Same panel as ⌘⌥Space;
        // no separate switcher UI to keep in sync.
        mgr.onWindowSwitcher = { [weak self] in
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
        // ⌃⌥Z restores the window's frame from before the last snap/move.
        mgr.onUndoSnap = {
            // An Organize apply affects N windows at once and is a rarer,
            // more deliberate action than a single snap — if one's pending,
            // ⌃⌥Z undoes THAT first (and consumes it), falling through to
            // the single-window undo on a second press.
            if OrganizeUndoService.shared.canUndo {
                OrganizeUndoService.shared.undo()
            } else {
                WindowSnapUndo.shared.undo()
            }
        }
        // ⌃⌥T pins/unpins the focused window as Always on Top.
        mgr.onToggleAlwaysOnTop = { [weak self] in
            self?.toggleAlwaysOnTopOnFrontmost()
        }
        // ⌃⌥⇧] / ⌃⌥⇧[ send the focused window to the next/previous display.
        mgr.onMoveToNextDisplay = {
            guard let (frame, screen) = WindowResizeService.shared.moveFrontmostWindowToDisplay(.next) else { return }
            SnapPreviewOverlay.shared.show(primary: frame, secondary: nil, indicator: "Next Display", on: screen)
        }
        mgr.onMoveToPreviousDisplay = {
            guard let (frame, screen) = WindowResizeService.shared.moveFrontmostWindowToDisplay(.previous) else { return }
            SnapPreviewOverlay.shared.show(primary: frame, secondary: nil, indicator: "Previous Display", on: screen)
        }
        // ⌃⌥F hides every other app's windows (toggle to restore).
        mgr.onToggleFocusMode = {
            FocusModeService.shared.toggle()
        }
        // ⌃⌥/ shows every active shortcut, grouped.
        mgr.onShowCheatSheet = { [weak self] in
            self?.toggleCheatSheet()
        }
        // ⌃⌥N opens the scratchpad.
        mgr.onToggleScratchpad = { [weak self] in
            self?.toggleScratchpad()
        }
        // ⌃⌥P parks the frontmost window; ⌃⌥⇧P restores every parked window.
        mgr.onParkFrontmostWindow = { [weak self] in
            self?.parkFrontmostWindow()
        }
        mgr.onRestoreAllParked = {
            WindowParkingService.shared.restoreAll()
        }
        // ⌃⌥G captures the current on-screen windows as a new Snap Group.
        mgr.onCreateSnapGroup = {
            let name = "Group \(SnapGroupService.shared.groups.count + 1)"
            SnapGroupService.shared.createGroup(named: name)
        }
        // ⌃⌥O opens the Organize Workspace preview.
        mgr.onFloatFrontmostWindow = { [weak self] in
            self?.floatFrontmostWindow()
        }
        mgr.onNLWorkspace = { [weak self] in
            self?.toggleNLWorkspace()
        }
        mgr.onShowLayoutPicker = { [weak self] in
            self?.layoutPickerController.toggle()
        }
        mgr.onOrganizeWorkspace = { [weak self] in
            self?.toggleOrganizeWorkspace()
        }
        // ⌃⌥←/→'s "hold and cycle" layout overlay owns those two shortcuts
        // now (see `WindowLayoutSelectorController`); `onResize` still
        // handles every OTHER layout hotkey (↑/↓, quarters, maximize,
        // center) exactly as before. When the overlay is turned off in
        // Settings, ⌃⌥←/→ fall back to this same dual-snap behavior too —
        // `legacyApply` below is that one shared implementation, not a copy.
        mgr.onResize = { [weak self] layout in self?.applyLayoutImmediately(layout) }
        layoutSelectorController.legacyApply = { [weak self] layout in self?.applyLayoutImmediately(layout) }
        layoutSelectorController.attach(to: mgr)
    }

    /// The original single-shot ⌃⌥-arrow behavior: snap the frontmost
    /// window, snap the topmost other visible window to the complementary
    /// half, flash a ghost preview + confirmation HUD. Used directly by
    /// every layout hotkey except ⌃⌥←/→, and by ⌃⌥←/→ themselves when the
    /// layout-cycle overlay is disabled in Settings.
    private func applyLayoutImmediately(_ layout: WindowLayout) {
        let svc = WindowResizeService.shared
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // `resizeFrontmostWindow` returns what it actually applied, which
        // may be mid-cycle for edge-snap layouts — not necessarily the
        // plain preset `frame(for:on:)` would report.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        // Grouped into one undo transaction — ⌃⌥Z restores both the
        // primary and the auto-filled partner together, not just whichever
        // was recorded last.
        WindowSnapUndo.shared.beginTransaction()
        let primary = svc.resizeFrontmostWindow(to: layout) ?? svc.frame(for: layout, on: screen)
        // Keep the partner complementary to whatever the primary's
        // edge-snap cycle just landed on (e.g. two-thirds → the partner
        // gets the remaining third), not always a fixed half.
        var secondary: CGRect?
        if let complement = layout.complement {
            secondary = svc.resizeOtherVisibleWindow(excluding: frontPID, to: complement,
                                                      fraction: svc.complementFraction(for: layout),
                                                      preferredScreen: screen)
        }
        WindowSnapUndo.shared.endTransaction()
        // Flash a ghost preview of where the windows land, with a "2/3"
        // step indicator if the edge-snap cycle is mid-sequence.
        if AppSettings.placementPreviewEnabled {
            SnapPreviewOverlay.shared.show(primary: primary, secondary: secondary,
                                            indicator: svc.cycleIndicator(for: layout), on: screen)
        }
        if let frontPID, let app = NSRunningApplication(processIdentifier: frontPID) {
            WindowActionHUD.shared.show(appIcon: app.icon, appName: app.localizedName ?? "Window",
                                         layout: layout, on: screen)
        }
    }
}

// MARK: - Key-capable panel

/// An NSPanel that can become the key/main window even with a non-activating,
/// borderless-style mask — required so the switcher's text field accepts input.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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
