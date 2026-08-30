import SwiftUI
import AppKit

/// Live-updated content behind the floating panel — a plain `@Observable`
/// box `FloatingWindowSession` pushes frames/errors into, so the SwiftUI
/// view just observes it rather than the session reaching into AppKit
/// views directly.
@MainActor
@Observable
final class FloatingWindowContent {
    var image: NSImage?
    var errorMessage: String?
    let appName: String
    let appIcon: NSImage?

    init(appName: String, appIcon: NSImage?) {
        self.appName = appName
        self.appIcon = appIcon
    }
}

/// SwiftUI body of a Picture-in-Picture panel — always visibly labeled
/// "Live view" per the brief, since clicking the mirrored pixels does
/// nothing; only "Restore" (focuses the real window) is actually
/// interactive here.
struct FloatingWindowView: View {
    @Bindable var content: FloatingWindowContent
    let onRestore: () -> Void
    let onClose: () -> Void
    @Binding var opacity: Double

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                Color.black.opacity(0.85)
                if let message = content.errorMessage {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                    }
                } else if let image = content.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .allowsHitTesting(false)   // it's pixels, not the real window
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
        .background(Color.black)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if let icon = content.appIcon {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
            Text(content.appName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("LIVE")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.15)))
            Spacer(minLength: 8)
            Slider(value: $opacity, in: 0.3...1)
                .frame(width: 70)
                .accessibilityLabel("Panel opacity")
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Close live view")
            .accessibilityLabel("Close live view")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.55))
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text("Live view — click the original window to interact")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Restore", action: onRestore)
                .controlSize(.small)
                .help("Bring the original window to the front")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.55))
    }
}

/// The floating panel itself — a resizable, key-capable `NSPanel` (can't
/// reuse `KeyablePanel` from `AppDelegate.swift`, which is `final`; the
/// same `canBecomeKey`/`canBecomeMain` override lives here instead) hosting
/// `FloatingWindowView`. One instance per `FloatingWindowSession`; several
/// can be open at once, each fully independent (own position/size/
/// opacity), matching the brief's "multiple simultaneous instances"
/// requirement.
final class FloatingWindowPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    convenience init(appName: String, appIcon: NSImage?, initialAspect: CGFloat,
                      content: FloatingWindowContent, opacity: Binding<Double>,
                      onRestore: @escaping () -> Void, onClose: @escaping () -> Void) {
        let width: CGFloat = 380
        let height = max(width * initialAspect + 66, 220)   // +66 ≈ top/bottom bar chrome
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .resizable, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 200, height: 150)

        let rootView = FloatingWindowView(content: content, onRestore: onRestore, onClose: onClose, opacity: opacity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        contentViewController = NSHostingController(rootView: rootView)

        // Cascade so several floats opened in a row don't stack exactly on
        // top of each other.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let baseX = screen.frame.midX - width / 2
        let baseY = screen.frame.midY - height / 2
        setFrame(NSRect(x: baseX, y: baseY, width: width, height: height), display: false)
    }
}
