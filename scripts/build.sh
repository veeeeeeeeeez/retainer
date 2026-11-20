#!/bin/bash
# Builds build/Retainer.app with SwiftPM, without needing Xcode.
#
#   ./scripts/build.sh            release build
#   ./scripts/build.sh debug      debug build
#
# The result is signed with the stable local identity when it exists
# (see scripts/setup-signing.sh), otherwise ad-hoc with a warning.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh
source scripts/signing.sh

configuration="${1:-release}"
app="build/Retainer.app"

echo "Building ($configuration) with $("$SWIFT" --version 2>&1 | head -1)"
"$SWIFT" build --package-path RetainerKit -c "$configuration" --product RetainerMain
binary="$("$SWIFT" build --package-path RetainerKit -c "$configuration" --show-bin-path)/RetainerMain"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Retainer"
cp App/Info.plist "$app/Contents/Info.plist"
cp App/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$app/Contents/PkgInfo"

executable="$app/Contents/MacOS/Retainer"

# Swift back-deployment libraries, if the binary uses any, travel inside the
# bundle. (Xcode does this automatically; SwiftPM does not.)
embedded=0
while IFS= read -r library; do
    name="${library#@rpath/}"
    source_library="$(dirname "$SWIFT")/../lib/swift-6.2/macosx/$name"
    if [ -f "$source_library" ]; then
        mkdir -p "$app/Contents/Frameworks"
        cp "$source_library" "$app/Contents/Frameworks/$name"
        embedded=1
    else
        echo "warning: $name is linked but was not found in the toolchain" >&2
    fi
done < <(otool -L "$executable" | awk '/@rpath\/libswift/ {print $1}')
if [ "$embedded" = 1 ]; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$executable"
fi

# Drop run paths that point into the build machine's toolchain or build folder.
while IFS= read -r run_path; do
    case "$run_path" in
        /usr/lib/swift | @executable_path/*) ;;
        *) install_name_tool -delete_rpath "$run_path" "$executable" 2>/dev/null || true ;;
    esac
done < <(otool -l "$executable" | awk '/LC_RPATH/ {getline; getline; print $2}')

sign() {
    codesign --force --timestamp=none --sign "$@" "$app"
}

if identity_in_search_list; then
    identity_in_signing_keychain && unlock_signing_keychain
    sign "$SIGN_IDENTITY"
    echo "Signed with \"$SIGN_IDENTITY\"."
elif identity_in_signing_keychain && read_search_list; then
    # codesign only finds identities in keychains on the search list. Put the
    # signing keychain there for the length of this one command, then restore
    # the list exactly as it was.
    restore_search_list() { security list-keychains -d user -s "${SEARCH_LIST[@]}"; }
    trap restore_search_list EXIT
    unlock_signing_keychain
    security list-keychains -d user -s "${SEARCH_LIST[@]}" "$SIGNING_KEYCHAIN"
    sign "$SIGN_IDENTITY" --keychain "$SIGNING_KEYCHAIN"
    restore_search_list
    trap - EXIT
    echo "Signed with \"$SIGN_IDENTITY\"."
else
    sign -
    echo "warning: no stable signing identity; signed ad-hoc." >&2
    echo "         macOS will ask for every permission again after each rebuild." >&2
    echo "         Run ./scripts/setup-signing.sh once, then build again." >&2
fi

codesign --verify --strict "$app"
echo "Built $app"
