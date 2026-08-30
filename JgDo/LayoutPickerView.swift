import SwiftUI
import AppKit

/// A grid of every `WindowLayout`, shown as a visual tile (`LayoutPreviewIcon`
/// + label) rather than a text list — "recognition over memorization" for
/// window layouts specifically. Hovering (or arrow-keying to) a tile flashes
/// where the window would actually land on the real screen (reusing
/// `SnapPreviewOverlay`, the same ghost-tile the hotkey/command-palette
/// paths already use); clicking or pressing Return applies it. Starred
/// layouts sort first.
struct LayoutPickerView: View {
    let targetAppName: String
    let targetIcon: NSImage?
    let onPick: (WindowLayout) -> Void
    let onCancel: () -> Void

    /// 5 columns × 2 rows fits all 10 layouts without scrolling — also the
    /// stride arrow-up/down uses to move a full row at a time.
    private static let columnCount = 5
    private static let columns = [GridItem](repeating: GridItem(.flexible(), spacing: 10), count: columnCount)

    @State private var favorites = AppSettings.favoriteLayouts
    private var layouts: [WindowLayout] {
        WindowLayout.allCases.sorted { favorites.contains($0) && !favorites.contains($1) }
    }

    /// The single source of truth for "which tile is highlighted right
    /// now" — mouse hover and arrow-key movement both write here, so
    /// either input method drives the exact same preview/apply path.
    @State private var selection: WindowLayout?
    @FocusState private var gridFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                if let targetIcon {
                    Image(nsImage: targetIcon).resizable().frame(width: 18, height: 18)
                }
                Text("Layout for \(targetAppName)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: Self.columns, spacing: 10) {
                ForEach(layouts, id: \.self) { layout in
                    tile(layout)
                }
            }

            HStack(spacing: 12) {
                KeyHint(key: "↑↓←→", label: "Navigate")
                KeyHint(key: "↩", label: "Apply")
                KeyHint(key: "⭐", label: "Favorite")
                KeyHint(key: "esc", label: "Close")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: 360)
        // Same dark-tinted, accent-bordered chrome as the ⌃⌥←/→ layout
        // overlay and its "fill other side" search — same layout-picking
        // domain, reachable from the same SnapPreviewOverlay ghost tile.
        .hudCard(cornerRadius: 22)
        .focusable()
        .focused($gridFocused)
        .onAppear { gridFocused = true; if selection == nil { selection = layouts.first } }
        .onExitCommand(perform: onCancel)
        .onKeyPress(.return) { applySelection(); return .handled }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-Self.columnCount); return .handled }
        .onKeyPress(.downArrow) { move(Self.columnCount); return .handled }
        .onKeyPress(KeyEquivalent("f")) { toggleFavorite(selection); return .handled }
        .onChange(of: selection) { _, layout in updatePreview(layout) }
        .onAppear { updatePreview(selection) }
        .onDisappear { SnapPreviewOverlay.shared.hidePersistent() }
    }

    private func move(_ delta: Int) {
        guard let current = selection, let index = layouts.firstIndex(of: current) else {
            selection = layouts.first
            return
        }
        let newIndex = (index + delta + layouts.count) % layouts.count
        selection = layouts[newIndex]
    }

    private func applySelection() {
        guard let selection else { return }
        onPick(selection)
    }

    private func toggleFavorite(_ layout: WindowLayout?) {
        guard let layout else { return }
        if favorites.contains(layout) { favorites.remove(layout) } else { favorites.insert(layout) }
        AppSettings.favoriteLayouts = favorites
    }

    private func updatePreview(_ layout: WindowLayout?) {
        guard let layout, let screen = NSScreen.main else {
            SnapPreviewOverlay.shared.hidePersistent()
            return
        }
        let frame = WindowResizeService.shared.frame(for: layout, on: screen)
        SnapPreviewOverlay.shared.showPersistent(primary: frame, guide: nil, on: screen)
    }

    private func tile(_ layout: WindowLayout) -> some View {
        let isSelected = selection == layout
        let isFavorite = favorites.contains(layout)
        return Button {
            selection = layout
            onPick(layout)
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    LayoutPreviewIcon(layout: layout, color: isSelected ? .white : .accentColor)
                        .frame(width: 44, height: 28)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.yellow)
                            .offset(x: 4, y: -4)
                    }
                }
                Text(layout.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering in if isHovering { selection = layout } }
        .contextMenu {
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") { toggleFavorite(layout) }
        }
        .accessibilityLabel(layout.rawValue + (isFavorite ? ", favorite" : ""))
        .accessibilityHint("Applies this layout to \(targetAppName). Press F to favorite.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
