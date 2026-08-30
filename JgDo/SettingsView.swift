import SwiftUI
import AppKit
import ServiceManagement
import Sparkle
import UniformTypeIdentifiers

// MARK: - Window plumbing

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "JgDo Settings"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsRootView())
            w.minSize = NSSize(width: 620, height: 420)
            w.center()
            // Forces an initial layout pass before this window is ever
            // shown — otherwise the very first frame can render before
            // SwiftUI has established the content's safe-area inset for
            // the transparent titlebar, leaving the top row visually
            // overlapping the title text until the next layout pass.
            w.contentViewController?.view.layoutSubtreeIfNeeded()
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


private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, windows, smartFeatures, features, shortcuts, clipboard, license, diagnostics, about
    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:       return "General"
        case .windows:       return "Windows"
        case .smartFeatures: return "Smart Features"
        case .features:      return "Features"
        case .shortcuts:     return "Shortcuts"
        case .clipboard:     return "Clipboard"
        case .license:       return "License"
        case .diagnostics:   return "Diagnostics"
        case .about:         return "About"
        }
    }

    var icon: String {
        switch self {
        case .general:       return "gearshape"
        case .windows:       return "macwindow"
        case .smartFeatures: return "sparkles"
        case .features:      return "checklist"
        case .shortcuts:     return "keyboard"
        case .clipboard:     return "doc.on.clipboard"
        case .license:       return "key"
        case .diagnostics:   return "stethoscope"
        case .about:         return "info.circle"
        }
    }
}

struct SettingsRootView: View {
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.label, systemImage: section.icon).tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 175, max: 220)
        } detail: {
            detailView(for: selection ?? .general)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 700, height: 520)
    }

    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        switch section {
        case .general:       GeneralSettingsView()
        case .windows:       WindowsSettingsView()
        case .smartFeatures: SmartFeaturesSettingsView()
        case .features:      FeaturesSettingsView()
        case .shortcuts:     ShortcutsSettingsView()
        case .clipboard:     ClipboardSettingsView()
        case .license:       LicenseSettingsView()
        case .diagnostics:   DiagnosticsView()
        case .about:         AboutSettingsView()
        }
    }
}

// MARK: - General (startup, menu bar, battery, backup/recovery, updates)

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(AppSettings.showPerCoreCPUKey) private var showPerCoreCPU = false
    @AppStorage(AppSettings.menuBarStatKey) private var menuBarStat = MenuBarStat.off.rawValue
    @AppStorage(AppSettings.lowBatteryEnabledKey) private var lowBatteryEnabled = true
    @AppStorage(AppSettings.lowBatteryThresholdKey) private var lowBatteryThreshold = 20
    @AppStorage(AppSettings.customStatusIconPathKey) private var customStatusIconPath = ""
    @AppStorage(AppSettings.customStatusIconTemplateKey) private var customStatusIconTemplate = false
    @AppStorage(AppSettings.actionToastsEnabledKey) private var actionToastsEnabled = true
    @AppStorage(TipsStore.tipsEnabledKey) private var tipsEnabled = true
    @State private var updateService = UpdateService.shared
    @State private var exportDoc: SettingsBackupDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var importError: String?
    @State private var iconPickError: String?
    @State private var persistence = Persistence.shared
    @State private var showRecoveryPicker = false
    @State private var pendingRecoveryBackup: URL?
    @State private var recoveryError: String?
    @State private var recoveredNeedsRelaunch = false

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

            Section("Menu Bar") {
                Picker("Live stat", selection: $menuBarStat) {
                    ForEach(MenuBarStat.allCases) { stat in
                        Text(stat.label).tag(stat.rawValue)
                    }
                }
                .onChange(of: menuBarStat) { _, _ in AppDelegate.shared?.applyMenuBarStatSetting() }
                Toggle("Show per-core CPU in popover", isOn: $showPerCoreCPU)
                Text("Right-click the icon for volume, brightness, Focus Mode, and more. Scroll to adjust volume, ⌥-scroll for brightness.")
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
            }

            Section("Feedback") {
                Toggle("Show confirmation pill after actions", isOn: $actionToastsEnabled)
                Text("A brief \"Coding Workspace Restored\"-style pill near the top of the screen — not a system notification, no history.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Show tips", isOn: $tipsEnabled)
                Text("Occasional suggestions, like offering to save a repeated window arrangement as a Workspace. Always dismissible.")
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
            }

            Section("Backup") {
                Button("Export Settings…") {
                    exportDoc = SettingsBackupDocument(backup: SettingsBackup.current())
                    showExporter = true
                }
                Button("Import Settings…") { showImporter = true }
                Text("Shortcuts and preferences only — not history, workspaces, or license.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Data & Recovery") {
                if case .failed(let description, let backupURL) = persistence.loadState {
                    Label("Couldn't open your data file — running with empty, unsaved data", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHint("Nothing was deleted. A backup of the affected file was saved automatically.")
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let backupURL {
                        Button("Reveal Backup in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([backupURL])
                        }
                    }
                }
                Button("Recover from Backup…") { showRecoveryPicker = true }
                    .disabled(persistence.availableBackups.isEmpty)
                if persistence.availableBackups.isEmpty {
                    Text("A backup is taken automatically before every launch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Restoring overwrites current data (itself backed up first) and requires a relaunch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
        .confirmationDialog("Recover from Backup", isPresented: $showRecoveryPicker, titleVisibility: .visible) {
            ForEach(persistence.availableBackups, id: \.self) { backup in
                Button(backupLabel(for: backup)) { pendingRecoveryBackup = backup }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a snapshot to restore. The current data file is backed up first, so this can be undone the same way.")
        }
        .alert("Restore this backup?", isPresented: Binding(
            get: { pendingRecoveryBackup != nil },
            set: { if !$0 { pendingRecoveryBackup = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingRecoveryBackup = nil }
            Button("Restore & Quit", role: .destructive) {
                guard let backup = pendingRecoveryBackup else { return }
                do {
                    try persistence.recover(from: backup)
                    recoveredNeedsRelaunch = true
                } catch {
                    recoveryError = error.localizedDescription
                }
                pendingRecoveryBackup = nil
            }
        } message: {
            if let backup = pendingRecoveryBackup {
                Text("JgDo will quit so the restored data takes effect on next launch. Restoring \(backupLabel(for: backup)) overwrites the current data file (which is itself backed up first).")
            }
        }
        .alert("Couldn't Restore Backup", isPresented: Binding(
            get: { recoveryError != nil },
            set: { if !$0 { recoveryError = nil } }
        )) {
            Button("OK") { recoveryError = nil }
        } message: {
            Text(recoveryError ?? "")
        }
        .alert("Restored — Quit JgDo to Finish", isPresented: $recoveredNeedsRelaunch) {
            Button("Quit Now") { NSApp.terminate(nil) }
        } message: {
            Text("The backup was restored. Quit and reopen JgDo to load it.")
        }
    }

    private func backupLabel(for url: URL) -> String {
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return url.deletingPathExtension().lastPathComponent
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

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

// MARK: - Windows (snapping, magnetism, memory, cleaning)

struct WindowsSettingsView: View {
    @AppStorage(AppSettings.edgeGapKey) private var edgeGap: Double = 8
    @AppStorage(AppSettings.dragSnapEnabledKey) private var dragSnapEnabled = true
    @AppStorage(AppSettings.adjacentResizeEnabledKey) private var adjacentResizeEnabled = true
    @AppStorage(AppSettings.magnetismEnabledKey) private var magnetismEnabled = true
    @AppStorage(AppSettings.magnetismDistanceKey) private var magnetismDistance: Double = 12
    @AppStorage(AppSettings.cleaningDurationKey) private var cleaningDuration: Int = 60
    @AppStorage(AppSettings.windowActionHUDEnabledKey) private var windowActionHUDEnabled = true
    @AppStorage(AppSettings.placementPreviewEnabledKey) private var placementPreviewEnabled = true
    @AppStorage(AppSettings.windowActionHUDDurationKey) private var hudDuration: Double = 0.65
    @AppStorage(AppSettings.layoutSelectorOverlayEnabledKey) private var layoutSelectorOverlayEnabled = true
    @AppStorage(AppSettings.layoutSelectorDimEnabledKey) private var layoutSelectorDimEnabled = true
    @AppStorage(AppSettings.layoutSelectorApplyOnReleaseKey) private var layoutSelectorApplyOnRelease = false
    @State private var demoRunning = false

    var body: some View {
        Form {
            Section("Window Layout Selector") {
                Toggle("Show Layout Overlay", isOn: $layoutSelectorOverlayEnabled)
                Toggle("Dim Desktop", isOn: $layoutSelectorDimEnabled)
                    .disabled(!layoutSelectorOverlayEnabled)
                Toggle("Show Placement Preview", isOn: $placementPreviewEnabled)
                    .disabled(!layoutSelectorOverlayEnabled)
                Picker("Apply Layout", selection: $layoutSelectorApplyOnRelease) {
                    Text("Immediately").tag(false)
                    Text("When modifiers are released").tag(true)
                }
                .pickerStyle(.radioGroup)
                .disabled(!layoutSelectorOverlayEnabled)

                howToUse

                Button {
                    playOverlayDemo()
                } label: {
                    Label(demoRunning ? "Previewing…" : "Preview Overlay Style", systemImage: "play.circle")
                }
                .disabled(demoRunning)
                Text("Shows the actual overlay with sample data — nothing on your screen moves.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                layoutCycleReference
            }

            Section("Window Feedback") {
                Toggle("Show Window Action HUD", isOn: $windowActionHUDEnabled)
                Toggle("Show Placement Preview", isOn: $placementPreviewEnabled)
                LabeledContent("HUD duration") {
                    HStack(spacing: 10) {
                        Slider(value: $hudDuration, in: AppSettings.windowActionHUDDurationRange, step: 0.05)
                            .frame(width: 200)
                        Text("\(Int(hudDuration * 1000))ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                Text("The small \"Safari → Left Half\" card and the ghost-tile preview shown after ⌃⌥-arrow snap actions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                Toggle("Snap into available space while dragging (⌘)", isOn: $dragSnapEnabled)
                Toggle("Resize adjacent windows together (⌘)", isOn: $adjacentResizeEnabled)
                Text("Hold ⌘ while dragging or resizing to snap into open space or resize neighbors together.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Window Magnetism") {
                Toggle("Gently align windows while dragging", isOn: $magnetismEnabled)
                LabeledContent("Snap distance") {
                    HStack(spacing: 10) {
                        Slider(value: $magnetismDistance, in: AppSettings.magnetismDistanceRange, step: 1)
                            .frame(width: 200)
                            .disabled(!magnetismEnabled)
                        Text("\(Int(magnetismDistance)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Text("Edges align to nearby windows while dragging normally. Hold ⌥ to bypass.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Window Memory") {
                let remembered = WindowMemoryService.shared.rememberedApps
                if remembered.isEmpty {
                    Text("Right-click the menu bar icon → “Remember Window Position” to add one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remembered, id: \.bundleID) { entry in
                        LabeledContent(entry.name) {
                            Button("Forget") { WindowMemoryService.shared.forget(bundleID: entry.bundleID) }
                                .controlSize(.small)
                        }
                    }
                    Text("Reapplies a remembered frame the next time that app launches.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
    }

    /// A short numbered walkthrough instead of one dense sentence — mirrors
    /// whichever "Apply Layout" mode is currently selected, so it never
    /// describes a flow the user isn't actually using.
    private var howToUse: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("How to use").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            let steps = layoutSelectorApplyOnRelease
                ? ["Hold ⌃⌥ and press ← or → — the overlay opens on the current layout step.",
                   "Keep holding ⌃⌥ and press ←/→ again to step through halves, thirds, quarters, and next/previous display.",
                   "Release ⌃⌥ to move the window there, or press Escape to cancel without moving it."]
                : ["Press ⌃⌥← or ⌃⌥→ — the window moves right away and the card flashes to confirm.",
                   "Press the same arrow again shortly after to step to the next layout in that direction.",
                   "Press \(ShortcutStore.shared.combo(for: .layoutFillOtherSide).display) afterward to also fill the remaining space with another open window."]
            ForEach(Array(steps.enumerated()), id: \.offset) { i, text in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(i + 1).").foregroundStyle(.tertiary)
                    Text(text)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Every step in both cycles, as real diagrams (not text) — the same
    /// geometry (`LayoutCycleStep.diagramUnit`) that drives the actual
    /// overlay and the real window move, so this reference can never drift
    /// out of sync with what ⌃⌥←/→ actually does.
    private var layoutCycleReference: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Layout Reference").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            LayoutCycleReferenceRow(title: "⌃⌥←  Left", family: .left)
            LayoutCycleReferenceRow(title: "⌃⌥→  Right", family: .right)
        }
        .padding(.vertical, 2)
    }

    /// Plays the real overlay (dim, pill, card, ghost tile) through the
    /// first three left-cycle steps with sample data — genuine production
    /// UI, not a mockup, but `previewFrame` is pure geometry and nothing
    /// here ever calls into `WindowResizeService.resize`/AX, so no real
    /// window is touched.
    private func playOverlayDemo() {
        guard !demoRunning, let screen = NSScreen.main else { return }
        demoRunning = true
        let icon = NSImage(systemSymbolName: "safari.fill", accessibilityDescription: nil)
        let steps = LayoutCycleFamily.left.steps
        let previewCount = min(3, steps.count)
        for i in 0..<previewCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.85) {
                let step = steps[i]
                if case .layout(let layout, let fraction) = step.kind, placementPreviewEnabled {
                    let frame = WindowResizeService.shared.previewFrame(for: layout, fraction: fraction, on: screen)
                    SnapPreviewOverlay.shared.show(primary: frame, secondary: nil, on: screen)
                }
                WindowLayoutSelectorOverlay.shared.show(
                    step: step, index: i, count: steps.count, family: .left,
                    appIcon: icon, appName: "Safari",
                    otherWindows: PartnerWindowCandidate.others(excludingPID: NSRunningApplication.current.processIdentifier),
                    dim: layoutSelectorDimEnabled,
                    autoHideAfter: i == previewCount - 1 ? 1.3 : nil, on: screen)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(previewCount - 1) * 0.85 + 1.4) {
            demoRunning = false
        }
    }
}

/// One row of the Settings layout reference — every step in a cycle shown
/// as a small diagram + name, in actual cycle order.
private struct LayoutCycleReferenceRow: View {
    let title: String
    let family: LayoutCycleFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                ForEach(Array(family.steps.enumerated()), id: \.offset) { _, step in
                    VStack(spacing: 3) {
                        tile(for: step)
                            .frame(width: 44, height: 28)
                        Text(step.name)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 50, height: 20)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tile(for step: LayoutCycleStep) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay {
                if case .layout(let layout, _) = step.kind, let unit = step.diagramUnit {
                    LayoutPreviewIcon(layout: layout, unitOverride: unit)
                        .padding(3)
                } else {
                    Image(systemName: step.kind == .previousDisplay ? "arrow.left.square" : "arrow.right.square")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }
            }
    }
}

// MARK: - Smart Features (Command Palette, Dashboard, Smart Layouts, PiP, NL Workspace)

struct SmartFeaturesSettingsView: View {
    @AppStorage(AppSettings.fileSearchEnabledKey) private var fileSearchEnabled = true
    @AppStorage(AppSettings.dashboardShowCPUKey) private var dashboardShowCPU = true
    @AppStorage(AppSettings.dashboardShowMemoryKey) private var dashboardShowMemory = true
    @AppStorage(AppSettings.smartLayoutsEnabledKey) private var smartLayoutsEnabled = true
    @AppStorage(AppSettings.pipEnabledKey) private var pipEnabled = true
    @AppStorage(AppSettings.nlWorkspaceEnabledKey) private var nlWorkspaceEnabled = true
    @AppStorage(AppSettings.nlWorkspaceProviderKey) private var nlWorkspaceProviderRaw = NaturalLanguageProviderKind.ruleBased.rawValue

    var body: some View {
        Form {
            Section("Command Palette") {
                Toggle("Search files (Spotlight)", isOn: $fileSearchEnabled)
                Text("Space on a result opens Quick Look.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Menu Bar Dashboard") {
                Toggle("Show CPU usage", isOn: $dashboardShowCPU)
                Toggle("Show Memory usage", isOn: $dashboardShowMemory)
                Text("Adds live gauges to the right-click quick panel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Smart Layouts") {
                Toggle("Learn app-combination patterns", isOn: $smartLayoutsEnabled)
                Text("Notices repeated app combinations and offers to save them as a Workspace. Nothing saves automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Clear Learned Patterns", role: .destructive) {
                    SmartLayoutEngine.shared.resetLearning()
                }
                .controlSize(.small)
            }

            Section("Picture-in-Picture") {
                Toggle("Enable floating live windows", isOn: $pipEnabled)
                Text("Mirrors a window in a floating panel (⌃⌥⇧F, or “>float”). It's a live view — “Restore” focuses the real window.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Natural-Language Workspace") {
                Toggle("Enable natural-language commands", isOn: $nlWorkspaceEnabled)
                Picker("Parser", selection: $nlWorkspaceProviderRaw) {
                    ForEach(NaturalLanguageProviderKind.allCases) { kind in
                        Text(kind.label).tag(kind.rawValue)
                    }
                }
                .disabled(!nlWorkspaceEnabled)
                Text("Describe an arrangement in plain English (⌃⌥⇧N) — e.g. “Slack on the left, Xcode on the right.” Only places windows; never runs arbitrary code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if nlWorkspaceProviderRaw == NaturalLanguageProviderKind.remote.rawValue {
                    RemoteLLMSettingsSection()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Remote LLM key entry (only shown when that provider is selected)

private struct RemoteLLMSettingsSection: View {
    @AppStorage(AppSettings.remoteLLMEnabledKey) private var remoteEnabled = false
    @AppStorage(AppSettings.remoteLLMEndpointKey) private var endpoint = AppSettings.remoteLLMEndpoint
    @AppStorage(AppSettings.remoteLLMModelKey) private var model = AppSettings.remoteLLMModel
    @State private var apiKey: String = KeychainRemoteLLMKeyStore.load() ?? ""
    @State private var saved = false

    var body: some View {
        Toggle("Enable remote model calls", isOn: $remoteEnabled)
        LabeledContent("Endpoint") {
            TextField("https://…/chat/completions", text: $endpoint)
                .textFieldStyle(.plain)
                .disabled(!remoteEnabled)
        }
        LabeledContent("Model") {
            TextField("gpt-4o-mini", text: $model)
                .textFieldStyle(.plain)
                .disabled(!remoteEnabled)
        }
        LabeledContent("API Key") {
            HStack {
                SecureField("sk-…", text: $apiKey)
                    .textFieldStyle(.plain)
                    .disabled(!remoteEnabled)
                Button(saved ? "Saved" : "Save") {
                    KeychainRemoteLLMKeyStore.save(apiKey)
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
                }
                .controlSize(.small)
                .disabled(!remoteEnabled || apiKey.isEmpty)
            }
        }
        Text("Sends your instruction to this endpoint using your own key. Off by default.")
            .font(.footnote)
            .foregroundStyle(.secondary)
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
    private let floatActions: [HotkeyAction] = [.floatFrontmostWindow]
    private let nlActions: [HotkeyAction] = [.nlWorkspace]

    /// VoiceOver's own modifier prefix is bare Control+Option — any JgDo
    /// shortcut using exactly that (no ⇧/⌘) can compete with it. Checked
    /// across every action (not just Window Snapping) since
    /// `.layoutFillOtherSide` also defaults to a bare ⌃⌥ combo.
    private var voiceOverConflictWarning: Bool {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return false }
        return HotkeyAction.allCases.contains { action in
            let combo = store.combo(for: action)
            return combo.control && combo.option && !combo.shift && !combo.command
        }
    }
    private let layoutPickerActions: [HotkeyAction] = [.showLayoutPicker]
    private let layoutOverlayActions: [HotkeyAction] = [.layoutFillOtherSide]

    var body: some View {
        Form {
            Section("Global") {
                ForEach(globalActions) { row($0) }
            }
            Section("Window Snapping") {
                ForEach(snapActions) { row($0) }
                if voiceOverConflictWarning {
                    Label("⌃⌥ shortcuts may conflict with VoiceOver, which is currently on. If a snap key doesn't fire, remap it above.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Section("Resize Steps") {
                ForEach(resizeStepActions) { row($0) }
                Text("Steps between preset sizes, centered on the screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Undo") {
                ForEach(undoActions) { row($0) }
                Text("Restores the last window's frame from right before a JgDo action.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Always on Top") {
                ForEach(pinActions) { row($0) }
                Text("Pins the focused window above all others until toggled off.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Displays") {
                ForEach(displayActions) { row($0) }
                Text("Sends the focused window to the adjacent display.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Focus Mode") {
                ForEach(focusActions) { row($0) }
                Text("Hides every other app's windows until toggled again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Window Parking") {
                ForEach(parkActions) { row($0) }
                Text("Tucks a window away and remembers exactly where it was.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Snap Groups") {
                ForEach(groupActions) { row($0) }
                Text("Manages the current windows together as one unit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Organize Workspace") {
                ForEach(organizeActions) { row($0) }
                Text("Previews a cleaner arrangement before applying it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Picture-in-Picture") {
                ForEach(floatActions) { row($0) }
            }
            Section("Natural-Language Workspace") {
                ForEach(nlActions) { row($0) }
            }
            Section("Layout Picker") {
                ForEach(layoutPickerActions) { row($0) }
                Text("Opens a visual grid of every layout for the frontmost app — arrow keys to move, Return to apply.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Layout Overlay") {
                ForEach(layoutOverlayActions) { row($0) }
                Text("After a ⌃⌥←/→ press, opens a search prompt for which other open window fills the remaining half/third/quarter.")
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
        LabeledContent {
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
        } label: {
            HStack(spacing: 6) {
                if let layout = action.layout {
                    LayoutPreviewIcon(layout: layout)
                        .frame(width: 20, height: 13)
                }
                Text(action.label)
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
    @State private var clearIncludingPinned = false
    @State private var privacy = ClipboardPrivacyService.shared
    @State private var clipboard = ClipboardService.shared
    @State private var addExclusionError: String?

    private var retentionBinding: Binding<Double> {
        Binding(get: { Double(privacy.retentionDays) }, set: { privacy.retentionDays = Int($0) })
    }
    private var maxStorageMBBinding: Binding<Double> {
        Binding(get: { Double(privacy.maxStorageBytes) / 1_000_000 },
                set: { privacy.maxStorageBytes = Int($0 * 1_000_000) })
    }

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
                Text("Pinned items are always kept; confidential content is never recorded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                LabeledContent("Pause capture") {
                    HStack(spacing: 6) {
                        ForEach(ClipboardPrivacyService.PauseDuration.allCases, id: \.self) { duration in
                            Button(duration.label) { privacy.pause(for: duration) }
                                .controlSize(.small)
                        }
                    }
                }
                if privacy.isPaused {
                    HStack {
                        Label(pauseStatusText, systemImage: "pause.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 11.5))
                        Spacer()
                        Button("Resume") { privacy.resume() }
                            .controlSize(.small)
                    }
                }

                LabeledContent("Delete after") {
                    HStack(spacing: 10) {
                        Slider(value: retentionBinding, in: 0...90, step: 5)
                            .frame(width: 200)
                        Text(privacy.retentionDays == 0 ? "Never" : "\(privacy.retentionDays)d")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }

                LabeledContent("Maximum storage") {
                    HStack(spacing: 10) {
                        Slider(value: maxStorageMBBinding, in: 0...500, step: 25)
                            .frame(width: 200)
                        Text(privacy.maxStorageBytes == 0 ? "Unlimited" : "\(Int(maxStorageMBBinding.wrappedValue)) MB")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }

                LabeledContent("Currently using") {
                    Text(ClipboardPrivacyService.formattedByteCount(privacy.storageUsageBytes(items: clipboard.items)))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Excluded Apps") {
                if privacy.excludedBundleIDs.isEmpty {
                    Text("No apps excluded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(privacy.excludedBundleIDs).sorted(), id: \.self) { bundleID in
                        LabeledContent(displayName(forBundleID: bundleID)) {
                            Button("Remove") { privacy.setExcluded(false, bundleID: bundleID) }
                                .controlSize(.small)
                        }
                    }
                }
                Button("Add App…") { pickAppToExclude() }
                Text("Copies made while these apps are frontmost are never recorded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                Button("Clear History…") { clearIncludingPinned = false; confirmClear = true }
                Button("Clear All (Including Pinned)…") { clearIncludingPinned = true; confirmClear = true }
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(clearIncludingPinned ? "Clear all clipboard history, including pinned items?" : "Clear clipboard history?",
                             isPresented: $confirmClear) {
            Button(clearIncludingPinned ? "Clear Everything" : "Clear History", role: .destructive) {
                ClipboardService.shared.clearHistory(keepPinned: !clearIncludingPinned)
            }
        } message: {
            Text(clearIncludingPinned ? "This also removes pinned items. This can't be undone." : "Pinned items are kept.")
        }
        .alert("Couldn't Add App", isPresented: Binding(
            get: { addExclusionError != nil },
            set: { if !$0 { addExclusionError = nil } }
        )) {
            Button("OK") { addExclusionError = nil }
        } message: {
            Text(addExclusionError ?? "")
        }
    }

    private var pauseStatusText: String {
        guard let until = privacy.pausedUntil else { return "" }
        if until == .distantFuture { return "Paused until resumed" }
        return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
    }

    private func displayName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return (Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    private func pickAppToExclude() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App to Exclude"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            addExclusionError = "Couldn't read that app's identifier."
            return
        }
        privacy.setExcluded(true, bundleID: bundleID)
    }
}

// MARK: - License

struct LicenseSettingsView: View {
    @State private var license = LicenseManager.shared
    @State private var confirmDeactivate = false
    @State private var didCopyKey = false

    /// Line-wraps the key every 32 characters for readability — display
    /// only. The Copy button below still copies the exact original string.
    private func wrapped(_ key: String) -> String {
        stride(from: 0, to: key.count, by: 32).map { start in
            let from = key.index(key.startIndex, offsetBy: start)
            let to = key.index(from, offsetBy: 32, limitedBy: key.endIndex) ?? key.endIndex
            return String(key[from..<to])
        }.joined(separator: "\n")
    }

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Plan") {
                    Text(license.plan.displayName)
                        .fontWeight(.medium)
                        .foregroundStyle(license.isPro ? Color.accentColor : .secondary)
                }
                if let key = license.licenseKey {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("License Key")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(wrapped(key))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
                        Button(didCopyKey ? "Copied!" : "Copy Key") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(key, forType: .string)
                            didCopyKey = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopyKey = false }
                        }
                        .controlSize(.small)
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
            AppLogoView(size: 42)
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
            Button("Show Welcome Tour…") {
                SettingsWindow.hide()
                OnboardingWindow.show()
            }
            .controlSize(.small)
            .accessibilityHint("Reopens the first-run onboarding walkthrough of JgDo's main features, permissions, and shortcuts.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
