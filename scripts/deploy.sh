#!/bin/zsh
# Build Nudge (iPhone app with the embedded Watch app), install it on the connected
# iPhone and launch it. The Watch app installs itself from the iPhone app.
#
# Usage: scripts/deploy.sh            build + install + launch on the iPhone
#        scripts/deploy.sh --build    build only
#
# Uses the full Xcode even if xcode-select still points at the Command Line Tools.
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."

BUNDLE_ID="com.nudgea11y.Nudge"
APP="build/Build/Products/Debug-iphoneos/Nudge.app"

xcodegen generate --quiet

xcodebuild -project Nudge.xcodeproj -scheme Nudge -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  -allowProvisioningUpdates build \
  | grep -E 'error|warning: |BUILD (SUCCEEDED|FAILED)' | grep -v appintents || true

[[ -d "$APP" ]] || { echo "Build did not produce $APP"; exit 1; }
[[ "${1:-}" == "--build" ]] && exit 0

# First connected iPhone.
PHONE=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /(available|connected)/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}-/) {print $i; exit}}')
[[ -n "$PHONE" ]] || { echo "No iPhone found. Plug it in, unlock it and trust this Mac."; exit 1; }

xcrun devicectl device install app --device "$PHONE" "$APP"
xcrun devicectl device process launch --device "$PHONE" --terminate-existing "$BUNDLE_ID"
echo "Installed and launched on the iPhone. The Watch app installs from the iPhone within a minute or two."
