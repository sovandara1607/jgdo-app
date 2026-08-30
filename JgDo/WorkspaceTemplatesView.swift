import SwiftUI
import AppKit

/// Browse/apply the 4 built-in workspace templates. Applying places real
/// windows — from there, "Save Current Layout" in the Workspaces tile turns
/// it into a normal, renameable/duplicable Workspace.
struct WorkspaceTemplatesView: View {
    let onApply: (WorkspaceTemplate) -> Void
    let onCancel: () -> Void

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    var body: some View {
        VStack(spacing: 10) {
            Text("WORKSPACE TEMPLATES")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(WorkspaceTemplate.builtIns) { template in
                        card(template)
                    }
                }
            }

            KeyHint(key: "esc", label: "Close")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: 420, height: 420)
        .panelCard()
        .onExitCommand(perform: onCancel)
    }

    private func card(_ template: WorkspaceTemplate) -> some View {
        let available = WorkspaceTemplateService.shared.isAvailable(template)
        return HStack(spacing: 12) {
            SchematicPreview(title: "", frames: WorkspaceTemplateService.shared.previewFrames(for: template, on: screen), screen: screen)
                .frame(width: 84, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: template.symbolName)
                        .foregroundStyle(Color.accentColor)
                    Text(template.name)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(template.slots.map(\.roleLabel).joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !available {
                    Text("None of the suggested apps are installed")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Button("Apply") { onApply(template) }
                .controlSize(.small)
                .disabled(!available)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(template.name) template: \(template.slots.map(\.roleLabel).joined(separator: ", "))")
    }
}
