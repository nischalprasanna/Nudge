#!/bin/zsh
# Build Nudge for the iOS Simulator and take screenshots of its screens.
# The simulator has no camera, LiDAR or microphone, so this checks layout and animation only.
#
# Usage: scripts/sim.sh <output-folder> [state ...]
#   states: home settings idle listening planning seeking closer tap done problem
#   Extra simulator settings can be given through the environment:
#     TEXT_SIZE=accessibility-extra-large   (see `xcrun simctl ui booted content_size`)
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
OUT="$1"; shift
STATES=("$@")
[[ ${#STATES[@]} -gt 0 ]] || STATES=(home settings idle listening planning seeking closer tap done problem)
BUNDLE_ID="com.nudgea11y.Nudge"
mkdir -p "$OUT"

DEVICE=$(xcrun simctl list devices booted | awk -F '[()]' '/iPhone/ {print $2; exit}')
if [[ -z "$DEVICE" ]]; then
  DEVICE=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone .*Pro Max/ {print $2}' | tail -1)
  xcrun simctl boot "$DEVICE"
  xcrun simctl bootstatus "$DEVICE" -b >/dev/null
fi

python3 -I - <<'PY'
s = open("project.yml").read()
s = s.replace("name: Nudge\n", "name: NudgePhoneOnly\n", 1)
s = s.replace("    dependencies:\n      - target: NudgeWatch\n", "")
s = s[:s.index("  NudgeWatch:\n    type: application")]
s += "\nschemes:\n  Nudge:\n    build:\n      targets:\n        Nudge: all\n"
open(".phone-only.yml", "w").write(s)
PY
xcodegen generate --spec .phone-only.yml --quiet
rm -f .phone-only.yml

set +e
xcodebuild -project NudgePhoneOnly.xcodeproj -scheme Nudge -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build/sim build \
  | grep -E 'error|warning: |BUILD (SUCCEEDED|FAILED)' | grep -v appintents | sort -u
STATUS=${pipestatus[1]}
set -e
[[ $STATUS == 0 ]] || { echo "Build failed."; exit 1; }

xcrun simctl install "$DEVICE" build/sim/Build/Products/Debug-iphonesimulator/Nudge.app
xcrun simctl ui "$DEVICE" appearance dark >/dev/null 2>&1 || true
[[ -n "${TEXT_SIZE:-}" ]] && xcrun simctl ui "$DEVICE" content_size "$TEXT_SIZE" || true
for state in "${STATES[@]}"; do
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" -NudgePreview "$state" >/dev/null
  sleep "${SETTLE:-2.5}"
  xcrun simctl io "$DEVICE" screenshot "$OUT/$state.png" >/dev/null 2>&1
  echo "saved $OUT/$state.png"
done
