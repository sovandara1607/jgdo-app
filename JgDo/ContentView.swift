import SwiftUI
import AppKit

// MARK: - Design tokens (theme-adaptive, minimal)
//
// Internal (not file-private) since `PopoverTileComponents.swift`'s
// reusable bars/sparklines use these tokens too.
enum Theme {
    // Semantic, opacity-based on `primary` so they invert with Light/Dark.
    static let track      = Color.primary.opacity(0.10)
    static let accent     = Color.accentColor      // the user's system accent
    static let divider    = Color.primary.opacity(0.08)
    static let cardFill   = Color.primary.opacity(0.04)
    static let cardStroke = Color.primary.opacity(0.08)
}

/// Shared animation durations — three speeds, used consistently instead of
/// picking a new number at every call site. Reduce Motion isn't baked in
/// here (each call site already reads `@Environment(\.accessibilityReduceMotion)`
/// and either passes `nil`/a short opacity-only fade or skips the modifier
/// entirely) — these are just the "motion is on" values.
enum Motion {
    /// Hover, press, small icon transitions.
    static let fast = Animation.easeOut(duration: 0.12)
    /// Tab switching, row expansion, section changes.
    static let normal = Animation.easeOut(duration: 0.16)
    /// Metric progress, workspace state changes, larger geometry.
    static let slow = Animation.easeOut(duration: 0.24)
    /// The sliding tab-selection capsule — the one place a spring reads
    /// better than a plain ease. Same response/damping family as
    /// `MenuBarPopoverPanel`'s window-level open spring, just expressed as
    /// a SwiftUI `Animation` instead of a `CASpringAnimation`.
    static let capsule = Animation.spring(response: 0.26, dampingFraction: 0.92)
    /// Reduce Motion's replacement for anything above — opacity-only, short.
    static let reduced = Animation.easeOut(duration: 0.1)
}

// MARK: - System Status popover root (native sidebar + list, à la System Settings)

/// Popover sections, shown as sidebar rows. The chosen section persists across opens.
private enum PopoverTab: String, CaseIterable, Identifiable, Hashable {
    case overview, system, productivity
    var id: Self { self }

    var label: String {
        switch self {
        case .overview:     return "Overview"
        case .system:       return "System"
        case .productivity: return "Workspace"
        }
    }

    var icon: String {
        switch self {
        case .overview:     return "square.grid.2x2"
        case .system:       return "gauge.with.dots.needle.67percent"
        case .productivity: return "rectangle.3.group"
        }
    }
}

// MARK: - Compact metric column (label, live value, thin bar)

/// One metric in the Overview tab's system-summary row — icon, label, a
/// live value, and a thin progress bar. Deliberately not a gauge/ring: a
/// decorative circle takes far more space to convey the same one number,
/// and this panel's job is a fast glance, not a dashboard. Tapping jumps to
/// the System tab for the full detail (per-core breakdown, memory
/// composition, charging state, …) — "glance, then act" extends to "glance,
/// then drill in" for whichever number actually caught your eye.
private struct CompactStat: View {
    let icon: String
    let label: String
    let value: String
    let progress: Double
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 8.5, weight: .semibold))
                    Text(label.uppercased())
                        .font(.system(size: 8.5, weight: .semibold))
                        .tracking(0.3)
                }
                .foregroundStyle(isHovering ? Color.accentColor : .secondary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: value)
                AccentBar(progress: progress)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help("See \(label) details")
        .onHover { hovering in
            guard !reduceMotion else { isHovering = hovering; return }
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityHint("Opens System details")
    }
}

// MARK: - Overview ring gauge (icon at rest, + percentage on hover)
//
// Still used by `MenuBarQuickPanel` (the right-click quick panel) — not
// part of this redesign, so kept as-is rather than removed.

/// One CPU/Memory/Disk ring in the Overview tab's quick-stat row. Shows just
/// its icon at rest; hovering adds the live percentage alongside it rather
/// than replacing it — a plain `func` helper can't hold its own `@State`, so
/// this needs to be its own `View` to track hover per-gauge.
struct RingGauge: View {
    let icon: String
    let label: String
    let percent: Double
    let color: Color

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Theme.track, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(max(percent, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: percent)
                VStack(spacing: 1) {
                    Image(systemName: icon)
                        .font(.system(size: isHovering ? 12 : 15, weight: .medium))
                        .foregroundStyle(isHovering ? .secondary : .primary)
                    if isHovering {
                        Text(String(format: "%.0f", percent * 100))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: percent)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: isHovering)
            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
            .onHover { hovering in
                isHovering = hovering
            }
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((percent * 100).rounded())) percent")
    }
}

// MARK: - Hoverable action buttons (icon toolbar, Overview row, footer)

/// One tab in `iconToolbar`'s pill switcher. Unselected tabs get a faint
/// background tint on hover instead of staying totally inert — a small
/// "this is clickable" cue that was previously entirely absent between
/// "not hovering" and "selected". The selection fill itself is a single
/// shape shared across all three buttons via `matchedGeometryEffect` — it
/// slides between them on tab change instead of one background disappearing
/// while another pops in.
private struct TabIconButton: View {
    let icon: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 28, height: 24)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "tabSelection", in: namespace)
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard !reduceMotion else { isHovering = hovering; return }
            withAnimation(Motion.fast) { isHovering = hovering }
        }
    }
}

/// The Overview tab's Focus/Park/Organize row. A `struct` (like `RingGauge`
/// above) rather than a plain function, purely so it can hold its own
/// hover `@State` — a `func` returning `some View` can't.
/// A small icon (settings gear, overflow ellipsis, …) with the same subtle
/// hover language as everything else in this panel — a faint round material
/// background plus a touch of scale (~1.03), never a rotate/spin. Used as
/// the label for both a plain `Button` and a `Menu`, since neither cares
/// what view it's given.
private struct HoverIconLabel: View {
    let icon: String
    var size: CGFloat = 11

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.secondary)
            .scaleEffect(isHovering && !reduceMotion ? 1.03 : 1)
            .padding(5)
            .background(Circle().fill(Color.primary.opacity(isHovering ? 0.08 : 0)))
            .onHover { hovering in
                guard !reduceMotion else { isHovering = hovering; return }
                withAnimation(Motion.fast) { isHovering = hovering }
            }
    }
}

/// The Overview→System "Keyboard Cleaning" action row. On hover, the row
/// brightens slightly and the chevron nudges 2pt to the right — the same
/// "this is clickable" cue as `TabIconButton`, scaled down for a text row.
private struct CleaningRow: View {
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "bubbles.and.sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keyboard Cleaning")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Locks the keyboard so you can wipe it down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isHovering ? .secondary : .tertiary)
                    .offset(x: isHovering ? 2 : 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.04 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard !reduceMotion else { isHovering = hovering; return }
            withAnimation(Motion.fast) { isHovering = hovering }
        }
    }
}

private struct QuickActionButton: View {
    let icon: String
    let label: String
    var active: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? .white : .primary)
                    // Only the icon moves, and only a touch — the brief is
                    // explicit that whole rows shouldn't scale on hover.
                    .scaleEffect(isHovering && !active ? 1.05 : 1)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(active ? .white : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Theme.accent : Color.primary.opacity(isHovering ? 0.09 : 0.05))
            )
        }
        .buttonStyle(PressableButtonStyle())
        .help(label)
        .onHover { hovering in
            guard !reduceMotion else { isHovering = hovering; return }
            withAnimation(Motion.fast) { isHovering = hovering }
        }
    }
}

struct StatusPopoverView: View {
    @State private var monitor = SystemMonitor.shared
    @State private var focus = FocusModeService.shared
    @State private var storage = StorageBreakdownService.shared
    @State private var showStorageBreakdown = false
    @State private var showAdvancedInterfaces = false
    @AppStorage(AppSettings.cleaningDurationKey) private var cleaningDuration: Int = 60
    @AppStorage("popoverTab") private var tab: PopoverTab = .overview
    @Environment(\.dismissPopover) private var dismissPopover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shared identity for the sliding tab-selection capsule
    /// (`TabIconButton`'s `matchedGeometryEffect`) — one namespace so
    /// SwiftUI can animate the same shape moving between buttons instead of
    /// cross-fading two independent ones.
    @Namespace private var tabNamespace
    /// +1 when moving right through tab order (Overview → System →
    /// Workspace), -1 moving left — read by `card`'s content transition so
    /// the slide direction matches which way the user actually navigated.
    @State private var tabDirection: CGFloat = 1
    /// Flips true once, right after the panel finishes laying out — drives
    /// `card`'s/`footer`'s `.staggeredAppear` cascade. `MenuBarPopoverPanel`
    /// hands this view a fresh `NSHostingController` on every open, so this
    /// resets to `false` automatically each time rather than needing to be
    /// reset by hand.
    @State private var contentAppeared = false

    var body: some View {
        VStack(spacing: 9) {
            iconToolbar
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader
                // `showsIndicators: false` here (rather than the trailing
                // `.scrollIndicators(.hidden)` modifier) is what actually
                // stops SwiftUI reserving a scrollbar gutter down the right
                // edge — the modifier only hid the indicator visually and
                // left the reserved space behind as a gap.
                ScrollView(.vertical, showsIndicators: false) {
                    card
                        .background(ScrollbarHider())
                }
            }
            footer
                .staggeredAppear(4, appeared: $contentAppeared)
        }
        .padding(11)
        .frame(width: 288, height: 400)
        .glassPopoverCard()
        .onAppear { contentAppeared = true }
    }

    // MARK: Icon toolbar (section switcher, pill container)

    private var iconToolbar: some View {
        HStack(spacing: 4) {
            ForEach(PopoverTab.allCases) { t in
                TabIconButton(icon: t.icon, isSelected: tab == t, namespace: tabNamespace) {
                    switchTab(to: t)
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.cardStroke, lineWidth: 1)
        )
    }

    /// Records which way the user is navigating (for `card`'s directional
    /// content slide) and commits the tab change under one shared
    /// animation — the sliding selection capsule and the content crossfade
    /// both ride this same transaction, so they visibly settle together.
    private func switchTab(to newTab: PopoverTab) {
        let order = PopoverTab.allCases
        if let oldIndex = order.firstIndex(of: tab), let newIndex = order.firstIndex(of: newTab) {
            tabDirection = newIndex >= oldIndex ? 1 : -1
        }
        withAnimation(reduceMotion ? Motion.reduced : Motion.normal) { tab = newTab }
    }

    // MARK: Section header (uppercase caption + quick settings shortcut)

    private var sectionHeader: some View {
        HStack {
            // Old label lifts + fades out, new one enters from just below —
            // same idea as switching between named workspaces, applied to
            // the one piece of the popover that actually changes title:
            // the tab switcher. `.id(tab)` is what makes SwiftUI treat this
            // as a genuine identity change (old view removed, new one
            // inserted) rather than an in-place text mutation, which is
            // what makes the transition apply at all.
            Text(tab.label.uppercased())
                .id(tab)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            Spacer()
            Button {
                dismissPopover()
                SettingsWindow.show()
            } label: {
                HoverIconLabel(icon: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }

    // MARK: Card (rounded container, hairline-divided rows — replaces the tab content)

    private var card: some View {
        VStack(spacing: 0) {
            tabContent
                // A genuine identity change (not an in-place mutation) is
                // what makes SwiftUI treat this as removal+insertion rather
                // than diffing individual rows across two unrelated tabs —
                // same technique `sectionHeader`'s title already uses.
                // Scoped to just the rows, not the card's own background/
                // border below, so the container itself never re-fades —
                // only its contents cross-slide.
                .id(tab)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 4 * tabDirection)),
                    removal: .opacity.combined(with: .offset(x: -4 * tabDirection))
                ))
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1)
        )
        // Clipped so the ±4pt slide never peeks past the card's own rounded
        // corners mid-transition.
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var tabContent: some View {
        VStack(spacing: 0) {
            switch tab {
            case .overview:
                // Quick Actions first — this is a window-management utility,
                // not a system monitor, so the thing you can *do* leads.
                quickActionsRow
                    .staggeredAppear(0, appeared: $contentAppeared)
                summaryRow
                    .staggeredAppear(1, appeared: $contentAppeared)
                rowDivider
                activitySection
                    .staggeredAppear(2, appeared: $contentAppeared)
            case .system:
                cpuTile(monitor.status).cardRowPadding()
                    .staggeredAppear(0, appeared: $contentAppeared)
                rowDivider
                memoryTile(monitor.status).cardRowPadding()
                    .staggeredAppear(1, appeared: $contentAppeared)
                rowDivider
                diskTile(monitor.status).cardRowPadding()
                    .staggeredAppear(2, appeared: $contentAppeared)
                rowDivider
                networkTile(monitor.status).cardRowPadding()
                    .staggeredAppear(3, appeared: $contentAppeared)
                if monitor.status.hasBattery {
                    rowDivider
                    batteryTile(monitor.status).cardRowPadding()
                        .staggeredAppear(3, appeared: $contentAppeared)
                }
                rowDivider
                MonitorControlsTile()
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .staggeredAppear(4, appeared: $contentAppeared)
                rowDivider
                cleaningRow
                    .staggeredAppear(4, appeared: $contentAppeared)
            case .productivity:
                // Current workspace + Smart Layouts + Focus Today lead —
                // this is a workspace manager, not a settings sheet, so the
                // "what am I working on" content comes before the more
                // occasional utility tiles below it.
                WorkspacesTile().cardRowPadding()
                    .staggeredAppear(0, appeared: $contentAppeared)
                rowDivider
                SmartLayoutsTile().cardRowPadding()
                    .staggeredAppear(1, appeared: $contentAppeared)
                rowDivider
                InsightsTile().cardRowPadding()
                    .staggeredAppear(2, appeared: $contentAppeared)
                rowDivider
                LayoutPresetsTile().cardRowPadding()
                    .staggeredAppear(3, appeared: $contentAppeared)
                rowDivider
                ParkedWindowsTile().cardRowPadding()
                    .staggeredAppear(3, appeared: $contentAppeared)
                rowDivider
                SnapGroupsTile().cardRowPadding()
                    .staggeredAppear(3, appeared: $contentAppeared)
            }
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
            .padding(.horizontal, 14)
    }

    // MARK: Overview — quick actions row

    private var quickActionsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionCaption("Quick Actions")
            HStack(spacing: 8) {
                QuickActionButton(icon: "rectangle.stack", label: "Focus", active: focus.isActive) {
                    focus.toggle()
                }
                QuickActionButton(icon: "eye.slash", label: "Park") {
                    AppDelegate.shared?.parkFrontmostWindow()
                }
                QuickActionButton(icon: "square.grid.2x2", label: "Organize") {
                    dismissPopover()
                    AppDelegate.shared?.toggleOrganizeWorkspace()
                }
                QuickActionButton(icon: "rectangle.split.2x2", label: "Layouts") {
                    dismissPopover()
                    AppDelegate.shared?.toggleLayoutPicker()
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 9)
        .padding(.bottom, 4)
    }

    // MARK: Overview — compact system summary (replaces the old ring gauges)
    //
    // Same three metrics the rings showed, at a fraction of the height:
    // a label, a live value, and a thin bar — scannable in one glance
    // instead of three decorative circles. Tapping any of them jumps to
    // the System tab, where the full detail (per-core, memory breakdown,
    // charging state, …) lives.

    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionCaption("System")
            HStack(alignment: .top, spacing: 16) {
                CompactStat(icon: "cpu", label: "CPU", value: String(format: "%.0f%%", monitor.status.cpuPercent),
                            progress: monitor.status.cpuPercent / 100, action: goToSystemTab)
                CompactStat(icon: "memorychip", label: "Memory",
                            value: String(format: "%.0f%%", monitor.status.memPercent * 100),
                            progress: monitor.status.memPercent, action: goToSystemTab)
                if monitor.status.hasBattery {
                    CompactStat(icon: monitor.status.isCharging ? "bolt.fill" : "battery.100",
                                label: "Battery", value: "\(monitor.status.batteryPercent)%",
                                progress: Double(monitor.status.batteryPercent) / 100, action: goToSystemTab)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
    }

    private func goToSystemTab() {
        withAnimation(.spring(duration: 0.2)) { tab = .system }
    }

    // MARK: Overview — activity (CPU trend + network only; everything else
    // moved to the System tab so Overview stays a glance, not a dashboard)

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionCaption("Activity")
            HStack(spacing: 8) {
                Text("CPU")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)
                Sparkline(values: monitor.cpuHistory, color: Theme.accent)
                    .frame(height: 16)
            }
            HStack(spacing: 6) {
                Text("Network")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("↓\(monitor.status.netDownSpeed.asSpeed())")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("↑\(monitor.status.netUpSpeed.asSpeed())")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    /// Small uppercase section label — used sparingly now that whitespace
    /// does most of the grouping work dividers used to.
    private func sectionCaption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
    }

    private var cleaningRow: some View {
        CleaningRow {
            dismissPopover()
            // Let the popover fade out before the lock overlay appears.
            let duration = cleaningDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                CleaningModeController.shared.start(duration: max(duration, 15))
            }
        }
    }

    // MARK: CPU tile

    private func cpuTile(_ s: SystemStatus) -> some View {
        MetricTile(icon: "cpu", title: "Processor",
                   value: String(format: "%.1f%%", s.cpuPercent),
                   progress: s.cpuPercent / 100) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    MemLegendDot(opacity: 1.0,  label: String(format: "User %.1f%%", s.cpuUser))
                    MemLegendDot(opacity: 0.45, label: String(format: "System %.1f%%", s.cpuSystem))
                    Spacer()
                }
                if !s.cpuPerCore.isEmpty {
                    CoreBarsView(cores: s.cpuPerCore)
                    Text("\(s.cpuPerCore.count) cores")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Memory tile

    private func memoryTile(_ s: SystemStatus) -> some View {
        MetricTile(icon: "memorychip", title: "Memory",
                   value: "\(s.memUsed.asGB) / \(s.memTotal.asGB)",
                   progress: nil) {
            VStack(alignment: .leading, spacing: 7) {
                StackedMemBar(app: s.memApp, wired: s.memWired,
                              compressed: s.memCompressed, cached: s.memCached,
                              total: s.memTotal)
                HStack(spacing: 10) {
                    MemLegendDot(opacity: 1.0,  label: "App \(s.memApp.asGB)")
                    MemLegendDot(opacity: 0.6,  label: "Wired \(s.memWired.asGB)")
                    MemLegendDot(opacity: 0.35, label: "Comp \(s.memCompressed.asGB)")
                    Spacer()
                }
                if s.swapTotal > 0 {
                    Text("Swap  \(s.swapUsed.asMB) / \(s.swapTotal.asGB)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Disk tile

    private func diskTile(_ s: SystemStatus) -> some View {
        MetricTile(icon: "internaldrive", title: "Storage",
                   value: "\(s.diskUsed.asGB) / \(s.diskTotal.asGB)",
                   progress: s.diskPercent) {
            // `DisclosureGroup` for the same reason as the Network tab's
            // "Advanced Interfaces" — the native chevron rotation + height
            // expand come for free instead of a hand-rolled toggle/spring.
            DisclosureGroup(isExpanded: $showStorageBreakdown) {
                storageBreakdownList
            } label: {
                HStack(spacing: 16) {
                    ioStat(icon: "arrow.down", label: "Read", value: s.diskReadSpeed.asSpeed())
                    ioStat(icon: "arrow.up", label: "Write", value: s.diskWriteSpeed.asSpeed())
                }
            }
            .accessibilityLabel("What's using space")
            .onChange(of: showStorageBreakdown) { _, expanded in
                if expanded && storage.categories.isEmpty { storage.scan() }
            }
        }
    }

    private var storageBreakdownList: some View {
        VStack(alignment: .leading, spacing: 5) {
            if storage.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            } else if storage.categories.isEmpty {
                Text("Tap to scan common folders.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let maxSize = storage.categories.map(\.sizeBytes).max() ?? 1
                ForEach(storage.categories) { category in
                    storageRow(category, maxSize: maxSize)
                }
            }
        }
        .padding(.top, 2)
    }

    private func storageRow(_ category: StorageCategory, maxSize: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(category.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(UInt64(category.sizeBytes).asGB)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(Theme.accent)
                        .frame(width: max(geo.size.width * CGFloat(category.sizeBytes) / CGFloat(max(maxSize, 1)), 2))
                }
            }
            .frame(height: 4)
        }
    }

    private func ioStat(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(value).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Network tile

    /// `displayName == bsdName` means `SCNetworkInterface` had no friendly
    /// name for it — reliably true for the virtual/tunnel interfaces
    /// (utun*, llw0, awdl0, …) that would otherwise clutter this list, and
    /// reliably false for anything a user would recognize (Wi-Fi, USB
    /// Ethernet, Thunderbolt Bridge, …). No hardcoded name list to maintain.
    private func isAdvancedInterface(_ iface: NetworkInterfaceStat) -> Bool {
        iface.displayName == iface.bsdName
    }

    private func networkTile(_ s: SystemStatus) -> some View {
        let primary = s.netInterfaces.filter { !isAdvancedInterface($0) }
        let advanced = s.netInterfaces.filter { isAdvancedInterface($0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                netColumn(icon: "arrow.down", label: "DOWNLOAD", value: s.netDownSpeed.asSpeed())
                Rectangle().fill(Theme.divider).frame(width: 1, height: 26)
                netColumn(icon: "arrow.up", label: "UPLOAD", value: s.netUpSpeed.asSpeed())
            }
            if !primary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(primary) { iface in
                        interfaceRow(iface)
                    }
                }
            }
            if !advanced.isEmpty {
                advancedInterfacesDisclosure(advanced)
            }
        }
        .padding(.vertical, 5)
    }

    private func advancedInterfacesDisclosure(_ interfaces: [NetworkInterfaceStat]) -> some View {
        DisclosureGroup(isExpanded: $showAdvancedInterfaces) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(interfaces) { iface in
                    interfaceRow(iface)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Advanced Interfaces")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .accessibilityLabel("Advanced network interfaces, \(interfaces.count)")
    }

    private func interfaceRow(_ iface: NetworkInterfaceStat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iface.displayName.localizedCaseInsensitiveContains("wi-fi") ? "wifi" : "cable.connector")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Text(iface.displayName)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("↓\(iface.downSpeed.asSpeed())")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text("↑\(iface.upSpeed.asSpeed())")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func netColumn(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold)).tracking(0.4)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Battery tile

    private func batteryTile(_ s: SystemStatus) -> some View {
        let icon = s.isCharging ? "bolt.fill"
            : (s.batteryPercent < 20 ? "battery.25" : "battery.75")
        return MetricTile(icon: icon, title: "Battery",
                          value: "\(s.batteryPercent)%",
                          progress: Double(s.batteryPercent) / 100) {
            HStack(spacing: 6) {
                Text(s.isCharging ? "Charging" : "On battery")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if s.batteryMinutesRemain > 0 {
                    let h = s.batteryMinutesRemain / 60, m = s.batteryMinutesRemain % 60
                    Text(h > 0 ? "~\(h)h \(m)m left" : "~\(m)m left")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Footer — a single status strip, not a second row of buttons
    //
    // Settings already has its own top-right gear in `sectionHeader`, so
    // the footer doesn't need to repeat it — Quit is the only thing left
    // that needs a home, tucked into an overflow menu instead of a
    // full-width pill sitting at the same visual weight as a primary
    // JgDo action.

    private var footer: some View {
        HStack(spacing: 8) {
            InfoChip(icon: "clock", text: uptimeString)
            InfoChip(icon: "apple.logo", text: osVersion)
            Spacer()
            Menu {
                Button("Settings…") {
                    dismissPopover()
                    SettingsWindow.show()
                }
                Divider()
                Button("Quit JgDo") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                HoverIconLabel(icon: "ellipsis.circle", size: 13)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More options")
        }
    }

    // MARK: Derived strings

    private var osVersion: String {
        "macOS " + (ProcessInfo.processInfo.operatingSystemVersionString
            .replacingOccurrences(of: "Version ", with: "")
            .components(separatedBy: " (").first ?? "")
    }

    private var uptimeString: String {
        let s = Int(ProcessInfo.processInfo.systemUptime)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        return d > 0 ? "\(d)d \(h)h \(m)m" : String(format: "%dh %02dm", h, m)
    }
}
