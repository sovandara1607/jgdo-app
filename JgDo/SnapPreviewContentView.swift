import SwiftUI

/// The redesigned ghost-preview overlay content: a "snap target" reticle —
/// tinted tile, glowing corner brackets, and a colored ambient shadow —
/// replacing the old flat, hand-drawn blue rectangle. Deliberately no
/// `.glassEffect()`: this tile's position is animating for nearly its whole
/// visible lifetime, and recomputing real-time backdrop blur every frame
/// while moving is exactly what caused the stutter this file used to have.
///
/// Rect changes animate ONLY for discrete, one-off snaps (`state.animate`);
/// during a live ⌘-drag, `showPersistent` sets `animate = false` so the tile
/// tracks the cursor directly instead of a spring perpetually chasing a
/// value that's retargeted every mouse-move tick (which read as lag/wobble,
/// not smoothness).
///
/// Every element stays in the view tree at all times (opacity-hidden rather
/// than conditionally removed) so it keeps its SwiftUI identity — removing
/// and re-inserting mid-drag was breaking position animations and popping
/// instead of transitioning. Each element also remembers its own last valid
/// (non-nil, non-degenerate) rect and keeps showing that while hidden, so it
/// fades out in place instead of collapsing to the origin corner, and
/// reappears from wherever it last was instead of growing out of (0,0).
struct SnapPreviewContentView: View {
    let state: SnapPreviewState

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                GhostTile(rect: state.secondary, containerHeight: h, isPrimary: false, animate: state.animate)
                GhostTile(rect: state.primary, containerHeight: h, isPrimary: true, animate: state.animate)
                IndicatorLabel(text: state.indicator, rect: state.primary, containerHeight: h, animate: state.animate)
                GuideBar(rect: state.guide, containerHeight: h, animate: state.animate)
                HighlightOutline(rect: state.highlight, containerHeight: h, animate: state.animate)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// A fast, minimally-bouncy spring for discrete snaps — settles quickly
/// (~0.2s) with almost no overshoot, so it still looks crisp under rapid
/// repeated presses (e.g. cycling ⌃⌥→ quickly) instead of visibly wobbling.
private let snapAnimation = Animation.spring(response: 0.2, dampingFraction: 0.88)

private func isValid(_ rect: CGRect?) -> Bool {
    guard let rect else { return false }
    return rect.width > 1 && rect.height > 1
}

// MARK: - Ghost tile

private struct GhostTile: View {
    let rect: CGRect?
    let containerHeight: CGFloat
    let isPrimary: Bool
    let animate: Bool
    @State private var shown: CGRect = .zero

    private let cornerRadius: CGFloat = 20

    private var center: CGPoint { CGPoint(x: shown.midX, y: containerHeight - shown.midY) }
    private var size: CGSize { CGSize(width: max(shown.width - 12, 1), height: max(shown.height - 12, 1)) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            // Flat tint only — no `.glassEffect()`. Its real-time backdrop
            // blur is expensive to recompute every frame, and this tile's
            // position is animating (live ⌘-drag tracking, or settling into
            // a discrete snap) for basically its entire visible lifetime, so
            // there's no point where the expensive version would actually
            // pay for itself.
            shape.fill(isPrimary ? Color.accentColor.opacity(0.24) : Color.white.opacity(0.08))
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: isPrimary
                            ? [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.4)]
                            : [Color.white.opacity(0.6), Color.white.opacity(0.2)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: isPrimary ? 2.5 : 1.5
                )
            if isPrimary {
                CornerBrackets(cornerLength: min(size.width, size.height) * 0.16)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(-7)
            }
        }
        .frame(width: size.width, height: size.height)
        // Same reasoning as the fill above — keep the ambient glow cheap
        // unconditionally instead of a bigger blur that only makes sense at
        // rest, which this tile rarely is.
        .shadow(color: isPrimary ? Color.accentColor.opacity(0.3) : .clear, radius: 8, y: 4)
        .position(center)
        .opacity(isValid(rect) ? 1 : 0)
        .animation(animate ? snapAnimation : nil, value: shown)
        .onAppear { if isValid(rect) { shown = rect! } }
        .onChange(of: rect) { _, new in if isValid(new) { shown = new! } }
    }
}

/// Four L-shaped corner marks framing a tile, like a camera focus reticle —
/// reinforces "this is a snap target" at a glance, sitting just outside the
/// glass tile's own edge.
private struct CornerBrackets: Shape {
    var cornerLength: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        func corner(_ point: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
            p.move(to: CGPoint(x: point.x, y: point.y + dy * cornerLength))
            p.addLine(to: point)
            p.addLine(to: CGPoint(x: point.x + dx * cornerLength, y: point.y))
        }
        corner(CGPoint(x: rect.minX, y: rect.minY), 1, 1)
        corner(CGPoint(x: rect.maxX, y: rect.minY), -1, 1)
        corner(CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)
        corner(CGPoint(x: rect.minX, y: rect.maxY), 1, -1)
        return p
    }
}

// MARK: - Cycle-step indicator

/// A short "2/3" / "70%"-style label centered on the primary tile, showing
/// which step of a hotkey cycle (edge-snap thirds, or shrink/grow presets)
/// the window just landed on.
private struct IndicatorLabel: View {
    let text: String?
    let rect: CGRect?
    let containerHeight: CGFloat
    let animate: Bool
    @State private var shown: CGRect = .zero
    @State private var shownText: String = ""

    private var center: CGPoint { CGPoint(x: shown.midX, y: containerHeight - shown.midY) }

    var body: some View {
        Text(shownText)
            .font(.system(size: 36, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.9))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            .contentTransition(.numericText())
            .position(center)
            .opacity(text != nil && isValid(rect) ? 1 : 0)
            .animation(animate ? snapAnimation : nil, value: shown)
            .animation(.snappy, value: shownText)
            .onAppear {
                if isValid(rect) { shown = rect! }
                shownText = text ?? shownText
            }
            .onChange(of: rect) { _, new in if isValid(new) { shown = new! } }
            .onChange(of: text) { _, new in if let new { shownText = new } }
    }
}

// MARK: - Resize divider guide

private struct GuideBar: View {
    let rect: CGRect?
    let containerHeight: CGFloat
    let animate: Bool
    @State private var shown: CGRect = .zero
    @State private var pulse = false

    private var center: CGPoint { CGPoint(x: shown.midX, y: containerHeight - shown.midY) }

    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: max(shown.width, 1), height: max(shown.height, 1))
            .shadow(color: Color.accentColor.opacity(pulse ? 0.9 : 0.35), radius: pulse ? 16 : 6)
            .position(center)
            .opacity(isValid(rect) ? 1 : 0)
            .animation(animate ? snapAnimation : nil, value: shown)
            .onAppear {
                if isValid(rect) { shown = rect! }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .onChange(of: rect) { _, new in if isValid(new) { shown = new! } }
    }
}

// MARK: - Tab-picked target highlight

private struct HighlightOutline: View {
    let rect: CGRect?
    let containerHeight: CGFloat
    let animate: Bool
    @State private var shown: CGRect = .zero
    @State private var phase: CGFloat = 0

    private var center: CGPoint { CGPoint(x: shown.midX, y: containerHeight - shown.midY) }
    private var size: CGSize { CGSize(width: max(shown.width, 1), height: max(shown.height, 1)) }

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8, 6], dashPhase: phase))
            .foregroundStyle(Color.orange)
            .frame(width: size.width, height: size.height)
            .position(center)
            .opacity(isValid(rect) ? 1 : 0)
            .animation(animate ? snapAnimation : nil, value: shown)
            .onAppear {
                if isValid(rect) { shown = rect! }
                withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
                    phase = -14
                }
            }
            .onChange(of: rect) { _, new in if isValid(new) { shown = new! } }
    }
}
