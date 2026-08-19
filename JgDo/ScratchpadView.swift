import SwiftUI

/// A tiny persistent notes panel — jot something down without switching to a
/// notes app. Content auto-saves on every keystroke via `@AppStorage`; no
/// explicit save action needed. Same visual language as the other floating
/// panels (frosted card).
struct ScratchpadView: View {
    let onDismiss: () -> Void
    @AppStorage("scratchpadText") private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("SCRATCHPAD")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    text = ""
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PanelTheme.fieldFill)
                )
                .focused($focused)
            HStack(spacing: 14) {
                KeyHint(key: "esc", label: "Close")
                Spacer()
                Text("\(text.count) characters")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 320, height: 260)
        .panelCard()
        .onAppear { focused = true }
    }
}
