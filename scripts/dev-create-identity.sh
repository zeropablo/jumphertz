#!/bin/bash
# Development only. Creates a self-signed code signing identity so that local builds keep the same signing
# identity across rebuilds: macOS then keeps the microphone permission instead of asking again after every
# reinstall (ad hoc signatures change with every build).
#
# The identity lives in a dedicated keychain whose password is generated and stored next to the config, so
# that build.sh can unlock it and sign without any prompt, independently of the login keychain.
#
#   ~/Library/Keychains/jumphertz-dev.keychain-db
#   ~/Library/Application Support/Jumphertz/dev-keychain-pass   (chmod 600)
#
# Idempotent, no sudo.
#   scripts/dev-create-identity.sh            create (or repair) the keychain and identity
#   scripts/dev-create-identity.sh --remove   delete them (also done by uninstall.sh --dev)
#
# Then: JUMPHERTZ_SIGN_IDENTITY="Jumphertz Local Signing" scripts/install.sh
#
# Overrides (for tests): JUMPHERTZ_IDENTITY_NAME, JUMPHERTZ_DEV_KEYCHAIN, JUMPHERTZ_DEV_KEYCHAIN_PASS_FILE,
# JUMPHERTZ_LEGACY_KEYCHAIN (keychain cleaned of identities created by earlier versions of this script).
set -euo pipefail

NAME=${JUMPHERTZ_IDENTITY_NAME:-Jumphertz Local Signing}
KEYCHAIN=${JUMPHERTZ_DEV_KEYCHAIN:-$HOME/Library/Keychains/jumphertz-dev.keychain-db}
PASS_FILE=${JUMPHERTZ_DEV_KEYCHAIN_PASS_FILE:-$HOME/Library/Application Support/Jumphertz/dev-keychain-pass}
LEGACY_KEYCHAIN=${JUMPHERTZ_LEGACY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}
OPENSSL=/usr/bin/openssl   # LibreSSL: its PKCS#12 output is readable by `security import` (OpenSSL 3's is not by default)

# User keychain search list, one path per line.
search_list() { security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/'; }

in_search_list() { search_list | grep -Fxq "$KEYCHAIN"; }

remove_from_search_list() {
    in_search_list || return 0
    local keep=()
    while IFS= read -r path; do [[ "$path" == "$KEYCHAIN" ]] || keep+=("$path"); done < <(search_list)
    security list-keychains -d user -s ${keep[@]+"${keep[@]}"}
    echo "Removed $(basename "$KEYCHAIN") from the keychain search list."
}

if [[ "${1:-}" == "--remove" ]]; then
    remove_from_search_list
    if [[ -f "$KEYCHAIN" ]]; then
        security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"
        echo "Deleted $KEYCHAIN"
    fi
    if [[ -f "$PASS_FILE" ]]; then rm -f "$PASS_FILE" && echo "Deleted $PASS_FILE"; fi
    exit 0
fi

# 1. Password: generated once, readable by the user only.
if [[ ! -s "$PASS_FILE" ]]; then
    if [[ -f "$KEYCHAIN" ]]; then
        echo "error: $KEYCHAIN exists but its password file is missing." >&2
        echo "Remove it with: $0 --remove   then run this script again." >&2
        exit 1
    fi
    mkdir -p "$(dirname "$PASS_FILE")"
    (umask 077 && "$OPENSSL" rand -hex 32 > "$PASS_FILE")
fi
chmod 600 "$PASS_FILE"
PASS=$(<"$PASS_FILE")

# 2. Dedicated keychain, never auto-locked (no timeout, no lock on sleep).
if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "$PASS" "$KEYCHAIN"
    echo "Created keychain $KEYCHAIN"
fi
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASS" "$KEYCHAIN"

# 3. codesign only finds identities in keychains of the search list. Append, keep the existing ones.
if ! in_search_list; then
    existing=()
    while IFS= read -r path; do existing+=("$path"); done < <(search_list)
    security list-keychains -d user -s ${existing[@]+"${existing[@]}"} "$KEYCHAIN"
    echo "Added $(basename "$KEYCHAIN") to the keychain search list."
fi

# 4. Self-signed code signing certificate + private key.
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Identity \"$NAME\" already present."
else
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/openssl.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    p12pass=$(uuidgen)
    "$OPENSSL" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
        -out "$tmp/identity.p12" -passout "pass:$p12pass"
    security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$p12pass" -T /usr/bin/codesign >/dev/null
    echo "Created identity \"$NAME\"."
fi

# 5. Let Apple tools (codesign) use the key without the "allow access" prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null

# 6. Clean up identities created in the login keychain by earlier versions of this script (best effort).
if [[ -f "$LEGACY_KEYCHAIN" && "$LEGACY_KEYCHAIN" != "$KEYCHAIN" ]]; then
    for _ in 1 2 3 4 5; do
        security find-certificate -c "$NAME" "$LEGACY_KEYCHAIN" >/dev/null 2>&1 || break
        if security delete-identity -c "$NAME" "$LEGACY_KEYCHAIN" >/dev/null 2>&1 \
           || security delete-certificate -c "$NAME" "$LEGACY_KEYCHAIN" >/dev/null 2>&1; then
            echo "Removed the old \"$NAME\" identity from $(basename "$LEGACY_KEYCHAIN")."
        else
            echo "warning: could not remove \"$NAME\" from $(basename "$LEGACY_KEYCHAIN"); delete it in Keychain Access." >&2
            break
        fi
    done
fi

if ! security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "error: identity \"$NAME\" not usable for code signing in $KEYCHAIN" >&2
    exit 1
fi

cat <<MSG

Ready. Build and install with:
  JUMPHERTZ_SIGN_IDENTITY="$NAME" scripts/install.sh

The certificate is self-signed and not trusted system-wide; it does not need to be. macOS identifies
Jumphertz by this certificate for the microphone permission.
MSG
