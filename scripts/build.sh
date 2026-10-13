#!/bin/bash
# Builds a universal (arm64 + x86_64) MicBridge.app and signs it.
#
# Everything is built and assembled outside the source tree (default ~/Library/Caches/MicBridge): codesign
# fails on bundles stored on exFAT volumes ("resource fork, Finder information, or similar detritus").
#
# Environment:
#   MICBRIDGE_SIGN_IDENTITY  codesign identity in the dedicated dev keychain created by
#                            scripts/dev-create-identity.sh (e.g. "MicBridge Local Signing").
#                            Unset = ad hoc signature.
#   MICBRIDGE_DEV_KEYCHAIN, MICBRIDGE_DEV_KEYCHAIN_PASS_FILE  override the dev keychain location.
#   MICBRIDGE_CACHE_DIR      build location (default ~/Library/Caches/MicBridge)
#
# Prints the path of the signed bundle on the last line of stdout.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CACHE=${MICBRIDGE_CACHE_DIR:-$HOME/Library/Caches/MicBridge}
SCRATCH="$CACHE/swiftpm"
OUT="$CACHE/build"
APP="$OUT/MicBridge.app"
IDENTITY=${MICBRIDGE_SIGN_IDENTITY:--}
DEV_KEYCHAIN=${MICBRIDGE_DEV_KEYCHAIN:-$HOME/Library/Keychains/micbridge-dev.keychain-db}
DEV_PASS_FILE=${MICBRIDGE_DEV_KEYCHAIN_PASS_FILE:-$HOME/Library/Application Support/MicBridge/dev-keychain-pass}
ARCHS=(arm64 x86_64)

log() { printf '==> %s\n' "$*" >&2; }

# Fail before the long build if the signing identity is not usable.
keychain_args=()
if [[ "$IDENTITY" != "-" ]]; then
    if [[ ! -f "$DEV_KEYCHAIN" || ! -s "$DEV_PASS_FILE" ]]; then
        echo "error: MICBRIDGE_SIGN_IDENTITY is set but the dev keychain is missing. Run scripts/dev-create-identity.sh" >&2
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

VERSION=$(sed -nE 's/^let version = "([^"]+)".*/\1/p' "$ROOT/Sources/MicBridge/main.swift")
[[ -n "$VERSION" ]] || { echo "error: cannot read version from main.swift" >&2; exit 1; }

# `swift build --arch arm64 --arch x86_64` needs Xcode's xcbuild; with only the Command Line Tools we
# build each architecture separately and merge them.
binaries=()
for arch in "${ARCHS[@]}"; do
    log "Building $arch (release)"
    swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" \
        --triple "$arch-apple-macosx13.0" --product MicBridge >&2
    binaries+=("$SCRATCH/$arch-apple-macosx/release/MicBridge")
done

log "Assembling MicBridge.app $VERSION"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/MicBridge"
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
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
    --identifier com.zeropablo.micbridge \
    --entitlements "$ROOT/Resources/MicBridge.entitlements" \
    "$APP" >&2
codesign --verify --strict --verbose=1 "$APP" >&2

log "Architectures: $(lipo -archs "$APP/Contents/MacOS/MicBridge")"
echo "$APP"
