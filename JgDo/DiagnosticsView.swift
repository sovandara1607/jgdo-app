import SwiftUI
import AppKit

/// Settings → Diagnostics: live Accessibility/Screen Recording status with
/// direct links to the right System Settings pane, whether hotkeys and
/// drag-snapping are actually running right now, data-store health, and a
/// copyable summary for support requests. The summary deliberately never
/// includes clipboard contents, the license key, or any other private
/// data — only counts, booleans, and version strings.
struct DiagnosticsView: View {
    @State private var permissions = PermissionMonitor.shared
    @State private var coordinator = LicenseFeatureCoordinator.shared
    @State private var persistence = Persistence.shared
    @State private var didCopy = false
    @State private var requestedScreenRecording = false

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow(
                    title: "Accessibility", granted: permissions.accessibilityTrusted,
                    detail: "Required for global shortcuts, window snapping, and drag-to-snap.",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                    requestAction: {}
                )
                permissionRow(
                    title: "Screen Recording", granted: permissions.screenRecordingAuthorized,
                    detail: "Optional — enables live window thumbnails in the Command Palette.",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                    requestAction: {
                        requestedScreenRecording = true
                        WindowThumbnailService.requestAccessIfNeeded()
                    },
                    // Screen Recording doesn't update live like Accessibility
                    // does — needs a relaunch to actually pick up a grant.
                    needsRelaunch: requestedScreenRecording && !permissions.screenRecordingAuthorized
                )
            }

            Section("Running Now") {
                statusRow("Global Hotkeys", running: coordinator.hotkeyManager != nil)
                statusRow("⌘-Drag Snapping", running: coordinator.dragController != nil)
                statusRow("Clipboard Capture", running: !ClipboardPrivacyService.shared.isPaused && ClipboardService.shared.isEnabled)
                if !coordinator.isRunning {
                    Text("Licensed features aren't running — activate a license in Settings → License.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Data Store") {
                switch persistence.loadState {
                case .ready:
                    Label("Data file opened normally", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let description, _):
                    Label("Couldn't open data file", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("See Settings → General → Data & Recovery to restore from a backup.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostic Summary") {
                Text(summaryText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                Button(didCopy ? "Copied!" : "Copy Summary") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(summaryText, forType: .string)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
                }
                Text("Includes counts and status only — never clipboard contents, license keys, or other private data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { PermissionMonitor.shared.start() }
        .onDisappear { PermissionMonitor.shared.stop() }
    }

    private func permissionRow(title: String, granted: Bool, detail: String, settingsURL: String,
                                requestAction: @escaping () -> Void, needsRelaunch: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? .green : .red)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                if !granted {
                    Button("Open System Settings") {
                        requestAction()
                        if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if needsRelaunch {
                HStack(spacing: 8) {
                    Text("Granted it already? JgDo needs to restart to pick that up.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Restart JgDo", action: AppRelauncher.relaunch)
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(granted ? "granted" : "not granted")")
    }

    private func statusRow(_ title: String, running: Bool) -> some View {
        HStack {
            Image(systemName: running ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(running ? .green : .secondary)
                .accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(running ? "Running" : "Stopped")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(running ? "running" : "stopped")")
    }

    private var summaryText: String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let screens = NSScreen.screens
        let screenDescriptions = screens.map { screen in
            "\(Int(screen.frame.width))×\(Int(screen.frame.height))@(\(Int(screen.frame.minX)),\(Int(screen.frame.minY)))"
        }.joined(separator: ", ")

        let persistenceLine: String
        switch persistence.loadState {
        case .ready: persistenceLine = "ready"
        case .failed: persistenceLine = "failed (see Data Store section)"
        }

        return """
        JgDo Diagnostic Summary
        App: \(appVersion) (\(buildNumber))
        macOS: \(osVersion)
        Accessibility: \(permissions.accessibilityTrusted ? "granted" : "not granted")
        Screen Recording: \(permissions.screenRecordingAuthorized ? "granted" : "not granted")
        License: \(LicenseManager.shared.plan.displayName)
        Hotkeys running: \(coordinator.hotkeyManager != nil)
        Drag-snap running: \(coordinator.dragController != nil)
        Clipboard capture: \(!ClipboardPrivacyService.shared.isPaused && ClipboardService.shared.isEnabled)
        Clipboard items: \(ClipboardService.shared.items.count)
        Workspaces saved: \(WorkspaceService.shared.workspaces.count)
        Data store: \(persistenceLine)
        Displays (\(screens.count)): \(screenDescriptions)
        """
    }
}
