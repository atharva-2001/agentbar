#!/bin/sh
# ./build.sh        build AgentBar.app
# ./build.sh test   run the parser self-check
set -e
cd "$(dirname "$0")"
mkdir -p AgentBar.app/Contents/MacOS
swiftc -O -parse-as-library AgentBar.swift -o AgentBar.app/Contents/MacOS/AgentBar
cat > AgentBar.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentBar</string>
<key>CFBundleIdentifier</key><string>local.atharva.agentbar</string>
<key>CFBundleName</key><string>AgentBar</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
[ "$1" = test ] && AgentBar.app/Contents/MacOS/AgentBar --selftest
exit 0
