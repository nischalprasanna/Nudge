#!/bin/zsh
# Runs the depth-based hand finder on a synthetic screen-and-finger scene, on the Mac.
# It checks the geometry only; real LiDAR data is noisier than this scene.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")"
P=../../Nudge/Perception
OUT=$(mktemp -d)
xcrun swiftc -O main.swift $P/ScreenAnchor.swift $P/FrameGeometry.swift $P/DepthHandFinder.swift -o "$OUT/handtest"
"$OUT/handtest"
