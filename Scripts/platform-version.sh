#!/usr/bin/env bash
# Sourced by build-app.sh and dev.sh. Sets PLATFORM_VERSION: the linker flags that record the SDK the
# app was actually BUILT AGAINST, keeping the deployment target where Package.swift put it.
#
# SwiftPM writes the deployment target into BOTH fields of LC_BUILD_VERSION, so the binary claimed to
# have been built against the macOS 15 SDK — and that field is what AppKit reads to decide whether an app
# gets the current design or the compatibility appearance. The result was a window drawn in the
# pre-Liquid-Glass style on macOS 26/27: toolbar buttons as loose icons with no shared glass background,
# a bordered search field. Nothing in the toolbar code was wrong; it was never consulted.
#
# The minos value has to stay exactly what SwiftPM compiled for, so it's read from Package.swift rather
# than repeated here.
MIN_OS=$(sed -n 's/.*platforms: \[\.macOS(\.v\([0-9][0-9]*\)).*/\1.0/p' Package.swift)
SDK_VERSION=$(xcrun --show-sdk-version)
if [ -z "$MIN_OS" ]; then
    echo "!! couldn't read the macOS deployment target from Package.swift" >&2
    exit 1
fi
PLATFORM_VERSION=(-Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_OS" -Xlinker "$SDK_VERSION")
