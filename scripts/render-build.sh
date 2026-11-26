#!/bin/bash
# What Render runs to build the website (see render.yaml): the downloads page
# with a row for every published release, and the sign-in pages beside it,
# into website/_site.
#
# The releases are read from GitHub without signing in (the repository is
# public). If GitHub cannot be reached the build fails, and Render goes on
# serving the last one that worked.
set -euo pipefail
cd "$(dirname "$0")/.."

repository="${RETAINER_REPOSITORY:-veeeeeeeeeez/retainer}"
releases="$(mktemp)"
curl -fsSL --retry 3 --max-time 20 \
    "https://api.github.com/repos/$repository/releases?per_page=100" -o "$releases"
python3 website/build.py --releases "$releases" --out website/_site
rm -f "$releases"
