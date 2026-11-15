#!/bin/zsh
# Builds the Mac tools that replay a recording from the phone (Documents/track.bin).
#   ./replay <track.bin> <outdir> [base|two|black|mirror|roi|roi2]   Apple's hand tracker on every frame, contact sheets, frames.csv
#   ./depthview <track.bin> <out.jpg> <frame> <frame> ...            photo beside LiDAR height above the screen
#   ./ridgetest <track.bin> <outdir>                                 the LiDAR finger finder scored against the hand tracker
#   ./heights <track.bin> <frame> ...                                LiDAR height along the finger, 3 mm steps
#   python3 analyse.py <outdir>                                      breakdown of ridgetest's both.csv
cd "$(dirname "$0")"
P=../../Nudge/Perception
swiftc -O -o replay main.swift Track.swift $P/FrameGeometry.swift $P/ScreenAnchor.swift
swiftc -O -o depthview depth/main.swift Track.swift $P/FrameGeometry.swift $P/ScreenAnchor.swift
swiftc -O -o ridgetest fingertest/main.swift Track.swift $P/DepthFingerFinder.swift $P/FrameGeometry.swift $P/ScreenAnchor.swift
swiftc -O -o heights profile/main.swift Track.swift $P/FrameGeometry.swift $P/ScreenAnchor.swift
