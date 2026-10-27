#!/bin/zsh
# Captures App Store screenshots from booted Simulators running the app against tools/camerasim.py.
#
#   capture.sh <simulator-udid> <out-dir> <frames-dir> name:frame:overlays ...
#
# Each shot restarts the fake camera serving <frames-dir>/<frame>.jpg as live view, relaunches the
# app with CINEMAHUD_OVERLAYS=<overlays> (Debug builds only), and saves <out-dir>/<name>.png.
# Install a landscape-only build for the viewfinder layout, or the normal build for portrait.
# CAPTURE_DISPLAY picks the panel on multi-display devices (iPhone Duo: primary or primary-1).
set -euo pipefail
sim=$1 out=$2 frames=$3; shift 3
repo=${0:A:h:h:h:h}
bundle=com.shivvyas.cinemahud.mobile
mkdir -p "$out"

for spec in "$@"; do
    name=${spec%%:*}; rest=${spec#*:}; frame=${rest%%:*}; overlays=${rest#*:}
    pkill -f "tools/camerasim.py" 2>/dev/null || true
    python3 "$repo/tools/camerasim.py" --port 8080 --no-ssdp --no-label --photo "$frames/$frame.jpg" >/dev/null 2>&1 &
    cam=$!
    for _ in {1..40}; do curl -s -o /dev/null http://127.0.0.1:8080/dd.xml && break; sleep 0.25; done
    xcrun simctl terminate "$sim" "$bundle" 2>/dev/null || true
    SIMCTL_CHILD_CINEMAHUD_NO_INTRO=1 SIMCTL_CHILD_CINEMAHUD_ADDRESS=127.0.0.1:8080 \
        SIMCTL_CHILD_CINEMAHUD_OVERLAYS="$overlays" xcrun simctl launch "$sim" "$bundle" >/dev/null
    sleep 11
    xcrun simctl io "$sim" screenshot ${CAPTURE_DISPLAY:+--display="$CAPTURE_DISPLAY"} "$out/$name.png" >/dev/null 2>&1
    kill $cam 2>/dev/null || true
    echo "$name"
done
