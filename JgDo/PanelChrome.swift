import SwiftUI

// MARK: - Tokens

/// Shared design tokens for the floating panels (app switcher, clipboard).
/// Everything derives from `primary` opacities and the system accent color,
/// so the panels adapt to Light/Dark mode and the user's accent choice.
enum PanelTheme {
    static let fieldFill = Color.primary.opacity(0.06)
    static let chipFill = Color.primary.opacity(0.08)
    static let border = Color.primary.opacity(0.10)
    static let selectedFill = Color.accentColor.opacity(0.18)
    static let selectedStroke = Color.accentColor.opacity(0.8)
}

// MARK: - Card background

/// Frosted rounded card used as the body of every floating panel.
struct PanelCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(PanelTheme.border, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.30), radius: 28, y: 12)
    }
}

extension View {
    func panelCard() -> some View { modifier(PanelCard()) }
}

// MARK: - Search field

/// Search field shown at the top of the floating panels. Navigation keys are
/// handled by the AppDelegate's local key monitor; this only takes typing.
struct PanelSearchField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(PanelTheme.fieldFill)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

// MARK: - Footer hint

/// "⌨ key — label" hint chip for panel footers.
struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(PanelTheme.chipFill))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Floating notice (non-modal alert replacement)

/// A small floating notice used instead of `NSAlert.runModal()`. This app is
/// a menu-bar accessory with no persistent window, and an app-modal `NSAlert`
/// freezes the *entire* app — including the menu bar icon — until it's
/// dismissed (and can even show up without key focus in an accessory app).
/// This panel never blocks anything else in the app while it's showing.
struct FloatingNoticeView: View {
    let title: String
    let message: String
    let primaryTitle: String
    let onPrimary: () -> Void
    let secondaryTitle: String?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if let secondaryTitle {
                    Button(secondaryTitle, action: onDismiss)
                        .keyboardShortcut(.cancelAction)
                }
                Button(primaryTitle, action: onPrimary)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 340)
        .panelCard()
        .onExitCommand(perform: onDismiss)
    }
}

// MARK: - Floating notice center

/// Owns the single floating notice panel so any part of the app can present
/// a non-modal alert without duplicating the panel setup (previously
/// AppDelegate-only, which meant other call sites reached for `NSAlert`).
@MainActor
final class FloatingNoticeCenter {
    static let shared = FloatingNoticeCenter()
    private var panel: NSPanel?
    private init() {}

    /// Two-button "open settings / later" notice, the common case for
    /// permission prompts.
    func showPermissionRequest(title: String, message: String, settingsURLString: String) {
        show(title: title, message: message, primaryTitle: "Open System Settings") {
            if let url = URL(string: settingsURLString) { NSWorkspace.shared.open(url) }
        }
    }

    func show(title: String, message: String,
              primaryTitle: String, secondaryTitle: String? = "Later",
              onPrimary: @escaping () -> Void) {
        hide()

        // `.shadow()` in panelCard() never affects SwiftUI layout size — it's
        // pure visual overflow — so it needs extra transparent margin to
        // render into instead of being clipped at the window edge.
        let rootView = FloatingNoticeView(
            title: title, message: message,
            primaryTitle: primaryTitle,
            onPrimary: { [weak self] in onPrimary(); self?.hide() },
            secondaryTitle: secondaryTitle,
            onDismiss: { [weak self] in self?.hide() }
        )
        .padding(40)
        let hosting = NSHostingController(rootView: rootView)

        // Measure the content on a detached hosting controller and create the
        // panel directly at that final size. A transparent (`isOpaque =
        // false`) panel that gets resized *after* its backing store already
        // exists leaves a stale ghost of the original frame's edge in the
        // compositor — a jittery duplicate outline around the real card.
        // Sizing it once, up front, avoids that resize entirely.
        let fitted = hosting.view.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let x = screen.frame.minX + (screen.frame.width - fitted.width) / 2
        let y = screen.frame.minY + (screen.frame.height - fitted.height) / 2

        let panel = KeyablePanel(
            contentRect: NSRect(x: x, y: y, width: fitted.width, height: fitted.height),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hosting

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
