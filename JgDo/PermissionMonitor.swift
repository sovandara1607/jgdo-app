import AppKit

/// Live Accessibility / Screen Recording trust status, polled so the
/// diagnostics tab and onboarding update without the user hunting for a
/// refresh button. Accessibility updates live once granted. Screen
/// Recording does NOT — `CGPreflightScreenCaptureAccess()` keeps returning
/// the old answer until the app restarts, so that row also offers a
/// "Restart JgDo" button once a grant is detected as still pending.
@MainActor
@Observable
final class PermissionMonitor {
    static let shared = PermissionMonitor()

    private(set) var accessibilityTrusted: Bool
    private(set) var screenRecordingAuthorized: Bool

    private var timer: Timer?

    private init() {
        accessibilityTrusted = AXIsProcessTrusted()
        screenRecordingAuthorized = WindowThumbnailService.isAuthorized
    }

    /// Starts polling. Cheap (two synchronous system calls per tick) and
    /// only runs while something is actually displaying live status —
    /// callers should pair this with `stop()` (e.g. `.onAppear`/`.onDisappear`
    /// in the diagnostics view) rather than leaving it running for the
    /// whole app lifetime.
    func start(interval: TimeInterval = 1.0) {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
        screenRecordingAuthorized = WindowThumbnailService.isAuthorized
    }
}
