import XCTest
import CryptoKit
@testable import JgDo

/// Covers the asymmetric license scheme end to end: valid signatures are
/// accepted, every form of tampering is rejected, and old HMAC-format keys
/// (the scheme this replaced) no longer validate at all — proving the
/// clean break is real, not just documented in a comment.
final class LicenseVerificationTests: XCTestCase {

    /// A throwaway keypair generated fresh per test run — verification
    /// logic is exercised against it via `verify(_:publicKeyBase64:)`'s
    /// override parameter, so these tests never touch the real production
    /// public key embedded in `LicenseManager`.
    private var testPrivateKey: Curve25519.Signing.PrivateKey!
    private var testPublicKeyBase64: String!

    override func setUp() {
        super.setUp()
        testPrivateKey = Curve25519.Signing.PrivateKey()
        testPublicKeyBase64 = testPrivateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    private func sign(_ payload: LicensePayload, with key: Curve25519.Signing.PrivateKey? = nil) throws -> String {
        let data = try JSONEncoder().encode(payload)
        let signature = try (key ?? testPrivateKey).signature(for: data)
        return data.base64EncodedString() + "." + signature.base64EncodedString()
    }

    // MARK: - Valid tokens

    func testValidSignatureIsAccepted() throws {
        let payload = LicensePayload(plan: .pro, licenseID: "ORDER-1")
        let token = try sign(payload)
        let verified = LicenseManager.verify(token, publicKeyBase64: testPublicKeyBase64)
        XCTAssertEqual(verified?.plan, "pro")
        XCTAssertEqual(verified?.licenseID, "ORDER-1")
    }

    func testProPlusPlanRoundTrips() throws {
        let payload = LicensePayload(plan: .proPlus, licenseID: "ORDER-2", features: ["earlyAccess"])
        let token = try sign(payload)
        let verified = LicenseManager.verify(token, publicKeyBase64: testPublicKeyBase64)
        XCTAssertEqual(verified?.plan, "proPlus")
        XCTAssertEqual(verified?.features, ["earlyAccess"])
    }

    /// A fixture actually produced by `tools/license-signer/sign.swift`
    /// against the keypair currently embedded as
    /// `LicenseManager.publicKeyBase64` — this is the one test proving the
    /// CLI and the app agree on wire format, not just that the isolated
    /// crypto logic is self-consistent. Regenerate this fixture (and update
    /// the comment) if the embedded public key ever rotates.
    func testRealSignerOutputVerifiesAgainstEmbeddedPublicKey() {
        let token = "eyJsaWNlbnNlSUQiOiJURVNULTAwMDEiLCJpc3N1ZWRBdCI6ODA5NjIzNzE5Ljg1MDAxMywiZmVhdHVyZXMiOltdLCJ2ZXJzaW9uIjoxLCJwbGFuIjoicHJvIn0=.WeIqRK3eZfb/rwZlx84TZM2rPAGOfHcsDWCQPHq2/vG23EQwRJQxGMWOtvZsumk1m1V148IBZ6ZxrBQjFcRnCg=="
        let verified = LicenseManager.verify(token) // default = real embedded public key
        XCTAssertEqual(verified?.plan, "pro")
        XCTAssertEqual(verified?.licenseID, "TEST-0001")
    }

    // MARK: - Tampering is rejected

    func testTamperedPayloadIsRejected() throws {
        let payload = LicensePayload(plan: .pro, licenseID: "ORDER-1")
        let token = try sign(payload)
        let parts = token.split(separator: ".")
        // Swap "pro" for "proPlus" worth of bytes inside the base64 payload
        // without re-signing — a real attacker's exact move.
        var payloadData = Data(base64Encoded: String(parts[0]))!
        payloadData[0] ^= 0xFF // flip a byte
        let tampered = payloadData.base64EncodedString() + "." + parts[1]
        XCTAssertNil(LicenseManager.verify(tampered, publicKeyBase64: testPublicKeyBase64))
    }

    func testTamperedSignatureIsRejected() throws {
        let payload = LicensePayload(plan: .pro, licenseID: "ORDER-1")
        let token = try sign(payload)
        let parts = token.split(separator: ".")
        var sigData = Data(base64Encoded: String(parts[1]))!
        sigData[0] ^= 0xFF
        let tampered = parts[0] + "." + sigData.base64EncodedString()
        XCTAssertNil(LicenseManager.verify(String(tampered), publicKeyBase64: testPublicKeyBase64))
    }

    func testSignatureFromWrongPrivateKeyIsRejected() throws {
        let attackerKey = Curve25519.Signing.PrivateKey()
        let payload = LicensePayload(plan: .pro, licenseID: "ORDER-1")
        // Signed by a different keypair than the one whose public half
        // we're verifying against — must fail even though the payload
        // itself is well-formed and internally consistent.
        let token = try sign(payload, with: attackerKey)
        XCTAssertNil(LicenseManager.verify(token, publicKeyBase64: testPublicKeyBase64))
    }

    // MARK: - Malformed / unsupported input

    func testUnknownPayloadVersionIsRejected() throws {
        struct FuturePayload: Codable { var version = 999; var plan = "pro"; var licenseID = "X"; var issuedAt = Date(); var features: [String] = [] }
        let data = try JSONEncoder().encode(FuturePayload())
        let signature = try testPrivateKey.signature(for: data)
        let token = data.base64EncodedString() + "." + signature.base64EncodedString()
        XCTAssertNil(LicenseManager.verify(token, publicKeyBase64: testPublicKeyBase64))
    }

    func testUnknownPlanCodeIsRejected() throws {
        struct BadPlanPayload: Codable { var version = 1; var plan = "enterprise"; var licenseID = "X"; var issuedAt = Date(); var features: [String] = [] }
        let data = try JSONEncoder().encode(BadPlanPayload())
        let signature = try testPrivateKey.signature(for: data)
        let token = data.base64EncodedString() + "." + signature.base64EncodedString()
        XCTAssertNil(LicenseManager.verify(token, publicKeyBase64: testPublicKeyBase64))
    }

    func testMissingSeparatorIsRejected() {
        XCTAssertNil(LicenseManager.verify("not-a-valid-token-at-all", publicKeyBase64: testPublicKeyBase64))
    }

    func testInvalidBase64IsRejected() {
        XCTAssertNil(LicenseManager.verify("not base64!.also not base64!", publicKeyBase64: testPublicKeyBase64))
    }

    func testEmptyStringIsRejected() {
        XCTAssertNil(LicenseManager.verify("", publicKeyBase64: testPublicKeyBase64))
    }

    /// The clean break: a key in the old `{PLAN}-{XXXX}-{XXXX}-{CHECKSUM}`
    /// HMAC format must be rejected outright — there is no dual verifier.
    func testLegacyHMACFormatKeyIsRejected() {
        XCTAssertNil(LicenseManager.verify("PRO0-A1B2-C3D4-9F3E", publicKeyBase64: testPublicKeyBase64))
        XCTAssertNil(LicenseManager.verify("PRO0-A1B2-C3D4-9F3E")) // also against the real embedded key
    }
}
