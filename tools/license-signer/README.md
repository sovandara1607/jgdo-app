# License signer

The server/website side of JgDo's license scheme. **Not part of the Xcode
project** — nothing under `tools/` is added to any build target or the
`JgDo` file-system-synchronized group, so this never ships inside the app.

## How the scheme works

- A license token is `base64(payload JSON).base64(Ed25519 signature)`.
- This script holds the **private** signing key and produces tokens.
- The app (`JgDo/LicenseManager.swift`) holds only the matching **public**
  key, hardcoded as `LicenseManager.publicKeyBase64`. A public key can
  verify signatures but can't create them, so shipping it inside the
  compiled app — even if someone extracts it via `strings JgDo` — doesn't
  let them mint new valid licenses. That's the property the previous
  HMAC-secret scheme didn't have.

This replaces the old symmetric HMAC scheme entirely. **Every license key
issued under the old scheme is invalid under this one** — there is no dual
verifier — so switching keypairs (or rotating this one) requires reissuing
licenses to existing users; there's no silent-compatibility path.

## Setup

1. Generate a keypair once (Swift/CryptoKit, no external tooling needed):

   ```swift
   import CryptoKit
   let priv = Curve25519.Signing.PrivateKey()
   print("private:", priv.rawRepresentation.base64EncodedString())
   print("public:",  priv.publicKey.rawRepresentation.base64EncodedString())
   ```

2. Put the private key's base64 in `.keys/private_key.base64` next to this
   script (create the `.keys/` directory — it's gitignored at the repo
   root's `.gitignore`, `tools/license-signer/.keys/`) — or export it as
   `$JGDO_LICENSE_PRIVATE_KEY` instead of writing it to disk at all.
3. Put the **public** key's base64 into `LicenseManager.publicKeyBase64`
   in the app (`JgDo/LicenseManager.swift`) and ship that.
4. **Never commit `.keys/`.** If this repo's dev keypair (checked in only
   as a placeholder for local testing) is still what `LicenseManager`
   embeds, generate a real production keypair before shipping to any real
   customer and rotate both sides together.

## Usage

```sh
swift sign.swift --plan pro --license-id ORDER-1234
swift sign.swift --plan proPlus --license-id ORDER-5678 --features earlyAccess,extraThemes
```

Prints the signed token to stdout and nothing else — pipe it straight into
whatever delivers keys to customers (email template, download page, etc.).

## Rotating the key

Generate a new pair, update `LicenseManager.publicKeyBase64` in a JgDo
release, and reissue tokens for anyone who needs to keep working past that
release — old tokens signed with the retired key stop verifying the moment
the new build ships, by design (asymmetric verification has no graceful
multi-key fallback here; add one deliberately if that's ever needed, e.g.
by embedding a small array of accepted public keys instead of one).
