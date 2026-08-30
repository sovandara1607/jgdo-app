import SwiftUI

/// Search prompt for picking which other open window fills the
/// complementary half/third/quarter after a ⌃⌥←/→ commit — opened by the
/// dedicated "fill other side" hotkey. Search field + highlighted-row
/// language borrowed from the Command Palette (`PanelSearchField`,
/// `PanelTheme.selectedFill/selectedStroke` for row selection), but the
/// card chrome itself matches the ⌃⌥←/→ layout overlay (dark tint, accent
/// border, rounded) — same feature family, same surface language.
struct WindowLayoutPartnerSearchView: View {
    let state: WindowLayoutPartnerSearchState
    let complementName: String
    /// Fired whenever the highlighted row changes (arrow keys or typing) —
    /// the controller uses this to keep the desktop ghost tile in sync, so
    /// arrowing to a different candidate immediately previews it there
    /// instead of only after Return.
    var onSelectionChange: (PartnerWindowCandidate?) -> Void = { _ in }
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var s = state
        VStack(spacing: 12) {
            Text("Fill \(complementName) with…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            PanelSearchField(icon: "magnifyingglass", placeholder: "Search open windows…",
                              text: $s.query, focused: $focused)

            if state.filtered.isEmpty {
                Text("No other windows open")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 14)
            } else {
                VStack(spacing: 3) {
                    ForEach(Array(state.filtered.enumerated()), id: \.element.pid) { index, candidate in
                        row(candidate, isSelected: index == state.selectedIndex)
                    }
                }
            }

            HStack {
                KeyHint(key: "↩", label: "Fill")
                KeyHint(key: "esc", label: "Skip")
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 360)
        .hudCard(cornerRadius: 24, shadowY: 12)
        .onAppear {
            focused = true
            onSelectionChange(state.selected)
        }
        .onChange(of: state.selected?.pid) { _, _ in onSelectionChange(state.selected) }
    }

    private func row(_ candidate: PartnerWindowCandidate, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            if let icon = candidate.icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            }
            Text(candidate.appName)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? PanelTheme.selectedFill : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? PanelTheme.selectedStroke : Color.clear, lineWidth: 1.5)
        )
    }
}
