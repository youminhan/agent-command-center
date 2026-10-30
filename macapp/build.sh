#!/bin/bash
# Builds "Agent Command Center.app" and shareable packages in dist/.
#   ./build.sh            build + package (dist/AgentCommandCenter.zip, .dmg)
#   ./build.sh --install  also install into /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
VERSION="1.1.0"
NAME="Agent Command Center"
APP="build/$NAME.app"

rm -rf build dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

# Universal binary: Apple Silicon + Intel, macOS 13+.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" main.swift logo.swift \
    -o "build/ACC-$arch" -framework Cocoa -framework WebKit -framework ServiceManagement
done
lipo -create build/ACC-arm64 build/ACC-x86_64 -output "$APP/Contents/MacOS/AgentCommandCenter"

swiftc -O -parse-as-library icon.swift logo.swift -o build/icon -framework Cocoa
build/icon build/AppIcon.iconset "$ROOT/assets/logo.png"
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/app.py" "$ROOT/ui.html" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.agentcommandcenter.app</string>
  <key>CFBundleExecutable</key><string>AgentCommandCenter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>Manage local tmux and Copilot sessions</string>
  <key>NSAppleEventsUsageDescription</key><string>Opens iTerm or Terminal to attach to your tmux sessions.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
EOF
codesign --force --deep -s - "$APP"

# Shareable packages: a zip, and a dmg with the app, an Applications link and Install.command.
ditto -c -k --keepParent "$APP" "dist/AgentCommandCenter.zip"
STAGE=build/dmg && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/" && cp install.sh "$STAGE/Install.command" && ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "dist/AgentCommandCenter.dmg"
echo "Built $APP"
echo "Packages: $(ls dist | tr '\n' ' ')"

if [[ "${1:-}" == "--install" ]]; then
  ./install.sh "$APP"
fi
# Don't leave a second copy of the app around for Launch Services to open instead.
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$APP" "$STAGE/$NAME.app" 2>/dev/null || true
rm -rf build
