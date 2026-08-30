import Foundation
import os

/// Non-destructive backup/recovery for the SwiftData store, used in place of
/// the delete-and-retry behavior `Persistence` used to fall back to. The
/// operating rule throughout this file: **never delete the live store**
/// unless the caller is explicitly restoring a different backup over it
/// (and even then, the thing being overwritten gets backed up first).
enum PersistenceBackup {
    private static let storeSuffixes = ["", "-wal", "-shm"]

    static func backupsDirectory(in storeDir: URL) -> URL {
        storeDir.appendingPathComponent("Backups", isDirectory: true)
    }

    /// Copies `storeName` (+ `-wal`/`-shm` sidecars, whichever exist) into
    /// `Backups/JgDo-{timestamp}.store` before a risky open, then prunes to
    /// the `keep` most recent backups. No-ops (returns `nil`) if there's no
    /// live store yet — nothing to protect on a first launch.
    @discardableResult
    static func backupBeforeOpen(storeDir: URL, storeName: String = "JgDo.store", keep: Int = 5) -> URL? {
        let storePath = storeDir.appendingPathComponent(storeName).path
        guard FileManager.default.fileExists(atPath: storePath) else { return nil }

        let backupsDir = backupsDirectory(in: storeDir)
        do {
            try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        } catch {
            AppLog.persistence.error("Couldn't create Backups directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Fractional seconds keep same-second consecutive calls (e.g. a
        // recovery immediately followed by another backup) from colliding
        // on one filename; a short random suffix is a second guard in case
        // two calls still land in the same millisecond.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let unique = String(UUID().uuidString.prefix(6))
        let destBasePath = backupsDir.appendingPathComponent("JgDo-\(stamp)-\(unique).store").path
        var copiedAny = false
        for suffix in storeSuffixes {
            let srcPath = storePath + suffix
            guard FileManager.default.fileExists(atPath: srcPath) else { continue }
            let destPath = destBasePath + suffix
            do {
                try FileManager.default.copyItem(atPath: srcPath, toPath: destPath)
                copiedAny = true
            } catch {
                AppLog.persistence.error("Couldn't back up \((srcPath as NSString).lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        guard copiedAny else { return nil }
        prune(backupsDir: backupsDir, keep: keep)
        return URL(fileURLWithPath: destBasePath)
    }

    /// Base `.store` file URLs under `Backups/`, newest first. Sidecars are
    /// addressed relative to these (`path + "-wal"` etc.), same convention
    /// as `backupBeforeOpen`.
    static func listBackups(storeDir: URL) -> [URL] {
        let backupsDir = backupsDirectory(in: storeDir)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: backupsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "store" }
            .sorted { modDate($0) > modDate($1) }
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private static func prune(backupsDir: URL, keep: Int) {
        let bases = listBackups(storeDir: backupsDir.deletingLastPathComponent())
        guard bases.count > keep else { return }
        for old in bases.dropFirst(keep) {
            for suffix in storeSuffixes {
                do {
                    try FileManager.default.removeItem(atPath: old.path + suffix)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // Sidecar didn't exist for this backup — fine.
                } catch {
                    AppLog.persistence.error("Couldn't prune old backup \(old.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    enum RecoveryError: LocalizedError {
        case backupMissing
        var errorDescription: String? {
            switch self {
            case .backupMissing: return "That backup file no longer exists."
            }
        }
    }

    /// Overwrites the live store with `backup`, first backing up whatever's
    /// currently live (so a wrong choice is itself reversible). The caller
    /// must relaunch afterward — a `ModelContainer` can't be swapped while
    /// the app is running, it's only read at `Persistence.init()`.
    static func recover(from backup: URL, storeDir: URL, storeName: String = "JgDo.store") throws {
        guard FileManager.default.fileExists(atPath: backup.path) else { throw RecoveryError.backupMissing }
        backupBeforeOpen(storeDir: storeDir, storeName: storeName) // protect the pre-recovery state too
        let storePath = storeDir.appendingPathComponent(storeName).path
        for suffix in storeSuffixes {
            let destPath = storePath + suffix
            let srcPath = backup.path + suffix
            if FileManager.default.fileExists(atPath: destPath) {
                try? FileManager.default.removeItem(atPath: destPath)
            }
            if FileManager.default.fileExists(atPath: srcPath) {
                try FileManager.default.copyItem(atPath: srcPath, toPath: destPath)
            }
        }
    }
}
