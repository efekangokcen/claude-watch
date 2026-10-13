#!/bin/bash
# Installs (or with --remove uninstalls) a user LaunchAgent so the bridge starts at login
# and is restarted if it dies. Logs: ~/.claude-watch/bridge.log
set -euo pipefail

LABEL="com.claude-watch.bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BRIDGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"
LOG_DIR="$HOME/.claude-watch"
mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents"

UID_NUM="$(id -u)"

if [[ "${1:-}" == "--remove" ]]; then
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL"
  exit 0
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BUN</string>
    <string>run</string>
    <string>$BRIDGE_DIR/src/index.js</string>
  </array>
  <key>WorkingDirectory</key><string>$BRIDGE_DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$LOG_DIR/bridge.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/bridge.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"
echo "Installed $LABEL -> $PLIST"
echo "Status: launchctl print gui/$UID_NUM/$LABEL | head -20"
echo "Logs:   tail -f $LOG_DIR/bridge.log"
