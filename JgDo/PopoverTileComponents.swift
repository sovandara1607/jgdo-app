import SwiftUI

// MARK: - Metric tile shell (flat row, hairline divider — no boxes)

struct MetricTile<Detail: View>: View {
    let icon: String
    let title: String
    let value: String
    let progress: Double?
    @ViewBuilder let detail: () -> Detail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                // `.numericText()` reads the digits in `value` and animates
                // between old/new rather than snapping — cheap (no timer of
                // its own, just responds to `value` actually changing) and
                // works for any of this tile's callers' formats ("42%",
                // "3.2 GB / 16 GB", …) since it diffs character-by-character
                // rather than requiring a bound numeric type.
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: value)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(geo.size.width * min(max(progress, 0), 1), 3))
                    .animation(reduceMotion ? nil : Motion.slow, value: progress)
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
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

// MARK: - Press feedback

/// A quick, physical-feeling press-down for buttons that otherwise have no
/// feedback between "hover" and "the action already happened" — scales to
/// ~0.97 while the mouse is down and springs back on release. Kept under
/// the panel's own FAST tier (~120ms) so it never reads as sluggish.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(reduceMotion ? nil : Motion.fast, value: configuration.isPressed)
    }
}

// MARK: - Hoverable list row background

/// Subtle hover feedback for the Workspace tab's list rows (workspaces,
/// snap groups, layout presets, parked windows, smart-layout suggestions)
/// — a faint material tint that fades in over ~120ms, same hover language
/// as `TabIconButton`/`QuickActionButton` elsewhere in this panel, so a row
/// reads as clickable before you've actually clicked it.
private struct HoverRowBackground: ViewModifier {
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
            )
            .onHover { hovering in
                guard !reduceMotion else { isHovering = hovering; return }
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
    }
}

extension View {
    func hoverRowBackground() -> some View { modifier(HoverRowBackground()) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.track)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent)
                    .frame(height: max(geo.size.height * min(usage / 100, 1), 2))
                    .animation(reduceMotion ? nil : Motion.slow, value: usage)
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

// MARK: - Staggered content reveal (popover open only, not every data refresh)

/// A subtle fade + 4pt rise, delayed a few steps after `appeared` (the
/// panel's own container) flips true — the SwiftUI-native follow-up to
/// `MenuBarPopoverPanel`'s window-level open spring, so a popover's
/// sections cascade in rather than all popping in at once underneath it.
///
/// Ties its animation to `appeared` specifically (not to the content's own
/// data), so it only plays once — right when the panel opens — and never
/// replays just because `SystemMonitor`/`WorkspaceService`/etc. pushed a
/// routine update while the panel was already sitting open. Each popover
/// open recreates its root SwiftUI view fresh (`MenuBarPopoverPanel.show`
/// hands it a brand new `NSHostingController`), so `appeared` starting
/// `false` again next time is automatic, not something this modifier has
/// to reset itself.
private struct StaggeredAppear: ViewModifier {
    let order: Int
    @Binding var appeared: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// ~28ms between steps — "extremely subtle", per the brief: a 4-step
    /// cascade tops out under 120ms of extra tail latency, well inside how
    /// long the container's own open spring is still settling anyway.
    private static let stepDelay: Double = 0.028

    func body(content: Content) -> some View {
        let visible = appeared || reduceMotion
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(Double(order) * Self.stepDelay), value: appeared)
    }
}

extension View {
    /// Applies `StaggeredAppear` — call once per top-level section of a
    /// popover tab, with `order` increasing top-to-bottom (0, 1, 2, …) and
    /// `appeared` bound to a `@State` the container flips to `true` in its
    /// own `onAppear`.
    func staggeredAppear(_ order: Int, appeared: Binding<Bool>) -> some View {
        modifier(StaggeredAppear(order: order, appeared: appeared))
    }
}
