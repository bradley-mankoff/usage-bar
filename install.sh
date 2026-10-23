#!/bin/bash
# Build UsageBar, install it as ~/Applications/UsageBar.app, and (re)start it
# through a launch agent that opens it at login and restarts it if it crashes.
set -euo pipefail
cd "$(dirname "$0")"

label=com.bradley-mankoff.usagebar
app="$HOME/Applications/UsageBar.app"
agent="$HOME/Library/LaunchAgents/$label.plist"

swift build -c release
mkdir -p "$app/Contents/MacOS"
cp .build/release/UsageBar "$app/Contents/MacOS/UsageBar"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>UsageBar</string>
    <key>CFBundleIdentifier</key><string>$label</string>
    <key>CFBundleName</key><string>UsageBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$app"

cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array><string>$app/Contents/MacOS/UsageBar</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$UID" "$agent" 2>/dev/null || true
launchctl kickstart -k "gui/$UID/$label"
