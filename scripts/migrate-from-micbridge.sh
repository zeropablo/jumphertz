#!/bin/bash
# Removes an installation of MicBridge (the project's name before its first release) and moves its configuration
# to Jumphertz. Called by install.sh; safe to run on its own and to run again. No sudo.
#
# This is the only place in the repository that still refers to the old name.
set -euo pipefail

OLD_LABEL=com.zeropablo.micbridge
OLD_APP="$HOME/Applications/MicBridge.app"
OLD_PLIST="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
OLD_LINK="$HOME/.local/bin/micbridge"
OLD_SUPPORT="$HOME/Library/Application Support/MicBridge"
OLD_CACHE="$HOME/Library/Caches/MicBridge"
OLD_KEYCHAIN="$HOME/Library/Keychains/micbridge-dev.keychain-db"
NEW_SUPPORT="$HOME/Library/Application Support/Jumphertz"
DOMAIN="gui/$(id -u)"
LSREGISTER=${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}

present=false
for path in "$OLD_APP" "$OLD_PLIST" "$OLD_LINK" "$OLD_SUPPORT" "$OLD_CACHE" "$OLD_KEYCHAIN"; do
    [[ -e "$path" || -L "$path" ]] && present=true
done
launchctl print "$DOMAIN/$OLD_LABEL" >/dev/null 2>&1 && present=true
if ! $present; then
    echo "No previous MicBridge installation."
    exit 0
fi

echo "Previous MicBridge installation found: removing it."

# The old agent must be gone before the new one starts, or both would write into BlackHole.
launchctl bootout "$DOMAIN/$OLD_LABEL" 2>/dev/null && echo "  stopped the MicBridge agent" || true
for _ in {1..50}; do launchctl print "$DOMAIN/$OLD_LABEL" >/dev/null 2>&1 || break; sleep 0.1; done
[[ -f "$OLD_PLIST" ]] && rm -f "$OLD_PLIST" && echo "  removed $OLD_PLIST"

if [[ -d "$OLD_APP" ]]; then
    "$LSREGISTER" -u "$OLD_APP" 2>/dev/null || true
    rm -rf "$OLD_APP" && echo "  removed $OLD_APP"
fi
if [[ -L "$OLD_LINK" && "$(readlink "$OLD_LINK")" == "$OLD_APP/"* ]]; then
    rm -f "$OLD_LINK" && echo "  removed $OLD_LINK"
fi
tccutil reset Microphone "$OLD_LABEL" >/dev/null 2>&1 && echo "  reset the MicBridge microphone permission" || true

# Configuration: keep the user's settings (same keys) unless Jumphertz already has its own.
if [[ -f "$OLD_SUPPORT/config.json" ]]; then
    if [[ -f "$NEW_SUPPORT/config.json" ]]; then
        echo "  kept the existing Jumphertz configuration (MicBridge's was not copied)"
    else
        mkdir -p "$NEW_SUPPORT"
        cp "$OLD_SUPPORT/config.json" "$NEW_SUPPORT/config.json"
        echo "  migrated the configuration to $NEW_SUPPORT/config.json"
    fi
fi

# Development signing keychain (scripts/dev-create-identity.sh of MicBridge).
if [[ -f "$OLD_KEYCHAIN" ]]; then
    keep=()
    while IFS= read -r path; do
        [[ "$path" == "$OLD_KEYCHAIN" ]] || keep+=("$path")
    done < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')
    security list-keychains -d user -s ${keep[@]+"${keep[@]}"}
    security delete-keychain "$OLD_KEYCHAIN" 2>/dev/null || true
    rm -f "$OLD_KEYCHAIN"
    echo "  removed the MicBridge development keychain (run scripts/dev-create-identity.sh for Jumphertz)"
fi

for dir in "$OLD_SUPPORT" "$OLD_CACHE"; do
    [[ -e "$dir" ]] && rm -rf "$dir" && echo "  removed $dir"
done
rmdir "$HOME/.local/bin" "$HOME/.local" 2>/dev/null || true
echo "MicBridge removed."
