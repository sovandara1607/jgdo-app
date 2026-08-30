import SwiftUI
import AppKit

@MainActor
enum ActivationWindow {
    private static var window: NSWindow?
    private static var onActivated: (() -> Void)?

    static func show(onActivated: @escaping () -> Void) {
        Self.onActivated = onActivated
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Activate JgDo"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: ActivationView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Called by ActivationView once `LicenseManager.activate` succeeds.
    static func handleActivationSuccess() {
        window?.close()
        onActivated?()
        onActivated = nil
    }
}

struct ActivationView: View {
    @State private var key = ""
    @State private var error: String?
    @State private var license = LicenseManager.shared
  
    /// Set active, if it succeeds, it will form a brief confirmation (check whether which plan match)
    @State private var activatedPlan: LicensePlan?

    var body: some View {
        VStack(spacing: 16) {
            AppLogoView(size: 36)

            if let activatedPlan {
                successState(plan: activatedPlan)
            } else {
                form
            }
        }
        .padding(28)
        .frame(width: 420, height: 400)
        .animation(.easeOut(duration: 0.2), value: activatedPlan != nil)
    }

    private var form: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Activate JgDo")
                    .font(.system(size: 18, weight: .semibold))
                Text("JgDo requires a license key to run. Enter the key from your purchase email, or buy one below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 300)
            }

            TextField("Paste your license key", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 300)
                .onSubmit(activate)

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(width: 300)
            }

            Button("Activate") { activate() }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)

            Divider().frame(width: 260)

            Button {
                NSWorkspace.shared.open(URL(string: "https://jgdo.sovandara.lol/pricing")!)
            } label: {
                Text("Buy a License →")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Button("Quit JgDo") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func successState(plan: LicensePlan) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            Text("License Activated")
                .font(.system(size: 16, weight: .semibold))
            Text("Your key matched — you're on the \(plan.displayName) plan.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 280)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func activate() {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if license.activate(key: trimmed) {
            error = nil
            activatedPlan = license.plan
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                ActivationWindow.handleActivationSuccess()
            }
        } else {
            error = "That license key isn't valid. Double-check for typos."
        }
    }
}
