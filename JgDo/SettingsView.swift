import SwiftUI
import AppKit
import ServiceManagement
import Sparkle
import UniformTypeIdentifiers

// MARK: - Window plumbing

/// Lazily-created settings window (the app is an accessory, so it manages
/// its own window instead of using the Settings scene).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "JgDo Settings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsRootView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func hide() {
        window?.close()
    }
}

// MARK: - Root

struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            ClipboardSettingsView()
                .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            LicenseSettingsView()
                .tabItem { Label("License", systemImage: "key") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(AppSettings.edgeGapKey) private var edgeGap: Double = 8
    @AppStorage(AppSettings.cleaningDurationKey) private var cleaningDuration: Int = 60
    @AppStorage(AppSettings.dragSnapEnabledKey) private var dragSnapEnabled = true
    @AppStorage(AppSettings.adjacentResizeEnabledKey) private var adjacentResizeEnabled = true
    @AppStorage(AppSettings.showPerCoreCPUKey) private var showPerCoreCPU = false
    @AppStorage(AppSettings.menuBarStatKey) private var menuBarStat = MenuBarStat.off.rawValue
    @AppStorage(AppSettings.lowBatteryEnabledKey) private var lowBatteryEnabled = true
    @AppStorage(AppSettings.lowBatteryThresholdKey) private var lowBatteryThreshold = 20
    @AppStorage(AppSettings.customStatusIconPathKey) private var customStatusIconPath = ""
    @AppStorage(AppSettings.customStatusIconTemplateKey) private var customStatusIconTemplate = false
    @State private var updateService = UpdateService.shared
    @State private var exportDoc: SettingsBackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var importError: String?
    @State private var iconPickError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch JgDo at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Window Snapping") {
                LabeledContent("Window gap") {
                    HStack(spacing: 10) {
                        Slider(value: $edgeGap, in: AppSettings.edgeGapRange, step: 1)
                            .frame(width: 200)
                        Text(edgeGap == 0 ? "Off" : "\(Int(edgeGap)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Text("Padding around screen edges and between snapped windows.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Snap into available space while dragging (⌘)", isOn: $dragSnapEnabled)
                Toggle("Resize adjacent windows together (⌘)", isOn: $adjacentResizeEnabled)
                Text("Hold ⌘ while dragging or resizing a window to snap it into whatever space is left, or to resize snapped neighbors in lockstep. A searchable list of windows appears next to the cursor while dragging — type, use Tab/arrows, or just keep dragging to pick which one to align against.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Status Popover") {
                Toggle("Show per-core CPU usage", isOn: $showPerCoreCPU)
                Text("When enabled, the status popover displays individual CPU core utilization. Disabled by default to reduce background CPU usage.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Menu Bar") {
                Picker("Live stat", selection: $menuBarStat) {
                    ForEach(MenuBarStat.allCases) { stat in
                        Text(stat.label).tag(stat.rawValue)
                    }
                }
                .onChange(of: menuBarStat) { _, _ in AppDelegate.shared?.applyMenuBarStatSetting() }
                Text("Shows a live reading next to the menu bar icon. Off by default to reduce background CPU usage — sampling only runs while this or the popover is open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Right-click the menu bar icon for a quick panel — volume/brightness sliders, Focus Mode, Keyboard Cleaning, Always on Top, and your last workspace — without opening the full popover. A small colored dot on the icon shows when Focus Mode, Cleaning, or a pin is active. Scroll over the icon to nudge system volume; hold ⌥ while scrolling for brightness.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                LabeledContent("Icon") {
                    HStack(spacing: 8) {
                        if let url = AppSettings.customStatusIconURL, let img = NSImage(contentsOf: url) {
                            Image(nsImage: img).resizable().frame(width: 18, height: 18)
                        } else {
                            Image(nsImage: NSImage(named: "StatusBarIcon") ?? NSImage()).resizable().frame(width: 18, height: 18)
                        }
                        Button("Choose Image…") { pickCustomStatusIcon() }
                        if !customStatusIconPath.isEmpty {
                            Button("Use JgDo Logo") { resetCustomStatusIcon() }
                        }
                    }
                }
                Toggle("Render as monochrome template", isOn: $customStatusIconTemplate)
                    .onChange(of: customStatusIconTemplate) { _, _ in AppDelegate.shared?.applyStatusIconSetting() }
                Text("Pick any image to use as the menu bar icon in place of the JgDo logo. \"Monochrome template\" tints it to match the system menu bar automatically (best for simple, single-color glyphs); leave it off to keep the image's original colors.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Battery") {
                Toggle("Alert when battery is low", isOn: $lowBatteryEnabled)
                    .onChange(of: lowBatteryEnabled) { _, on in
                        if on { BatteryAlertService.shared.start() } else { BatteryAlertService.shared.stop() }
                    }
                LabeledContent("Threshold") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { Double(lowBatteryThreshold) },
                            set: { lowBatteryThreshold = Int($0) }
                        ), in: Double(AppSettings.lowBatteryThresholdRange.lowerBound)...Double(AppSettings.lowBatteryThresholdRange.upperBound), step: 5)
                            .frame(width: 200)
                            .disabled(!lowBatteryEnabled)
                        Text("\(lowBatteryThreshold)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Text("Fires once when battery drops below this level while unplugged — works even with no JgDo window open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Backup") {
                Button("Export Settings…") {
                    exportDoc = SettingsBackupDocument(backup: SettingsBackup.current())
                    showExporter = true
                }
                Button("Import Settings…") { showImporter = true }
                Text("Shortcuts and preferences only — not clipboard history, workspaces, or license state.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Window Memory") {
                let remembered = WindowMemoryService.shared.rememberedApps
                if remembered.isEmpty {
                    Text("No apps remembered yet. Right-click the menu bar icon → \"Remember Window Position\" while an app is frontmost to start.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remembered, id: \.bundleID) { entry in
                        LabeledContent(entry.name) {
                            Button("Forget") { WindowMemoryService.shared.forget(bundleID: entry.bundleID) }
                                .controlSize(.small)
                        }
                    }
                }
                Text("Reapplies a remembered app's last window frame automatically the next time that app launches (not on every switch back).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updateService.updater.automaticallyChecksForUpdates },
                    set: { updateService.setAutoCheckUpdates($0) }
                ))
                Toggle("Include pre-release versions", isOn: Binding(
                    get: { updateService.allowPrereleaseUpdates },
                    set: { updateService.setAllowPrereleaseUpdates($0) }
                ))
                Button("Check Now…") {
                    updateService.checkForUpdates()
                }
                .disabled(AppcastConfig.appcastURL == "https://your-domain.com/appcast.xml")

                if updateService.updateAvailable, let item = updateService.updateInfo {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.green)
                            Text("Update Available: \(item.displayVersionString)")
                                .foregroundStyle(.primary)
                        }
                        if let notes = item.releaseNotesURL {
                            Link("Release Notes", destination: notes)
                                .font(.footnote)
                        }
                        Text("Click \"Check Now…\" to review and install.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if let error = updateService.updateCheckError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if let lastCheck = updateService.lastCheckDate {
                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                if AppcastConfig.appcastURL == "https://your-domain.com/appcast.xml" {
                    Text("⚠️ Configure appcast URL in AppcastConfig.swift to enable updates")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("Keyboard Cleaning") {
                LabeledContent("Lock duration") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { Double(cleaningDuration) },
                            set: { cleaningDuration = Int($0) }
                        ), in: 15...300, step: 15)
                        .frame(width: 200)
                        Text("\(cleaningDuration) s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Text("Emergency unlock any time with ⌘⌥⎋.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Reflect changes made directly in System Settings while we were closed.
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
        .fileExporter(isPresented: $showExporter, document: exportDoc,
                      contentType: .json, defaultFilename: "JgDo Settings") { _ in }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let backup = try? JSONDecoder().decode(SettingsBackup.self, from: data)
            else { importError = "Couldn't read that file."; return }
            backup.apply()
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("Couldn't Set Icon", isPresented: Binding(
            get: { iconPickError != nil },
            set: { if !$0 { iconPickError = nil } }
        )) {
            Button("OK") { iconPickError = nil }
        } message: {
            Text(iconPickError ?? "")
        }
    }

    /// Lets the user pick any image file to replace the menu bar icon.
    /// Copies it into Application Support so it keeps working even if the
    /// original file is moved, renamed, or deleted.
    private func pickCustomStatusIcon() {
        let panel = NSOpenPanel()
        panel.title = "Choose Menu Bar Icon"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }

        let dir = URL.applicationSupportDirectory.appendingPathComponent("JgDo/CustomIcons", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("status_icon." + source.pathExtension)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            customStatusIconPath = dest.path
            AppDelegate.shared?.applyStatusIconSetting()
        } catch {
            iconPickError = "Couldn't copy that image: \(error.localizedDescription)"
        }
    }

    private func resetCustomStatusIcon() {
        if !customStatusIconPath.isEmpty {
            try? FileManager.default.removeItem(atPath: customStatusIconPath)
        }
        customStatusIconPath = ""
        customStatusIconTemplate = false
        AppDelegate.shared?.applyStatusIconSetting()
    }
}

// MARK: - Shortcuts (recorder)

struct ShortcutsSettingsView: View {
    @State private var store = ShortcutStore.shared
    @State private var recording: HotkeyAction?
    @State private var eventMonitor: Any?
    @State private var notice: String?

    private let globalActions: [HotkeyAction] = [.toggleSwitcher, .clipboardHistory, .commandPalette,
                                                  .showCheatSheet, .toggleScratchpad]
    private var snapActions: [HotkeyAction] {
        HotkeyAction.allCases.filter { $0.layout != nil }
    }
    private let resizeStepActions: [HotkeyAction] = [.shrinkWindow, .growWindow]
    private let undoActions: [HotkeyAction] = [.undoSnap]
    private let pinActions: [HotkeyAction] = [.toggleAlwaysOnTop]
    private let displayActions: [HotkeyAction] = [.moveToNextDisplay, .moveToPreviousDisplay]
    private let focusActions: [HotkeyAction] = [.toggleFocusMode]
    private let parkActions: [HotkeyAction] = [.parkFrontmostWindow, .restoreAllParked]
    private let groupActions: [HotkeyAction] = [.createSnapGroup]
    private let organizeActions: [HotkeyAction] = [.organizeWorkspace]

    var body: some View {
        Form {
            Section("Global") {
                ForEach(globalActions) { row($0) }
            }
            Section("Window Snapping") {
                ForEach(snapActions) { row($0) }
            }
            Section("Resize Steps") {
                ForEach(resizeStepActions) { row($0) }
                Text("Steps the focused window between preset sizes (90/70/50/30% of the screen), centered on the screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Undo") {
                ForEach(undoActions) { row($0) }
                Text("Restores the last window's frame from right before a JgDo snap/resize/drag-to-snap — only if nothing has moved it since.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Always on Top") {
                ForEach(pinActions) { row($0) }
                Text("Pins the focused window above all others until toggled off or the window closes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Displays") {
                ForEach(displayActions) { row($0) }
                Text("Sends the focused window to the adjacent display, keeping its relative position/size.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Focus Mode") {
                ForEach(focusActions) { row($0) }
                Text("Hides every other app's windows, leaving only the frontmost app visible. Toggle again to restore them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Window Parking") {
                ForEach(parkActions) { row($0) }
                Text("Removes a window from the workspace while remembering exactly where it was — restore it later from the popover's Parked Windows list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Snap Groups") {
                ForEach(groupActions) { row($0) }
                Text("Captures the current windows as a named group you can move, resize, minimize, or close together — manage from the popover's Snap Groups list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Organize Workspace") {
                ForEach(organizeActions) { row($0) }
                Text("Previews a cleaner arrangement of the current windows before applying — Balanced, Focus, Columns, Rows, or Main + Stack. ⌃⌥Z undoes the last Organize as one step.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let notice {
                Section {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Button("Restore Defaults") { store.resetAll() }
                Text("Click a shortcut, then press the new key combination. Esc cancels.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { endRecording() }
    }

    private func row(_ action: HotkeyAction) -> some View {
        LabeledContent(action.label) {
            HStack(spacing: 6) {
                Button {
                    if recording == action { endRecording() } else { beginRecording(action) }
                } label: {
                    Text(recording == action ? "Press keys…" : store.combo(for: action).display)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(recording == action ? Color.accentColor : .primary)
                        .frame(minWidth: 76)
                }
                .buttonStyle(.bordered)
                if !store.isDefault(action) {
                    Button {
                        store.reset(action)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reset to default")
                }
            }
        }
    }

    private func beginRecording(_ action: HotkeyAction) {
        endRecording()
        recording = action
        notice = nil
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleRecorded(event)
            return nil   // consume everything while recording
        }
    }

    private func handleRecorded(_ event: NSEvent) {
        guard let action = recording else { return }
        let combo = KeyCombo(event: event)
        // Bare Esc cancels recording (⌃⌥⎋-style combos are still recordable).
        if event.keyCode == 53 && !combo.hasModifier {
            endRecording()
            return
        }
        guard combo.hasModifier else {
            notice = "Shortcuts need at least one modifier (⌘ ⌥ ⌃ ⇧)."
            return
        }
        if let other = store.conflict(for: combo, excluding: action) {
            notice = "\(combo.display) is already used by “\(other.label)”."
            return
        }
        store.set(combo, for: action)
        notice = nil
        endRecording()
    }

    private func endRecording() {
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
        recording = nil
    }
}

// MARK: - Clipboard

struct ClipboardSettingsView: View {
    @AppStorage(ClipboardService.enabledKey) private var enabled = true
    @AppStorage(ClipboardService.limitKey) private var limit = 200
    @AppStorage(AppSettings.clipboardPollIntervalKey) private var pollInterval: Double = 1.5
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("History") {
                Toggle("Record clipboard history", isOn: $enabled)
                LabeledContent("Keep up to") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { Double(limit) },
                            set: { limit = Int($0) }
                        ), in: 50...1000, step: 50)
                        .frame(width: 200)
                        .disabled(!enabled)
                        Text("\(limit) items")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 68, alignment: .trailing)
                    }
                }
                LabeledContent("Poll interval") {
                    HStack(spacing: 10) {
                        Slider(value: $pollInterval, in: AppSettings.clipboardPollIntervalRange, step: 0.5)
                            .frame(width: 200)
                            .disabled(!enabled)
                        Text("\(pollInterval, specifier: "%.1f") s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Text("Pinned items are always kept. Content marked confidential by password managers is never recorded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Data") {
                Button("Clear History…") { confirmClear = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                ClipboardService.shared.clearHistory()
            }
        } message: {
            Text("Pinned items are kept.")
        }
    }
}

// MARK: - License

struct LicenseSettingsView: View {
    @State private var license = LicenseManager.shared
    @State private var confirmDeactivate = false

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Plan") {
                    Text(license.plan.displayName)
                        .fontWeight(.medium)
                        .foregroundStyle(license.isPro ? Color.accentColor : .secondary)
                }
                if let key = license.licenseKey {
                    LabeledContent("License Key") {
                        Text(key)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if license.isPro {
                Section {
                    Button("Deactivate License…") { confirmDeactivate = true }
                    Text("Removes this key from JgDo. You'll need to activate again to keep using the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Button("Buy a License →") {
                        NSWorkspace.shared.open(URL(string: "https://jgdo.sovandara.lol/pricing")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Deactivate this license?", isPresented: $confirmDeactivate) {
            Button("Deactivate", role: .destructive) {
                license.deactivate()
                SettingsWindow.hide()
                ActivationWindow.show {}
            }
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 3) {
                Text("JgDo")
                    .font(.system(size: 20, weight: .semibold))
                Text(version)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Window management, clipboard history and system\nmonitoring — right from your menu bar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
