import SwiftUI
import AppKit
import ServiceManagement

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
    }
}

// MARK: - Shortcuts (recorder)

struct ShortcutsSettingsView: View {
    @State private var store = ShortcutStore.shared
    @State private var recording: HotkeyAction?
    @State private var eventMonitor: Any?
    @State private var notice: String?

    private let globalActions: [HotkeyAction] = [.toggleSwitcher, .clipboardHistory, .commandPalette]
    private var snapActions: [HotkeyAction] {
        HotkeyAction.allCases.filter { $0.layout != nil }
    }
    private let resizeStepActions: [HotkeyAction] = [.shrinkWindow, .growWindow]

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
