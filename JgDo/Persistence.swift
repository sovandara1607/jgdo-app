import Foundation
import CoreGraphics
import SwiftData

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

/// A saved arrangement of application windows that can be restored later.
@Model
final class Workspace {
    var name: String = ""
    var symbolName: String = "square.grid.2x2"
    var createdAt: Date = Date()
    var lastUsedAt: Date?
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
    var workspace: Workspace?

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(bundleID: String, appName: String, title: String?, frame: CGRect) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
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

// MARK: - Container

/// Single shared SwiftData stack. Falls back to an in-memory store if the
/// on-disk store can't be opened (e.g. after a schema change during development)
/// so the app never crashes at launch over persistence.
@MainActor
final class Persistence {
    static let shared = Persistence()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    private init() {
        let schema = Schema([ClipboardItem.self, Workspace.self,
                             WorkspaceWindow.self, AppUsageEvent.self,
                             LayoutPreset.self, LayoutSlot.self,
                             ParkedWindow.self,
                             SnapGroup.self, SnapGroupMember.self])
        let dir = URL.applicationSupportDirectory.appendingPathComponent("JgDo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = ModelConfiguration(url: dir.appendingPathComponent("JgDo.store"))
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Wipe an incompatible development store and retry once before
            // giving up and running in-memory. The -wal/-shm sidecars must go
            // too, or SQLite can replay the old journal into the fresh store.
            let storePath = dir.appendingPathComponent("JgDo.store").path
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: storePath + suffix)
            }
            if let retried = try? ModelContainer(for: schema, configurations: [config]) {
                container = retried
            } else {
                let memory = ModelConfiguration(isStoredInMemoryOnly: true)
                container = try! ModelContainer(for: schema, configurations: [memory])
            }
        }
    }

    func save() {
        try? context.save()
    }
}
