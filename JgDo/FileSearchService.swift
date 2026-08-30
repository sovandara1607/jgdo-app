import AppKit

/// One Spotlight result, detached from `NSMetadataItem` (which can't cross
/// into SwiftUI view state cleanly) into a plain value type.
struct FileSearchResult: Identifiable, Hashable {
    let id: URL   // a file's path is already a stable, unique identity
    let url: URL
    let name: String
    /// "~/Documents/Projects" style display path for the containing folder.
    let folderPath: String
    let icon: NSImage?
    let kind: String?
    let modifiedDate: Date?
    let fileSize: Int64?

    static func == (lhs: FileSearchResult, rhs: FileSearchResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Live file search for the Command Palette, via Spotlight (`NSMetadataQuery`)
/// — deliberately not a custom filesystem crawler, per the requirement to
/// prefer native indexing APIs over an expensive custom search. Scoped to
/// the common locations people actually keep files in (Desktop, Documents,
/// Downloads, and `~/Projects` if it exists) rather than the whole disk,
/// both for speed and so one keystroke in the palette doesn't touch the
/// entire filesystem.
///
/// `NSMetadataQuery` only surfaces Spotlight-indexed content — locations
/// explicitly excluded from Spotlight (System Settings → Siri & Spotlight)
/// or certain network/removable volumes won't appear here. That's a
/// property of using Spotlight, not a bug; there's no lower-risk way to
/// reach those without the custom crawler this is explicitly avoiding.
@MainActor
@Observable
final class FileSearchService {
    static let shared = FileSearchService()

    private(set) var results: [FileSearchResult] = []

    private var query: NSMetadataQuery?
    private var finishObserver: NSObjectProtocol?
    private var updateObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var activeQueryText = ""

    private init() {}

    /// Desktop/Documents/Downloads always; `~/Projects` only if it exists —
    /// matches the brief's own example list without guessing at folders
    /// that usually aren't there.
    static var searchScopes: [String] {
        let home = NSHomeDirectory()
        var scopes = ["\(home)/Desktop", "\(home)/Documents", "\(home)/Downloads"]
        let projects = "\(home)/Projects"
        if FileManager.default.fileExists(atPath: projects) { scopes.append(projects) }
        return scopes
    }

    /// Debounced — restarts the underlying Spotlight query at most once
    /// per ~150ms of typing, not on every keystroke, so fast typing doesn't
    /// spin up and tear down a query per character.
    func search(_ text: String) {
        debounceTask?.cancel()
        guard AppSettings.fileSearchEnabled else {
            stopQuery()
            results = []
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.runQuery(text: trimmed)
        }
    }

    /// Stops the live query — call when the palette closes so Spotlight
    /// isn't kept busy in the background for a search nobody's looking at.
    func stop() {
        debounceTask?.cancel()
        stopQuery()
        results = []
    }

    private func runQuery(text: String) {
        stopQuery()
        activeQueryText = text
        let predicate = text.isEmpty ? Self.recentFilesPredicate() : Self.predicate(forQuery: text)
        let q = NSMetadataQuery()
        q.predicate = predicate
        q.searchScopes = Self.searchScopes
        q.sortDescriptors = text.isEmpty
            ? [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
            : []
        query = q

        // `queue: .main` only guarantees which dispatch queue invokes this,
        // not Swift-concurrency MainActor isolation (a separate,
        // compile-time-checked property) — hop explicitly so the compiler
        // can verify `handleResults()`'s MainActor-isolated access.
        finishObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleResults() } }
        updateObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: q, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleResults() } }

        q.start()
    }

    private func stopQuery() {
        query?.stop()
        if let o = finishObserver { NotificationCenter.default.removeObserver(o) }
        if let o = updateObserver { NotificationCenter.default.removeObserver(o) }
        finishObserver = nil
        updateObserver = nil
        query = nil
    }

    private func handleResults() {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }
        let items = (q.results as? [NSMetadataItem]) ?? []
        var mapped = items.compactMap(Self.makeResult(from:))
        // Spotlight's own CONTAINS[cd] predicate already filters to
        // name-substring matches; re-scoring with the same `FuzzyMatch`
        // the rest of the app's search UX uses keeps ranking quality/feel
        // consistent (tighter, earlier matches first) without ever
        // dropping a result Spotlight already deemed a match — a
        // subsequence match is implied by a substring match, so this
        // re-rank can only reorder, never exclude.
        if !activeQueryText.isEmpty {
            mapped = mapped
                .compactMap { result -> (FileSearchResult, Int)? in
                    guard let score = FuzzyMatch.score(query: activeQueryText, target: result.name) else { return nil }
                    return (result, score)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        results = Array(mapped.prefix(20))
    }

    // MARK: - Pure helpers (unit-testable without a live Spotlight index)

    static func predicate(forQuery text: String) -> NSPredicate {
        NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@ OR kMDItemDisplayName CONTAINS[cd] %@", text, text)
    }

    /// "Recent files" tier — anything indexed, not just a specific kind,
    /// excluding plain folders (a folder result isn't very useful to
    /// "open" from a launcher the way a document is).
    static func recentFilesPredicate() -> NSPredicate {
        NSPredicate(format: "kMDItemContentTypeTree != %@", "public.folder")
    }

    static func displayFolderPath(for url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        if folder.hasPrefix(home) {
            return "~" + folder.dropFirst(home.count)
        }
        return folder
    }

    private static func makeResult(from item: NSMetadataItem) -> FileSearchResult? {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let url = URL(fileURLWithPath: path)
        let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String) ?? url.lastPathComponent
        return FileSearchResult(
            id: url, url: url, name: name, folderPath: displayFolderPath(for: url),
            icon: NSWorkspace.shared.icon(forFile: path),
            kind: item.value(forAttribute: NSMetadataItemKindKey) as? String,
            modifiedDate: item.value(forAttribute: NSMetadataItemContentModificationDateKey) as? Date,
            fileSize: item.value(forAttribute: NSMetadataItemFSSizeKey) as? Int64
        )
    }
}
