#!/bin/bash
# Build and install Claude Watch on your paired Apple Watch.
# Free Apple ID: the signature expires after 7 days, so run this weekly (iPhone connected by cable,
# watch nearby and unlocked). Pairing/settings on the watch are kept.
set -euo pipefail
cd "$(dirname "$0")/.."
DD="${DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/ClaudeWatch-deploy}"
STAMP="$HOME/.claude-watch/last-deploy"

echo "→ Finding paired Apple Watch…"
JSON=$(mktemp)
xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
WATCH_ID=$(python3 - "$JSON" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for dev in d.get("result",{}).get("devices",[]):
    hw=dev.get("hardwareProperties",{})
    if "watch" in (hw.get("platform","")+hw.get("deviceType","")).lower():
        print(dev.get("identifier","")); break
PY
)

echo "→ Building for watchOS (automatic signing)…"
xcodebuild build -project ClaudeWatch.xcodeproj -scheme ClaudeWatch -configuration Debug \
  -destination 'generic/platform=watchOS' -allowProvisioningUpdates -derivedDataPath "$DD" \
  | grep -E "error:|warning: .*sign|BUILD" || true
APP="$DD/Build/Products/Debug-watchos/ClaudeWatch.app"
[ -d "$APP" ] || { echo "✗ Build failed. Open watch/ClaudeWatch.xcodeproj in Xcode and set Signing → Team once."; exit 1; }

if [ -n "$WATCH_ID" ]; then
  echo "→ Installing on watch $WATCH_ID…"
  if xcrun devicectl device install app --device "$WATCH_ID" "$APP"; then
    date +%s > "$STAMP"
    echo "✓ Installed. Next refresh due in 7 days ($(date -v+7d '+%d %b'))."
    exit 0
  fi
fi

echo "ℹ Could not install from the command line (no paired watch found via devicectl)."
echo "  Open Xcode → select your Apple Watch as destination → Run (⌘R). Then: date +%s > $STAMP"
