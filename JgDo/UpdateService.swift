
// JgDo/UpdateService.swift
// Sparkle auto-update service wrapper

import Foundation
import Sparkle
import os

/// Sparkle's delegate protocol requires `NSObjectProtocol` conformance, which
/// would force `UpdateService` itself to inherit from `NSObject`. Instead we
/// keep a small proxy object as the actual delegate and forward callbacks to
/// the shared `UpdateService`, so `UpdateService` can stay a plain
/// `@Observable` class.
private final class SparkleDelegateProxy: NSObject, SPUUpdaterDelegate {
    weak var owner: UpdateService?

    /// Drives the feed URL from `AppcastConfig` instead of Info.plist, so it
    /// stays editable from Swift.
    func feedURLString(for updater: SPUUpdater) -> String? {
        AppcastConfig.appcastURL
    }

    /// Opts into the "beta" channel (appcast items tagged
    /// `<sparkle:channel>beta</sparkle:channel>`) when the user enables
    /// prerelease updates.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        owner?.allowPrereleaseUpdates == true ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        DispatchQueue.main.async { [weak owner] in
            owner?.updateAvailable = true
            owner?.updateInfo = item
            owner?.updateCheckError = nil
            owner?.lastCheckDate = Date()
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        DispatchQueue.main.async { [weak owner] in
            owner?.updateAvailable = false
            owner?.updateInfo = nil
            owner?.updateCheckError = nil
            owner?.lastCheckDate = Date()
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        DispatchQueue.main.async { [weak owner] in
            owner?.updateCheckError = error.localizedDescription
            owner?.lastCheckDate = Date()
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        // Optional: prepare for install (save state, etc.)
        AppLog.general.info("Will install update: \(item.displayVersionString, privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        // Appcast loaded successfully
    }
}

@Observable
final class UpdateService {
    static let shared = UpdateService()

    private let delegateProxy = SparkleDelegateProxy()
    private let updaterController: SPUStandardUpdaterController
    let updater: SPUUpdater

    var updateAvailable = false
    var updateInfo: SUAppcastItem?
    var updateCheckError: String?
    var lastCheckDate: Date?
    var allowPrereleaseUpdates: Bool

    private init() {
        allowPrereleaseUpdates = UserDefaults.standard.bool(forKey: "allowPrereleaseUpdates")

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegateProxy,
            userDriverDelegate: nil
        )
        updater = updaterController.updater
        delegateProxy.owner = self

        // Auto-check settings
        updater.automaticallyChecksForUpdates = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
        updater.updateCheckInterval = 3600 // 1 hour
    }

    /// Manually check for updates (shows UI)
    func checkForUpdates() {
        updateCheckError = nil
        updater.checkForUpdates()
    }

    /// Check for updates in background (no UI unless update found)
    func checkForUpdatesInBackground() {
        updateCheckError = nil
        updater.checkForUpdatesInBackground()
    }

    /// Set auto-check preference
    func setAutoCheckUpdates(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        UserDefaults.standard.set(enabled, forKey: "autoCheckUpdates")
    }

    /// Set prerelease preference
    func setAllowPrereleaseUpdates(_ enabled: Bool) {
        allowPrereleaseUpdates = enabled
        UserDefaults.standard.set(enabled, forKey: "allowPrereleaseUpdates")
        updater.resetUpdateCycle()
    }
}

