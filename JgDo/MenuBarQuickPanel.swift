import SwiftUI
import AppKit
import SwiftData

/// Content of the menu bar's right-click quick panel — a real SwiftUI
/// popover (same `NSPopover` mechanism as the main status popover) rather
/// than a plain `NSMenu`, so it can host live sliders and reactive toggle
/// rows instead of static text items. Kept visually consistent with
/// `StatusPopoverView`'s tokens (frosted card, hairline dividers) without
/// pulling in that view's tab machinery — this is meant to be glanceable
/// and small.
struct MenuBarQuickPanel: View {
    let onOpenSettings: () -> Void
    let onRestoreWorkspace: () -> Void
    let onToggleAlwaysOnTop: () -> Void
    let onToggleWindowMemory: () -> Void
    let onPickClipboardItem: (ClipboardItem) -> Void
    let onQuit: () -> Void

    @State private var monitor = MonitorControlService.shared
    @State private var system = SystemMonitor.shared
    @State private var clipboard = ClipboardService.shared
    @State private var focus = FocusModeService.shared
    @State private var cleaning = CleaningModeController.shared
    @AppStorage(AppSettings.cleaningDurationKey) private var cleaningDuration: Int = 60
    @AppStorage(AppSettings.dashboardShowCPUKey) private var showCPU = true
    @AppStorage(AppSettings.dashboardShowMemoryKey) private var showMemory = true
    /// Keeps the sliders live while the panel is open, same as
    /// `MonitorControlsTile` — otherwise hardware volume/brightness keys
    /// pressed while this is open wouldn't be reflected until it's reopened.
    @State private var pollTimer: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lastWorkspaceName: String? { WorkspaceService.shared.workspaces.first?.name }
    private var recentClipboardItems: [ClipboardItem] { Array(clipboard.filteredItems.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showCPU || showMemory {
                performanceRow
                divider
            }
            if system.status.hasBattery {
                batteryRow
            }
            networkRow
            divider

            if monitor.brightnessAvailable {
                sliderRow(icon: "sun.max.fill", label: "Brightness", value: Double(monitor.brightness)) {
                    monitor.setBrightness(Float($0))
                }
                .animation(reduceMotion ? nil : .linear(duration: 0.1), value: monitor.brightness)
            }
            if monitor.volumeAvailable {
                HStack(spacing: 8) {
                    Button {
                        monitor.setMuted(!monitor.isMuted)
                    } label: {
                        Image(systemName: monitor.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .help(monitor.isMuted ? "Unmute" : "Mute")
                    .accessibilityLabel(monitor.isMuted ? "Unmute" : "Mute")
                    Slider(value: Binding(
                        get: { Double(monitor.isMuted ? 0 : monitor.volume) },
                        set: { monitor.setVolume(Float($0)) }
                    ), in: 0...1)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int((monitor.isMuted ? 0 : monitor.volume) * 100)) percent")
                }
                .animation(reduceMotion ? nil : .linear(duration: 0.1), value: monitor.volume)
            }
            if monitor.brightnessAvailable || monitor.volumeAvailable {
                divider
            }

            toggleRow(icon: "rectangle.stack", title: "Focus Mode", isOn: focus.isActive) {
                focus.toggle()
            }
            toggleRow(icon: "bubbles.and.sparkles", title: "Keyboard Cleaning", isOn: cleaning.isActive) {
                if cleaning.isActive { cleaning.stop() }
                else { cleaning.start(duration: max(cleaningDuration, 15)) }
            }
            actionRow(icon: "pin", title: "Toggle Always on Top", action: onToggleAlwaysOnTop)
            actionRow(icon: "pin.square", title: "Remember Window Position", action: onToggleWindowMemory)
            if let name = lastWorkspaceName {
                actionRow(icon: "square.grid.2x2", title: "Restore “\(name)”", action: onRestoreWorkspace)
            }

            if !recentClipboardItems.isEmpty {
                divider
                clipboardSection
            }

            divider
            HStack(spacing: 8) {
                quickButton(icon: "gearshape", label: "Settings", action: onOpenSettings)
                quickButton(icon: "power", label: "Quit", action: onQuit)
            }
        }
        .padding(12)
        .frame(width: 250)
        .glassPopoverCard()
        .onAppear {
            monitor.refresh()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                monitor.refresh()
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: Performance (Mini Dashboard)

    /// CPU/Memory at a glance — reuses `RingGauge`, the exact same compact
    /// gauge the main status popover's Overview tab already renders, so
    /// this doesn't introduce a second visual language for the same data.
    /// No new polling either: `SystemMonitor` is already sampling whenever
    /// this panel is open (`setQuickPanelVisible`, called by
    /// `AppDelegate.showQuickPanel()`) — these rows just read `system.status`.
    private var performanceRow: some View {
        // `spacing: 0` + each gauge's own `maxWidth: .infinity` (inside
        // `RingGauge`) splits the row evenly — same layout the main
        // popover's `ringGrid` uses for its (three-gauge) row.
        HStack(spacing: 0) {
            if showCPU {
                RingGauge(icon: "cpu", label: "CPU", percent: system.status.cpuPercent / 100, color: Theme.accent)
            }
            if showMemory {
                RingGauge(icon: "memorychip", label: "Memory", percent: system.status.memPercent, color: Theme.accent)
            }
        }
    }

    // MARK: Battery / Network

    private var batteryRow: some View {
        let s = system.status
        return HStack(spacing: 8) {
            Image(systemName: s.isCharging ? "bolt.fill" : "battery.75")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text("Battery")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            if s.batteryMinutesRemain > 0 {
                let h = s.batteryMinutesRemain / 60, m = s.batteryMinutesRemain % 60
                Text(h > 0 ? "~\(h)h \(m)m" : "~\(m)m")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Text("\(s.batteryPercent)%")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var networkRow: some View {
        let s = system.status
        return HStack(spacing: 14) {
            netStat(icon: "arrow.down", value: s.netDownSpeed.asSpeed())
            netStat(icon: "arrow.up", value: s.netUpSpeed.asSpeed())
            Spacer(minLength: 0)
        }
    }

    private func netStat(icon: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Clipboard preview

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CLIPBOARD")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            ForEach(recentClipboardItems, id: \.persistentModelID) { item in
                Button {
                    onPickClipboardItem(item)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: clipboardKindSymbol(item))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(item.kind == .image
                             ? (item.recognizedText?.isEmpty == false ? item.recognizedText! : "Image")
                             : (item.preview.isEmpty ? "—" : item.preview))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityHint("Pastes this clipboard item.")
            }
        }
    }

    private func clipboardKindSymbol(_ item: ClipboardItem) -> String {
        switch item.kind {
        case .text:  return "text.alignleft"
        case .image: return "photo"
        case .file:  return "doc"
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }

    private func sliderRow(icon: String, label: String, value: Double, onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { value }, set: onChange), in: 0...1)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(value * 100)) percent")
        }
    }

    private func toggleRow(icon: String, title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverRowFill()
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .hoverRowFill()
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private func quickButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(label).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .hoverRowFill(cornerRadius: 10, resting: 0.06, hover: 0.11)
        .help(label)
    }
}

// MARK: - Hover fill (menu-item background fades in on hover)

/// A background pill that fades in behind whatever it's applied to on
/// hover, rather than the row staying totally inert until clicked. Shared
/// by `toggleRow`/`actionRow` (fade from nothing) and `quickButton` (which
/// already has a resting fill — this just brightens it slightly instead).
private struct HoverRowFill: ViewModifier {
    var cornerRadius: CGFloat = 6
    var restingOpacity: Double = 0
    var hoverOpacity: Double = 0.06

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? hoverOpacity : restingOpacity))
            )
            .onHover { hovering in
                guard !reduceMotion else { isHovering = hovering; return }
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
    }
}

private extension View {
    func hoverRowFill(cornerRadius: CGFloat = 6, resting: Double = 0, hover: Double = 0.06) -> some View {
        modifier(HoverRowFill(cornerRadius: cornerRadius, restingOpacity: resting, hoverOpacity: hover))
    }
}
