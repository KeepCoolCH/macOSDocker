# Signing and notarization

The Xcode project enables automatic signing and Hardened Runtime for team `RYPSKH8HG5`. Embedded Docker tools use Xcode's signing identity, Hardened Runtime and a secure timestamp in signed builds. App version and build number are configured in the Xcode project.

## Archiving with Xcode

Double-click `App archivieren.command` in the project directory. It creates a Release archive and opens it in Xcode. Choose **Distribute App → Developer ID** and upload for notarization.

## Automated export

After storing a notarization profile in Keychain, run:

```sh
./scripts/release-app.sh PROFILE_NAME
```

Create the profile interactively with `xcrun notarytool store-credentials PROFILE_NAME`. Credentials are not stored in the project.

The script archives the app, exports with Developer ID, signs embedded tools and the app, submits a ZIP for notarization and checks the result. Only an `Accepted` result triggers ticket stapling, Gatekeeper validation and creation of the final ZIP. Output is written to `build/Distribution`. The exported app retains the entitlements set by Xcode's export process.

## Requirements

The selected team needs valid certificates and a provisioning profile for the app's bundle identifier. Register the development Mac if Xcode requires a registered device for development signing.

Apple must approve `com.apple.vm.networking` for this app and the intended distribution method. Adding the entitlement to a file does not grant approval. The current development setup has successfully started the native bridge. Validate the exported app separately; successful notarization alone does not verify bridge startup.
