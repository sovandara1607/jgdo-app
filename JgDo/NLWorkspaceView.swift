import SwiftUI
import AppKit

/// The Natural-Language Workspace panel's content — same window-chrome
/// pattern as `OrganizeWorkspaceView`/`ScratchpadView` (a `.panelCard()`
/// over a `KeyablePanel`). One text field, a live preview built by
/// re-parsing on every keystroke (debounced), and Apply/Cancel — nothing
/// moves until Apply, and anything that would launch/close more than a
/// couple of apps gets one extra confirmation tap first.
struct NLWorkspaceView: View {
    let installedAppNames: [String]
    let screen: NSScreen
    let currentWindows: [WindowInfo]
    let onApply: (WorkspaceCommandExecutor.ValidatedCommand) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var command = WorkspaceCommand()
    @State private var validated: WorkspaceCommandExecutor.ValidatedCommand?
    @State private var isParsing = false
    @State private var confirmingBigChange = false
    @State private var parseTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    /// A command touching more than this many apps at once (placements +
    /// closes) needs an explicit second confirmation before Apply actually
    /// runs — matches the brief's "explicit confirmation gating any command
    /// that would launch/close more than a couple of apps".
    private static let confirmThreshold = 2

    private var proposedFrames: [CGRect] {
        guard let validated else { return [] }
        return validated.placements.compactMap { placement -> CGRect? in
            let targetScreen = placement.screenIndex.flatMap { NSScreen.screens.indices.contains($0) ? NSScreen.screens[$0] : nil } ?? screen
            return WindowResizeService.shared.frame(for: placement.layout, on: targetScreen)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("NATURAL-LANGUAGE WORKSPACE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            PanelSearchField(icon: "sparkles", placeholder: "Put Slack on the left and Xcode on the right…",
                              text: $text, focused: $fieldFocused)
                .onChange(of: text) { _, newValue in scheduleParse(newValue) }
                .onSubmit { if validated?.isActionable == true { requestApply() } }

            if isParsing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !command.summary.isEmpty {
                Text(command.summary)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !text.isEmpty {
                Text("Couldn't understand that yet — try phrasing like “Put Slack on the left and Xcode on the right.”")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let validated, !validated.issues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(validated.issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                SchematicPreview(title: "CURRENT", frames: currentWindows.map(\.appKitFrame), screen: screen)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                SchematicPreview(title: "PROPOSED", frames: proposedFrames, screen: screen)
            }

            if confirmingBigChange {
                Text("This will affect \(affectedAppCount) apps. Apply anyway?")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                Button {
                    requestApply()
                } label: {
                    Text(confirmingBigChange ? "Apply Anyway" : "Apply")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(validated?.isActionable != true)
                .opacity(validated?.isActionable == true ? 1 : 0.4)
            }

            KeyHint(key: "esc", label: "Close")
        }
        .padding(16)
        .frame(width: 560, height: 360)
        .panelCard()
        .onAppear { fieldFocused = true }
    }

    private var affectedAppCount: Int {
        (validated?.placements.count ?? 0) + (validated?.appsToClose.count ?? 0)
    }

    private func scheduleParse(_ newText: String) {
        parseTask?.cancel()
        confirmingBigChange = false
        guard !newText.trimmingCharacters(in: .whitespaces).isEmpty else {
            command = WorkspaceCommand()
            validated = nil
            isParsing = false
            return
        }
        isParsing = true
        parseTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)   // debounce — don't re-parse every keystroke
            guard !Task.isCancelled else { return }
            let parsed = await NaturalLanguageService.shared.parse(newText)
            guard !Task.isCancelled else { return }
            command = parsed
            validated = WorkspaceCommandExecutor.validate(
                parsed, installedAppNames: installedAppNames, screenCount: NSScreen.screens.count
            )
            isParsing = false
        }
    }

    private func requestApply() {
        guard let validated, validated.isActionable else { return }
        if affectedAppCount > Self.confirmThreshold && !confirmingBigChange {
            confirmingBigChange = true
            return
        }
        onApply(validated)
    }
}
