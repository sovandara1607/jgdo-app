#!/usr/bin/env swift
//
// Offline license-token signer. NOT part of the JgDo Xcode project or app
// target — this is the website/server side of the asymmetric license
// scheme (see JgDo/LicenseManager.swift). Run it wherever the private key
// lives, never on a machine that ships the app itself.
//
// Usage:
//   swift sign.swift --plan pro --license-id ORDER-1234
//   swift sign.swift --plan proPlus --license-id ORDER-5678 --features earlyAccess,extraThemes
//
// Reads the private key from $JGDO_LICENSE_PRIVATE_KEY (base64, raw 32-byte
// Curve25519 seed) if set, else from .keys/private_key.base64 next to this
// script. Prints the signed token to stdout — nothing else, so it's safe
// to pipe straight into wherever the website delivers keys.

import Foundation
import CryptoKit

// MARK: - Payload shape
//
// Mirrors JgDo/LicensePayload.swift field-for-field. Duplicated rather than
// shared because this script deliberately has zero dependency on the app
// target (it must be runnable with nothing but a Swift toolchain, on a
// machine that never checks out JgDo/ at all).
struct LicensePayload: Codable {
    static let currentVersion = 1
    var version: Int = LicensePayload.currentVersion
    var plan: String
    var licenseID: String
    var issuedAt: Date
    var features: [String]
}

// MARK: - Argument parsing

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Error: " + message + "\n").utf8))
    exit(1)
}

var plan: String?
var licenseID: String?
var features: [String] = []

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--plan":
        plan = args.next()
    case "--license-id":
        licenseID = args.next()
    case "--features":
        features = (args.next() ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    case "--help", "-h":
        print("""
        Usage: sign.swift --plan <pro|proPlus> --license-id <id> [--features a,b,c]
        """)
        exit(0)
    default:
        fail("unrecognized argument '\(arg)'")
    }
}

guard let plan, ["pro", "proPlus"].contains(plan) else {
    fail("--plan is required and must be 'pro' or 'proPlus'")
}
guard let licenseID, !licenseID.isEmpty else {
    fail("--license-id is required")
}

// MARK: - Load the private key

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    let base64: String
    if let fromEnv = ProcessInfo.processInfo.environment["JGDO_LICENSE_PRIVATE_KEY"], !fromEnv.isEmpty {
        base64 = fromEnv
    } else {
        let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let keyFile = scriptDir.appendingPathComponent(".keys/private_key.base64")
        guard let contents = try? String(contentsOf: keyFile, encoding: .utf8) else {
            fail("""
            No private key found. Set $JGDO_LICENSE_PRIVATE_KEY or create \
            \(keyFile.path) (base64, gitignored — see README.md).
            """)
        }
        base64 = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let data = Data(base64Encoded: base64),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("private key is not valid base64-encoded raw Curve25519 key material")
    }
    return key
}

// MARK: - Sign

let payload = LicensePayload(plan: plan, licenseID: licenseID, issuedAt: Date(), features: features)
let encoder = JSONEncoder()
guard let payloadData = try? encoder.encode(payload) else {
    fail("couldn't encode payload")
}

let privateKey = loadPrivateKey()
guard let signature = try? privateKey.signature(for: payloadData) else {
    fail("signing failed")
}

let token = payloadData.base64EncodedString() + "." + signature.base64EncodedString()
print(token)
