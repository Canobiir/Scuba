#!/bin/zsh
# Quits Scuba, builds this folder's copy, and opens the new build.
osascript -e 'quit app "Scuba"'
cd "$(dirname "$0")" && ./build.sh && open build/Scuba.app
