// JgDo/AppcastConfig.swift
// Configuration for Sparkle auto-updates

import Foundation

enum AppcastConfig {
    /// Hosted as a GitHub Release asset: attach `appcast.xml` to each new
    /// GitHub Release on sovandara1607/jgdo-app and this "latest" URL will
    /// always resolve to the most recent one.
    /// Wired to Sparkle via `SparkleDelegateProxy.feedURLString(for:)` in UpdateService.swift.
    static let appcastURL = "https://github.com/sovandara1607/jgdo-app/releases/latest/download/appcast.xml"

    /// The Ed25519 public key is NOT read from here. Sparkle's separate
    /// installer/downloader process validates signatures by reading the key
    /// directly from Info.plist (Sparkle has no delegate hook for this, by
    /// design — the key must be readable without running the app's code).
    ///
    /// Set it as the `SUPublicEDKey` build setting
    /// (INFOPLIST_KEY_SUPublicEDKey) on the JgDo target, for both Debug and
    /// Release configurations, in JgDo.xcodeproj/project.pbxproj or Xcode's
    /// Build Settings editor.
    ///
    /// Generate a key pair with `./bin/sign_update -g` (or `generate_keys`)
    /// from the Sparkle release tools, then paste the printed public key
    /// into that build setting.
}
