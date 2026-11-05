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
# Reload rather than kickstart: launchd pins a loaded job to the cdhash of the
# binary it first saw, so after a rebuild a kickstart dies with "Launch
# Constraint Violation" (macOS 27). A fresh bootstrap records the new hash.
launchctl bootout "gui/$UID/$label" 2>/dev/null || true
# bootout returns before the job is gone; bootstrapping too early fails with error 5.
for _ in $(seq 50); do launchctl print "gui/$UID/$label" >/dev/null 2>&1 || break; sleep 0.1; done
launchctl bootstrap "gui/$UID" "$agent"
