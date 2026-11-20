#!/bin/bash
# Renders the downloads page and serves it on http://localhost:3000.
#
# The page lists the package made by ./scripts/package.sh, if there is one,
# and under it the published releases: the rows the public page has.
#
#   ./scripts/site.sh               serve on port 3000
#   PORT=8080 ./scripts/site.sh     or on another port
set -euo pipefail
cd "$(dirname "$0")/.."

port="${PORT:-3000}"
# The folder's real path. Conductor can reach one workspace by two names (one
# a link to the other), and the server from an earlier run is recognised
# below by this path.
site="$(pwd -P)/website/_site"

# The published releases, read from GitHub without signing in (the repository
# is public). Offline, the page is made from the local package alone.
repository="$(git remote get-url origin 2>/dev/null | sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p' | sed 's/\.git$//')"
releases="$(mktemp)"
if [ -z "$repository" ] ||
    ! curl -fsSL --max-time 10 "https://api.github.com/repos/$repository/releases?per_page=100" -o "$releases"; then
    echo "note: could not read the published releases; listing local packages only." >&2
    echo '[]' > "$releases"
fi

mkdir -p website/downloads
python3 website/build.py --releases "$releases" --local website/downloads --out "$site"
rm -f "$releases"

# An earlier run of this script still holding the port is replaced. Anything
# else on the port is somebody else's server and is left alone.
for pid in $(lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null || true); do
    command="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    case "$command" in
        *"http.server $port"*"$site"*)
            kill "$pid" 2>/dev/null || true
            while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
            ;;
        *)
            echo "error: port $port is already in use by: ${command:-process $pid}" >&2
            echo "       Stop it, or pick another port: PORT=3001 ./scripts/site.sh" >&2
            exit 1
            ;;
    esac
done

echo "Retainer downloads: http://localhost:$port"
exec python3 -m http.server "$port" --bind 127.0.0.1 --directory "$site"
