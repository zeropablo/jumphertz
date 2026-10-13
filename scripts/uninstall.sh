#!/bin/bash
# Removes everything install.sh created.
#   -y, --yes   delete the configuration without asking
#   --dev       also delete the development signing keychain and its password (scripts/dev-create-identity.sh)
set -euo pipefail

LABEL=com.zeropablo.jumphertz
DOMAIN="gui/$(id -u)"
APP="$HOME/Applications/Jumphertz.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LINK="$HOME/.local/bin/jumphertz"
SUPPORT="$HOME/Library/Application Support/Jumphertz"
CACHE="$HOME/Library/Caches/Jumphertz"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

ROOT=$(cd "$(dirname "$0")/.." && pwd)

assume_yes=false
dev=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) assume_yes=true ;;
        --dev) dev=true ;;
        *) echo "usage: $0 [-y|--yes] [--dev]" >&2; exit 1 ;;
    esac
done

echo "==> Stopping the agent"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null && echo "stopped" || echo "not running"

echo "==> Removing files"
[[ -d "$APP" ]] && "$LSREGISTER" -u "$APP" 2>/dev/null || true
for path in "$PLIST" "$APP" "$CACHE"; do
    [[ -e "$path" ]] && rm -rf "$path" && echo "removed $path"
done
# Only remove the symlink if it is ours.
if [[ -L "$LINK" && "$(readlink "$LINK")" == "$APP/"* ]]; then rm -f "$LINK" && echo "removed $LINK"; fi
rmdir "$HOME/.local/bin" "$HOME/.local" 2>/dev/null || true   # only if empty

echo "==> Resetting the microphone permission"
tccutil reset Microphone "$LABEL" >/dev/null 2>&1 || true

if [[ -d "$SUPPORT" ]]; then
    answer=n
    if $assume_yes; then answer=y; else read -r -p "Delete the configuration in $SUPPORT? [y/N] " answer || true; fi
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        # The dev keychain password stays unless --dev: without it the dev keychain could not be unlocked.
        find "$SUPPORT" -mindepth 1 -maxdepth 1 ! -name dev-keychain-pass -exec rm -rf {} +
        rmdir "$SUPPORT" 2>/dev/null || true
        echo "removed the configuration in $SUPPORT"
    else
        echo "kept $SUPPORT"
    fi
fi

if $dev; then
    echo "==> Removing the development signing keychain"
    "$ROOT/scripts/dev-create-identity.sh" --remove
    rmdir "$SUPPORT" 2>/dev/null || true
fi

echo "==> Jumphertz uninstalled. BlackHole 2ch was left in place (brew uninstall blackhole-2ch to remove it)."
