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

mkdir "$work/image"
ditto --norsrc --noextattr "$app" "$work/image/Retainer.app"
ln -s /Applications "$work/image/Applications"
# hdiutil now and then finds the folder "busy" on a build machine; it is
# worth a second and a third try before giving up.
attempt=1
until hdiutil create -quiet -volname "Retainer" -srcfolder "$work/image" -fs HFS+ -format UDZO -ov "$image"; do
    if [ "$attempt" -ge 3 ]; then
        echo "error: could not create $image." >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 2
done

# Check what will be downloaded, not what was built: unpack the zip and make
# sure the signature survived the trip.
ditto -x -k "$zip" "$work/unpacked"
codesign --verify --deep --strict "$work/unpacked/Retainer.app"
hdiutil verify -quiet "$image"

echo "Packaged $(du -h "$image" | cut -f1 | tr -d ' ') $image"
echo "         $(du -h "$zip" | cut -f1 | tr -d ' ') $zip"
