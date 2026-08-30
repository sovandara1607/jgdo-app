import Foundation
import CryptoKit
import os

enum LicensePlan: String {
    case free, pro, proPlus

    var displayName: String {
        switch self {
        case .free:    return "Free"
        case .pro:     return "Pro"
        case .proPlus: return "Pro+"
        }
    }
}

/// Validates and persists JgDo license keys, entirely offline.
///
/// Tokens are `base64(payload-JSON).base64(Ed25519 signature)` — signed by
/// the website's `tools/license-signer` using a private key that never
/// leaves that side. This app ships only the matching **public** key below,
/// so extracting the compiled binary (e.g. via `strings JgDo`) can no
/// longer be used to mint new valid licenses — the previous scheme signed
/// with a symmetric HMAC secret embedded in the binary, which anyone who
/// extracted it could reuse to forge keys. That scheme's issued keys are
/// intentionally incompatible with this one (see `LicenseVerificationTests`);
/// every existing license had to be reissued when this shipped.
@Observable
final class LicenseManager {
    static let shared = LicenseManager()

    /// Ed25519 public key, paired with the private key held by
    /// `tools/license-signer` (outside this app target, never committed —
    /// see `tools/license-signer/README.md`). Safe to ship: a public key
    /// only lets you verify signatures, never create them.
    private static let publicKeyBase64 = "SkhEDZbt296k0FcI+3WCzhQAPKjFM2CYtujqAr75JlI="

    private(set) var plan: LicensePlan
    private(set) var licenseKey: String?

    var isPro: Bool { plan != .free }

    private init() {
        if let stored = KeychainLicenseStore.load(),
           let payload = Self.verify(stored) {
            licenseKey = stored
            plan = LicensePlan(rawValue: payload.plan) ?? .free
        } else {
            licenseKey = nil
            plan = .free
        }
    }

    /// Validates and, on success, persists `key` (Keychain, not
    /// `UserDefaults`) as the active license.
    @discardableResult
    func activate(key: String) -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = Self.verify(normalized) else { return false }
        guard KeychainLicenseStore.save(normalized) else {
            // Signature checked out but we couldn't persist it — don't
            // report success for a license that won't survive relaunch.
            AppLog.license.error("License verified but Keychain save failed; not activating.")
            return false
        }
        licenseKey = normalized
        plan = LicensePlan(rawValue: payload.plan) ?? .free
        return true
    }

    func deactivate() {
        KeychainLicenseStore.clear()
        licenseKey = nil
        plan = .free
        // Immediately, not just "until next launch": stop every subsystem
        // that only makes sense while licensed — global hotkeys, ⌘-drag
        // snapping, clipboard polling, battery monitoring, cleaning mode.
        // Deactivation used to only clear the stored key; everything else
        // kept running untouched until the app was quit and relaunched.
        LicenseFeatureCoordinator.shared.stop()
    }

    /// Splits `token` into its payload and signature halves, verifies the
    /// signature against `publicKeyBase64` **before** trusting the decoded
    /// JSON at all, then rejects anything with an unrecognized payload
    /// version or plan code. `publicKeyBase64` is a parameter (defaulting
    /// to the app's real key) purely so tests can verify against a
    /// throwaway keypair without touching the production key.
    static func verify(_ token: String, publicKeyBase64: String = LicenseManager.publicKeyBase64) -> LicensePayload? {
        let parts = token.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              let payloadData = Data(base64Encoded: parts[0]),
              let signatureData = Data(base64Encoded: parts[1]) else { return nil }

        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            AppLog.license.fault("The embedded license public key is malformed — no license can ever validate.")
            return nil
        }
        // Verify the signature over the raw payload bytes BEFORE decoding —
        // decoding first and checking the signature after would mean a
        // well-formed-but-unsigned/tampered payload gets parsed (and its
        // fields potentially acted on) ahead of the trust check.
        guard publicKey.isValidSignature(signatureData, for: payloadData) else { return nil }

        guard let payload = try? JSONDecoder().decode(LicensePayload.self, from: payloadData),
              payload.version == LicensePayload.currentVersion,
              LicensePlan(rawValue: payload.plan) != nil
        else { return nil }
        return payload
    }
}
