import Foundation

/// Remembers the last few layout commands applied via the Command Palette
/// (`bundleID|layoutRawValue`, most-recent-first, comma-joined in
/// UserDefaults) — shown as the palette's RECENT section when the search
/// field is empty.
enum RecentCommandsStore {
    private static let key = "recentPaletteCommands"
    private static let limit = 5

    struct Entry {
        let bundleID: String
        let layout: WindowLayout
    }

    static var recent: [Entry] {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return raw.split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let layout = WindowLayout(rawValue: String(parts[1])) else { return nil }
            return Entry(bundleID: String(parts[0]), layout: layout)
        }
    }

    static func record(bundleID: String, layout: WindowLayout) {
        var entries = recent.filter { $0.bundleID != bundleID || $0.layout != layout }
        entries.insert(Entry(bundleID: bundleID, layout: layout), at: 0)
        let encoded = entries.prefix(limit).map { "\($0.bundleID)|\($0.layout.rawValue)" }.joined(separator: ",")
        UserDefaults.standard.set(encoded, forKey: key)
    }
}
