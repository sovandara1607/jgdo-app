import Foundation
import CoreGraphics
import SwiftData
import CryptoKit
import os

// MARK: - SwiftData models

/// One captured pasteboard entry. Text is stored inline; images go to
/// external storage so the store file stays small.
@Model
final class ClipboardItem {
    enum Kind: String, Codable { case text, image, file }

    var kindRaw: String = Kind.text.rawValue
    var text: String?
    @Attribute(.externalStorage) var imageData: Data?
    /// Text extracted from `imageData` via `ClipboardOCRService`, filled in
    /// asynchronously right after capture (nil until then, or forever if
    /// none was found) — makes screenshots searchable/pasteable as text.
    var recognizedText: String?
    /// File URLs are stored as strings (bookmarks would break without sandbox anyway).
    var filePaths: [String] = []
    var createdAt: Date = Date()
    var isPinned: Bool = false
    /// Bundle ID of the app that was frontmost when the copy happened.
    var sourceBundleID: String?
    var sourceAppName: String?
    /// SHA-256 of the item's actual content (text bytes / image bytes /
    /// joined file paths), for cross-item deduplication — `ClipboardService`
    /// used to only compare a new capture against the single most-recent
    /// item, so two identical copies with something else in between would
    /// both get stored. `nil` only for rows captured before this field
    /// existed, until `ClipboardService`'s one-time backfill catches up.
    var contentHash: String?

    var kind: Kind { Kind(rawValue: kindRaw) ?? .text }

    /// Short single-line preview used in list rows and dedupe checks.
    var preview: String {
        switch kind {
        case .text:
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > 120 ? String(t.prefix(120)) + "…" : t
        case .image:
            return "Image"
        case .file:
            return filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }

    init(kind: Kind, text: String? = nil, imageData: Data? = nil,
         filePaths: [String] = [], sourceBundleID: String? = nil,
         sourceAppName: String? = nil) {
        self.kindRaw = kind.rawValue
        self.text = text
        self.imageData = imageData
        self.filePaths = filePaths
        self.createdAt = Date()
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
    }
}

extension ClipboardItem {
    /// Pure content-hash computation, deliberately `nonisolated` (and
    /// operating only on plain value types, not the `@Model` instance
    /// itself) so it's safe to call from a background task — used both at
    /// capture time and by `ClipboardService`'s one-time backfill for rows
    /// that predate `contentHash`, which hashes potentially many images'
    /// worth of bytes and shouldn't do that on the main actor.
    nonisolated static func computeContentHash(kind: Kind, text: String?, imageData: Data?, filePaths: [String]) -> String {
        var hasher = SHA256()
        // Mix in the kind so a text item and a single-path file item that
        // happen to contain the identical string (e.g. "/tmp/a") don't hash
        // identically and get treated as duplicates of each other.
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data([0])) // fixed separator between the kind tag and the content below
        switch kind {
        case .text:
            if let text { hasher.update(data: Data(text.utf8)) }
        case .image:
            if let imageData { hasher.update(data: imageData) }
        case .file:
            hasher.update(data: Data(filePaths.joined(separator: "\n").utf8))
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Recomputes and stores this item's dedup hash from its current
    /// content. Mutates the `@Model` instance, so — unlike
    /// `computeContentHash` — this must run on the main actor.
    func recomputeContentHash() {
        contentHash = Self.computeContentHash(kind: kind, text: text, imageData: imageData, filePaths: filePaths)
    }
}

/// A saved arrangement of application windows that can be restored later.
@Model
final class Workspace {
    var name: String = ""
    var symbolName: String = "square.grid.2x2"
    var createdAt: Date = Date()
    var lastUsedAt: Date?
    /// If true, this workspace is restored automatically at app launch
    /// (see `WorkspaceService`). Off by default — restoring windows
    /// unprompted at every launch is surprising unless the user opts in.
    var restoreOnLaunch: Bool = false
    /// Starred — sorts to the top of the Workspaces list.
    var isFavorite: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \WorkspaceWindow.workspace)
    var windows: [WorkspaceWindow] = []

    init(name: String, symbolName: String = "square.grid.2x2") {
        self.name = name
        self.symbolName = symbolName
        self.createdAt = Date()
    }
}

/// One window's placement inside a Workspace. Frame is stored in AppKit
/// coordinates (bottom-left origin) relative to the whole desktop.
@Model
final class WorkspaceWindow {
    var bundleID: String = ""
    var appName: String = ""
    /// Window title at capture time — used to match the right AX window on
    /// restore when an app has several windows.
    var title: String?
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
    /// The display's stable `CGDisplayCreateUUIDFromDisplayID` at capture
    /// time — survives display arrangement changes better than raw
    /// coordinates alone, so restore can detect "this exact monitor is
    /// gone" instead of just "nothing currently overlaps this position"
    /// (which can coincidentally match the wrong screen). `nil` for rows
    /// saved before this field existed; restore falls back to geometric
    /// containment for those, same as before.
    var displayUUID: String?
    var workspace: Workspace?

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(bundleID: String, appName: String, title: String?, frame: CGRect, displayUUID: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.displayUUID = displayUUID
        self.x = frame.minX
        self.y = frame.minY
        self.width = frame.width
        self.height = frame.height
    }
}

/// A saved window-layout SHAPE (fractional rects, not tied to any specific
/// app) that can be reapplied to whatever windows happen to be on screen —
/// distinct from `Workspace`, which restores specific *apps* to specific
/// absolute positions. Slot 0 always gets the frontmost window, slot 1 the
/// next, etc., regardless of what's running — see `LayoutPresetService`.
@Model
final class LayoutPreset {
    var name: String = ""
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \LayoutSlot.preset)
    var slots: [LayoutSlot] = []

    init(name: String) {
        self.name = name
        self.createdAt = Date()
    }
}

/// One window slot's shape within a `LayoutPreset` — a fraction (0...1) of
/// the screen's visible frame, AppKit coords (bottom-left origin).
@Model
final class LayoutSlot {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
    var orderIndex: Int = 0
    var preset: LayoutPreset?

    var fraction: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(fraction: CGRect, orderIndex: Int) {
        self.x = fraction.minX
        self.y = fraction.minY
        self.width = fraction.width
        self.height = fraction.height
        self.orderIndex = orderIndex
    }
}

/// A named group of specific windows that are managed as one logical unit —
/// moved, resized, minimized, or closed together — while remembering each
/// member's shape RELATIVE to the group's own bounding box, so the group's
/// internal layout survives being moved to a different display/position.
/// Distinct from `Workspace` (restore point for specific apps at specific
/// absolute places) and `LayoutPreset` (an app-agnostic shape) — a
/// `SnapGroup` is both: specific apps, AND a live-managed shape. See
/// `SnapGroupService`.
@Model
final class SnapGroup {
    var name: String = ""
    var createdAt: Date = Date()
    /// The group's bounding box (AppKit coords) at capture time — the
    /// default place `restore()` puts it back, before any `moveGroup`.
    var boundsX: Double = 0
    var boundsY: Double = 0
    var boundsWidth: Double = 0
    var boundsHeight: Double = 0
    @Relationship(deleteRule: .cascade, inverse: \SnapGroupMember.group)
    var members: [SnapGroupMember] = []

    var bounds: CGRect { CGRect(x: boundsX, y: boundsY, width: boundsWidth, height: boundsHeight) }

    init(name: String, bounds: CGRect) {
        self.name = name
        self.createdAt = Date()
        self.boundsX = bounds.minX
        self.boundsY = bounds.minY
        self.boundsWidth = bounds.width
        self.boundsHeight = bounds.height
    }
}

/// One window's identity + shape within a `SnapGroup`. `fx/fy/fw/fh` are
/// fractions (0...1) of the group's bounding box — resolving them against
/// a NEW bounding box (e.g. on a different display) is how "move entire
/// group" preserves the windows' relative layout.
@Model
final class SnapGroupMember {
    var bundleID: String = ""
    var appName: String = ""
    var title: String = ""
    var fx: Double = 0
    var fy: Double = 0
    var fw: Double = 0
    var fh: Double = 0
    var group: SnapGroup?

    var fraction: CGRect { CGRect(x: fx, y: fy, width: fw, height: fh) }

    init(bundleID: String, appName: String, title: String, fraction: CGRect) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.fx = fraction.minX
        self.fy = fraction.minY
        self.fw = fraction.width
        self.fh = fraction.height
    }
}

/// A window that's been "parked" — temporarily removed from the workspace
/// (via AX minimize, so the OS's own restore machinery is a second line of
/// defense) with its full pre-park context captured independently, so
/// restore is robust even across a monitor reconnect. See
/// `WindowParkingService`.
@Model
final class ParkedWindow {
    var bundleID: String = ""
    var appName: String = ""
    var title: String = ""
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
    /// The display's `localizedName` at park time — used to detect "that
    /// monitor is gone" on restore and fall back gracefully.
    var screenName: String?
    var parkedAt: Date = Date()

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(bundleID: String, appName: String, title: String, frame: CGRect, screenName: String?) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.x = frame.minX
        self.y = frame.minY
        self.width = frame.width
        self.height = frame.height
        self.screenName = screenName
        self.parkedAt = Date()
    }
}

/// App-activation event used by the workflow insights engine.
@Model
final class AppUsageEvent {
    var bundleID: String = ""
    var appName: String = ""
    var timestamp: Date = Date()
    /// The app the user switched away from — lets us detect frequent pairs.
    var previousBundleID: String?

    init(bundleID: String, appName: String, previousBundleID: String?) {
        self.bundleID = bundleID
        self.appName = appName
        self.timestamp = Date()
        self.previousBundleID = previousBundleID
    }
}

/// A remembered "these two apps get paired often" signal — no AI, just a
/// simple local frequency + recency score per unordered app-bundle pair.
/// Powers the dual-snap auto-pick's "previously paired window" ranking
/// tier (see `WindowPartnerRanking`/`WindowPairService`): if you keep
/// pairing VS Code with Safari, snapping VS Code increasingly prefers
/// Safari for the other side. `bundleIDA` is always the
/// lexicographically-smaller of the two bundle IDs so a pair is never
/// stored/counted under both orderings.
@Model
final class WindowPairScore {
    var bundleIDA: String = ""
    var bundleIDB: String = ""
    var pairCount: Int = 0
    var lastPairedAt: Date = Date()

    /// Callers pass the pair in either order — the initializer normalizes it.
    init(bundleIDA: String, bundleIDB: String) {
        if bundleIDA < bundleIDB {
            self.bundleIDA = bundleIDA
            self.bundleIDB = bundleIDB
        } else {
            self.bundleIDA = bundleIDB
            self.bundleIDB = bundleIDA
        }
        self.pairCount = 0
        self.lastPairedAt = Date()
    }
}

/// One detected "session" of back-and-forth switching between the same set
/// of apps — the raw signal `SmartLayoutEngine` accumulates over time to
/// decide whether a combination recurs often enough to suggest. One row per
/// *session* (not per activation — `SmartLayoutEngine` dedupes a
/// continuously-active session down to a single observation), so
/// `timesSeen` for a signature is simply a row count, not something that
/// needs its own counter field prone to getting out of sync.
@Model
final class AppCombinationObservation {
    /// Sorted, `|`-joined bundle IDs — e.g. "com.apple.Terminal|com.apple.dt.Xcode".
    var signature: String = ""
    var timestamp: Date = Date()

    init(signature: String) {
        self.signature = signature
        self.timestamp = Date()
    }
}

/// A not-yet-accepted Smart Layout pattern — surfaced once its signature's
/// `AppCombinationObservation` count crosses the recurrence threshold.
/// Never applied automatically; the popover tile always requires an
/// explicit "Save as Workspace" or "Ignore".
@Model
final class SmartLayoutSuggestion {
    enum Status: String, Codable { case pending, ignored, accepted }

    /// Same sorted/joined shape as `AppCombinationObservation.signature` —
    /// the join key between the two.
    var appSignature: String = ""
    var suggestedName: String = ""
    var timesSeen: Int = 0
    var firstSeenAt: Date = Date()
    var lastSeenAt: Date = Date()
    var statusRaw: String = Status.pending.rawValue
    /// Fractional geometry captured the moment this suggestion was first
    /// created — display-only (an at-a-glance sense of the pattern's
    /// layout); accepting a suggestion re-captures LIVE geometry via
    /// `WorkspaceService.saveCurrentLayout`, it doesn't replay these.
    @Relationship(deleteRule: .cascade, inverse: \SmartLayoutSlot.suggestion)
    var slots: [SmartLayoutSlot] = []

    var status: Status { Status(rawValue: statusRaw) ?? .pending }

    init(appSignature: String, suggestedName: String) {
        self.appSignature = appSignature
        self.suggestedName = suggestedName
        self.timesSeen = 0
        self.firstSeenAt = Date()
        self.lastSeenAt = Date()
    }
}

/// One app's fractional on-screen position within a `SmartLayoutSuggestion`
/// at capture time — same shape as `LayoutSlot`, just additionally tagged
/// with which app it belongs to (a `SmartLayoutSuggestion` is about a
/// specific app combination, unlike `LayoutPreset`'s app-agnostic slots).
@Model
final class SmartLayoutSlot {
    var bundleID: String = ""
    var appName: String = ""
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
    var suggestion: SmartLayoutSuggestion?

    var fraction: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(bundleID: String, appName: String, fraction: CGRect) {
        self.bundleID = bundleID
        self.appName = appName
        self.x = fraction.minX
        self.y = fraction.minY
        self.width = fraction.width
        self.height = fraction.height
    }
}

// MARK: - Container

/// How the on-disk store came up at launch. Drives the recovery banner in
/// Settings → General → Backup.
enum PersistenceLoadState: Equatable {
    /// The versioned/migrated on-disk store opened normally.
    case ready
    /// The on-disk store couldn't be opened (corruption, an unmigratable
    /// shape change, disk error, …). Nothing was deleted — `backupURL`
    /// points at the pre-open snapshot `Persistence` took just in case, and
    /// the app is currently running against a temporary, unsaved in-memory
    /// store so it can still launch. The user must explicitly choose to
    /// recover from a backup or continue with empty data.
    case failed(description: String, backupURL: URL?)
}

/// Single shared SwiftData stack. Never deletes the user's on-disk store:
/// every open attempt is preceded by a timestamped backup (`PersistenceBackup`),
/// and if the store still can't be opened, the app falls back to a temporary
/// in-memory container rather than wiping anything — see `loadState`.
@MainActor
@Observable
final class Persistence {
    static let shared = Persistence()

    let container: ModelContainer
    let storeDirectory: URL
    private(set) var loadState: PersistenceLoadState = .ready

    var context: ModelContext { container.mainContext }

    /// Timestamped `.store` snapshots under `Backups/`, newest first —
    /// candidates for "Recover from Backup…" in Settings.
    var availableBackups: [URL] { PersistenceBackup.listBackups(storeDir: storeDirectory) }

    private init() {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let dir = URL.applicationSupportDirectory.appendingPathComponent("JgDo", isDirectory: true)
        storeDirectory = dir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            AppLog.persistence.error("Couldn't create Application Support/JgDo: \(error.localizedDescription, privacy: .public)")
        }
        let config = ModelConfiguration(url: dir.appendingPathComponent("JgDo.store"))

        // Always protect the existing store before an open attempt that
        // could fail — this is the only place data would previously have
        // been deleted, so it's the only place that needs a safety net.
        let backupURL = PersistenceBackup.backupBeforeOpen(storeDir: dir)

        do {
            container = try ModelContainer(for: schema, migrationPlan: JgDoMigrationPlan.self, configurations: [config])
        } catch {
            AppLog.persistence.fault("""
                Failed to open JgDo.store: \(error.localizedDescription, privacy: .public). \
                Nothing was deleted; a backup was preserved at \
                \(backupURL?.path ?? "n/a", privacy: .public).
                """)
            // Fall back to a clearly temporary, unsaved in-memory container
            // so the app can still launch. The on-disk file is left exactly
            // as it was for the user to recover from Settings, or for
            // manual inspection — never auto-deleted or silently replaced.
            let memory = ModelConfiguration(isStoredInMemoryOnly: true)
            container = (try? ModelContainer(for: schema, configurations: [memory]))
                ?? Self.emergencyEmptyContainer(schema: schema)
            loadState = .failed(description: error.localizedDescription, backupURL: backupURL)
        }
    }

    /// Last-resort fallback if even an in-memory container fails to build —
    /// that indicates a programming error in the schema itself (e.g. two
    /// models with a broken relationship), not a user-data problem, so
    /// there's nothing left to protect by staying alive. Still never
    /// touches the on-disk store.
    private static func emergencyEmptyContainer(schema: Schema) -> ModelContainer {
        guard let container = try? ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]) else {
            fatalError("JgDo could not construct even an in-memory model container — this is a schema programming error, not recoverable at runtime.")
        }
        return container
    }

    func save() {
        do {
            try context.save()
        } catch {
            AppLog.persistence.error("SwiftData save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Overwrites the live on-disk store with `backup` (itself backed up
    /// first) and signals the caller to relaunch — a `ModelContainer` can't
    /// be swapped while running, it's only read once at `init()`.
    func recover(from backup: URL) throws {
        try PersistenceBackup.recover(from: backup, storeDir: storeDirectory)
    }
}
