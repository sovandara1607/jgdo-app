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
                             WorkspaceWindow.self, AppUsageEvent.self])
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
