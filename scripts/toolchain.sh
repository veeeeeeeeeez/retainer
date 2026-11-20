#!/bin/bash
# Sourced by the other scripts. Picks the Swift toolchain to build with.
#
# The app needs a macOS 26 SDK and Swift 6.2 or later. If the active developer
# directory already provides that (Xcode 26+), it is used as is. Otherwise set
# TERMINAL_TOOLCHAIN to a Command Line Tools-style directory (containing
# usr/bin/swift and SDKs/MacOSX.sdk).

DEFAULT_SCRATCH_TOOLCHAIN="$HOME/Library/Caches/terminal-build-toolchain/CLT26"

if [ -z "${TERMINAL_TOOLCHAIN:-}" ] && [ -x "$DEFAULT_SCRATCH_TOOLCHAIN/usr/bin/swift" ]; then
    sdk_major=$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)
    if [ -z "$sdk_major" ] || [ "$sdk_major" -lt 26 ]; then
        TERMINAL_TOOLCHAIN="$DEFAULT_SCRATCH_TOOLCHAIN"
    fi
fi

if [ -n "${TERMINAL_TOOLCHAIN:-}" ]; then
    if [ ! -x "$TERMINAL_TOOLCHAIN/usr/bin/swift" ]; then
        echo "error: TERMINAL_TOOLCHAIN=$TERMINAL_TOOLCHAIN has no usr/bin/swift" >&2
        exit 1
    fi
    export SDKROOT="$TERMINAL_TOOLCHAIN/SDKs/MacOSX.sdk"
    export PATH="$TERMINAL_TOOLCHAIN/usr/bin:$PATH"
    SWIFT="$TERMINAL_TOOLCHAIN/usr/bin/swift"
else
    SWIFT="$(xcrun --find swift 2>/dev/null || command -v swift)"
    sdk_major=$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)
    if [ -z "$sdk_major" ] || [ "$sdk_major" -lt 26 ]; then
        echo "error: the active toolchain's macOS SDK is ${sdk_major:-unknown}; version 26 or later is required." >&2
        echo "       Install Xcode 26+ and select it with xcode-select, or set TERMINAL_TOOLCHAIN." >&2
        exit 1
    fi
fi
export SWIFT
