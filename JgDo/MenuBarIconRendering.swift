import AppKit

/// Pure icon-drawing helpers for the menu bar status item — split out of
/// `AppDelegate` since neither function touches any of its state, they
/// just take inputs and return an `NSImage`.
enum MenuBarIconRendering {
    /// Draws a small live ring (track + accent-colored progress arc) in
    /// place of the static SF Symbol — a mini radial gauge, à la iStat
    /// Menus, for whichever reading the Settings picker selected. Not a
    /// template image (it carries real color), so it's rebuilt on every
    /// update rather than tinted automatically like the plain icon is.
    static func renderGaugeIcon(percent: Double) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let lineWidth: CGFloat = 2.2
            let ringRect = rect.insetBy(dx: lineWidth / 2 + 0.5, dy: lineWidth / 2 + 0.5)

            let track = NSBezierPath(ovalIn: ringRect)
            track.lineWidth = lineWidth
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            track.stroke()

            let clamped = min(max(percent, 0), 1)
            guard clamped > 0 else { return true }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: ringRect.midX, y: ringRect.midY),
                          radius: ringRect.width / 2,
                          startAngle: 90, endAngle: 90 - clamped * 360, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            NSColor.controlAccentColor.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Loads the current menu bar icon: a user-chosen image if one is set in
    /// Settings, otherwise the bundled JgDo logo. Scaled to menu bar size
    /// (18pt, @2x/@3x-ready) so custom images of any resolution look crisp
    /// without distorting the status item's layout.
    static func loadStatusIcon() -> NSImage? {
        let raw: NSImage?
        if let url = AppSettings.customStatusIconURL {
            raw = NSImage(contentsOf: url)
        } else {
            raw = NSImage(named: "StatusBarIcon")
        }
        guard let raw else { return nil }
        let size = NSSize(width: 18, height: 18)
        let scaled = NSImage(size: size, flipped: false) { rect in
            raw.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            return true
        }
        scaled.accessibilityDescription = "JgDo"
        scaled.isTemplate = AppSettings.customStatusIconTemplate
        return scaled
    }
}
