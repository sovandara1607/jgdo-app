import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreMedia
import CoreImage

/// Owns one Picture-in-Picture mirror end to end: the continuous
/// `SCStream` capturing the source window, and the `FloatingWindowPanel`
/// displaying it. One instance per floated window — see
/// `FloatingWindowManager`, which owns a list of these.
@MainActor
final class FloatingWindowSession: NSObject {
    let sourceWindowID: CGWindowID
    private let sourceWindow: WindowInfo
    private(set) var panel: FloatingWindowPanel!
    private let content: FloatingWindowContent
    private var stream: SCStream?
    /// Set by `FloatingWindowManager` right after creating this session —
    /// called once, when the mirror is closed (by the user or because the
    /// source window went away), so the manager can drop it from its list.
    var onFinished: (() -> Void)?

    // `CIContext`/`DispatchQueue` are documented thread-safe for exactly
    // this concurrent-image-creation use, so `nonisolated(unsafe)` is
    // deliberate here (same convention `HotkeyManager`'s CGEventTap state
    // uses) rather than something to "fix" — these are read from
    // `stream(_:didOutputSampleBuffer:of:)`, which SCStream genuinely
    // calls on a background queue, not the main actor.
    nonisolated(unsafe) private static let ciContext = CIContext()
    nonisolated(unsafe) private static let frameQueue = DispatchQueue(label: "com.jgdo.floatingwindow.frames", qos: .userInitiated)

    init(window: WindowInfo) {
        self.sourceWindowID = window.windowID
        self.sourceWindow = window
        let icon = NSWorkspace.shared.runningApplications
            .first(where: { $0.processIdentifier == window.pid })?.icon ?? window.icon
        self.content = FloatingWindowContent(appName: window.appName, appIcon: icon)
        super.init()

        let aspect = window.bounds.width > 0 ? window.bounds.height / window.bounds.width : 0.6
        let opacityBinding = Binding<Double>(
            get: { [weak self] in Double(self?.panel?.alphaValue ?? 1) },
            set: { [weak self] v in self?.panel?.alphaValue = CGFloat(v) }
        )
        panel = FloatingWindowPanel(
            appName: window.appName, appIcon: icon, initialAspect: aspect,
            content: content, opacity: opacityBinding,
            onRestore: { [weak self] in self?.restoreOriginal() },
            onClose: { [weak self] in self?.stop() }
        )
    }

    /// Shows the panel immediately (with a spinner) and starts the stream
    /// asynchronously — the panel appears right away rather than waiting on
    /// `SCShareableContent`'s round trip, which can take a beat.
    func start() {
        panel.orderFront(nil)
        Task {
            do {
                let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scWindow = shareable.windows.first(where: { $0.windowID == sourceWindowID }) else {
                    content.errorMessage = "This window is no longer available."
                    return
                }

                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                let size = scWindow.frame.size
                let maxDimension: CGFloat = 1400
                let scale = min(maxDimension / max(size.width, 1), 1)
                config.width = max(Int(size.width * scale), 2)
                config.height = max(Int(size.height * scale), 2)
                // ~15fps — a "live view" doesn't need 60fps to read as
                // live, and this keeps the mirror cheap to run continuously
                // in the background, matching the brief's low-CPU goal.
                config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
                config.queueDepth = 3
                config.showsCursor = false

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: Self.frameQueue)
                try await stream.startCapture()
                self.stream = stream
            } catch {
                content.errorMessage = "Couldn't start live view: \(error.localizedDescription)"
            }
        }
    }

    /// Stops the stream and closes the panel — safe to call more than once
    /// (e.g. both the panel's close button AND the manager's `stopAll()`).
    func stop() {
        guard onFinished != nil || stream != nil else { return }
        let activeStream = stream
        stream = nil
        panel.orderOut(nil)
        onFinished?()
        onFinished = nil
        Task { try? await activeStream?.stopCapture() }
    }

    /// "Restore" — focuses the REAL source window (activates its app,
    /// raises it via AX). Deliberately does NOT close the mirror; they're
    /// independent actions, matching the panel's own "click the original
    /// window to interact" guidance.
    private func restoreOriginal() {
        WindowManagerService().focusWindow(sourceWindow)
    }
}

// MARK: - ScreenCaptureKit callbacks

/// `@preconcurrency` because `SCStreamOutput`/`SCStreamDelegate` aren't
/// actor-isolated protocols themselves, but their requirements below are
/// implemented `nonisolated` on purpose — SCStream genuinely invokes them
/// off the main actor (on `frameQueue` / an internal error-reporting
/// queue), so each hops to `@MainActor` explicitly only once it has
/// something to hand off, rather than forcing the callback itself onto the
/// main actor (which would mean the isolation-check machinery, not our
/// code, decides when frames get dropped under load).
extension FloatingWindowSession: @preconcurrency SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        Task { @MainActor [weak self] in
            self?.content.image = nsImage
            self?.content.errorMessage = nil
        }
    }
}

extension FloatingWindowSession: @preconcurrency SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.content.errorMessage = "The source window was closed."
            self.stream = nil
        }
    }
}
