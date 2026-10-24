# Releasing Murmur

A release is a signed, notarized `Murmur-<version>.dmg` attached to a GitHub release. Signed and notarized means people can open it with a double-click: no "unidentified developer" warning, and macOS keeps granting the same permissions across updates.

## One-time setup

### 1. A Developer ID Application certificate

Notarized distribution outside the Mac App Store needs a **Developer ID Application** certificate. *Apple Development* and *Apple Distribution* certificates do **not** work for this (`release.sh` refuses them).

1. Join the Apple Developer Program (the Account Holder creates this certificate).
2. In Xcode: **Settings → Accounts →** your team **→ Manage Certificates… → + → Developer ID Application**. (Or create it at developer.apple.com → Certificates.)
3. Check that it is in your keychain:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   The quoted name, for example `Developer ID Application: Your Name (TEAMID)`, is your signing identity.

### 2. Notarization credentials

1. Create an **app-specific password** at appleid.apple.com → Sign-In and Security → App-Specific Passwords.
2. Store it in your keychain once (the command prompts for the password; nothing is written to the repository):

   ```bash
   xcrun notarytool store-credentials "murmur-notary" --apple-id "you@example.com" --team-id "TEAMID"
   ```

### Alternative: use an App Store Connect API key instead of an Apple ID password

If you already have an App Store Connect API key (Users and Access → Integrations → App Store Connect API; note the Key ID, the Issuer ID and download the `AuthKey_<KeyID>.p8` once), `notarytool` can use it directly, so no app-specific password is needed:

```bash
xcrun notarytool store-credentials "murmur-notary" \
  --key /path/to/AuthKey_<KeyID>.p8 --key-id <KeyID> --issuer <IssuerID>
```

The same key can create the Developer ID Application certificate through the API (`POST /v1/certificates` with `certificateType: DEVELOPER_ID_APPLICATION` and a CSR you generate locally, then import the returned certificate with its private key into your login keychain). That call needs a key with the Admin role; with a lower role, create the certificate in Xcode or the developer portal instead. Keep the `.p8` file and the Key and Issuer IDs out of the repository.

## Cutting a release locally

```bash
# 1. Bump the version and note the changes
echo "1.1.0" > VERSION            # then edit CHANGELOG.md

# 2. Test
./test.sh

# 3. Build, sign, notarize, staple, and package
export MURMUR_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export MURMUR_NOTARY_PROFILE="murmur-notary"
./release.sh
```

`release.sh` prints whether the result is *signed and notarized*, *signed but not notarized*, or *unsigned*. Only the first is ready to publish. Output: `build/Murmur-<version>.dmg` and `build/Murmur-<version>.dmg.sha256`.

Check it the way a user's Mac will:

```bash
spctl --assess --type open --context context:primary-signature -v build/Murmur-1.1.0.dmg
xcrun stapler validate build/Murmur-1.1.0.dmg
```

Publish:

```bash
git tag v1.1.0 && git push origin v1.1.0
gh release create v1.1.0 build/Murmur-1.1.0.dmg build/Murmur-1.1.0.dmg.sha256 --generate-notes
```

## Releasing from GitHub Actions instead

Pushing a `v*` tag runs `.github/workflows/release.yml`, which signs, notarizes and publishes for you. It needs these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `MURMUR_CERT_P12` | Your Developer ID Application certificate exported from Keychain Access as a `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `MURMUR_CERT_PASSWORD` | The password you set when exporting the `.p12` |
| `MURMUR_SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `MURMUR_APPLE_ID` | Your Apple ID email |
| `MURMUR_TEAM_ID` | Your 10-character Team ID |
| `MURMUR_APP_PASSWORD` | The app-specific password from step 2 |

> **Not yet verified:** the workflows use the `macos-26` runner label and have never run. Confirm that label exists for your account (GitHub's runner images list) before relying on them, and do a first release locally.

## Homebrew

`packaging/homebrew/murmur.rb` is a cask template. To offer `brew install --cask murmur`:

1. Create a public repository named `homebrew-murmur`.
2. Copy the template to `Casks/murmur.rb` in it.
3. After each release, set `version` and set `sha256` to the first field of `Murmur-<version>.dmg.sha256`.

Users then run:

```bash
brew install --cask vinoth12940/murmur/murmur
```

## Updates for users

Murmur does not update itself and makes no background network requests. *Check for Updates…* in the menu asks GitHub for the latest release only when clicked and opens the release page when there is a newer one. (An in-app updater such as Sparkle would add a dependency and background networking, so it is deliberately not included.)

## What stays out of the repository

Certificates, `.p12` files, passwords, Apple IDs and Team IDs. Signing is driven by environment variables and your keychain.
