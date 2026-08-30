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
            AppSettings.magnetismEnabledKey: true,
            AppSettings.magnetismDistanceKey: 12.0,
            AppSettings.fileSearchEnabledKey: true,
            AppSettings.dashboardShowCPUKey: true,
            AppSettings.dashboardShowMemoryKey: true,
            AppSettings.smartLayoutsEnabledKey: true,
            AppSettings.pipEnabledKey: true,
            AppSettings.nlWorkspaceEnabledKey: true,
            AppSettings.nlWorkspaceProviderKey: NaturalLanguageProviderKind.ruleBased.rawValue,
            AppSettings.clipboardPollIntervalKey: 1.5,
            AppSettings.showPerCoreCPUKey: false,
            AppSettings.menuBarStatKey: MenuBarStat.off.rawValue,
            AppSettings.lowBatteryThresholdKey: 20,
            AppSettings.lowBatteryEnabledKey: true,
            AppSettings.actionToastsEnabledKey: true,
            AppSettings.windowActionHUDEnabledKey: true,
            AppSettings.placementPreviewEnabledKey: true,
            AppSettings.windowActionHUDDurationKey: 0.65,
            AppSettings.layoutSelectorOverlayEnabledKey: true,
            AppSettings.layoutSelectorDimEnabledKey: true,
            AppSettings.layoutSelectorApplyOnReleaseKey: false,
        ])
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Shared keys + clamping for persisted user settings.
enum AppSettings {
    /// Set once the first-run onboarding flow completes (or is skipped) —
    /// reopenable any time from Settings → About, but never shown
    /// automatically again after the first pass.
    static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    static var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasCompletedOnboardingKey) }
    }
    /// Which areas the user said they mainly want JgDo for, from onboarding's
    /// interest-selection step (`OnboardingInterest`) — comma-joined raw
    /// values. Empty until onboarding's interest step is reached (older
    /// installs that already finished onboarding before this step existed
    /// also read as empty, which every reader below treats as "no
    /// preference stated" rather than "nothing selected").
    static let onboardingInterestsKey = "onboardingInterests"
    static var onboardingInterests: Set<OnboardingInterest> {
        get {
            let raw = UserDefaults.standard.string(forKey: onboardingInterestsKey) ?? ""
            return Set(raw.split(separator: ",").compactMap { OnboardingInterest(rawValue: String($0)) })
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue).joined(separator: ","), forKey: onboardingInterestsKey)
        }
    }
    /// Whether the small "Safari → Left Half" confirmation pill shows after
    /// window/workspace actions (see `ActionToastCenter`). On by default;
    /// this is exactly the kind of thing a "no notification spam" setting
    /// should let a user opt fully out of if they'd rather have silence.
    static let actionToastsEnabledKey = "actionToastsEnabled"
    static var actionToastsEnabled: Bool { UserDefaults.standard.bool(forKey: actionToastsEnabledKey) }
    static let edgeGapKey = "edgeGap"
    static let edgeGapRange: ClosedRange<Double> = 0...40
    /// Clamped tiling/gap padding in points (default 8). Originally read
    /// only by `WindowResizeService`'s own local computed var; exposed here
    /// too now that Window Magnetism wants the exact same value, so a
    /// manually-dragged window that snaps lands with the same spacing a
    /// hotkey-tiled one would.
    static var edgeGap: Double {
        let v = UserDefaults.standard.double(forKey: edgeGapKey)
        return min(max(v, edgeGapRange.lowerBound), edgeGapRange.upperBound)
    }
    static let cleaningDurationKey = "cleaningDuration"
    static let dragSnapEnabledKey = "dragSnapEnabled"
    static let adjacentResizeEnabledKey = "adjacentResizeEnabled"
    /// Ambient edge/window alignment while dragging or resizing with a
    /// plain (no-⌘) mouse drag — distinct from `dragSnapEnabled`, which is
    /// the ⌘-held "snap into available space" feature. Defaults on; hold ⌥
    /// during a drag to bypass it for that gesture, or disable it entirely
    /// here.
    static let magnetismEnabledKey = "magnetismEnabled"
    static var magnetismEnabled: Bool { UserDefaults.standard.bool(forKey: magnetismEnabledKey) }
    static let magnetismDistanceKey = "magnetismDistance"
    static let magnetismDistanceRange: ClosedRange<Double> = 4...30
    /// How close (points) an edge needs to get to a magnet point before it
    /// aligns (default 12).
    static var magnetismDistance: Double {
        let v = UserDefaults.standard.double(forKey: magnetismDistanceKey)
        return v > 0 ? min(max(v, magnetismDistanceRange.lowerBound), magnetismDistanceRange.upperBound) : 12
    }

    /// Whether the Command Palette also searches files (via Spotlight)
    /// alongside windows/apps. Defaults on; disabling it means the palette
    /// never starts an `NSMetadataQuery` at all.
    static let fileSearchEnabledKey = "fileSearchEnabled"
    static var fileSearchEnabled: Bool { UserDefaults.standard.bool(forKey: fileSearchEnabledKey) }
    /// Whether the menu bar's right-click quick panel shows a live CPU/Memory
    /// row (Feature: Menu Bar Mini Dashboard). Both default on; the data is
    /// already flowing from `SystemMonitor` whenever the quick panel is
    /// open (`setQuickPanelVisible`) — these only gate whether it's
    /// *rendered*, not any new polling.
    static let dashboardShowCPUKey = "dashboardShowCPU"
    static var dashboardShowCPU: Bool { UserDefaults.standard.bool(forKey: dashboardShowCPUKey) }
    static let dashboardShowMemoryKey = "dashboardShowMemory"
    static var dashboardShowMemory: Bool { UserDefaults.standard.bool(forKey: dashboardShowMemoryKey) }

    /// Whether `SmartLayoutEngine` learns app-combination patterns at all.
    /// On by default, same convention as `magnetismEnabled`/`fileSearchEnabled`
    /// above — only gates new detection, not existing suggestions/history.
    static let smartLayoutsEnabledKey = "smartLayoutsEnabled"
    static var smartLayoutsEnabled: Bool { UserDefaults.standard.bool(forKey: smartLayoutsEnabledKey) }
    /// Whether the `>float` quick action / "Float Frontmost Window" hotkey
    /// are active. On by default; disabling it means `FloatingWindowManager`
    /// never starts an `SCStream`.
    static let pipEnabledKey = "pipEnabled"
    static var pipEnabled: Bool { UserDefaults.standard.bool(forKey: pipEnabledKey) }
    /// Whether the Natural-Language Workspace panel (hotkey ⌃⌥⇧N) is
    /// active at all. On by default; the rule-based provider needs no
    /// network/model so there's no setup cost to leaving it on.
    static let nlWorkspaceEnabledKey = "nlWorkspaceEnabled"
    static var nlWorkspaceEnabled: Bool { UserDefaults.standard.bool(forKey: nlWorkspaceEnabledKey) }
    /// Which `NaturalLanguageProviding` implementation parses the typed
    /// instruction. Defaults to the offline rule-based one — Apple
    /// Intelligence and the remote model are both explicit opt-ins.
    static let nlWorkspaceProviderKey = "nlWorkspaceProvider"
    static var nlWorkspaceProvider: NaturalLanguageProviderKind {
        NaturalLanguageProviderKind(rawValue: UserDefaults.standard.string(forKey: nlWorkspaceProviderKey) ?? "") ?? .ruleBased
    }
    /// Remote-LLM provider config — the API key itself lives in
    /// `KeychainRemoteLLMKeyStore`, never here; these are just the
    /// (non-secret) endpoint/model, and an explicit separate on/off so
    /// simply having leftover settings from a past trial doesn't silently
    /// re-enable a network call.
    static let remoteLLMEnabledKey = "remoteLLMEnabled"
    static var remoteLLMEnabled: Bool { UserDefaults.standard.bool(forKey: remoteLLMEnabledKey) }
    static let remoteLLMEndpointKey = "remoteLLMEndpoint"
    static var remoteLLMEndpoint: String {
        UserDefaults.standard.string(forKey: remoteLLMEndpointKey) ?? "https://api.openai.com/v1/chat/completions"
    }
    static let remoteLLMModelKey = "remoteLLMModel"
    static var remoteLLMModel: String {
        UserDefaults.standard.string(forKey: remoteLLMModelKey) ?? "gpt-4o-mini"
    }
    /// Small "Safari → Left Half" card shown briefly on ⌃⌥-arrow layout
    /// actions, alongside the ghost-tile placement preview.
    static let windowActionHUDEnabledKey = "windowActionHUDEnabled"
    static var windowActionHUDEnabled: Bool { UserDefaults.standard.bool(forKey: windowActionHUDEnabledKey) }
    /// The ghost-tile placement preview itself (`SnapPreviewOverlay`) —
    /// separate switch from the card above.
    static let placementPreviewEnabledKey = "placementPreviewEnabled"
    static var placementPreviewEnabled: Bool { UserDefaults.standard.bool(forKey: placementPreviewEnabledKey) }
    static let windowActionHUDDurationKey = "windowActionHUDDuration"
    static let windowActionHUDDurationRange: ClosedRange<Double> = 0.4...1.2
    static var windowActionHUDDuration: Double {
        let v = UserDefaults.standard.double(forKey: windowActionHUDDurationKey)
        return v > 0 ? min(max(v, windowActionHUDDurationRange.lowerBound), windowActionHUDDurationRange.upperBound) : 0.65
    }
    /// Whether ⌃⌥←/→ show the "hold and cycle" layout overlay at all — off
    /// reverts those two shortcuts to their original single-shot dual-snap
    /// behavior (same as every other layout hotkey), not a hidden/invisible
    /// version of the new flow.
    static let layoutSelectorOverlayEnabledKey = "layoutSelectorOverlayEnabled"
    static var layoutSelectorOverlayEnabled: Bool { UserDefaults.standard.bool(forKey: layoutSelectorOverlayEnabledKey) }
    /// The subtle full-display dim behind the overlay card — separate
    /// switch from the overlay itself.
    static let layoutSelectorDimEnabledKey = "layoutSelectorDimEnabled"
    static var layoutSelectorDimEnabled: Bool { UserDefaults.standard.bool(forKey: layoutSelectorDimEnabledKey) }
    /// false (default) = every ⌃⌥←/→ press is a complete, independent
    /// action — applies immediately, no holding required, the overlay just
    /// flashes as confirmation. true = the original hold-⌃⌥-then-release-
    /// to-commit gesture, with a live preview while cycling. Defaults to
    /// instant: holding modifiers through a whole multi-press cycle turned
    /// out to feel fiddly in practice compared to every other hotkey in
    /// the app, which is a single discrete press.
    static let layoutSelectorApplyOnReleaseKey = "layoutSelectorApplyOnRelease"
    static var layoutSelectorApplyOnRelease: Bool { UserDefaults.standard.bool(forKey: layoutSelectorApplyOnReleaseKey) }
    /// Starred apps (bundle IDs) — sort first in the Command Palette.
    static let favoriteAppBundleIDsKey = "favoriteAppBundleIDs"
    static var favoriteAppBundleIDs: Set<String> {
        get { Set((UserDefaults.standard.string(forKey: favoriteAppBundleIDsKey) ?? "").split(separator: ",").map(String.init)) }
        set { UserDefaults.standard.set(newValue.joined(separator: ","), forKey: favoriteAppBundleIDsKey) }
    }
    /// Starred layouts — sort first in the Layout Picker grid.
    static let favoriteLayoutsKey = "favoriteLayouts"
    static var favoriteLayouts: Set<WindowLayout> {
        get {
            let raw = UserDefaults.standard.string(forKey: favoriteLayoutsKey) ?? ""
            return Set(raw.split(separator: ",").compactMap { WindowLayout(rawValue: String($0)) })
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue).joined(separator: ","), forKey: favoriteLayoutsKey)
        }
    }
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
    static var lowBatteryAlertsEnabled: Bool { UserDefaults.standard.bool(forKey: lowBatteryEnabledKey) }

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
