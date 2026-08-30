import AppKit
import CoreGraphics

/// Centralizes conversion between the two global coordinate spaces JgDo has
/// to bridge constantly:
///
/// - **CG/Quartz global space** — origin at the top-left of the primary
///   display, Y grows downward. `CGWindowListCopyWindowInfo` bounds,
///   `CGEvent` locations, and (per Apple's own AX docs) `kAXPositionAttribute`
///   /`kAXSizeAttribute` all use this space.
/// - **AppKit/Cocoa global space** — origin at the bottom-left of the
///   primary display, Y grows upward. `NSScreen.frame`/`.visibleFrame` and
///   `NSWindow` positioning use this space.
///
/// Both spaces are anchored to the SAME corner of the SAME screen — the
/// primary display, i.e. `NSScreen.screens.first`, which Apple documents as
/// always having `frame.origin == .zero` in AppKit space — and both span the
/// entire virtual desktop as one shared space, not one space per monitor.
/// That means exactly one constant, the primary screen's height, converts
/// between them everywhere, for every monitor arrangement: negative-origin
/// displays, and displays above, below, left, or right of the primary.
///
/// The bug this type exists to prevent: several call sites used to flip Y
/// against the *target* screen's own `frame.maxY` instead of the primary
/// screen's height. That happens to equal the same value under macOS's
/// default "align displays along the top edge" arrangement — which is
/// exactly why it went unnoticed — and silently misplaces windows the
/// moment a user arranges displays any other way in System Settings.
enum CoordinateSpace {

    /// The one constant every CG⇄AppKit flip in this app should key off —
    /// never a target screen's own `frame.height`/`frame.maxY`.
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    // MARK: - Rects

    /// CG global rect (top-left origin) → AppKit global rect (bottom-left
    /// origin). `primaryHeight` defaults to the live primary screen but
    /// takes a parameter so callers (and tests) can pin it to a specific
    /// value without depending on `NSScreen.screens` at call time.
    static func appKit(fromCG rect: CGRect, primaryHeight: CGFloat = primaryScreenHeight) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// AppKit global rect → CG global rect. The flip is self-inverse (Y
    /// reflection), so this is the identical formula to `appKit(fromCG:)` —
    /// kept as a separate name so call sites read as "converting to CG"
    /// rather than "converting to AppKit" at a glance.
    static func cg(fromAppKit rect: CGRect, primaryHeight: CGFloat = primaryScreenHeight) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Points

    static func appKit(fromCG point: CGPoint, primaryHeight: CGFloat = primaryScreenHeight) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func cg(fromAppKit point: CGPoint, primaryHeight: CGFloat = primaryScreenHeight) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    // MARK: - Screen lookup

    /// The screen whose AppKit-space frame contains `point`, falling back to
    /// the system's notion of the main screen, then simply the first
    /// screen — centralizes the `NSScreen.screens.first { … } ?? .main ??
    /// .screens[0]` chain that was duplicated at several call sites. `nil`
    /// only when there are zero screens (never true on a running Mac).
    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Same fallback chain, keyed by which screen contains `rect` (used when
    /// placing a whole window rather than hit-testing a single point).
    static func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(rect) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
