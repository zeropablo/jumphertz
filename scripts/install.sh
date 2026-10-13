#!/bin/bash
# Installs (or updates) MicBridge for the current user. Idempotent, never uses sudo.
#
#   ~/Applications/MicBridge.app
#   ~/Library/LaunchAgents/com.zeropablo.micbridge.plist
#   ~/.local/bin/micbridge -> MicBridge.app/Contents/MacOS/MicBridge
#
# MICBRIDGE_SIGN_IDENTITY: sign with this identity instead of ad hoc (see scripts/dev-create-identity.sh);
# the microphone permission is then kept across reinstalls.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LABEL=com.zeropablo.micbridge
DOMAIN="gui/$(id -u)"
APP="$HOME/Applications/MicBridge.app"
EXE="$APP/Contents/MacOS/MicBridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN_DIR="$HOME/.local/bin"

step() { printf '\n==> %s\n' "$*"; }
die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "do not run this script with sudo; MicBridge installs for the current user only."

step "Checking requirements"
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    die "the Xcode Command Line Tools are required. Install them with:  xcode-select --install"
fi
if [[ ! -d /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver ]] \
   && ! system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole 2ch:"; then
    die "BlackHole 2ch is not installed. Install it with:  brew install blackhole-2ch
       (or from https://existential.audio/blackhole/), then run this script again."
fi
echo "Command Line Tools: $(xcode-select -p)"
echo "BlackHole 2ch: found"

step "Building"
BUILT=$("$ROOT/scripts/build.sh" | tail -1)
[[ -d "$BUILT" ]] || die "build failed"

step "Stopping the running agent (if any)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null && echo "stopped" || echo "not running"
for _ in {1..50}; do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.1; done

step "Installing $APP"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$BUILT" "$APP"

if [[ -z "${MICBRIDGE_SIGN_IDENTITY:-}" ]]; then
    # An ad hoc signature changes with every build, so the previous permission no longer matches it and
    # the agent would silently record nothing. Start from a clean state and ask again.
    step "Resetting the microphone permission (ad hoc signature)"
    tccutil reset Microphone "$LABEL" >/dev/null 2>&1 || true
fi

step "Installing the command line tool"
mkdir -p "$BIN_DIR"
ln -sfn "$EXE" "$BIN_DIR/micbridge"
echo "$BIN_DIR/micbridge"

step "Microphone permission"
# Launched through LaunchServices, the prompt is attributed to MicBridge (not to this terminal).
result_file=$(mktemp -t micbridge-permission)
trap 'rm -f "$result_file"' EXIT
echo "If macOS asks, allow MicBridge to use the microphone."
open -W -n "$APP" --args --request-permission --result-file "$result_file" || true
permission=$(tr -d '[:space:]' < "$result_file" 2>/dev/null || true)
case "$permission" in
    granted) echo "granted" ;;
    denied)  echo "DENIED. Enable it in System Settings › Privacy & Security › Microphone › MicBridge." ;;
    *)       echo "unknown (${permission:-no answer}). Check System Settings › Privacy & Security › Microphone." ;;
esac

step "Installing the LaunchAgent"
mkdir -p "$(dirname "$PLIST")"
sed "s|__EXECUTABLE__|$EXE|g" "$ROOT/Resources/$LABEL.plist.template" > "$PLIST"
plutil -lint -s "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"
for _ in {1..30}; do [[ -n "$("$EXE" --status 2>/dev/null | grep '^Agent: *running')" ]] && break; sleep 0.1; done
"$EXE" --status | sed 's/^/  /'

step "Done"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) printf '%s is not in your PATH. To use the micbridge command, add this line to ~/.zshrc:\n  export PATH="$HOME/.local/bin:$PATH"\n\n' "$BIN_DIR" ;;
esac
cat <<'MSG'
Last step, in Discord: Settings › Voice & Video › Input Device = "BlackHole 2ch",
and turn off Krisp noise suppression.

Logs:  log stream --predicate 'subsystem == "com.zeropablo.micbridge"'
MSG
