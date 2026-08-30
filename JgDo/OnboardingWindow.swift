import SwiftUI
import AppKit
import Combine

/// First-run tour: explains JgDo's main features, walks through
/// Accessibility (required) and Screen Recording (optional) permissions,
/// lets the user opt out of clipboard history / workflow insights up
/// front, and shows the most important shortcuts. Shown once
/// (`AppSettings.hasCompletedOnboarding`), before the license gate — JgDo
/// has no free tier, so this informs rather than replaces `ActivationWindow`.
/// Reopenable any time from Settings → About.
@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?
    private static var onFinished: (() -> Void)?

    static func show(onFinished: @escaping () -> Void = {}) {
        Self.onFinished = onFinished
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Welcome to JgDo"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: OnboardingView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Called by `OnboardingView` once the user reaches the end (or skips).
    static func handleFinished() {
        AppSettings.hasCompletedOnboarding = true
        window?.close()
        onFinished?()
        onFinished = nil
    }
}

/// One area of JgDo the user can flag as a main interest during onboarding.
/// Doesn't gate or hide anything (every feature stays available regardless)
/// — it's a light signal `AppSettings.onboardingInterests` reads later to
/// decide what to emphasize first (e.g. which Overview quick actions lead),
/// matching "recognition over memorization" without adding a real mode
/// switch. Multi-select, changeable any time from Settings → About.
enum OnboardingInterest: String, CaseIterable, Identifiable {
    case windowManagement, appSwitching, clipboard, workspaces, fileSearch
    var id: String { rawValue }

    var label: String {
        switch self {
        case .windowManagement: return "Window Management"
        case .appSwitching:     return "App Switching"
        case .clipboard:        return "Clipboard"
        case .workspaces:       return "Workspaces"
        case .fileSearch:       return "File Search"
        }
    }

    var icon: String {
        switch self {
        case .windowManagement: return "square.on.square"
        case .appSwitching:     return "rectangle.stack"
        case .clipboard:        return "doc.on.clipboard"
        case .workspaces:       return "square.grid.2x2"
        case .fileSearch:       return "magnifyingglass"
        }
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome, interests, permissions, privacy, shortcuts

    var title: String {
        switch self {
        case .welcome:     return "Welcome to JgDo"
        case .interests:   return "What Do You Need?"
        case .permissions: return "Permissions"
        case .privacy:     return "Your Data"
        case .shortcuts:   return "Key Shortcuts"
        }
    }
}

struct OnboardingView: View {
    @State private var step: OnboardingStep = .welcome
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var screenRecordingAuthorized = WindowThumbnailService.isAuthorized
    @State private var requestedScreenRecording = false
    @State private var interests: Set<OnboardingInterest> = AppSettings.onboardingInterests
    @AppStorage(ClipboardService.enabledKey) private var clipboardEnabled = true
    @AppStorage(WorkflowInsightsService.enabledKey) private var workflowInsightsEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Re-checks live permission status when the window regains focus —
    /// e.g. after the user comes back from System Settings.
    private let refreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 520)
        .onReceive(refreshTimer) { _ in
            accessibilityTrusted = AXIsProcessTrusted()
            screenRecordingAuthorized = WindowThumbnailService.isAuthorized
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.12))
                        .frame(height: 4)
                        .animation(reduceMotion ? nil : .default, value: step)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .accessibilityHidden(true) // decorative; the step title below carries the same info

            Text(step.title)
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 6)
                .padding(.bottom, 14)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:     welcomeStep
        case .interests:   interestsStep
        case .permissions: permissionsStep
        case .privacy:     privacyStep
        case .shortcuts:   shortcutsStep
        }
    }

    // MARK: Step 1.5 — Interests

    private var interestsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick whatever you're here for — you can change this any time in Settings → About.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(OnboardingInterest.allCases) { interest in
                    interestRow(interest)
                }
            }
        }
    }

    private func interestRow(_ interest: OnboardingInterest) -> some View {
        let selected = interests.contains(interest)
        return Button {
            // Persisted immediately (matching the Privacy step's `@AppStorage`
            // toggles) rather than only on Next/Back, so hitting "Skip" from
            // this step still keeps whatever was checked.
            if selected { interests.remove(interest) } else { interests.insert(interest) }
            AppSettings.onboardingInterests = interests
        } label: {
            HStack(spacing: 12) {
                Image(systemName: interest.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(interest.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(selected ? 0.07 : 0.04)))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(interest.label)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    // MARK: Step 1 — Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppLogoView(size: 40)
                .frame(maxWidth: .infinity)

            Text("JgDo is a keyboard-first window manager. Here's what it does:")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            featureRow(icon: "square.on.square", title: "Window Snapping",
                       detail: "⌘-drag any window to snap it into whatever space is left, or use hotkeys to tile halves, thirds, and corners.")
            featureRow(icon: "rectangle.stack", title: "App Switcher HUD",
                       detail: "⌥Space shows a searchable list of your recent apps and their windows.")
            featureRow(icon: "doc.on.clipboard", title: "Clipboard History",
                       detail: "⌥V brings up everything you've copied recently, with OCR text search on screenshots.")
            featureRow(icon: "command", title: "Command Palette",
                       detail: "⌘⌥Space finds and jumps to any open window, or runs a quick action, Spotlight-style.")
            featureRow(icon: "square.grid.2x2", title: "Workspaces & Snap Groups",
                       detail: "Save an arrangement of apps and restore it later, or group related windows to move them together.")
        }
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Step 2 — Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("JgDo needs Accessibility access to intercept keyboard shortcuts and move windows. Screen Recording is optional — it only improves the Command Palette's live window thumbnails.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            permissionRow(
                title: "Accessibility", required: true, granted: accessibilityTrusted,
                detail: "Required for global shortcuts, window snapping, and drag-to-snap.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                requestAction: {
                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                    _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
                }
            )
            permissionRow(
                title: "Screen Recording", required: false, granted: screenRecordingAuthorized,
                detail: "Optional — without it, the Command Palette shows app icons instead of live window previews.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                requestAction: {
                    requestedScreenRecording = true
                    WindowThumbnailService.requestAccessIfNeeded()
                },
                // Screen Recording doesn't take effect live like
                // Accessibility does — the checkmark stays off until
                // relaunch even after granting it in System Settings.
                needsRelaunch: requestedScreenRecording && !screenRecordingAuthorized
            )
        }
    }

    private func permissionRow(title: String, required: Bool, granted: Bool, detail: String,
                                settingsURL: String, requestAction: @escaping () -> Void,
                                needsRelaunch: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? .green : .secondary)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 13, weight: .semibold))
                if !required {
                    Text("Optional")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer()
                if !granted {
                    Button("Open Settings") {
                        requestAction()
                        if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
            }
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if needsRelaunch {
                HStack(spacing: 8) {
                    Text("Granted it already? JgDo needs to restart to pick that up.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Button("Restart JgDo", action: AppRelauncher.relaunch)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(required ? "required" : "optional"), \(granted ? "granted" : "not granted")")
        .accessibilityHint(granted ? "" : "Double-tap Open Settings to grant this permission.")
    }

    // MARK: Step 3 — Privacy

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Both are on by default and can be changed any time in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Toggle(isOn: $clipboardEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clipboard History").font(.system(size: 13, weight: .semibold))
                    Text("Records what you copy so ⌥V can bring it back. Password-manager entries are never recorded.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .accessibilityHint("Turns clipboard history recording on or off.")

            Toggle(isOn: $workflowInsightsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workflow Insights").font(.system(size: 13, weight: .semibold))
                    Text("Tracks which apps you use and for how long, entirely on-device, to show your daily focus breakdown.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .accessibilityHint("Turns on-device workflow insight tracking on or off.")
        }
    }

    // MARK: Step 4 — Shortcuts

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The essentials — see the full list any time with ⌃⌥/.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            shortcutRow("⌥Space", "Open the app switcher")
            shortcutRow("⌥V", "Open clipboard history")
            shortcutRow("⌘⌥Space", "Open the command palette")
            shortcutRow("⌘-drag", "Snap a window into available space")
            shortcutRow("⌃⌥ + arrow", "Tile the focused window")
            shortcutRow("⌃⌥/", "Show every shortcut")
        }
    }

    private func shortcutRow(_ keys: String, _ label: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 110, alignment: .leading)
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(keys): \(label)")
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            Button("Skip") { OnboardingWindow.handleFinished() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityHint("Closes onboarding without changing the current step's settings.")
            if step == .shortcuts {
                Button("Get Started") { OnboardingWindow.handleFinished() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") { step = OnboardingStep(rawValue: step.rawValue + 1) ?? .shortcuts }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
