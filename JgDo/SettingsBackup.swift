import SwiftUI
import UniformTypeIdentifiers

/// A portable snapshot of user-configurable state — shortcuts + the
/// `AppSettings` preferences that materially affect behavior. Deliberately
/// excludes license/activation state (JgDo has no free tier; importing
/// shouldn't be a license-bypass vector) and clipboard/window data — this
/// is a *settings* backup, not a full data export.
struct SettingsBackup: Codable {
    var version = 1
    var shortcuts: [HotkeyAction: KeyCombo]
    var edgeGap: Double
    var cleaningDuration: Int
    var dragSnapEnabled: Bool
    var adjacentResizeEnabled: Bool
    var clipboardPollInterval: Double
    var showPerCoreCPU: Bool
    var menuBarStat: String
    /// Optional so exports from before this setting existed still decode.
    var lowBatteryThreshold: Int?
    var lowBatteryAlertsEnabled: Bool?

    @MainActor
    static func current() -> SettingsBackup {
        let d = UserDefaults.standard
        return SettingsBackup(
            shortcuts: ShortcutStore.shared.map,
            edgeGap: d.double(forKey: AppSettings.edgeGapKey),
            cleaningDuration: d.integer(forKey: AppSettings.cleaningDurationKey),
            dragSnapEnabled: d.bool(forKey: AppSettings.dragSnapEnabledKey),
            adjacentResizeEnabled: d.bool(forKey: AppSettings.adjacentResizeEnabledKey),
            clipboardPollInterval: AppSettings.clipboardPollInterval,
            showPerCoreCPU: d.bool(forKey: AppSettings.showPerCoreCPUKey),
            menuBarStat: d.string(forKey: AppSettings.menuBarStatKey) ?? MenuBarStat.off.rawValue,
            lowBatteryThreshold: d.object(forKey: AppSettings.lowBatteryThresholdKey) as? Int,
            lowBatteryAlertsEnabled: d.object(forKey: AppSettings.lowBatteryEnabledKey) as? Bool
        )
    }

    @MainActor
    func apply() {
        let d = UserDefaults.standard
        for (action, combo) in shortcuts {
            ShortcutStore.shared.set(combo, for: action)
        }
        d.set(edgeGap, forKey: AppSettings.edgeGapKey)
        d.set(cleaningDuration, forKey: AppSettings.cleaningDurationKey)
        d.set(dragSnapEnabled, forKey: AppSettings.dragSnapEnabledKey)
        d.set(adjacentResizeEnabled, forKey: AppSettings.adjacentResizeEnabledKey)
        d.set(clipboardPollInterval, forKey: AppSettings.clipboardPollIntervalKey)
        d.set(showPerCoreCPU, forKey: AppSettings.showPerCoreCPUKey)
        d.set(menuBarStat, forKey: AppSettings.menuBarStatKey)
        if let t = lowBatteryThreshold { d.set(t, forKey: AppSettings.lowBatteryThresholdKey) }
        if let e = lowBatteryAlertsEnabled { d.set(e, forKey: AppSettings.lowBatteryEnabledKey) }
    }
}

/// `.fileExporter`/`.fileImporter` document wrapper — plain JSON, no custom
/// UTType/Info.plist registration needed.
struct SettingsBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.json]

    var backup: SettingsBackup

    init(backup: SettingsBackup) {
        self.backup = backup
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let decoded = try? JSONDecoder().decode(SettingsBackup.self, from: data)
        else { throw CocoaError(.fileReadCorruptFile) }
        backup = decoded
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(backup)
        return FileWrapper(regularFileWithContents: data)
    }
}
