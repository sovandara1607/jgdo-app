import Foundation

/// One top-level folder's on-disk size, for the Disk tile's storage
/// breakdown — a lightweight, on-demand alternative to macOS's own Storage
/// pane (which scans everything; this only checks a handful of common
/// culprits).
struct StorageCategory: Identifiable {
    var id: String { name }
    let name: String
    let path: String
    var sizeBytes: Int64
}

/// Scans a fixed set of home-folder categories via `/usr/bin/du` (much
/// faster than a Swift-level recursive `FileManager` walk for large trees
/// like a Photos library) — run concurrently, on demand only (never
/// automatically), since even `du` can take a few seconds on a large disk.
@Observable
final class StorageBreakdownService {
    static let shared = StorageBreakdownService()
    private init() {}

    private(set) var categories: [StorageCategory] = []
    private(set) var isScanning = false
    private(set) var lastScanned: Date?

    private static let folders: [(name: String, path: String)] = [
        ("Applications", "/Applications"),
        ("Desktop", NSHomeDirectory() + "/Desktop"),
        ("Documents", NSHomeDirectory() + "/Documents"),
        ("Downloads", NSHomeDirectory() + "/Downloads"),
        ("Pictures", NSHomeDirectory() + "/Pictures"),
        ("Movies", NSHomeDirectory() + "/Movies"),
        ("Music", NSHomeDirectory() + "/Music"),
    ]

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let group = DispatchGroup()
            var results: [StorageCategory] = []
            let lock = NSLock()
            for (name, path) in Self.folders where FileManager.default.fileExists(atPath: path) {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let size = Self.duSize(path: path)
                    lock.lock()
                    results.append(StorageCategory(name: name, path: path, sizeBytes: size))
                    lock.unlock()
                    group.leave()
                }
            }
            group.wait()
            results.sort { $0.sizeBytes > $1.sizeBytes }
            DispatchQueue.main.async {
                self?.categories = results
                self?.isScanning = false
                self?.lastScanned = Date()
            }
        }
    }

    private static func duSize(path: String) -> Int64 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        task.arguments = ["-sk", path]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let str = String(data: data, encoding: .utf8),
                  let kb = str.split(separator: "\t").first.flatMap({ Int64($0) }) else { return 0 }
            return kb * 1024
        } catch {
            return 0
        }
    }
}
