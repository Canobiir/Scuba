#!/bin/bash
# Lets Claude build Scuba (and restart it) without typing in Terminal.
# Start it once in a Terminal window and leave that window open:
#     ~/Documents/Scuba/dev/watch.sh
# Ctrl + C stops it. It only ever runs ./build.sh, or restarts Scuba.
cd "$(dirname "$0")/.." || exit 1
mkdir -p dev/requests
echo "Scuba build helper: watching for requests (Ctrl + C to stop)"
while true; do
  for req in dev/requests/*; do
    [ -e "$req" ] || continue
    name=$(basename "$req")
    rm -f "$req"
    case "$name" in
      build-*)
        echo "[$(date '+%H:%M:%S')] Building ($name)…"
        if ./build.sh > dev/build.log 2>&1; then status=ok; else status=failed; fi
        echo "$status $(date '+%H:%M:%S') $name" > dev/build-status
        echo "[$(date '+%H:%M:%S')] Build $status"
        ;;
      run-*)
        osascript -e 'quit app "Scuba"' 2>/dev/null
        sleep 1.5
        open build/Scuba.app
        echo "running $(date '+%H:%M:%S') $name" > dev/run-status
        echo "[$(date '+%H:%M:%S')] Restarted Scuba"
        ;;
    esac
  done
  sleep 1
done
