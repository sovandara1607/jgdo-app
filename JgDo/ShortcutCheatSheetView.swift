import SwiftUI

/// A read-only overlay listing every active hotkey, grouped the same way as
/// Settings → Shortcuts (`ShortcutStore.categories`) — the two share one
/// source of truth so they can't drift apart. Purely informational: no
/// interaction beyond dismissing (Esc, or the same hotkey again).
struct ShortcutCheatSheetView: View {
    @State private var store = ShortcutStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("KEYBOARD SHORTCUTS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(HotkeyAction.categories, id: \.title) { category in
                        section(category.title, category.actions)
                    }
                }
            }

            KeyHint(key: "esc", label: "Close")
        }
        .padding(16)
        .frame(width: 340, height: 420)
        .panelCard()
    }

    private func section(_ title: String, _ actions: [HotkeyAction]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            ForEach(actions) { action in
                HStack {
                    Text(action.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    Text(store.combo(for: action).display)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(PanelTheme.chipFill))
                }
            }
        }
    }
}
