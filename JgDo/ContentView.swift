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

// MARK: - Design tokens (theme-adaptive, minimal)

private enum Theme {
    // Semantic, opacity-based on `primary` so they invert with Light/Dark.
    static let track      = Color.primary.opacity(0.10)
    static let accent     = Color.accentColor      // the user's system accent
    static let divider    = Color.primary.opacity(0.08)
    static let cardFill   = Color.primary.opacity(0.04)
    static let cardStroke = Color.primary.opacity(0.08)
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

struct StatusPopoverView: View {
    @State private var monitor = SystemMonitor.shared
    @State private var focus = FocusModeService.shared
    @State private var storage = StorageBreakdownService.shared
    @State private var showStorageBreakdown = false
    @AppStorage(AppSettings.edgeGapKey) private var edgeGap: Double = 8
    @AppStorage(AppSettings.cleaningDurationKey) private var cleaningDuration: Int = 60
    @AppStorage("popoverTab") private var tab: PopoverTab = .overview
    @Environment(\.dismissPopover) private var dismissPopover

    var body: some View {
        VStack(spacing: 9) {
            iconToolbar
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader
                ScrollView {
                    card
                }
            }
            footer
        }
        .padding(11)
        .frame(width: 288, height: 400)
        .background(.regularMaterial)
    }

    // MARK: Icon toolbar (section switcher, pill container)

    private var iconToolbar: some View {
        HStack(spacing: 4) {
            ForEach(PopoverTab.allCases) { t in
                Button(action: { withAnimation(.spring(duration: 0.2)) { tab = t } }) {
                    Image(systemName: t.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tab == t ? .white : .secondary)
                        .frame(width: 28, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(tab == t ? Color.accentColor : Color.clear)
                        )
                }
                .buttonStyle(.plain)
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

    // MARK: Section header (uppercase caption + quick settings shortcut)

    private var sectionHeader: some View {
        HStack {
            Text(tab.label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                dismissPopover()
                SettingsWindow.show()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    // MARK: Card (rounded container, hairline-divided rows — replaces the tab content)

    private var card: some View {
        VStack(spacing: 0) {
            switch tab {
            case .overview:
                ringGrid
                rowDivider
                quickActionsRow
                rowDivider
                Text("HARDWARE USAGE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.top, 8)
                    .padding(.bottom, 1)
                sparkMetricRow(icon: "cpu", label: "CPU",
                                percent: monitor.status.cpuPercent / 100,
                                color: Theme.accent, history: monitor.cpuHistory)
                rowDivider
                sparkMetricRow(icon: "memorychip", label: "Memory",
                                percent: monitor.status.memPercent,
                                color: Theme.accent, history: monitor.memHistory)
                rowDivider
                sparkMetricRow(icon: "internaldrive", label: "Disk",
                                percent: monitor.status.diskPercent,
                                color: Theme.accent, history: monitor.diskHistory)
                if monitor.status.hasBattery {
                    rowDivider
                    batteryRow(monitor.status)
                }
                rowDivider
                MonitorControlsTile()
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                rowDivider
                cleaningRow
            case .system:
                cpuTile(monitor.status).cardRowPadding()
                rowDivider
                memoryTile(monitor.status).cardRowPadding()
                rowDivider
                diskTile(monitor.status).cardRowPadding()
                rowDivider
                networkTile(monitor.status).cardRowPadding()
            case .productivity:
                WorkspacesTile().cardRowPadding()
                rowDivider
                LayoutPresetsTile().cardRowPadding()
                rowDivider
                ParkedWindowsTile().cardRowPadding()
                rowDivider
                SnapGroupsTile().cardRowPadding()
                rowDivider
                InsightsTile().cardRowPadding()
                rowDivider
                windowGapTile.cardRowPadding()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1)
        )
    }

    private var rowDivider: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
            .padding(.horizontal, 14)
    }

    // MARK: Overview — quick-stat ring gauges

    private var ringGrid: some View {
        HStack(spacing: 0) {
            ringGauge(label: "CPU", percent: monitor.status.cpuPercent / 100, color: Theme.accent)
            ringGauge(label: "Memory", percent: monitor.status.memPercent, color: Theme.accent)
            ringGauge(label: "Disk", percent: monitor.status.diskPercent, color: Theme.accent)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 12)
    }

    private func ringGauge(label: String, percent: Double, color: Color) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Theme.track, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(max(percent, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.45), value: percent)
                Text(String(format: "%.0f", percent * 100))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .frame(width: 48, height: 48)
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Overview — quick actions row

    private var quickActionsRow: some View {
        HStack(spacing: 8) {
            quickActionButton(icon: "rectangle.stack", label: "Focus",
                               active: focus.isActive) {
                focus.toggle()
            }
            quickActionButton(icon: "eye.slash", label: "Park") {
                AppDelegate.shared?.parkFrontmostWindow()
            }
            quickActionButton(icon: "square.grid.2x2", label: "Organize") {
                dismissPopover()
                AppDelegate.shared?.toggleOrganizeWorkspace()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }

    private func quickActionButton(icon: String, label: String, active: Bool = false,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(active ? .white : .primary)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(active ? .white : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Theme.accent : Color.primary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: Overview — bar + sparkline row

    private func sparkMetricRow(icon: String, label: String, percent: Double, color: Color, history: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(String(format: "%.0f%%", percent * 100))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ColoredBar(progress: percent, color: color)
            Sparkline(values: history, color: color)
                .frame(height: 18)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    private func batteryRow(_ s: SystemStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: s.isCharging ? "bolt.fill" : "battery.75")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 14)
                Text("Battery")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(s.batteryPercent)%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ColoredBar(progress: Double(s.batteryPercent) / 100, color: Theme.accent)
            HStack(spacing: 6) {
                Text(s.isCharging ? "Charging" : "On battery")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                if s.batteryMinutesRemain > 0 {
                    let h = s.batteryMinutesRemain / 60, m = s.batteryMinutesRemain % 60
                    Text(h > 0 ? "~\(h)h \(m)m left" : "~\(m)m left")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }

    private var cleaningRow: some View {
        Button {
            dismissPopover()
            // Let the popover fade out before the lock overlay appears.
            let duration = cleaningDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                CleaningModeController.shared.start(duration: max(duration, 15))
            }
        } label: {
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
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    // MARK: Window gap setting

    private var windowGapTile: some View {
        MetricTile(icon: "rectangle.split.2x1", title: "Window Gap",
                   value: edgeGap == 0 ? "Off" : "\(Int(edgeGap)) pt",
                   progress: nil) {
            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $edgeGap, in: AppSettings.edgeGapRange, step: 1)
                    .tint(Color.accentColor)
                Text("Padding around screen edges and between snapped windows.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 16) {
                    ioStat(icon: "arrow.down", label: "Read", value: s.diskReadSpeed.asSpeed())
                    ioStat(icon: "arrow.up", label: "Write", value: s.diskWriteSpeed.asSpeed())
                    Spacer()
                    Button {
                        withAnimation(.spring(duration: 0.25)) { showStorageBreakdown.toggle() }
                        if showStorageBreakdown && storage.categories.isEmpty { storage.scan() }
                    } label: {
                        Image(systemName: showStorageBreakdown ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("What's using space")
                }
                if showStorageBreakdown {
                    storageBreakdownList
                }
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
                Text("Tap to scan common folders (Applications, Documents, Downloads, Pictures, Movies, Music).")
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

    private func networkTile(_ s: SystemStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                netColumn(icon: "arrow.down", label: "DOWNLOAD", value: s.netDownSpeed.asSpeed())
                Rectangle().fill(Theme.divider).frame(width: 1, height: 26)
                netColumn(icon: "arrow.up", label: "UPLOAD", value: s.netUpSpeed.asSpeed())
            }
            if !s.netInterfaces.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(s.netInterfaces) { iface in
                        interfaceRow(iface)
                    }
                }
            }
        }
        .padding(.vertical, 5)
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

    // MARK: Footer — uptime strip + full-width pill action buttons

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                InfoChip(icon: "clock", text: uptimeString)
                InfoChip(icon: "apple.logo", text: osVersion)
                Spacer()
            }
            HStack(spacing: 6) {
                pillButton(icon: "gearshape", label: "Settings") {
                    dismissPopover()
                    SettingsWindow.show()
                }
                pillButton(icon: "power", label: "Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }

    private func pillButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(label).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(label)
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

// MARK: - Metric tile shell (flat row, hairline divider — no boxes)

struct MetricTile<Detail: View>: View {
    let icon: String
    let title: String
    let value: String
    let progress: Double?
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let progress {
                AccentBar(progress: progress)
            }
            detail()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Reusable pieces

struct AccentBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(geo.size.width * min(max(progress, 0), 1), 3))
                    .animation(.easeInOut(duration: 0.45), value: progress)
            }
        }
        .frame(height: 4)
    }
}

/// Same as `AccentBar` but with a caller-supplied color, for the dashboard's
/// per-metric hues (CPU orange, Memory blue, …) instead of the system accent.
struct ColoredBar: View {
    let progress: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color)
                    .frame(width: max(geo.size.width * min(max(progress, 0), 1), 3))
                    .animation(.easeInOut(duration: 0.45), value: progress)
            }
        }
        .frame(height: 4)
    }
}

/// Minimal line-chart sparkline over a rolling window of 0...1 samples.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                let w = geo.size.width, h = geo.size.height
                let stepX = w / CGFloat(values.count - 1)
                Path { path in
                    for (i, v) in values.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = h - CGFloat(min(max(v, 0), 1)) * h
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Consistent horizontal/vertical insets for rows dropped straight into
/// `StatusPopoverView.card` (the System/Workspace tabs, which reuse the
/// pre-existing detail tiles rather than the Overview tab's custom rows).
extension View {
    func cardRowPadding() -> some View {
        self.padding(.horizontal, 11).padding(.vertical, 7)
    }
}

struct InfoChip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .medium))
            Text(text).font(.system(size: 9.5, design: .monospaced))
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Per-core CPU bars (accent)

struct CoreBarsView: View {
    let cores: [Double]
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, usage in
                CoreBarView(usage: usage)
            }
        }
        .frame(height: 16)
    }
}

struct CoreBarView: View {
    let usage: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.track)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(height: max(geo.size.height * min(usage / 100, 1), 2))
                    .animation(.easeInOut(duration: 0.4), value: usage)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Stacked memory bar (accent shades)

struct StackedMemBar: View {
    let app: UInt64; let wired: UInt64
    let compressed: UInt64; let cached: UInt64
    let total: UInt64

    var body: some View {
        GeometryReader { geo in
            let t = max(Double(total), 1)
            let w = geo.size.width
            HStack(spacing: 1) {
                seg(width: w * Double(app) / t,        opacity: 1.0)
                seg(width: w * Double(wired) / t,      opacity: 0.6)
                seg(width: w * Double(compressed) / t, opacity: 0.35)
                seg(width: w * Double(cached) / t,     opacity: 0.18)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .background(Capsule().fill(Theme.track))
    }

    private func seg(width: Double, opacity: Double) -> some View {
        Rectangle().fill(Theme.accent.opacity(opacity)).frame(width: max(width, 0))
    }
}

// MARK: - Memory legend dot (accent shades)

struct MemLegendDot: View {
    let opacity: Double
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Theme.accent.opacity(opacity)).frame(width: 5, height: 5)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
