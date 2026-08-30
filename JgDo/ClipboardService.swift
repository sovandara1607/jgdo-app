import AppKit
import SwiftData

/// Watches the general pasteboard and records history into SwiftData.
/// Polling `changeCount` is the only supported way to observe the pasteboard
/// on macOS; 1.5 s default keeps CPU use negligible (configurable 0.5–5.0 s).
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
        backfillContentHashesIfNeeded()
    }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: AppSettings.clipboardPollInterval, repeats: true) { [weak self] _ in
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
        // Track the change count even while disabled/paused, so resuming
        // doesn't retroactively record whatever was copied in the meantime.
        lastChangeCount = pb.changeCount
        guard isEnabled else { return }
        guard !ClipboardPrivacyService.shared.isPaused else { return }
        // Respect password managers / marked-transient content.
        guard pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) != true,
              pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) != true
        else { return }

        let front = NSWorkspace.shared.frontmostApplication
        guard !ClipboardPrivacyService.shared.isExcluded(bundleID: front?.bundleIdentifier) else { return }
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
        item.recomputeContentHash()

        // Re-copying ANY existing entry (not just the most recent one) just
        // bumps it to the top instead of storing a duplicate — content-hash
        // based, so it catches "copied A, then B, then A again" too, not
        // only immediately-consecutive re-copies.
        if let existing = items.first(where: { $0.contentHash == item.contentHash }) {
            existing.createdAt = Date()
            Persistence.shared.save()
            reload()
            return
        }

        Persistence.shared.context.insert(item)
        trim()
        Persistence.shared.save()
        reload()

        // OCR runs async and writes back onto the already-inserted item —
        // `item` is a live @Model reference, so mutating it later and
        // re-saving is safe (same pattern as the `newest.createdAt = Date()`
        // re-save above).
        if item.kind == .image, let data = item.imageData {
            ClipboardOCRService.recognizeText(in: data) { [weak self] text in
                guard let self, let text, !text.isEmpty else { return }
                item.recognizedText = text
                Persistence.shared.save()
                self.reload()
            }
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

    /// Deletes, in order: unpinned entries past the configured retention
    /// period, unpinned entries pushing total storage over its cap, then
    /// the oldest unpinned entries beyond the count limit. All three are
    /// independent policies — an item can be removed by whichever fires
    /// first, and a save/reload after each keeps `items` accurate for the
    /// checks that follow.
    private func trim() {
        let ctx = Persistence.shared.context
        var all = ctx.fetchLogged(FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]), using: AppLog.clipboard)

        let expired = ClipboardPrivacyService.shared.expiredItems(in: all)
        if !expired.isEmpty {
            let expiredIDs = Set(expired.map(\.persistentModelID))
            for item in expired { ctx.delete(item) }
            all.removeAll { expiredIDs.contains($0.persistentModelID) }
        }

        let overCap = ClipboardPrivacyService.shared.itemsExceedingStorageCap(in: all)
        if !overCap.isEmpty {
            let overCapIDs = Set(overCap.map(\.persistentModelID))
            for item in overCap { ctx.delete(item) }
            all.removeAll { overCapIDs.contains($0.persistentModelID) }
        }

        all.removeAll(where: \.isPinned)
        guard all.count > limit else { return }
        for old in all.dropFirst(limit) { ctx.delete(old) }
    }

    /// One-time, off-main backfill for `contentHash` on rows captured
    /// before that field existed — hashes may include image bytes, so this
    /// deliberately hops off the main actor rather than blocking it the
    /// way a synchronous loop over every history item would.
    private func backfillContentHashesIfNeeded() {
        let missing = items.filter { $0.contentHash == nil }
        guard !missing.isEmpty else { return }
        struct Pending { let id: PersistentIdentifier; let kind: ClipboardItem.Kind; let text: String?; let imageData: Data?; let filePaths: [String] }
        let pending = missing.map {
            Pending(id: $0.persistentModelID, kind: $0.kind, text: $0.text, imageData: $0.imageData, filePaths: $0.filePaths)
        }
        Task.detached(priority: .utility) {
            let hashes = pending.map { p in
                (p.id, ClipboardItem.computeContentHash(kind: p.kind, text: p.text, imageData: p.imageData, filePaths: p.filePaths))
            }
            await MainActor.run {
                let ctx = Persistence.shared.context
                for (id, hash) in hashes {
                    (ctx.model(for: id) as? ClipboardItem)?.contentHash = hash
                }
                Persistence.shared.save()
                ClipboardService.shared.reload()
            }
        }
    }

    // MARK: Queries

    func reload() {
        let ctx = Persistence.shared.context
        let fetched = ctx.fetchLogged(FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]), using: AppLog.clipboard)
        // Pinned entries float to the top, newest-first within each group.
        items = fetched.filter(\.isPinned) + fetched.filter { !$0.isPinned }
    }

    var filteredItems: [ClipboardItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.preview.lowercased().contains(q)
                || ($0.sourceAppName ?? "").lowercased().contains(q)
                || ($0.recognizedText ?? "").lowercased().contains(q)
        }
    }

    // MARK: Actions

    func togglePin(_ item: ClipboardItem) {
        item.isPinned.toggle()
        let nowPinned = item.isPinned
        Persistence.shared.save()
        reload()
        ActionToastCenter.shared.show(nowPinned ? "Clipboard Item Pinned" : "Clipboard Item Unpinned",
                                       icon: nowPinned ? "pin.fill" : "pin", duration: 1.1)
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
            // Also write the OCR'd text (if any) as a plain-text pasteboard
            // type alongside the image, so pasting into a text-only target
            // still gets something useful.
            if let text = item.recognizedText, !text.isEmpty {
                pb.setString(text, forType: .string)
            }
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
