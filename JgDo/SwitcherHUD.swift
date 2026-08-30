import SwiftUI
import AppKit

// MARK: - Functional app switcher (⌥Space / ⌥S)

struct SwitcherHUD: View {
    let onDismiss: () -> Void
    let onPick: (NSRunningApplication) -> Void
    @Environment(HUDState.self) private var state
    @FocusState private var searchFocused: Bool

    private var maxRows: Int { HUDState.maxRows }

    /// Recent live apps, filtered by the search text (shared with the key handler).
    private var results: [NSRunningApplication] { state.filteredApps }

    var body: some View {
        @Bindable var s = state
        VStack(spacing: 9) {
            // Navigation keys (↑↓/Return/Esc) are handled by the AppDelegate's
            // local key monitor; the field only handles typing.
            PanelSearchField(icon: "magnifyingglass",
                             placeholder: "Search apps…",
                             text: $s.searchText,
                             focused: $searchFocused)
            SelectedAppPreview(windows: state.currentWindows)
            list
            footer
        }
        .padding(12)
        .frame(width: 360)
        .panelCard()
        .onChange(of: state.focusSearch) { _, v in
            if v { searchFocused = true; state.focusSearch = false }
        }
        .onChange(of: state.searchText) { _, _ in
            state.selectedIndex = 0
        }
    }

    // MARK: Results list

    private var rows: [(index: Int, app: NSRunningApplication)] {
        Array(results.prefix(maxRows).enumerated()).map { ($0.offset, $0.element) }
    }

    private var list: some View {
        VStack(spacing: 3) {
            if rows.isEmpty {
                Text("No matching apps")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                ForEach(rows, id: \.app.processIdentifier) { item in
                    row(item.app, selected: item.index == state.selectedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(item.app) }
                }
            }
        }
    }

    private func row(_ app: NSRunningApplication, selected: Bool) -> some View {
        let fill: Color = selected ? PanelTheme.selectedFill : Color.clear
        let stroke: Color = selected ? PanelTheme.selectedStroke : Color.clear
        return HStack(spacing: 9) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text(app.localizedName ?? "—")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1.5)
        )
    }

    // MARK: Footer hint

    private var footer: some View {
        HStack(spacing: 12) {
            KeyHint(key: "↑↓", label: "Navigate")
            KeyHint(key: "↩", label: "Snap side by side")
            KeyHint(key: "esc", label: "Close")
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Selected app window preview

/// Live thumbnails of whichever app is currently highlighted — reuses
/// `WindowThumbnailService`, the same live-capture the Command Palette's
/// window rows already use, so arrowing through the switcher (or typing to
/// filter it) shows what's actually on that app's windows right now instead
/// of just its icon. Collapses to nothing for a minimized/windowless app
/// rather than showing an empty box.
private struct SelectedAppPreview: View {
    let windows: [WindowInfo]

    var body: some View {
        if !windows.isEmpty {
            HStack(spacing: 6) {
                ForEach(windows.prefix(3)) { window in
                    WindowPreviewTile(window: window)
                }
            }
            .frame(height: 92)
        }
    }
}

private struct WindowPreviewTile: View {
    let window: WindowInfo
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let icon = window.icon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(PanelTheme.border, lineWidth: 1)
        )
        // Keyed on the stable CGWindowID (not `window.id`, a fresh UUID
        // every `fetchWindows()` call) so recapturing the same window twice
        // in a row doesn't restart the async fetch.
        .task(id: window.windowID) {
            thumbnail = await WindowThumbnailService.thumbnail(
                for: window.windowID, maxSize: CGSize(width: 280, height: 180)
            )
        }
    }
}
