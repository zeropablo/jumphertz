#!/bin/bash
# Builds a universal (arm64 + x86_64) Jumphertz.app and signs it.
#
# Everything is built and assembled outside the source tree (default ~/Library/Caches/Jumphertz): codesign
# fails on bundles stored on exFAT volumes ("resource fork, Finder information, or similar detritus").
#
# Environment:
#   JUMPHERTZ_SIGN_IDENTITY  codesign identity in the dedicated dev keychain created by
#                            scripts/dev-create-identity.sh (e.g. "Jumphertz Local Signing").
#                            Unset = ad hoc signature.
#   JUMPHERTZ_DEV_KEYCHAIN, JUMPHERTZ_DEV_KEYCHAIN_PASS_FILE  override the dev keychain location.
#   JUMPHERTZ_CACHE_DIR      build location (default ~/Library/Caches/Jumphertz)
#
# Prints the path of the signed bundle on the last line of stdout.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CACHE=${JUMPHERTZ_CACHE_DIR:-$HOME/Library/Caches/Jumphertz}
SCRATCH="$CACHE/swiftpm"
OUT="$CACHE/build"
APP="$OUT/Jumphertz.app"
IDENTITY=${JUMPHERTZ_SIGN_IDENTITY:--}
DEV_KEYCHAIN=${JUMPHERTZ_DEV_KEYCHAIN:-$HOME/Library/Keychains/jumphertz-dev.keychain-db}
DEV_PASS_FILE=${JUMPHERTZ_DEV_KEYCHAIN_PASS_FILE:-$HOME/Library/Application Support/Jumphertz/dev-keychain-pass}
ARCHS=(arm64 x86_64)

log() { printf '==> %s\n' "$*" >&2; }

# Fail before the long build if the signing identity is not usable.
keychain_args=()
if [[ "$IDENTITY" != "-" ]]; then
    if [[ ! -f "$DEV_KEYCHAIN" || ! -s "$DEV_PASS_FILE" ]]; then
        echo "error: JUMPHERTZ_SIGN_IDENTITY is set but the dev keychain is missing. Run scripts/dev-create-identity.sh" >&2
        exit 1
    fi
    # Unlocked with its own stored password: no prompt, whatever the state of the login keychain.
    security unlock-keychain -p "$(<"$DEV_PASS_FILE")" "$DEV_KEYCHAIN"
    # Sign by certificate hash: a name could also match a copy in another keychain ("ambiguous").
    SIGN_HASH=$(security find-identity -p codesigning "$DEV_KEYCHAIN" | grep -F "\"$IDENTITY\"" | awk 'NR==1 {print $2}')
    if [[ -z "$SIGN_HASH" ]]; then
        echo "error: identity \"$IDENTITY\" not found in $DEV_KEYCHAIN. Run scripts/dev-create-identity.sh" >&2
        exit 1
    fi
    keychain_args=(--keychain "$DEV_KEYCHAIN")
fi

VERSION=$(sed -nE 's/^let version = "([^"]+)".*/\1/p' "$ROOT/Sources/Jumphertz/main.swift")
[[ -n "$VERSION" ]] || { echo "error: cannot read version from main.swift" >&2; exit 1; }

# `swift build --arch arm64 --arch x86_64` needs Xcode's xcbuild; with only the Command Line Tools we
# build each architecture separately and merge them.
binaries=()
for arch in "${ARCHS[@]}"; do
    log "Building $arch (release)"
    swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" \
        --triple "$arch-apple-macosx13.0" --product Jumphertz >&2
    binaries+=("$SCRATCH/$arch-apple-macosx/release/Jumphertz")
done

log "Assembling Jumphertz.app $VERSION"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/Jumphertz"
# CFBundleShortVersionString carries the full version (1.0.0-beta.1); CFBundleVersion must stay numeric.
BUILD=${VERSION%%-*}
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint -s "$APP/Contents/Info.plist"

# Extended attributes (Finder info, quarantine, AppleDouble leftovers) make codesign fail.
xattr -cr "$APP"

if [[ "$IDENTITY" == "-" ]]; then
    log "Signing (ad hoc, hardened runtime)"
    SIGN_HASH=-
else
    log "Signing with \"$IDENTITY\" ($SIGN_HASH, hardened runtime)"
fi
codesign --force --sign "$SIGN_HASH" ${keychain_args[@]+"${keychain_args[@]}"} --options runtime --timestamp=none \
    --identifier com.zeropablo.jumphertz \
    --entitlements "$ROOT/Resources/Jumphertz.entitlements" \
    "$APP" >&2
codesign --verify --strict --verbose=1 "$APP" >&2

log "Architectures: $(lipo -archs "$APP/Contents/MacOS/Jumphertz")"
echo "$APP"
