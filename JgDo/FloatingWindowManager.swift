import AppKit
import ScreenCaptureKit
import CoreImage

/// Picture-in-Picture, implemented as a live ScreenCaptureKit MIRROR rather
/// than making the real foreign window float — macOS has no public API to
/// set another process's window level (what "float above everything" would
/// actually require; the only way is a private SkyLight call, which the
/// brief explicitly says to avoid unless absolutely necessary, and it isn't
/// here). Mirroring instead means every piece is fully public API: this
/// panel is JgDo's OWN window, so floating level, opacity, resize, and
/// multiple simultaneous instances are all trivial and risk-free — the
/// honest tradeoff is that it's a live VIEW, not the interactive window
/// itself, which is why every panel stays visibly labeled "Live view."
///
/// Extends `WindowThumbnailService`'s existing one-shot
/// `SCContentFilter(desktopIndependentWindow:)` technique into a
/// continuous `SCStream` — same capture approach, just longer-lived.
@MainActor
@Observable
final class FloatingWindowManager {
    static let shared = FloatingWindowManager()

    private(set) var sessions: [FloatingWindowSession] = []

    private init() {}

    /// Starts (or, if already floating this exact window, just raises) a
    /// live mirror panel for `window`.
    func float(window: WindowInfo) {
        guard AppSettings.pipEnabled else { return }
        if let existing = sessions.first(where: { $0.sourceWindowID == window.windowID }) {
            existing.panel.makeKeyAndOrderFront(nil)
            return
        }
        guard WindowThumbnailService.isAuthorized else {
            WindowThumbnailService.requestAccessIfNeeded()
            FloatingNoticeCenter.shared.showPermissionRequest(
                title: "Screen Recording Permission Needed",
                message: "Picture-in-Picture mirrors a window live, which needs Screen Recording access.\n\nGo to System Settings → Privacy & Security → Screen Recording, then enable JgDo and try again.",
                settingsURLString: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
            return
        }

        let session = FloatingWindowSession(window: window)
        session.onFinished = { [weak self, weak session] in
            guard let self, let session else { return }
            self.sessions.removeAll { $0 === session }
        }
        sessions.append(session)
        session.start()
    }

    func stopAll() {
        for session in sessions { session.stop() }
        sessions.removeAll()
    }
}
