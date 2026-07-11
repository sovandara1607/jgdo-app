import AppKit
import SwiftData

/// Watches the general pasteboard and records history into SwiftData.
/// Polling `changeCount` is the only supported way to observe the pasteboard
/// on macOS; 0.5 s keeps CPU use negligible.
@Observable
final class ClipboardService {
    static let shared = ClipboardService()

    static let enabledKey = "clipboardEnabled"
    static let limitKey = "clipboardLimit"

    private(set) var items: [ClipboardItem] = []
    var searchText: String = ""
    var selectedIndex: Int = 0
    var focusSearch: Bool = false

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    private init() {
        reload()
    }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private var limit: Int {
        let v = UserDefaults.standard.integer(forKey: Self.limitKey)
        return v > 0 ? v : 200
    }

    // MARK: Capture

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        // Track the change count even while disabled, so re-enabling doesn't
        // retroactively record whatever was copied in the meantime.
        lastChangeCount = pb.changeCount
        guard isEnabled else { return }
        // Respect password managers / marked-transient content.
        guard pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) != true,
              pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) != true
        else { return }

        let front = NSWorkspace.shared.frontmostApplication
        let text = pb.string(forType: .string)
        let imageData = pb.data(forType: .png) ?? tiffAsPNG(pb)

        let item: ClipboardItem?
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty, urls.allSatisfy(\.isFileURL) {
            item = ClipboardItem(kind: .file, filePaths: urls.map(\.path),
                                 sourceBundleID: front?.bundleIdentifier,
                                 sourceAppName: front?.localizedName)
        } else if let imageData, text == nil || isLoneURL(text!) {
            // "Copy Image" in browsers puts both the bitmap and its URL string
            // on the pasteboard — the image is what the user meant to copy.
            item = ClipboardItem(kind: .image, imageData: imageData,
                                 sourceBundleID: front?.bundleIdentifier,
                                 sourceAppName: front?.localizedName)
        } else if let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item = ClipboardItem(kind: .text, text: text,
                                 sourceBundleID: front?.bundleIdentifier,
                                 sourceAppName: front?.localizedName)
        } else if let imageData {
            item = ClipboardItem(kind: .image, imageData: imageData,
                                 sourceBundleID: front?.bundleIdentifier,
                                 sourceAppName: front?.localizedName)
        } else {
            item = nil
        }
        guard let item else { return }

        // Re-copying the most recent entry just bumps it instead of duplicating.
        // (Compare actual content — previews collide, e.g. every image is "Image".)
        if let newest = items.max(by: { $0.createdAt < $1.createdAt }),
           isDuplicate(newest, of: item) {
            newest.createdAt = Date()
            Persistence.shared.save()
            reload()
            return
        }

        Persistence.shared.context.insert(item)
        trim()
        Persistence.shared.save()
        reload()
    }

    private func isDuplicate(_ existing: ClipboardItem, of new: ClipboardItem) -> Bool {
        guard existing.kind == new.kind else { return false }
        switch new.kind {
        case .text:  return existing.text == new.text
        case .image: return existing.imageData == new.imageData
        case .file:  return existing.filePaths == new.filePaths
        }
    }

    /// A single URL with no surrounding prose (what browsers add next to a
    /// copied image) — not text worth recording on its own.
    private func isLoneURL(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: t), let scheme = url.scheme else { return false }
        return ["http", "https", "file", "data"].contains(scheme.lowercased())
    }

    private func tiffAsPNG(_ pb: NSPasteboard) -> Data? {
        guard let tiff = pb.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Delete the oldest unpinned entries beyond the history limit.
    private func trim() {
        let ctx = Persistence.shared.context
        var all = (try? ctx.fetch(FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        all.removeAll(where: \.isPinned)
        guard all.count > limit else { return }
        for old in all.dropFirst(limit) { ctx.delete(old) }
    }

    // MARK: Queries

    func reload() {
        let ctx = Persistence.shared.context
        let fetched = (try? ctx.fetch(FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        // Pinned entries float to the top, newest-first within each group.
        items = fetched.filter(\.isPinned) + fetched.filter { !$0.isPinned }
    }

    var filteredItems: [ClipboardItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.preview.lowercased().contains(q)
                || ($0.sourceAppName ?? "").lowercased().contains(q)
        }
    }

    // MARK: Actions

    func togglePin(_ item: ClipboardItem) {
        item.isPinned.toggle()
        Persistence.shared.save()
        reload()
    }

    func delete(_ item: ClipboardItem) {
        Persistence.shared.context.delete(item)
        Persistence.shared.save()
        reload()
    }

    func clearHistory(keepPinned: Bool = true) {
        for item in items where !(keepPinned && item.isPinned) {
            Persistence.shared.context.delete(item)
        }
        Persistence.shared.save()
        reload()
    }

    /// Put the item back on the pasteboard (without re-recording it —
    /// syncing `lastChangeCount` below makes `poll()` skip our own write).
    func copyToPasteboard(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            if let data = item.imageData { pb.setData(data, forType: .png) }
        case .file:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) as NSURL }
            pb.writeObjects(urls)
        }
        lastChangeCount = pb.changeCount
    }

    /// Simulate ⌘V so the item lands directly in the frontmost app.
    /// Caller must have restored focus to the target app first.
    func sendPasteKeystroke() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }
}
