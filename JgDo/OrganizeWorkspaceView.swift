import SwiftUI
import AppKit

/// "Clean Workspace" preview — shows current vs. proposed window layout
/// side by side as mini schematics before anything actually moves. Per
/// spec: never rearrange without confirmation.
struct OrganizeWorkspaceView: View {
    let windows: [WindowInfo]
    let screen: NSScreen
    let onApply: (OrganizeMode) -> Void
    let onCancel: () -> Void

    @State private var mode: OrganizeMode = .balanced

    private var proposed: [(WindowInfo, CGRect)] {
        OrganizeWorkspaceService.propose(mode: mode, windows: windows, on: screen)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("ORGANIZE WORKSPACE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: $mode) {
                ForEach(OrganizeMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            HStack(spacing: 12) {
                SchematicPreview(title: "CURRENT", frames: windows.map(\.appKitFrame), screen: screen)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                SchematicPreview(title: "PROPOSED", frames: proposed.map(\.1), screen: screen)
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
                    onApply(mode)
                } label: {
                    Text("Apply")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }

            KeyHint(key: "esc", label: "Close")
        }
        .padding(16)
        // Wide enough for all 5 segmented-picker labels ("Balanced" …
        // "Main + Stack") to fit without AppKit clipping/cutting off the
        // outer segments — at the old 420pt width "Balanced" and "Main +
        // Stack" were rendered partly outside the window, so they couldn't
        // be clicked at all.
        .frame(width: 560, height: 300)
        .panelCard()
    }

}

extension WindowInfo {
    /// This window's CG bounds converted to AppKit coords — used for the
    /// "current" side of the Organize preview and to snapshot the "before"
    /// frame for `OrganizeUndoService`. Thin wrapper over `CoordinateSpace`
    /// so every CG↔AppKit flip in the app goes through the one formula.
    var appKitFrame: CGRect { CoordinateSpace.appKit(fromCG: bounds) }
}
