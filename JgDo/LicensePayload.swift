import Foundation

/// The data a license token carries once its signature has been verified.
/// `version` lets `LicenseManager` reject a payload shape it doesn't
/// understand outright rather than guessing — bump it for any change that
/// isn't purely additive. `features`/`licenseID` aren't enforced by
/// anything yet (this pass is a format upgrade, not a business-logic
/// change — see `LicenseManager`), but exist so a future pass can add
/// expiry/seat/feature-flag checks without another format break.
struct LicensePayload: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    /// Matches `LicensePlan.rawValue` ("pro" / "proPlus").
    var plan: String
    /// Opaque identifier (e.g. an order or customer ID) — not shown in the
    /// UI, useful for support correlation against the website's own records.
    var licenseID: String
    var issuedAt: Date
    var features: [String]

    init(plan: LicensePlan, licenseID: String, issuedAt: Date = Date(), features: [String] = []) {
        self.version = Self.currentVersion
        self.plan = plan.rawValue
        self.licenseID = licenseID
        self.issuedAt = issuedAt
        self.features = features
    }
}
