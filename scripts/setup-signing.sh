#!/bin/bash
# Creates a stable code-signing identity for local builds of Retainer.
#
# macOS remembers privacy permissions per signing identity. Without a stable
# one, every rebuild looks like a new app and Accessibility, Screen Recording,
# Microphone and Speech Recognition all have to be granted again.
#
# This makes a self-signed certificate ("Terminal Local Signing", after the
# app's first name; renaming it would lose every permission already granted)
# in its own keychain under ~/Library/Application Support/blog.terminal.signing. It needs
# no Apple account, asks for no password, and does not touch the login
# keychain. Run it once.
#
#   ./scripts/setup-signing.sh                        create the identity
#   ./scripts/setup-signing.sh --add-to-search-list   also make it visible to Xcode
#   ./scripts/setup-signing.sh --remove               delete the identity and its keychain
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

case "${1:-}" in
    --remove)
        if [ -f "$SIGNING_KEYCHAIN" ]; then
            security delete-keychain "$SIGNING_KEYCHAIN"
        fi
        rm -rf "$SIGNING_DIR"
        echo "Removed the signing identity. Builds are ad-hoc signed until it is created again,"
        echo "and permissions granted to earlier builds will need to be granted afresh."
        exit 0
        ;;
    "" | --add-to-search-list) ;;
    *)
        echo "usage: $0 [--add-to-search-list | --remove]" >&2
        exit 2
        ;;
esac

if identity_in_signing_keychain; then
    echo "Signing identity \"$SIGN_IDENTITY\" already exists."
else
    if [ -e "$SIGNING_KEYCHAIN" ]; then
        echo "error: $SIGNING_KEYCHAIN exists but does not contain \"$SIGN_IDENTITY\"." >&2
        echo "       Run '$0 --remove' and try again." >&2
        exit 1
    fi

    umask 077
    mkdir -p "$SIGNING_DIR"
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT

    # The keychain's password only guards a key that signs this app on this
    # Mac. It is random and kept beside the keychain so builds can unlock it
    # without prompting.
    password="$(/usr/bin/openssl rand -hex 24)"
    printf '%s' "$password" > "$SIGNING_PASSWORD_FILE"

    cat > "$work/certificate.conf" <<CONF
[ req ]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[ subject ]
CN = $SIGN_IDENTITY
[ extensions ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

    # macOS's own LibreSSL, so the PKCS#12 file is one `security import` can read.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$work/key.pem" -out "$work/certificate.pem" -config "$work/certificate.conf" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/certificate.pem" \
        -name "$SIGN_IDENTITY" -out "$work/identity.p12" -passout "pass:$password"

    security create-keychain -p "$password" "$SIGNING_KEYCHAIN"
    # No auto-lock timeout.
    security set-keychain-settings "$SIGNING_KEYCHAIN"
    security unlock-keychain -p "$password" "$SIGNING_KEYCHAIN"
    security import "$work/identity.p12" -k "$SIGNING_KEYCHAIN" -P "$password" -T /usr/bin/codesign >/dev/null
    # Lets codesign use the key without a confirmation dialog.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$SIGNING_KEYCHAIN" >/dev/null

    echo "Created signing identity \"$SIGN_IDENTITY\" in:"
    echo "  $SIGNING_KEYCHAIN"
fi

if [ "${1:-}" = "--add-to-search-list" ]; then
    if keychain_search_list | grep -qxF "$SIGNING_KEYCHAIN"; then
        echo "The keychain is already in your search list."
    else
        if ! read_search_list; then
            echo "error: could not read your keychain search list; leaving it untouched." >&2
            exit 1
        fi
        security list-keychains -d user -s "${SEARCH_LIST[@]}" "$SIGNING_KEYCHAIN"
        echo "Added the keychain to your search list, so Xcode can find the identity."
    fi
    unlock_signing_keychain
fi

echo "Done. ./scripts/build.sh will sign with \"$SIGN_IDENTITY\" from now on."
