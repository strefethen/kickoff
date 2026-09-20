# Releasing Kickoff

Release builds are Apple Silicon-only (`arm64`), use hardened runtime Developer ID signing, and retain the app's macOS 13 deployment target. The release workflow is pinned to Xcode 16.4 on the `macos-15` runner.

## GitHub configuration

Use a dedicated App Store Connect team API key named **Kickoff CI** for notarization. Its role must permit notarization; team keys apply across apps even when named for one project. Keep its private key separate from other projects.

Configure these repository Actions secrets:

- `DEVELOPER_ID_P12_BASE64`: base64-encoded Developer ID Application certificate and private key in PKCS#12 format
- `DEVELOPER_ID_P12_PASSWORD`: password for that PKCS#12 file
- `ASC_PRIVATE_KEY`: contents of the App Store Connect API `.p8` private key
- `ASC_KEY_ID`: App Store Connect API key ID
- `ASC_ISSUER_ID`: App Store Connect issuer ID

The workflow signs with the `CODE_SIGN_IDENTITY` configured in `.github/workflows/release.yml` (for example, `Developer ID Application: Your Name (TEAM_ID)`). Change that value if the repository moves to another signing team.

Running the **Release** workflow manually requires a three-component version such as `1.2.3`. It builds, notarizes, staples, and uploads a workflow artifact only. Pushing an existing `v<version>` tag performs the same build and creates a draft GitHub release for that tag. Publishing the draft remains a manual action.

## Local packaging

Set the signing and App Store Connect values in the environment, then run:

```sh
RELEASE_VERSION=1.2.3 \
RELEASE_BUILD=123 \
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAM_ID)' \
ASC_KEY_ID="$ASC_KEY_ID" \
ASC_ISSUER_ID="$ASC_ISSUER_ID" \
ASC_KEY_PATH="$ASC_KEY_PATH" \
./scripts/release/package.sh
```

`ASC_KEY_PATH` points to the local App Store Connect `.p8` file. Packaging submits a temporary ZIP to Apple's notary service and requires an `Accepted` result before stapling and verification. The final files are `build/release/Kickoff-<version>-arm64.zip` and its `.sha256` checksum. A failed signing, notarization, stapling, or assessment step removes those distributable files.

For a signed app bundle without notarization or an archive, provide `RELEASE_VERSION`, `RELEASE_BUILD`, and `CODE_SIGN_IDENTITY` to `./build-app.sh --release`. The normal `./build-app.sh` command continues to create the ad-hoc signed native build at `build/Kickoff.app`.
