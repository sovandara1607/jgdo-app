import AppKit
import SwiftUI

/// A quiet, window-shaped placement preview. The faint title-bar treatment
/// makes the destination read as a future app window rather than a generic
/// selection rectangle, while the restrained accent edge keeps it visible
/// on both light and dark desktops. Deliberately no
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let shouldAnimate = state.animate && !reduceMotion
            ZStack {
                GhostTile(rect: state.secondary, containerHeight: h, isPrimary: false, animate: shouldAnimate)
                GhostTile(rect: state.primary, containerHeight: h, isPrimary: true, animate: shouldAnimate)
                IndicatorLabel(text: state.indicator, rect: state.primary, containerHeight: h, animate: shouldAnimate)
                GuideBar(rect: state.guide, containerHeight: h, animate: shouldAnimate)
                HighlightOutline(rect: state.highlight, containerHeight: h, animate: shouldAnimate)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// A fast, minimally-bouncy spring for discrete snaps — settles quickly
/// (~0.2s) with almost no overshoot, so it still looks crisp under rapid
/// repeated presses (e.g. cycling ⌃⌥→ quickly) instead of visibly wobbling.
private let snapAnimation = Animation.spring(response: 0.18, dampingFraction: 0.94)

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

    private var center: CGPoint { CGPoint(x: shown.midX, y: containerHeight - shown.midY) }
    private var size: CGSize { CGSize(width: max(shown.width - 10, 1), height: max(shown.height - 10, 1)) }
    private var cornerRadius: CGFloat {
        min(18, max(10, min(size.width, size.height) * 0.035))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(isPrimary ? 0.72 : 0.52))
            shape.fill(Color.accentColor.opacity(isPrimary ? 0.10 : 0.035))
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: isPrimary
                            ? [Color.white.opacity(0.68), Color.accentColor.opacity(0.72)]
                            : [Color.white.opacity(0.42), Color.white.opacity(0.16)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: isPrimary ? 1.5 : 1
                )
            shape.strokeBorder(Color.black.opacity(0.16), lineWidth: 1).padding(1)
            PreviewWindowChrome(isPrimary: isPrimary)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(isPrimary ? 0.24 : 0.12), radius: 18, y: 8)
        .shadow(color: isPrimary ? Color.accentColor.opacity(0.12) : .clear, radius: 7)
        .position(center)
        .opacity(isValid(rect) ? 1 : 0)
        .animation(animate ? snapAnimation : nil, value: shown)
        .onAppear { if isValid(rect) { shown = rect! } }
        .onChange(of: rect) { _, new in if isValid(new) { shown = new! } }
    }
}

/// A minimal macOS-window cue. It only appears when the target is large
/// enough, so narrow thirds and small available-space previews stay clean.
private struct PreviewWindowChrome: View {
    let isPrimary: Bool

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 150, geo.size.height >= 90 {
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(index == 0 && isPrimary
                                      ? Color.accentColor.opacity(0.8)
                                      : Color.white.opacity(0.34))
                                .frame(width: 6, height: 6)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    Rectangle()
                        .fill(Color.white.opacity(0.13))
                        .frame(height: 1)
                    Spacer(minLength: 0)
                }
            }
        }
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
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.94))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.48), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .shadow(color: .black.opacity(0.24), radius: 8, y: 3)
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
    private var center: CGPoint { CGPoint(x: shown.midX, y: containerHeight - shown.midY) }

    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: max(shown.width, 1), height: max(shown.height, 1))
            .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 1))
            .shadow(color: Color.accentColor.opacity(0.5), radius: 5)
            .position(center)
            .opacity(isValid(rect) ? 1 : 0)
            .animation(animate ? snapAnimation : nil, value: shown)
            .onAppear {
                if isValid(rect) { shown = rect! }
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
    private var center: CGPoint { CGPoint(x: shown.midX, y: containerHeight - shown.midY) }
    private var size: CGSize { CGSize(width: max(shown.width, 1), height: max(shown.height, 1)) }

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.orange.opacity(0.9), lineWidth: 2)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.orange.opacity(0.035))
            )
            .frame(width: size.width, height: size.height)
            .shadow(color: .orange.opacity(0.18), radius: 5)
            .position(center)
            .opacity(isValid(rect) ? 1 : 0)
            .animation(animate ? snapAnimation : nil, value: shown)
            .onAppear {
                if isValid(rect) { shown = rect! }
            }
            .onChange(of: rect) { _, new in if isValid(new) { shown = new! } }
    }
}
