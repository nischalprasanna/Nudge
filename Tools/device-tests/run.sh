#!/bin/zsh
# Tests saved devices on the Mac: recognising a device from a garbled reading, matching what was
# said to a saved task, and replaying a saved task with no network.
cd "$(dirname "$0")"
N=../../Nudge
swiftc -O -o matching-test matching/main.swift $N/Devices/DeviceStore.swift $N/Perception/Models.swift && ./matching-test
swiftc -O -o routine-test routine/main.swift stub.swift $N/Devices/DeviceStore.swift $N/Devices/RoutinePlanner.swift \
  $N/Perception/Models.swift $N/Intelligence/*.swift $N/Task/DebugLog.swift && ./routine-test
