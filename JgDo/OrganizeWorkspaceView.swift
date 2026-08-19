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

            HStack(spacing: 12) {
                schematic(title: "CURRENT", frames: windows.map { ($0, $0.appKitFrame(mainHeight: mainHeight)) })
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                schematic(title: "PROPOSED", frames: proposed)
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
        .frame(width: 420, height: 300)
        .panelCard()
    }

    private var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func schematic(title: String, frames: [(WindowInfo, CGRect)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.tertiary)
            GeometryReader { geo in
                let scaleX = geo.size.width / max(screen.visibleFrame.width, 1)
                let scaleY = geo.size.height / max(screen.visibleFrame.height, 1)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                    ForEach(Array(frames.enumerated()), id: \.offset) { i, pair in
                        let (_, frame) = pair
                        let vf = screen.visibleFrame
                        let boxWidth: CGFloat = max(frame.width * scaleX - 2, 2)
                        let boxHeight: CGFloat = max(frame.height * scaleY - 2, 2)
                        let centerX: CGFloat = (frame.minX - vf.minX + frame.width / 2) * scaleX
                        let centerY: CGFloat = geo.size.height - (frame.minY - vf.minY + frame.height / 2) * scaleY
                        let border = RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 1)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.accentColor.opacity(0.35))
                            .overlay(border)
                            .frame(width: boxWidth, height: boxHeight)
                            .position(x: centerX, y: centerY)
                            .id(i)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(screen.visibleFrame.width / max(screen.visibleFrame.height, 1), contentMode: .fit)
    }
}

extension WindowInfo {
    /// This window's CG bounds converted to AppKit coords — used for the
    /// "current" side of the Organize preview and to snapshot the "before"
    /// frame for `OrganizeUndoService`.
    func appKitFrame(mainHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: mainHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}
