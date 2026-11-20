#!/bin/bash
# Builds Retainer.app and packs it for download: a disk image and a zip.
#
#   ./scripts/package.sh               into website/downloads/, where
#                                      ./scripts/site.sh lists it
#   ./scripts/package.sh <directory>   somewhere else
#
# The files are named Retainer-<version>-<build>, <version> being
# CFBundleShortVersionString in App/Info.plist. Run by hand, <build> is
# "local" and each run replaces the last one's files. The release workflow
# sets RETAINER_BUILD_NUMBER, which becomes <build> and the app's
# CFBundleVersion.
set -euo pipefail

# A directory given by the caller is relative to where the caller is.
output="${1:-}"
case "$output" in
    "" | /*) ;;
    *) output="$PWD/$output" ;;
esac
cd "$(dirname "$0")/.."
output="${output:-website/downloads}"

build="${RETAINER_BUILD_NUMBER:-local}"
if [ -n "${RETAINER_BUILD_NUMBER:-}" ] && ! [[ "$RETAINER_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "error: RETAINER_BUILD_NUMBER must be a whole number, not \"$RETAINER_BUILD_NUMBER\"." >&2
    exit 2
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Info.plist)"
name="Retainer-$version-$build"
app="build/Retainer.app"

./scripts/build.sh release

# Whatever the binary loads from its own bundle has to be in the bundle.
# Nothing notices a missing library on the Mac that built it; the app just
# fails to start on a macOS that needs it.
missing=0
while IFS= read -r library; do
    if [ ! -f "$app/Contents/Frameworks/${library#@rpath/}" ]; then
        echo "error: the app links $library, which is not in $app/Contents/Frameworks." >&2
        missing=1
    fi
done < <(otool -L "$app/Contents/MacOS/Retainer" | awk '$1 ~ /^@rpath\// {print $1}')
[ "$missing" = 0 ] || exit 1

# The binary records the SDK it was linked against, and macOS 26 goes by
# that: an app that names an older SDK is run as one made for the older
# system. A build can come out that way without any error (toolchain.sh has
# the story), so look.
sdk="$(otool -l "$app/Contents/MacOS/Retainer" | awk '/LC_BUILD_VERSION/ {found = 1} found && $1 == "sdk" {print $2; exit}')"
case "${sdk%%.*}" in
    "" | *[!0-9]*) sdk_major=0 ;;
    *) sdk_major="${sdk%%.*}" ;;
esac
if [ "$sdk_major" -lt 26 ]; then
    echo "error: the app says it was linked against the macOS ${sdk:-unknown} SDK; it has to be 26 or later." >&2
    exit 1
fi

mkdir -p "$output"
output="$(cd "$output" && pwd)"
zip="$output/$name.zip"
image="$output/$name.dmg"
rm -f "$zip" "$image"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Extended attributes are left out of both: the bundle needs none, and in a
# zip they become "._" files that break the signature for anyone who unpacks
# it with something other than the Finder.
ditto -c -k --keepParent --norsrc --noextattr "$app" "$zip"

# The disk image opens on a window with the app, the Applications folder and
# an arrow from the one to the other. dmgbuild makes it (scripts/dmg/build.py
# has the layout, and checks the result). dmgbuild and the two packages it
# needs go into a folder under build/, at the exact versions and hashes in
# scripts/dmg/requirements.txt; nothing is installed on the Mac itself. The
# Python is the one that comes with Xcode and its Command Line Tools.
tools="build/dmg-tools"
if ! cmp -s scripts/dmg/requirements.txt "$tools/requirements.txt"; then
    rm -rf "$tools"
    /usr/bin/python3 -m venv "$tools"
    "$tools/bin/pip" install --quiet --disable-pip-version-check --require-hashes --only-binary :all: \
        -r scripts/dmg/requirements.txt
    cp scripts/dmg/requirements.txt "$tools/requirements.txt"
fi
ditto --norsrc --noextattr "$app" "$work/Retainer.app"
"$tools/bin/python" scripts/dmg/build.py "$work/Retainer.app" "$image"

# Check what will be downloaded, not what was built: unpack the zip and make
# sure the signature survived the trip. (build.py has done the same for the
# app inside the disk image.)
ditto -x -k "$zip" "$work/unpacked"
codesign --verify --deep --strict "$work/unpacked/Retainer.app"
hdiutil verify -quiet "$image"

echo "Packaged $(du -h "$image" | cut -f1 | tr -d ' ') $image"
echo "         $(du -h "$zip" | cut -f1 | tr -d ' ') $zip"
