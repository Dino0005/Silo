#!/usr/bin/env bash
# Add the gst-libav + matroska add-on (built by Scripts/build-gst-libav.sh) to a Wine runtime that has
# CrossOver's lib64 layout — e.g. one imported from CrossOver. Copies the two plugins into
# lib64/gstreamer-1.0 and the FFmpeg libraries into lib64; nothing existing is replaced.
#
# Refuses a runtime whose GStreamer isn't the version the add-on was built for: the core rejects a plugin
# built for a newer minor, and one built for an older minor is untested against it.
#
# Existing bottles pick the new plugins up by themselves: GStreamer re-validates its registry cache
# (GST_REGISTRY, per prefix) against the plugin directory on the next media use.
#
# Usage: Scripts/add-gst-libav.sh <runtime-root> [add-on dir, default: the newest dist/gst-libav-*]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RT="${1:?usage: add-gst-libav.sh <runtime-root> [add-on dir]}"
ADDON="${2:-$(ls -d "$ROOT"/dist/gst-libav-* 2>/dev/null | sort -V | tail -1)}"
[ -d "$ADDON/lib64/gstreamer-1.0" ] || { echo "ERROR: no add-on at '$ADDON' — run Scripts/build-gst-libav.sh"; exit 1; }
CORE="$RT/lib64/libgstreamer-1.0.0.dylib"
[ -f "$CORE" ] || { echo "ERROR: $CORE not found — not a CrossOver-layout runtime"; exit 1; }

# GStreamer's dylib compatibility version is minor*100+micro+1 (1.24.4 → 2405, 1.28.x → 28xx): compare the
# minor with the add-on's.
WANT="$(cut -d. -f2 "$ADDON/GSTREAMER_VERSION")"
HAVE="$(otool -L "$CORE" | sed -n 2p | sed 's/.*compatibility version \([0-9]*\).*/\1/')"
if [ "$((HAVE / 100))" != "$WANT" ]; then
  echo "ERROR: runtime GStreamer is 1.$((HAVE / 100)).x, add-on is built for $(cat "$ADDON/GSTREAMER_VERSION")"; exit 1
fi

cd "$ADDON/lib64"
for f in gstreamer-1.0/*.dylib *.dylib; do
  if [ -e "$RT/lib64/$f" ] && ! cmp -s "$f" "$RT/lib64/$f"; then
    echo "ERROR: $RT/lib64/$f already exists and differs — not overwriting"; exit 1
  fi
done
for f in gstreamer-1.0/*.dylib *.dylib; do cp -f "$f" "$RT/lib64/$f"; done
echo "Added $(ls gstreamer-1.0 | tr '\n' ' ')+ $(ls *.dylib | wc -l | tr -d ' ') FFmpeg libraries to $RT/lib64"
