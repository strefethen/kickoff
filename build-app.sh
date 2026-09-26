#!/bin/bash
set -euo pipefail

task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
task_mode="local"

if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [--release]\n' "$0" >&2
    exit 64
fi

if [[ $# -eq 1 ]]; then
    if [[ "$1" != "--release" ]]; then
        printf 'Unknown option: %s\n' "$1" >&2
        printf 'Usage: %s [--release]\n' "$0" >&2
        exit 64
    fi
    task_mode="release"
fi

if [[ "$task_mode" == "release" ]]; then
    : "${RELEASE_VERSION:?RELEASE_VERSION is required for release builds}"
    : "${RELEASE_BUILD:?RELEASE_BUILD is required for release builds}"
    : "${CODE_SIGN_IDENTITY:?CODE_SIGN_IDENTITY is required for release builds}"

    if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'RELEASE_VERSION must contain exactly three numeric components (for example, 1.2.3).\n' >&2
        exit 64
    fi
    if [[ ! "$RELEASE_BUILD" =~ ^[1-9][0-9]*$ ]]; then
        printf 'RELEASE_BUILD must be a positive integer.\n' >&2
        exit 64
    fi
    if [[ "$CODE_SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
        printf 'CODE_SIGN_IDENTITY must name a Developer ID Application identity.\n' >&2
        exit 64
    fi

    task_build="$task_root/build/release"
    task_bundle="$task_build/Kickoff.app"
    task_scratch="$task_build/swift"
    swift_args=(
        --package-path "$task_root"
        --scratch-path "$task_scratch"
        --configuration release
        --product Kickoff
        --arch arm64
    )
else
    if [[ "${CODE_SIGN_IDENTITY+x}" == "x" ]]; then
        task_signing_identity="$CODE_SIGN_IDENTITY"
    else
        task_signing_identity="$(git -C "$task_root" config --local --get kickoff.signingIdentity || true)"
    fi
    if [[ -z "${task_signing_identity//[[:space:]]/}" || "$task_signing_identity" == "-" ]]; then
        printf 'Local builds require a certificate signing identity; ad-hoc signing is not supported.\n' >&2
        printf 'Set it once with: git config --local kickoff.signingIdentity "<certificate SHA-1 fingerprint>"\n' >&2
        printf 'Or provide CODE_SIGN_IDENTITY for this build. See docs/releasing.md.\n' >&2
        exit 64
    fi

    task_build="$task_root/build"
    task_bundle="$task_build/Kickoff.app"
    swift_args=(--package-path "$task_root" --configuration release --product Kickoff)
fi

/usr/bin/plutil -lint "$task_root/Info.plist"
/usr/bin/swift build "${swift_args[@]}"

if [[ "$task_mode" == "release" ]]; then
    swift_bin_path="$(/usr/bin/swift build "${swift_args[@]}" --show-bin-path)"
    task_executable="$swift_bin_path/Kickoff"
    executable_archs="$(/usr/bin/lipo -archs "$task_executable")"
    if [[ "$executable_archs" != "arm64" ]]; then
        printf 'Release executable must contain exactly arm64 (found: %s).\n' "$executable_archs" >&2
        exit 1
    fi

    staging_bundle="$task_build/.Kickoff.app.staging.$$"
    cleanup_staging() {
        /bin/rm -rf "$staging_bundle"
    }
    trap cleanup_staging EXIT
    cleanup_staging
    /bin/mkdir -p "$staging_bundle/Contents/MacOS" "$staging_bundle/Contents/Resources"

    /bin/cp "$task_executable" "$staging_bundle/Contents/MacOS/Kickoff"
    /bin/cp "$task_root/Info.plist" "$staging_bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$staging_bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RELEASE_BUILD" "$staging_bundle/Contents/Info.plist"
    "$task_root/scripts/build-icon.sh" "$task_root/Resources/AppIcon.png" "$staging_bundle/Contents/Resources/AppIcon.icns"
    /usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp --options runtime "$staging_bundle"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$staging_bundle"

    /bin/rm -rf "$task_bundle"
    /bin/mv "$staging_bundle" "$task_bundle"
    trap - EXIT
else
    /bin/mkdir -p "$task_build"
    staging_bundle="$(/usr/bin/mktemp -d "$task_build/.Kickoff.app.staging.XXXXXX")"
    cleanup_staging() {
        /bin/rm -rf "$staging_bundle"
    }
    trap cleanup_staging EXIT
    /bin/mkdir -p "$staging_bundle/Contents/MacOS" "$staging_bundle/Contents/Resources"

    /bin/cp "$task_root/.build/release/Kickoff" "$staging_bundle/Contents/MacOS/Kickoff"
    /bin/cp "$task_root/Info.plist" "$staging_bundle/Contents/Info.plist"
    "$task_root/scripts/build-icon.sh" "$task_root/Resources/AppIcon.png" "$staging_bundle/Contents/Resources/AppIcon.icns"
    /usr/bin/codesign --force --sign "$task_signing_identity" --timestamp=none "$staging_bundle"
    /usr/bin/codesign --verify --strict "$staging_bundle"

    /bin/rm -rf "$task_bundle"
    /bin/mv "$staging_bundle" "$task_bundle"
    trap - EXIT
fi

printf 'Built %s\n' "$task_bundle"
