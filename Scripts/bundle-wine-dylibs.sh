#!/usr/bin/env bash
# Make a self-built Wine install self-contained, in CrossOver's own layout: every third-party dylib
# (freetype, gnutls, MoltenVK, SDL, and the whole GStreamer stack) in <wine>/lib64 with an @rpath install
# name, GStreamer's plugins in <wine>/lib64/gstreamer-1.0, and Wine's unix modules pointed at lib64 by
# rpath. See Scripts/bundle_wine_dylibs.py for the details.
#
# Usage: bundle-wine-dylibs.sh <wine-install-dir>
set -euo pipefail
exec python3 "$(dirname "$0")/bundle_wine_dylibs.py" "$@"
