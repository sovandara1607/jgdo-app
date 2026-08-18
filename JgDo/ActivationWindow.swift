import SwiftUI
import AppKit

/// Blocks app functionality until a valid license key is entered. JgDo has
/// no free tier — every install needs to be activated. Shown by AppDelegate
/// in place of the normal status popover whenever `!LicenseManager.shared.isPro`.
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

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.accentColor)

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

            TextField("PRO0-XXXX-XXXX-XXXX", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 260)
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
        .padding(28)
        .frame(width: 420, height: 400)
    }

    private func activate() {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if license.activate(key: trimmed) {
            error = nil
            ActivationWindow.handleActivationSuccess()
        } else {
            error = "That license key isn't valid. Double-check for typos."
        }
    }
}
