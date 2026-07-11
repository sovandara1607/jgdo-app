import SwiftUI
import AppKit

/// Passive, click-through list shown alongside a ⌘-drag, listing the other
/// on-screen windows to align against. All interaction (typing, arrows, Tab)
/// is driven by `WindowDragController`'s own event tap, never by this view
/// directly — the panel must never become key or steal keyboard focus away
/// from whatever window is mid-native-drag.
struct DragTargetPickerView: View {
    let state: DragTargetPickerState

    private var rows: [DragTargetPickerState.Candidate] { Array(state.filtered.prefix(6)) }

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 6) {
                searchRow
                if rows.isEmpty {
                    Text("No matching windows")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(rows) { c in
                        row(c, selected: c.windowID == state.selectedCandidate?.windowID)
                    }
                }
            }
            .padding(10)
        }
        .frame(width: 280)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var searchRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(state.searchText.isEmpty ? "Align next to…" : state.searchText)
                .font(.system(size: 12))
                .foregroundStyle(state.searchText.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("Tab")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(PanelTheme.chipFill))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PanelTheme.fieldFill))
    }

    private func row(_ c: DragTargetPickerState.Candidate, selected: Bool) -> some View {
        HStack(spacing: 8) {
            RowIcon(pid: c.pid)
            VStack(alignment: .leading, spacing: 0) {
                Text(c.appName).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Text(c.title).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? PanelTheme.selectedFill : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? PanelTheme.selectedStroke : .clear, lineWidth: 1.5))
    }
}

private struct RowIcon: View {
    let pid: pid_t
    var body: some View {
        Group {
            if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                Image(nsImage: icon).resizable()
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
