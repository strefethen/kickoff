#!/bin/bash
set -euo pipefail

task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
release_root="$task_root/build/release"
app_path="$release_root/Kickoff.app"

: "${RELEASE_VERSION:?RELEASE_VERSION is required}"
: "${RELEASE_BUILD:?RELEASE_BUILD is required}"
: "${CODE_SIGN_IDENTITY:?CODE_SIGN_IDENTITY is required}"
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"
: "${ASC_KEY_PATH:?ASC_KEY_PATH is required}"

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'RELEASE_VERSION must contain exactly three numeric components (for example, 1.2.3).\n' >&2
    exit 64
fi
if [[ ! "$RELEASE_BUILD" =~ ^[1-9][0-9]*$ ]]; then
    printf 'RELEASE_BUILD must be a positive integer.\n' >&2
    exit 64
fi
if [[ ! -f "$ASC_KEY_PATH" ]]; then
    printf 'ASC_KEY_PATH does not name a readable private key file.\n' >&2
    exit 66
fi

archive_name="Kickoff-$RELEASE_VERSION-universal.zip"
archive_path="$release_root/$archive_name"
checksum_path="$archive_path.sha256"
submission_path="$release_root/.Kickoff-$RELEASE_VERSION-submission.$$.zip"
notary_response="$release_root/notary-response.plist"
package_succeeded=0

cleanup() {
    /bin/rm -f "$submission_path"
    if [[ "$package_succeeded" -ne 1 ]]; then
        /bin/rm -f "$archive_path" "$checksum_path"
    fi
}
trap cleanup EXIT

/bin/mkdir -p "$release_root"
/bin/rm -f "$archive_path" "$checksum_path" "$notary_response"

"$task_root/build-app.sh" --release

/usr/bin/ditto -c -k --keepParent "$app_path" "$submission_path"
if ! /usr/bin/xcrun notarytool submit "$submission_path" \
    --key "$ASC_KEY_PATH" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" \
    --wait \
    --timeout 20m \
    --output-format plist > "$notary_response"; then
    printf 'Notarization submission failed; see %s for the structured response.\n' "$notary_response" >&2
    exit 1
fi

/usr/bin/plutil -lint "$notary_response"
notary_status="$(/usr/bin/plutil -extract status raw -o - "$notary_response")"
if [[ "$notary_status" != "Accepted" ]]; then
    printf 'Notarization was not accepted (status: %s).\n' "$notary_status" >&2
    exit 1
fi

/usr/bin/xcrun stapler staple "$app_path"
/usr/bin/xcrun stapler validate "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"

/usr/bin/ditto -c -k --keepParent "$app_path" "$archive_path"
(
    cd -- "$release_root"
    /usr/bin/shasum -a 256 "$archive_name" > "$archive_name.sha256"
)

package_succeeded=1
printf 'Packaged %s\n' "$archive_path"
printf 'Checksum %s\n' "$checksum_path"
