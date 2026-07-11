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
        VStack(spacing: 12) {
            // Navigation keys (↑↓/Return/Esc) are handled by the AppDelegate's
            // local key monitor; the field only handles typing.
            PanelSearchField(icon: "magnifyingglass",
                             placeholder: "Search apps…",
                             text: $s.searchText,
                             focused: $searchFocused)
            list
            footer
        }
        .padding(16)
        .frame(width: 460)
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
        VStack(spacing: 4) {
            if rows.isEmpty {
                Text("No matching apps")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
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
        return HStack(spacing: 11) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            Text(app.localizedName ?? "—")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1.5)
        )
    }

    // MARK: Footer hint

    private var footer: some View {
        HStack(spacing: 14) {
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
}

// MARK: - System Status popover root (minimal dashboard)

/// Popover sections — one long tile stack was unusable, so content is split
/// into three scannable tabs. The chosen tab persists across opens.
private enum PopoverTab: String, CaseIterable {
    case overview, system, productivity

    var label: String {
        switch self {
        case .overview:     return "Overview"
        case .system:       return "System"
        case .productivity: return "Workspace"
        }
    }
}

struct StatusPopoverView: View {
    @State private var monitor = SystemMonitor.shared
    @AppStorage(AppSettings.edgeGapKey) private var edgeGap: Double = 8
    @AppStorage(AppSettings.cleaningDurationKey) private var cleaningDuration: Int = 60
    @AppStorage("popoverTab") private var tab: PopoverTab = .overview
    @Environment(\.dismissPopover) private var dismissPopover

    var body: some View {
        let s = monitor.status
        VStack(spacing: 8) {
            header
            sectionPicker
            ScrollView {
                VStack(spacing: 0) {
                    switch tab {
                    case .overview:
                        MetricTile(icon: "cpu", title: "CPU",
                                   value: String(format: "%.0f%%", s.cpuPercent),
                                   progress: s.cpuPercent / 100) { EmptyView() }
                        MetricTile(icon: "memorychip", title: "Memory",
                                   value: String(format: "%.0f%%", s.memPercent * 100),
                                   progress: s.memPercent) { EmptyView() }
                        MetricTile(icon: "internaldrive", title: "Disk",
                                   value: String(format: "%.0f%%", s.diskPercent * 100),
                                   progress: s.diskPercent) { EmptyView() }
                        MonitorControlsTile()
                        if s.hasBattery { batteryTile(s) }
                    case .system:
                        cpuTile(s)
                        memoryTile(s)
                        diskTile(s)
                        networkTile(s)
                    case .productivity:
                        WorkspacesTile()
                        InsightsTile()
                        windowGapTile
                    }
                }
            }
            .animation(.spring(duration: 0.3), value: tab)
            footer
        }
        .padding(14)
        .frame(width: 300, height: 440)
        .background(.regularMaterial)   // adapts to system Light/Dark
    }

    private var sectionPicker: some View {
        Picker("Section", selection: $tab) {
            ForEach(PopoverTab.allCases, id: \.self) { t in
                Text(t.label).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    // MARK: Window gap setting

    private var windowGapTile: some View {
        MetricTile(icon: "rectangle.split.2x1", title: "Window Gap",
                   value: edgeGap == 0 ? "Off" : "\(Int(edgeGap)) pt",
                   progress: nil) {
            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $edgeGap, in: AppSettings.edgeGapRange, step: 1)
                    .tint(Theme.accent)
                Text("Padding around screen edges and between snapped windows.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("System Status")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text(hostName)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
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
            HStack(spacing: 16) {
                ioStat(icon: "arrow.down", label: "Read", value: s.diskReadSpeed.asSpeed())
                ioStat(icon: "arrow.up", label: "Write", value: s.diskWriteSpeed.asSpeed())
                Spacer()
            }
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
        HStack(spacing: 0) {
            netColumn(icon: "arrow.down", label: "DOWNLOAD", value: s.netDownSpeed.asSpeed())
            Rectangle().fill(Theme.divider).frame(width: 1, height: 26)
            netColumn(icon: "arrow.up", label: "UPLOAD", value: s.netUpSpeed.asSpeed())
        }
        .padding(.vertical, 9)
        .overlay(Rectangle().fill(Theme.divider).frame(height: 1), alignment: .bottom)
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

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            InfoChip(icon: "clock", text: uptimeString)
            InfoChip(icon: "apple.logo", text: osVersion)
            Spacer()
            cleaningButton
            settingsButton
            quitButton
        }
        .padding(.top, 2)
    }

    private var cleaningButton: some View {
        Button {
            dismissPopover()
            // Let the popover fade out before the lock overlay appears.
            let duration = cleaningDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                CleaningModeController.shared.start(duration: max(duration, 15))
            }
        } label: {
            footerIcon("bubbles.and.sparkles")
        }
        .buttonStyle(.plain)
        .help("Keyboard cleaning mode — locks the keyboard")
    }

    private var settingsButton: some View {
        Button {
            dismissPopover()
            SettingsWindow.show()
        } label: {
            footerIcon("gearshape")
        }
        .buttonStyle(.plain)
        .help("Settings")
    }

    private func footerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
    }

    private var quitButton: some View {
        Button(action: { NSApp.terminate(nil) }) {
            HStack(spacing: 4) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
                Text("Quit")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q", modifiers: .command)
        .help("Quit JgDo (⌘Q)")
    }

    // MARK: Derived strings

    private var hostName: String {
        ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "Mac"
    }

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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let progress {
                AccentBar(progress: progress)
            }
            detail()
        }
        .padding(.vertical, 9)
        .overlay(Rectangle().fill(Theme.divider).frame(height: 1), alignment: .bottom)
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
