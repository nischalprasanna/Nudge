#!/bin/zsh
# Builds the two Mac tools that replay a recording from the phone (Documents/track.bin).
#   ./replay <track.bin> <outdir> [base|two|black|mirror|roi|roi2]   hand tracker on every frame, contact sheets, frames.csv
#   ./depthview <track.bin> <out.jpg> <frame> <frame> ...            photo beside LiDAR height above the screen
cd "$(dirname "$0")"
P=../../Nudge/Perception
swiftc -O -o replay main.swift Track.swift $P/FrameGeometry.swift $P/ScreenAnchor.swift
swiftc -O -o depthview depth/main.swift Track.swift $P/FrameGeometry.swift $P/ScreenAnchor.swift
