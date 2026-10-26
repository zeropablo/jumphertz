#!/bin/bash
# Checks that Apple's developer tools can build Jumphertz, before the long build. Called by install.sh.
#
# Blocking checks: a developer directory, a working `swift`, and Package.swift compiling with it. The last
# one catches the case seen after macOS updates: the Command Line Tools half replaced (new compiler, old
# PackageDescription), e.g. "Package.swift: error: extra argument 'swiftLanguageModes' in call".
# The installer receipt (pkgutil) is only reported: some working installations have none.
#
# Usage: scripts/check-toolchain.sh [package directory]   (default: the repository)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE=${1:-$ROOT}
CLT=/Library/Developer/CommandLineTools

developer_dir=$(xcode-select -p 2>/dev/null || true)
receipt="not registered"
version=$(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | sed -n 's/^version: //p')
[[ -n "$version" ]] && receipt="registered, version $version"

broken() {
    local problem=$1 details=${2:-}
    printf '\nerror: %s\n\n' "$problem" >&2
    if [[ -n "$developer_dir" && "$developer_dir" != "$CLT" && "$developer_dir" == *.app/* ]]; then
        cat >&2 <<MSG
EN: The selected developer tools ($developer_dir) cannot build Jumphertz.
    Update Xcode, or switch to the Command Line Tools:
FR: Les outils de développement sélectionnés ($developer_dir) ne peuvent pas compiler Jumphertz.
    Mets Xcode à jour, ou passe sur les Command Line Tools :

    sudo xcode-select --switch $CLT
MSG
    else
        cat >&2 <<'MSG'
EN: Apple's Command Line Tools are missing or damaged. This often happens after a macOS update.
    Reinstall them (your Mac password is requested), then run scripts/install.sh again:
FR: Les Command Line Tools d'Apple sont absents ou abîmés. C'est fréquent après une mise à jour de macOS.
    Réinstalle-les (ton mot de passe Mac est demandé), puis relance scripts/install.sh :

    sudo rm -rf /Library/Developer/CommandLineTools
    xcode-select --install
MSG
    fi
    {
        printf '\nDetails / Détails:\n'
        printf '  developer directory: %s\n' "${developer_dir:-none}"
        printf '  installer receipt:   %s\n' "$receipt"
        printf '  swift:               %s\n' "$(swift --version 2>&1 | grep -m1 -i 'swift version' || echo 'does not run')"
        if [[ -n "$details" ]]; then
            # The compiler's own errors, not the long "compiled with: [...]" command line.
            useful=$(printf '%s\n' "$details" | grep -E '[0-9]+:[0-9]+: error:' | head -3)
            [[ -n "$useful" ]] || useful=$(printf '%s\n' "$details" | head -3)
            printf '%s\n' "$useful" | cut -c1-220 | sed 's/^/  > /'
        fi
    } >&2
    exit 1
}

[[ -n "$developer_dir" && -d "$developer_dir" ]] || broken "no Apple developer tools found"
swift --version >/dev/null 2>&1 || broken "swift does not run"

errors=$(cd "$PACKAGE" && swift package --scratch-path "$HOME/Library/Caches/Jumphertz/swiftpm-manifest" \
         dump-package 2>&1 >/dev/null) || broken "Package.swift cannot be compiled with this Swift toolchain" "$errors"

echo "Developer tools: $developer_dir ($(swift --version 2>&1 | grep -m1 -o -i 'swift version [0-9.]*'); receipt $receipt)"
