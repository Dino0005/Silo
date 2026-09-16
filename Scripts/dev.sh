#!/usr/bin/env bash
# Fast UI iteration: run the executable directly (debug). Pass --smoke for a headless check.
set -euo pipefail
cd "$(dirname "$0")/.."
# Same linker flags the app bundle gets: without them the window comes up in the compatibility
# appearance, which for a script whose whole purpose is looking at the UI is worse than useless.
. ./Scripts/platform-version.sh
exec swift run "${PLATFORM_VERSION[@]}" silo "$@"
