//
//  JgDoApp.swift
//  JgDo
//
//  Created by Sovandara Rith on 27/6/26.
//

import SwiftUI

@main
struct JgDoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Default edge/tile gap (points) before the user changes it.
        UserDefaults.standard.register(defaults: [
            AppSettings.edgeGapKey: 8.0,
            AppSettings.dragSnapEnabledKey: true,
            AppSettings.adjacentResizeEnabledKey: true,
            AppSettings.clipboardPollIntervalKey: 1.5,
            AppSettings.showPerCoreCPUKey: false,
            AppSettings.menuBarStatKey: MenuBarStat.off.rawValue,
            AppSettings.lowBatteryThresholdKey: 20,
            AppSettings.lowBatteryEnabledKey: true,
        ])
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Shared keys + clamping for persisted user settings.
enum AppSettings {
    static let edgeGapKey = "edgeGap"
    static let edgeGapRange: ClosedRange<Double> = 0...40
    static let cleaningDurationKey = "cleaningDuration"
    static let dragSnapEnabledKey = "dragSnapEnabled"
    static let adjacentResizeEnabledKey = "adjacentResizeEnabled"
    static let clipboardPollIntervalKey = "clipboardPollInterval"
    static let clipboardPollIntervalRange: ClosedRange<Double> = 0.5...5.0
    static let showPerCoreCPUKey = "showPerCoreCPU"
    /// Which live reading (if any) shows as text next to the menu bar icon.
    static let menuBarStatKey = "menuBarStat"
    static let lowBatteryThresholdKey = "lowBatteryThreshold"
    static let lowBatteryEnabledKey = "lowBatteryAlertsEnabled"
    static let lowBatteryThresholdRange: ClosedRange<Int> = 5...50
    /// Clamped battery percent below which a low-battery alert fires (default 20).
    static var lowBatteryThreshold: Int {
        let v = UserDefaults.standard.object(forKey: lowBatteryThresholdKey) as? Int ?? 20
        return min(max(v, lowBatteryThresholdRange.lowerBound), lowBatteryThresholdRange.upperBound)
    }
    static var lowBatteryAlertsEnabled: Bool {
        UserDefaults.standard.object(forKey: lowBatteryEnabledKey) as? Bool ?? true
    }

    /// Whether ⌘-dragging a window snaps it into the available space (Feature 1).
    static var dragSnapEnabled: Bool { UserDefaults.standard.bool(forKey: dragSnapEnabledKey) }
    /// Whether ⌘-resizing a snapped window resizes its neighbors too (Feature 2).
    static var adjacentResizeEnabled: Bool { UserDefaults.standard.bool(forKey: adjacentResizeEnabledKey) }
    /// Clipboard polling interval in seconds (default 1.5, range 0.5–5.0).
    static var clipboardPollInterval: Double {
        let v = UserDefaults.standard.double(forKey: clipboardPollIntervalKey)
        return v > 0 ? min(max(v, clipboardPollIntervalRange.lowerBound), clipboardPollIntervalRange.upperBound) : 1.5
    }
    /// Whether to show per-core CPU in status popover (default false).
    static var showPerCoreCPU: Bool { UserDefaults.standard.bool(forKey: showPerCoreCPUKey) }

    /// Path to a user-chosen menu bar icon, copied into Application Support
    /// so it survives the original file moving or being deleted. Empty/unset
    /// means "use the bundled JgDo logo".
    static let customStatusIconPathKey = "customStatusIconPath"
    static var customStatusIconURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: customStatusIconPathKey), !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    /// Whether the custom icon should render as a monochrome template
    /// (adapts to light/dark menu bar) rather than in full color.
    static let customStatusIconTemplateKey = "customStatusIconTemplate"
    static var customStatusIconTemplate: Bool { UserDefaults.standard.bool(forKey: customStatusIconTemplateKey) }
}

/// Which live reading, if any, shows as text next to the menu bar icon.
enum MenuBarStat: String, CaseIterable, Identifiable {
    case off, cpu, memory
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:    return "Off"
        case .cpu:    return "CPU"
        case .memory: return "Memory"
        }
    }
}
