import SwiftUI
import AppKit
import SwiftData

// MARK: - Thumbnail cache

/// Downsampled previews for image entries, decoded once per item instead of
/// re-decoding the full PNG on every row render.
@MainActor
enum ClipboardThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(for item: ClipboardItem) -> NSImage? {
        let key = String(describing: item.persistentModelID) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = item.imageData, let full = NSImage(data: data) else { return nil }
        let maxHeight: CGFloat = 88   // 44 pt row height @2×
        let scale = min(1, maxHeight / max(full.size.height, 1))
        let size = NSSize(width: max(full.size.width * scale, 1),
                          height: max(full.size.height * scale, 1))
        let thumb = NSImage(size: size, flipped: false) { rect in
            full.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return true
        }
        cache.setObject(thumb, forKey: key)
        return thumb
    }
}

// MARK: - Panel

/// Floating clipboard-history panel (⌥V by default). Same visual language as
/// the app switcher: frosted card, search on top, keyboard-driven list.
struct ClipboardHistoryView: View {
    let onDismiss: () -> Void
    let onPick: (ClipboardItem) -> Void

    @State private var service = ClipboardService.shared
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    private var results: [ClipboardItem] {
        Array(service.filteredItems.prefix(60))
    }

    var body: some View {
        @Bindable var s = service
        VStack(spacing: 12) {
            PanelSearchField(icon: "doc.on.clipboard",
                             placeholder: "Search clipboard history…",
                             text: $s.searchText,
                             focused: $searchFocused)
            list
            footer
        }
        .padding(16)
        .frame(width: 520)
        .panelCard()
        .onChange(of: service.focusSearch) { _, v in
            if v { searchFocused = true; service.focusSearch = false }
        }
        .onChange(of: service.searchText) { _, _ in
            service.selectedIndex = 0
        }
        .confirmationDialog("Clear clipboard history?",
                            isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                service.clearHistory()
            }
        } message: {
            Text("Pinned items are kept.")
        }
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    if results.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.persistentModelID) { index, item in
                            row(item, selected: index == service.selectedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(item) }
                        }
                    }
                }
            }
            .frame(height: 380)
            .onChange(of: service.selectedIndex) { _, idx in
                guard results.indices.contains(idx) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(results[idx].persistentModelID, anchor: nil)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(service.isEnabled ? "Nothing copied yet" : "Clipboard history is off")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func row(_ item: ClipboardItem, selected: Bool) -> some View {
        HStack(spacing: 11) {
            kindBadge(item)
            VStack(alignment: .leading, spacing: 3) {
                if item.kind == .image, let thumb = ClipboardThumbnailCache.thumbnail(for: item) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Text(item.preview.isEmpty ? "—" : item.preview)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let app = item.sourceAppName {
                        Text(app)
                    }
                    Text(item.createdAt, format: .relative(presentation: .named))
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button {
                service.togglePin(item)
            } label: {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(item.isPinned ? Color.orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(item.isPinned ? "Unpin" : "Pin")
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? PanelTheme.selectedFill : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? PanelTheme.selectedStroke : Color.clear, lineWidth: 1.5)
        )
        .contextMenu {
            Button(item.isPinned ? "Unpin" : "Pin") { service.togglePin(item) }
            Button("Copy") { service.copyToPasteboard(item) }
            Divider()
            Button("Delete", role: .destructive) { service.delete(item) }
        }
    }

    private func kindBadge(_ item: ClipboardItem) -> some View {
        let symbol: String
        switch item.kind {
        case .text:  symbol = "text.alignleft"
        case .image: symbol = "photo"
        case .file:  symbol = "doc"
        }
        return Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(PanelTheme.fieldFill)
            )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            KeyHint(key: "↑↓", label: "Navigate")
            KeyHint(key: "↩", label: "Paste")
            KeyHint(key: "esc", label: "Close")
            Spacer()
            Button("Clear…") { confirmClear = true }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("Clear history (keeps pinned items)")
        }
        .padding(.horizontal, 4)
    }
}
