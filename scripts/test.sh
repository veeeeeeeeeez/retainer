#!/bin/bash
# Runs the unit tests (Swift Testing) for the RetainerKit package.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh

extra=()
if [ -n "${TERMINAL_TOOLCHAIN:-}" ]; then
    # A Command Line Tools directory outside /Library/Developer is not searched
    # for the Testing framework automatically, so point the build at it.
    frameworks="$TERMINAL_TOOLCHAIN/Library/Developer/Frameworks"
    extra=(
        -Xswiftc -F -Xswiftc "$frameworks"
        -Xlinker -F -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$frameworks"
        -Xlinker -rpath -Xlinker "$TERMINAL_TOOLCHAIN/Library/Developer/usr/lib"
    )
fi

exec "$SWIFT" test --package-path RetainerKit "${extra[@]}" "$@"
