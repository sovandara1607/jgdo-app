import AppKit
import SwiftUI

/// The ⌃⌥←/→ layout-cycle overlay — a compact macOS-system-HUD-style pair
/// of surfaces (a small shortcut pill above a bordered layout card), not a
/// generic app popup. Shown while `WindowLayoutSelectorController` walks
/// the arrow-key cycle; closes on commit, cancel, or (instant mode) its own
/// auto-hide timer. Same borderless/click-through/non-activating window
/// shape `WindowActionHUD`/`SnapPreviewOverlay` already use — the entrance/
/// exit motion lives in the SwiftUI content, not the NSWindow, so the exact
/// scale/opacity/offset the design calls for is real SwiftUI animation
/// rather than an NSAnimationContext approximation of it.
///
/// THREE windows, not one: the dim is full-screen and sits at a level
/// explicitly below `.floating`, so it can never wash out
/// `SnapPreviewOverlay`'s ghost tile or this overlay's own surfaces (all at
/// `.floating`) — a single combined window ordered front used to do exactly
/// that. Pill and card are separate windows (not one taller window) so each
/// can run its own independent entrance animation/stagger, matching two
/// distinct floating surfaces instead of one panel with two sections.
@MainActor
final class WindowLayoutSelectorOverlay {
    static let shared = WindowLayoutSelectorOverlay()

    private var dimWindow: NSWindow?
    private var pillWindow: NSWindow?
    private var cardWindow: NSWindow?
    private let state = LayoutSelectorContentState()
    private var isVisible = false
    private var hideWorkItem: DispatchWorkItem?
    private var autoHideTimer: Timer?
    private var cardAppearWorkItem: DispatchWorkItem?

    private init() {}

    /// Shows the overlay for one cycle step, or — if already up — just
    /// updates its content in place (neither surface re-plays its entrance
    /// on every arrow press, only the diagram/label/dots/other-windows-list
    /// crossfade). `family` selects the pill's shortcut glyph (⌃⌥← vs ⌃⌥→)
    /// AND which side of the screen both surfaces sit on — see `origins` —
    /// the side that's about to become empty, not the side the window is
    /// snapping to, so the HUD never covers the window it's confirming.
    /// `otherWindows` is a passive glance list (icon + name, not
    /// interactive — the panel stays click-through) of what's open to fill
    /// that empty side; press the dedicated "fill other side" hotkey to
    /// actually search/pick one via `WindowLayoutPartnerSearchPanelController`.
    /// `autoHideAfter`, if set, self-closes after that many seconds with no
    /// further `show` call — instant mode's "flash a confirmation" (no
    /// explicit commit/cancel event exists there to close it instead); `nil`
    /// (hold-and-release mode) leaves it up until `hide()` is called explicitly.
    func show(step: LayoutCycleStep, index: Int, count: Int, family: LayoutCycleFamily,
              appIcon: NSImage?, appName: String, otherWindows: [PartnerWindowCandidate],
              dim: Bool, autoHideAfter: TimeInterval?, on screen: NSScreen) {
        hideWorkItem?.cancel()
        cardAppearWorkItem?.cancel()
        autoHideTimer?.invalidate()

        let dimWin = dimWindow ?? makeDimWindow()
        dimWindow = dimWin
        let pillWin = pillWindow ?? makePillWindow()
        pillWindow = pillWin
        let cardWin = cardWindow ?? makeCardWindow()
        cardWindow = cardWin

        state.appIcon = appIcon
        state.appName = appName
        state.dim = dim
        state.step = step
        state.index = index
        state.count = count
        state.family = family
        state.otherWindows = otherWindows

        // Both surfaces size to their own content and center on the same
        // horizontal axis, stacked with a fixed gap — computed on every
        // call (cheap) so they reposition correctly if the gesture started
        // on a different screen than last time.
        let pillHosting = pillWin.contentViewController as! NSHostingController<WindowLayoutSelectorPillView>
        let cardHosting = cardWin.contentViewController as! NSHostingController<WindowLayoutSelectorCardView>
        // `fittingSize` read immediately after mutating `state` above can
        // return a stale/undersized value — SwiftUI's Observation doesn't
        // guarantee the hosting view has re-laid-out for the new content by
        // the very next line. Most visible the first time a window is
        // created this launch: a truncated pill sized for old/default
        // content, mispositioned to match. Forcing a layout pass first
        // flushes the pending update before the size is trusted.
        pillHosting.view.layoutSubtreeIfNeeded()
        cardHosting.view.layoutSubtreeIfNeeded()
        let pillFitted = pillHosting.view.fittingSize
        let cardFitted = cardHosting.view.fittingSize
        let (pillOrigin, cardOrigin) = Self.origins(pillSize: pillFitted, cardSize: cardFitted, family: family, on: screen)
        pillWin.setFrame(NSRect(origin: pillOrigin, size: pillFitted), display: true)
        cardWin.setFrame(NSRect(origin: cardOrigin, size: cardFitted), display: true)

        if dim {
            dimWin.setFrame(screen.frame, display: false)
            dimWin.alphaValue = 1
            dimWin.orderFrontRegardless()
        } else {
            dimWin.orderOut(nil)
        }
        // Card ordered after the dim (and after the controller's own
        // ghost-tile call, which precedes this) so it's always above both.
        pillWin.alphaValue = 1
        pillWin.orderFrontRegardless()
        cardWin.alphaValue = 1
        cardWin.orderFrontRegardless()

        if let autoHideAfter {
            autoHideTimer = Timer.scheduledTimer(withTimeInterval: autoHideAfter, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
        }

        guard !isVisible else { return }
        isVisible = true
        state.pillAppeared = false
        state.cardAppeared = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // One run-loop tick so SwiftUI observes appeared go false → true —
        // setting it true in the same pass as ordering front would just
        // render already-appeared with nothing to animate from. The card
        // stagger (~28ms behind the pill) is real, not simulated.
        DispatchQueue.main.async { [state] in state.pillAppeared = true }
        let work = DispatchWorkItem { [state] in state.cardAppeared = true }
        cardAppearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.028), execute: work)
    }

    /// Closes the overlay — called on commit (modifiers released), cancel
    /// (Escape), or instant mode's own auto-hide timer. The windows only
    /// order out once the exit animation (owned by the content views) has
    /// had time to finish.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        autoHideTimer?.invalidate()
        cardAppearWorkItem?.cancel()
        state.pillAppeared = false
        state.cardAppeared = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let work = DispatchWorkItem { [weak self] in
            self?.dimWindow?.orderOut(nil)
            self?.pillWindow?.orderOut(nil)
            self?.cardWindow?.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.13), execute: work)
    }

    /// Upper-middle vertically (~40% down from the top), but horizontally
    /// on the side of the screen the active window is NOT taking — left
    /// family (window snapping left) puts the HUD on the right, and vice
    /// versa — so it never sits on top of the window it's confirming, and
    /// naturally reads as "here's what's going in the space I'm not using."
    private static func origins(pillSize: NSSize, cardSize: NSSize, family: LayoutCycleFamily, on screen: NSScreen) -> (pill: NSPoint, card: NSPoint) {
        let vf = screen.visibleFrame
        let gap: CGFloat = 14
        let topInset = vf.height * 0.40
        let pillOriginY = vf.maxY - topInset - pillSize.height
        let cardOriginY = pillOriginY - gap - cardSize.height

        // The empty side is the opposite of the family's own direction.
        let sideFraction: CGFloat = family == .left ? 0.74 : 0.26
        let margin: CGFloat = 28
        func centeredX(_ width: CGFloat) -> CGFloat {
            let x = vf.minX + vf.width * sideFraction - width / 2
            return max(vf.minX + margin, min(x, vf.maxX - width - margin))
        }

        let pillOrigin = NSPoint(x: centeredX(pillSize.width), y: pillOriginY)
        let cardOrigin = NSPoint(x: centeredX(cardSize.width), y: cardOriginY)
        return (pillOrigin, cardOrigin)
    }

    private func makeDimWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        // Explicitly below `.floating` — `SnapPreviewOverlay`'s ghost tile
        // and this overlay's own surfaces both live at `.floating`, and
        // must always render above the dim, never under it.
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.contentViewController = NSHostingController(rootView: DimBackdropView())
        return w
    }

    private func makePillWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.contentViewController = NSHostingController(rootView: WindowLayoutSelectorPillView(state: state))
        return w
    }

    private func makeCardWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.contentViewController = NSHostingController(rootView: WindowLayoutSelectorCardView(state: state))
        return w
    }
}

@Observable
private final class LayoutSelectorContentState {
    var appIcon: NSImage?
    var appName: String = ""
    var step = LayoutCycleFamily.left.steps[0]
    var index = 0
    var count = 1
    var family = LayoutCycleFamily.left
    var otherWindows: [PartnerWindowCandidate] = []
    var dim = true
    var pillAppeared = false
    var cardAppeared = false
}

/// A flat, subtle dim — no blur. An earlier pass used a full behind-window
/// blur here, which obscured the very window the overlay is meant to help
/// you watch move; a light tint keeps the desktop clearly visible behind
/// it, matching "the user should still be able to recognize their open
/// windows behind JgDo."
private struct DimBackdropView: View {
    var body: some View {
        Color.black.opacity(0.2)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

// MARK: - Pill

private struct WindowLayoutSelectorPillView: View {
    let state: LayoutSelectorContentState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Text(state.family == .left ? "⌃⌥←" : "⌃⌥→")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Window Layout")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .opacity(state.pillAppeared ? 1 : 0)
        .scaleEffect(reduceMotion ? 1 : (state.pillAppeared ? 1 : 0.96))
        .offset(y: reduceMotion ? 0 : (state.pillAppeared ? 0 : -4))
        .animation(.spring(response: 0.2, dampingFraction: 0.88), value: state.pillAppeared)
        .accessibilityHidden(true)
    }
}

// MARK: - Card

private struct WindowLayoutSelectorCardView: View {
    let state: LayoutSelectorContentState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        card
            .opacity(state.cardAppeared ? 1 : 0)
            .scaleEffect(reduceMotion ? 1 : (state.cardAppeared ? 1 : 0.95))
            .offset(y: reduceMotion ? 0 : (state.cardAppeared ? 0 : 8))
            .animation(.spring(response: 0.22, dampingFraction: 0.88), value: state.cardAppeared)
            // Transient, keyboard-driven confirmation — nothing here is
            // interactive and the arrow/modifier keys already convey state
            // to VoiceOver users far better than reading this card would.
            .accessibilityHidden(true)
    }

    private var card: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                if let icon = state.appIcon {
                    Image(nsImage: icon).resizable()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text(state.appName)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            diagram
                .frame(width: 300, height: 140)
                .animation(.easeOut(duration: 0.1), value: state.step)

            Text(state.step.name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .animation(.easeOut(duration: 0.1), value: state.step)

            navRow

            if hasComplement, !state.otherWindows.isEmpty {
                otherWindowsPreview
            }
        }
        .padding(24)
        .frame(width: 380)
        .hudCard(cornerRadius: 26, shadowY: 12)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Subtle, lightweight — plain glyphs and dots, not buttons, per the
    /// concept design ("do not turn them into large buttons").
    private var navRow: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(0..<max(state.count, 1), id: \.self) { i in
                    Circle()
                        .fill(i == state.index ? Color.accentColor : Color.primary.opacity(0.22))
                        .frame(width: 6, height: 6)
                }
            }
            .animation(.easeOut(duration: 0.1), value: state.index)
            Spacer(minLength: 0)
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    /// Passive glance list of other open windows — up to 3, "+N more"
    /// beyond that. Click-through (the panel itself `ignoresMouseEvents`),
    /// purely informational: the complementary side is already auto-filled
    /// with the topmost one of these the moment the layout applies (see
    /// `WindowLayoutSelectorController.autoFillComplement`); the hotkey
    /// below is only for swapping in a *different* one of these instead.
    private var otherWindowsPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.5)
            Text("Other Windows")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            ForEach(state.otherWindows.prefix(3)) { candidate in
                HStack(spacing: 8) {
                    if let icon = candidate.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(candidate.appName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            if state.otherWindows.count > 3 {
                Text("+\(state.otherWindows.count - 3) more")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Text("\(ShortcutStore.shared.combo(for: .layoutFillOtherSide).display) to search and swap the other side")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the "fill other side" hotkey does anything for the current
    /// step — true for every half/third/quarter step, false for the two
    /// display-change steps.
    private var hasComplement: Bool {
        if case .layout(let layout, _) = state.step.kind { return layout.complement != nil }
        return false
    }

    @ViewBuilder
    private var diagram: some View {
        switch state.step.kind {
        case .layout:
            if let unit = state.step.diagramUnit {
                LayoutDiagramView(unit: unit)
            }
        case .previousDisplay:
            DisplayChangeGlyph(direction: .previous)
        case .nextDisplay:
            DisplayChangeGlyph(direction: .next)
        }
    }
}

/// The card's own layout diagram — a bordered miniature display with a
/// grid-textured accent fill on the selected region, richer than
/// `LayoutPreviewIcon`'s flat rectangle to match the concept design. Reads
/// the SAME normalized geometry every other layout preview in the app uses
/// (`LayoutCycleStep.diagramUnit`, itself built on
/// `LayoutPreviewIcon.fraction(for:)`) — only the drawing style is
/// different here, not the numbers.
private struct LayoutDiagramView: View {
    let unit: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                ZStack {
                    Rectangle().fill(Color.accentColor.opacity(0.82))
                    GridTexture()
                }
                .frame(width: max(w * unit.width, 1), height: max(h * unit.height, 1))
                .offset(x: w * unit.x, y: h * unit.y)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1.5)
            )
        }
    }
}

/// Faint grid lines over the selected region — purely decorative texture,
/// not additional information, so it's cheap (`Canvas`, drawn once per
/// step change) and skipped by VoiceOver via the diagram's own
/// `accessibilityHidden` further up the view tree.
private struct GridTexture: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 16
            var x: CGFloat = spacing
            while x < size.width {
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                with: .color(.white.opacity(0.14)), lineWidth: 0.5)
                x += spacing
            }
            var y: CGFloat = spacing
            while y < size.height {
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                with: .color(.white.opacity(0.14)), lineWidth: 0.5)
                y += spacing
            }
        }
    }
}

/// A minimal "two monitors, destination highlighted" glyph for the
/// Previous/Next Display cycle steps — `LayoutDiagramView`'s single-screen
/// diagram doesn't apply once the action is "leave this screen entirely."
private struct DisplayChangeGlyph: View {
    let direction: WindowResizeService.DisplayDirection

    var body: some View {
        HStack(spacing: 10) {
            monitor(highlighted: direction == .previous)
            Image(systemName: direction == .previous ? "arrow.left" : "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            monitor(highlighted: direction == .next)
        }
    }

    private func monitor(highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(highlighted ? 0.9 : 0.3), lineWidth: highlighted ? 2 : 1)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(highlighted ? 0.25 : 0.05))
            )
            .frame(width: 84, height: 54)
    }
}
