import Foundation
import CryptoKit

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
/// Keys are self-verifying: `{PLAN}-{XXXX}-{XXXX}-{CHECKSUM}`, where
/// CHECKSUM is a truncated HMAC-SHA256 of PLAN+payload keyed by a secret
/// shared with the website's generator (website/src/lib/license.ts). That
/// lets the app verify a pasted key with no network call and no license
/// server — at the standard tradeoff for this scheme: `secret` below ships
/// inside the compiled binary, so anyone who extracts it (e.g. via
/// `strings JgDo`) could mint their own valid keys. Acceptable for a
/// low-price indie utility; move to server-side verification if that risk
/// profile ever changes.
@Observable
final class LicenseManager {
    static let shared = LicenseManager()

    // ⚠️ MUST exactly match LICENSE_SECRET in website/.env.local (production
    // env), or every key the website generates will fail to validate here.
    // If you ever rotate the website's LICENSE_SECRET, update this to match —
    // and every previously-issued key stops validating, so only rotate if
    // you're prepared to reissue.
    private static let secret = "2e23fcd37752d91ccc0ad624ce42e57937ac33e32d6054a2f00b07cd5f9d50ee"

    private static let storageKey = "jgdo.licenseKey"

    private(set) var plan: LicensePlan
    private(set) var licenseKey: String?

    var isPro: Bool { plan != .free }

    private init() {
        if let stored = UserDefaults.standard.string(forKey: Self.storageKey),
           let plan = Self.validate(stored) {
            licenseKey = stored
            self.plan = plan
        } else {
            licenseKey = nil
            plan = .free
        }
    }

    /// Validates and, on success, persists `key` as the active license.
    @discardableResult
    func activate(key: String) -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let plan = Self.validate(normalized) else { return false }
        UserDefaults.standard.set(normalized, forKey: Self.storageKey)
        licenseKey = normalized
        self.plan = plan
        return true
    }

    func deactivate() {
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        licenseKey = nil
        plan = .free
    }

    /// Parses `{PLAN}-{XXXX}-{XXXX}-{CHECKSUM}` and verifies the checksum.
    /// Returns the encoded plan only if the key is well-formed AND the
    /// checksum matches — never trust the plan code alone.
    private static func validate(_ key: String) -> LicensePlan? {
        let parts = key.split(separator: "-").map(String.init)
        guard parts.count == 4 else { return nil }
        let (planCode, p1, p2, checksum) = (parts[0], parts[1], parts[2], parts[3])
        guard p1.count == 4, p2.count == 4, checksum.count == 4 else { return nil }

        let plan: LicensePlan
        switch planCode {
        case "PRO0": plan = .pro
        case "PLUS": plan = .proPlus
        default: return nil
        }

        let payload = p1 + p2
        guard hmacChecksum(planCode + payload) == checksum else { return nil }
        return plan
    }

    private static func hmacChecksum(_ input: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: key)
        let hex = mac.map { String(format: "%02X", $0) }.joined()
        return String(hex.prefix(4))
    }
}
