#!/bin/bash
# Sourced by setup-signing.sh and build.sh. Shared names and helpers for the
# local signing identity.

# The identity keeps the name it was made with, when the app was called
# Terminal: macOS ties the app's permissions to it.
SIGN_IDENTITY="${RETAINER_SIGN_IDENTITY:-${TERMINAL_SIGN_IDENTITY:-Terminal Local Signing}}"
SIGNING_DIR="$HOME/Library/Application Support/blog.terminal.signing"
SIGNING_KEYCHAIN="$SIGNING_DIR/signing.keychain-db"
SIGNING_PASSWORD_FILE="$SIGNING_DIR/password"

# Prints the user's keychain search list, one path per line.
keychain_search_list() {
    security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/'
}

# True when the identity can be found through the normal search list.
identity_in_search_list() {
    security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_IDENTITY\""
}

# True when the dedicated keychain exists and holds the identity.
identity_in_signing_keychain() {
    [ -f "$SIGNING_KEYCHAIN" ] && [ -f "$SIGNING_PASSWORD_FILE" ] &&
        security find-identity -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null | grep -qF "\"$SIGN_IDENTITY\""
}

unlock_signing_keychain() {
    security unlock-keychain -p "$(cat "$SIGNING_PASSWORD_FILE")" "$SIGNING_KEYCHAIN"
}

# Reads the search list into the array SEARCH_LIST. Fails rather than return
# something that could not safely be written back.
read_search_list() {
    SEARCH_LIST=()
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            /*) SEARCH_LIST+=("$line") ;;
            *) return 1 ;;
        esac
    done < <(keychain_search_list)
    [ "${#SEARCH_LIST[@]}" -gt 0 ]
}
