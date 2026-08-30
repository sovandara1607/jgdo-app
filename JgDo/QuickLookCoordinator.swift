import AppKit
import Quartz

/// Drives the system's shared `QLPreviewPanel` for a single file at a time
/// — triggered by Space on a selected File Search row, matching Finder's
/// own convention. This is the simplified, direct-drive integration
/// (`panel.dataSource = self; panel.makeKeyAndOrderFront(nil)`) rather than
/// the full `QLPreviewPanelController` responder-chain dance Apple's
/// document-based-app sample code uses — appropriate here since JgDo has
/// exactly one place Quick Look can be triggered from (the Command
/// Palette), not multiple windows/documents that need to negotiate who
/// currently owns the shared panel. Fully public API either way
/// (`Quartz`/`QuickLookUI`), no private symbols.
@MainActor
final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookCoordinator()

    private var currentURL: URL?

    private override init() { super.init() }

    func preview(_ url: URL) {
        currentURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func closePreview() {
        currentURL = nil
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        currentURL as NSURL?
    }
}
