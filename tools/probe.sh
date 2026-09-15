#!/bin/bash
# Quick hardware check: prints what the camera at $1 (default 192.168.122.1:8080) says it supports.
# Usage: tools/probe.sh [host:port]
HOST="${1:-192.168.122.1:8080}"
URL="http://$HOST/sony/camera"
call() { curl -s --max-time 5 -X POST "$URL" -H 'Content-Type: application/json' -d "{\"method\":\"$1\",\"params\":$2,\"id\":1,\"version\":\"${3:-1.0}\"}"; echo; }
echo "== $URL"
echo "-- getVersions";          call getVersions '[]'
echo "-- getAvailableApiList";  call getAvailableApiList '[]'
echo "-- getEvent (1.0)";       call getEvent '[false]' | head -c 3000; echo
echo "-- startLiveview";        call startLiveview '[]'
