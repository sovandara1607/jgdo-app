import SwiftUI
import AppKit

// MARK: - Command Palette (⌘⌥Space)

/// Spotlight/Raycast-style window switcher: a single flat, searchable list,
/// one row per app — except the app that currently has keyboard focus, which
/// expands inline to show each of its windows as its own row. Distinct from
/// the simpler app-level `SwitcherHUD` (⌥Space) — this operates at the
/// window level.
struct CommandPaletteView: View {
    let onDismiss: () -> Void
    let onPick: (WindowInfo) -> Void
    @Environment(CommandPaletteState.self) private var state
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var s = state
        VStack(spacing: 10) {
            PanelSearchField(icon: "sparkle.magnifyingglass",
                             placeholder: "Search windows…",
                             text: $s.searchText,
                             focused: $searchFocused)
            list
            footer
        }
        .padding(18)
        .frame(width: 620, height: 460)
        // `.glassEffect()`/`GlassEffectContainer` did real-time backdrop blur
        // sampling over this whole panel, re-triggered on every keystroke
        // (search filtering) and every arrow-key press (expand/collapse
        // spring animation) — reported laggy in practice. `panelCard()` is
        // the same `.ultraThinMaterial` treatment `SwitcherHUD`/clipboard use
        // without issue, and is much cheaper to keep redrawing at that rate.
        .panelCard()
        .onChange(of: state.searchText) { _, _ in state.clampSelection() }
        .onChange(of: state.focusSearch) { _, v in
            if v { searchFocused = true; state.focusSearch = false }
        }
    }

    // MARK: Flat, accordion-style list

    private var list: some View {
        let groups = state.filteredGroups
        return Group {
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { gi, group in
                            groupRows(group, groupIndex: gi)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.3, bounce: 0.22), value: state.groupIndex)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No matching windows")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Renders one app's contribution to the list: either a single collapsed
    /// summary row, or — for the group with keyboard focus, when it has more
    /// than one window — a header row plus one row per window.
    @ViewBuilder
    private func groupRows(_ group: CommandPaletteState.AppGroup, groupIndex gi: Int) -> some View {
        let isActive = gi == state.groupIndex
        if group.windows.count > 1 && isActive {
            header(group)
            ForEach(Array(group.windows.enumerated()), id: \.element.id) { ri, window in
                row(icon: .window(window), title: "\(group.appName) - \(window.windowTitle)",
                    subtitle: nil, selected: ri == state.rowIndex)
                    .onTapGesture {
                        state.groupIndex = gi
                        state.rowIndex = ri
                        onPick(window)
                    }
            }
        } else if let first = group.windows.first {
            let subtitle = group.windows.count > 1
                ? "\(group.windows.count) windows"
                : (first.windowTitle == group.appName ? nil : first.windowTitle)
            row(icon: .app(group.icon), title: group.appName, subtitle: subtitle, selected: isActive)
                .onTapGesture {
                    state.groupIndex = gi
                    state.rowIndex = 0
                    if group.windows.count > 1 {
                        // Ambiguous which window — expand instead of picking.
                    } else {
                        onPick(first)
                    }
                }
        }
    }

    private func header(_ group: CommandPaletteState.AppGroup) -> some View {
        HStack(spacing: 10) {
            if let icon = group.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            }
            Text(group.appName)
                .font(.system(size: 13, weight: .semibold))
            Text("\(group.windows.count) windows")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private enum RowIcon {
        case app(NSImage?)
        case window(WindowInfo)
    }

    private func row(icon: RowIcon, title: String, subtitle: String?, selected: Bool) -> some View {
        let fill: Color = selected ? PanelTheme.selectedFill : .clear
        let stroke: Color = selected ? PanelTheme.selectedStroke : .clear
        return HStack(spacing: 11) {
            rowIcon(icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(stroke, lineWidth: 1.5))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func rowIcon(_ icon: RowIcon) -> some View {
        switch icon {
        case .app(let image):
            if let image {
                Image(nsImage: image).resizable().frame(width: 24, height: 24)
            } else {
                Color.clear.frame(width: 24, height: 24)
            }
        case .window(let window):
            WindowRowIcon(window: window)
        }
    }

    // MARK: Footer hint

    private var footer: some View {
        HStack(spacing: 14) {
            KeyHint(key: "↑↓", label: "Navigate")
            KeyHint(key: "↩", label: "Focus")
            KeyHint(key: "esc", label: "Close")
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Per-window row icon

/// A small live thumbnail for one specific window row, captured
/// asynchronously via `WindowThumbnailService`. Falls back to the app icon
/// until it resolves (or forever, if Screen Recording permission isn't granted).
private struct WindowRowIcon: View {
    let window: WindowInfo
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if let icon = window.icon {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
        }
        .frame(width: 24, height: 24)
        .clipped()
        .task(id: window.windowID) {
            thumbnail = await WindowThumbnailService.thumbnail(
                for: window.windowID, maxSize: CGSize(width: 96, height: 96)
            )
        }
    }
}
