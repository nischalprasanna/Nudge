#!/bin/zsh
# Build Nudge, install it on the connected iPhone and launch it.
#
# Usage: scripts/deploy.sh                build + install + launch, with the embedded Watch app
#        scripts/deploy.sh --phone-only   same, but without the Watch app (use until the Watch is set up)
#        add --build to stop after building
#
# Uses the full Xcode even if xcode-select still points at the Command Line Tools.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

BUNDLE_ID="com.nudgea11y.Nudge"
PHONE_ONLY=0
BUILD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --phone-only) PHONE_ONLY=1 ;;
    --build) BUILD_ONLY=1 ;;
  esac
done

# First physical iPhone that is connected.
DEVICES_JSON=$(mktemp)
xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1 || true
read -r PHONE PHONE_UDID <<<"$(python3 -I - "$DEVICES_JSON" <<'EOF'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    if (hw.get("deviceType") == "iPhone" and hw.get("reality") == "physical"
            and d.get("connectionProperties", {}).get("tunnelState") == "connected"):
        print(d["identifier"], hw.get("udid", ""))
        break
EOF
)"
rm -f "$DEVICES_JSON"
[[ -n "${PHONE:-}" ]] || { echo "No iPhone found. Plug it in, unlock it and trust this Mac."; exit 1; }

if [[ $PHONE_ONLY == 1 ]]; then
  # Derive a spec without the Watch target, so signing does not need a registered Watch.
  python3 -I - <<'EOF'
s = open("project.yml").read()
s = s.replace("name: Nudge\n", "name: NudgePhoneOnly\n", 1)
s = s.replace("    dependencies:\n      - target: NudgeWatch\n", "")
s = s[:s.index("  NudgeWatch:\n    type: application")]
s += "\nschemes:\n  Nudge:\n    build:\n      targets:\n        Nudge: all\n"
open(".phone-only.yml", "w").write(s)
EOF
  xcodegen generate --spec .phone-only.yml --quiet
  rm -f .phone-only.yml
  PROJECT="NudgePhoneOnly.xcodeproj"
  DERIVED="build/phone-only"
else
  xcodegen generate --quiet
  PROJECT="Nudge.xcodeproj"
  DERIVED="build"
fi
APP="$DERIVED/Build/Products/Debug-iphoneos/Nudge.app"

set +e
xcodebuild -project "$PROJECT" -scheme Nudge -configuration Debug \
  -destination "id=$PHONE_UDID" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
  | grep -E 'error|warning: |BUILD (SUCCEEDED|FAILED)' | grep -v appintents | sort -u
BUILD_STATUS=${pipestatus[1]}
set -e
[[ $BUILD_STATUS == 0 ]] || { echo "Build failed."; exit 1; }
[[ $BUILD_ONLY == 1 ]] && exit 0

xcrun devicectl device install app --device "$PHONE" "$APP" | grep -E 'App installed|error|bundleID' || true
xcrun devicectl device process launch --device "$PHONE" --terminate-existing "$BUNDLE_ID" | grep -E 'Launched|error|denied' || true
echo "Done."
