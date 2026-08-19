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

    private var lastWorkspaceName: String? { WorkspaceService.shared.workspaces.first?.name }
    private var recentClipboardItems: [ClipboardItem] { Array(clipboard.filteredItems.prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if system.status.hasBattery {
                batteryRow
            }
            networkRow
            divider

            if monitor.brightnessAvailable {
                sliderRow(icon: "sun.max.fill", value: Double(monitor.brightness)) {
                    monitor.setBrightness(Float($0))
                }
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
                    Slider(value: Binding(
                        get: { Double(monitor.isMuted ? 0 : monitor.volume) },
                        set: { monitor.setVolume(Float($0)) }
                    ), in: 0...1)
                }
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

    private func sliderRow(icon: String, value: Double, onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(value: Binding(get: { value }, set: onChange), in: 0...1)
        }
    }

    private func toggleRow(icon: String, title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
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
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
