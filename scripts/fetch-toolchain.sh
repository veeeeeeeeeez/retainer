#!/bin/bash
# Fetches a Swift toolchain and macOS 26 SDK for Macs that cannot install Xcode 26.
#
# You do not need this if Xcode 26 or later is installed and selected.
#
# Retainer needs the macOS 26 SDK to compile (SpeechAnalyzer, Foundation
# Models). Apple ships that SDK in Xcode and in "Command Line Tools for
# Xcode 26", but Software Update does not offer either to macOS 15. The
# Command Line Tools packages themselves are published on Apple's update
# server and their compiler runs on macOS 14 and later, so this script
# downloads them from Apple, checks Apple's signature, and unpacks them into a
# folder in your home directory. Nothing is installed system-wide and the
# Command Line Tools in /Library/Developer are left untouched.
#
#   ./scripts/fetch-toolchain.sh              unpack to ~/Library/Caches/terminal-build-toolchain/CLT26
#   ./scripts/fetch-toolchain.sh <directory>  unpack somewhere else (then set TERMINAL_TOOLCHAIN to it)
#
# About 1 GB to download and 5 GB on disk. Delete the folder to remove it.
set -euo pipefail

destination="${1:-$HOME/Library/Caches/terminal-build-toolchain/CLT26}"
catalog_url="https://swscan.apple.com/content/catalogs/others/index-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz"

if [ -x "$destination/usr/bin/swift" ]; then
    echo "A toolchain is already present at $destination"
    "$destination/usr/bin/swift" --version 2>&1 | head -1
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Reading Apple's software update catalog..."
curl -fsSL "$catalog_url" -o "$work/catalog.gz"
gunzip "$work/catalog.gz"

# Pick the newest "Command Line Tools for Xcode 26.x" and list its packages.
python3 -I - "$work/catalog" > "$work/packages" <<'PYTHON'
import plistlib, re, sys, urllib.request

with open(sys.argv[1], "rb") as handle:
    catalog = plistlib.load(handle)

best = None
for product in catalog.get("Products", {}).values():
    urls = [package.get("URL", "") for package in product.get("Packages", [])]
    if not any("/CLTools_Executables" in url for url in urls):
        continue
    distributions = product.get("Distributions") or {}
    distribution = distributions.get("English") or next(iter(distributions.values()), None)
    if not distribution:
        continue
    text = urllib.request.urlopen(distribution, timeout=60).read().decode("utf-8", "replace")
    match = re.search(r'"SU_VERS"\s*=\s*"(\d+)\.(\d+)', text)
    if not match or int(match.group(1)) != 26:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    if best is None or version > best[0]:
        best = (version, [url for url in urls if "Remove" not in url])

if best is None:
    sys.exit("No Command Line Tools for Xcode 26 found in the catalog.")
sys.stderr.write("Found Command Line Tools for Xcode %d.%d\n" % best[0])
print("\n".join(best[1]))
PYTHON

mkdir -p "$work/packages.d" "$work/expanded"
while IFS= read -r url; do
    [ -z "$url" ] && continue
    name="$(basename "$url")"
    echo "Downloading $name"
    curl -fL --retry 3 --progress-bar "$url" -o "$work/packages.d/$name"

    # Refuse anything that is not signed by Apple.
    if ! pkgutil --check-signature "$work/packages.d/$name" | grep -q "Status: signed Apple Software"; then
        echo "error: $name is not signed by Apple; stopping." >&2
        exit 1
    fi

    pkgutil --expand-full "$work/packages.d/$name" "$work/expanded/${name%.pkg}"
    rm "$work/packages.d/$name"
done < "$work/packages"

mkdir -p "$destination"
for payload in "$work"/expanded/*/Payload/Library/Developer/CommandLineTools; do
    [ -d "$payload" ] && ditto "$payload" "$destination"
done

if [ ! -x "$destination/usr/bin/swift" ] || [ ! -d "$destination/SDKs/MacOSX.sdk" ]; then
    echo "error: the unpacked toolchain is incomplete." >&2
    exit 1
fi

echo "Toolchain ready at $destination"
"$destination/usr/bin/swift" --version 2>&1 | head -1
echo "SDK: $(basename "$(readlink "$destination/SDKs/MacOSX.sdk" || echo MacOSX.sdk)")"
