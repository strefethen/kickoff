#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]] || [[ "$1" != "setup" && "$1" != "cleanup" ]]; then
    printf 'Usage: %s setup|cleanup\n' "$0" >&2
    exit 64
fi

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
state_dir="$RUNNER_TEMP/kickoff-signing-state"
keychain_state="$state_dir/keychain-path"
original_keychains_state="$state_dir/original-keychains"

cleanup_signing_assets() {
    if [[ -f "$original_keychains_state" ]]; then
        original_keychains=()
        while IFS= read -r keychain_path; do
            if [[ -n "$keychain_path" ]]; then
                original_keychains+=("$keychain_path")
            fi
        done < "$original_keychains_state"

        if [[ ${#original_keychains[@]} -gt 0 ]]; then
            /usr/bin/security list-keychains -d user -s "${original_keychains[@]}" || true
        else
            /usr/bin/security list-keychains -d user -s || true
        fi
    fi

    if [[ -f "$keychain_state" ]]; then
        signing_keychain="$(<"$keychain_state")"
        if [[ -n "$signing_keychain" ]]; then
            /usr/bin/security delete-keychain "$signing_keychain" 2>/dev/null || true
            /bin/rm -f "$signing_keychain"
        fi
    fi

    /bin/rm -rf "$state_dir"
}

if [[ "$1" == "cleanup" ]]; then
    cleanup_signing_assets
    exit 0
fi

: "${DEVELOPER_ID_P12_BASE64:?DEVELOPER_ID_P12_BASE64 is required}"
: "${DEVELOPER_ID_P12_PASSWORD:?DEVELOPER_ID_P12_PASSWORD is required}"
: "${ASC_PRIVATE_KEY:?ASC_PRIVATE_KEY is required}"
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${CODE_SIGN_IDENTITY:?CODE_SIGN_IDENTITY is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

if [[ ! "$ASC_KEY_ID" =~ ^[A-Za-z0-9]+$ ]]; then
    printf 'ASC_KEY_ID must contain only letters and numbers.\n' >&2
    exit 64
fi
if [[ -e "$state_dir" ]]; then
    printf 'Signing state already exists at %s. Run cleanup before setup.\n' "$state_dir" >&2
    exit 1
fi

umask 077
/bin/mkdir -p "$state_dir"

setup_failed() {
    setup_status=$?
    cleanup_signing_assets
    exit "$setup_status"
}
trap setup_failed ERR INT TERM

signing_keychain="$RUNNER_TEMP/kickoff-signing-${RANDOM}-${RANDOM}.keychain-db"
p12_path="$state_dir/developer-id.p12"
asc_key_path="$state_dir/AuthKey_${ASC_KEY_ID}.p8"
keychain_password="$(/usr/bin/openssl rand -hex 32)"

/usr/bin/security list-keychains -d user \
    | /usr/bin/sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//' \
    > "$original_keychains_state"
printf '%s\n' "$signing_keychain" > "$keychain_state"
printf '%s' "$DEVELOPER_ID_P12_BASE64" | /usr/bin/base64 --decode > "$p12_path"
printf '%s\n' "$ASC_PRIVATE_KEY" > "$asc_key_path"
/bin/chmod 600 "$p12_path" "$asc_key_path" "$keychain_state" "$original_keychains_state"

/usr/bin/security create-keychain -p "$keychain_password" "$signing_keychain"
/usr/bin/security set-keychain-settings -lut 21600 "$signing_keychain"
/usr/bin/security unlock-keychain -p "$keychain_password" "$signing_keychain"
/usr/bin/security import "$p12_path" \
    -k "$signing_keychain" \
    -P "$DEVELOPER_ID_P12_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security
/usr/bin/security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "$keychain_password" \
    "$signing_keychain" >/dev/null

current_keychains=("$signing_keychain")
while IFS= read -r keychain_path; do
    if [[ -n "$keychain_path" ]]; then
        current_keychains+=("$keychain_path")
    fi
done < "$original_keychains_state"
/usr/bin/security list-keychains -d user -s "${current_keychains[@]}"

if ! /usr/bin/security find-identity -v -p codesigning "$signing_keychain" \
    | /usr/bin/grep -Fq "$CODE_SIGN_IDENTITY"; then
    printf 'The imported certificate does not provide CODE_SIGN_IDENTITY.\n' >&2
    exit 1
fi

printf 'ASC_KEY_PATH=%s\n' "$asc_key_path" >> "$GITHUB_ENV"
trap - ERR INT TERM
printf 'Configured temporary release signing credentials.\n'
