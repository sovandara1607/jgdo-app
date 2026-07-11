import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Live per-window screenshot previews for the Command Palette, via
/// ScreenCaptureKit's one-shot capture API — there's no need for a
/// persistent `SCStream` when all we want is a single static thumbnail.
/// Requires Screen Recording permission, gated the same way the rest of the
/// app gates Accessibility (see `AppDelegate.checkScreenRecordingPermission`).
enum WindowThumbnailService {

    private static let cache = NSCache<NSNumber, NSImage>()

    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts for Screen Recording access if the user hasn't decided yet.
    /// Safe to call repeatedly — macOS only shows the system prompt once.
    @discardableResult
    static func requestAccessIfNeeded() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Clears cached thumbnails — call when the palette closes so the next
    /// open recaptures fresh content instead of showing stale pixels.
    static func clearCache() {
        cache.removeAllObjects()
    }

    /// A cached (or freshly captured) thumbnail for `windowID`, aspect-fit
    /// within `maxSize`. Returns nil if unauthorized, the window is gone, or
    /// capture otherwise fails — callers should fall back to the app icon.
    static func thumbnail(for windowID: CGWindowID, maxSize: CGSize) async -> NSImage? {
        let key = NSNumber(value: windowID)
        if let cached = cache.object(forKey: key) { return cached }
        guard isAuthorized else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let size = scWindow.frame.size
            let scale = min(maxSize.width / max(size.width, 1), maxSize.height / max(size.height, 1), 1)
            config.width = max(Int(size.width * scale), 1)
            config.height = max(Int(size.height * scale), 1)
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }
}
