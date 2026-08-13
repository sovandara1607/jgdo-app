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
}
