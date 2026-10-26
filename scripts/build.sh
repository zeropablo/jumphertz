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
#   JUMPHERTZ_BUILD_SYSTEM   passed to `swift build --build-system` (native, swiftbuild); unset = Swift's default
#
# Prints the path of the signed bundle on the last line of stdout.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CACHE=${JUMPHERTZ_CACHE_DIR:-$HOME/Library/Caches/Jumphertz}
OUT="$CACHE/build"
APP="$OUT/Jumphertz.app"
IDENTITY=${JUMPHERTZ_SIGN_IDENTITY:--}
DEV_KEYCHAIN=${JUMPHERTZ_DEV_KEYCHAIN:-$HOME/Library/Keychains/jumphertz-dev.keychain-db}
DEV_PASS_FILE=${JUMPHERTZ_DEV_KEYCHAIN_PASS_FILE:-$HOME/Library/Application Support/Jumphertz/dev-keychain-pass}
ARCHS=(arm64 x86_64)

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

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

# One build per architecture, each in its own scratch directory, then merged with lipo. Never assume where
# the product lands: the native build system uses <scratch>/<triple>/release, Swift Build (the backend
# introduced as an option in Swift 6.2 and used by default later) uses <scratch>/out/Products/Release with
# no per-triple folder, so a shared scratch directory lets one architecture overwrite the other. Some
# versions also produce a universal product for a single --triple. Hence: separate scratch directories,
# the path from --show-bin-path, and an architecture check on everything lipo touches.
build_system=()
[[ -n "${JUMPHERTZ_BUILD_SYSTEM:-}" ]] && build_system=(--build-system "$JUMPHERTZ_BUILD_SYSTEM")
rm -rf "$CACHE/swiftpm"   # shared scratch directory of Jumphertz 1.0.0
SLICES="$OUT/slices"
rm -rf "$SLICES"
mkdir -p "$SLICES"

slices=()
for arch in "${ARCHS[@]}"; do
    options=(-c release --package-path "$ROOT" --scratch-path "$CACHE/swiftpm-$arch"
             --triple "$arch-apple-macosx13.0" ${build_system[@]+"${build_system[@]}"})
    log "Building $arch (release)"
    swift build "${options[@]}" --product Jumphertz >&2
    product="$(swift build "${options[@]}" --show-bin-path)/Jumphertz"
    [[ -f "$product" ]] || die "the $arch build reported success but $product does not exist"

    archs=$(lipo -archs "$product")
    case " $archs " in
        *" $arch "*) ;;
        *) die "the $arch build produced a binary for [$archs], not $arch ($product)" ;;
    esac
    slice="$SLICES/Jumphertz-$arch"
    if [[ "$archs" == "$arch" ]]; then
        cp "$product" "$slice"
    else
        log "The $arch build produced [$archs]; keeping its $arch slice"
        lipo "$product" -thin "$arch" -output "$slice"
    fi
    [[ "$(lipo -archs "$slice")" == "$arch" ]] || die "$slice is not a $arch binary"
    slices+=("$slice")
done

log "Assembling Jumphertz.app $VERSION"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/Jumphertz"
final_archs=$(lipo -archs "$APP/Contents/MacOS/Jumphertz" | tr ' ' '\n' | sort | xargs)
[[ "$final_archs" == "arm64 x86_64" ]] || die "the app binary is [$final_archs], expected arm64 + x86_64"
rm -rf "$SLICES"

# Smoke-run both slices (the x86_64 one through Rosetta, when it is installed).
"$APP/Contents/MacOS/Jumphertz" --version >/dev/null || die "the app binary does not run"
if arch -x86_64 /usr/bin/true 2>/dev/null; then
    arch -x86_64 "$APP/Contents/MacOS/Jumphertz" --version >/dev/null || die "the x86_64 slice does not run"
else
    log "Rosetta not installed: x86_64 slice not run"
fi
# CFBundleShortVersionString carries the full version (e.g. 1.1.0-beta.1); CFBundleVersion must stay numeric.
BUILD=${VERSION%%-*}
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/Resources/ThirdPartyNotices" "$APP/Contents/Resources/ThirdPartyNotices.txt"
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
