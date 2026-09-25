#!/bin/bash
# Собирает Utka.app без Xcode.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Utka.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/utka-mark.png" "$APP/Contents/Resources/utka-mark.png"
swiftc -O -target x86_64-apple-macosx13.3 \
  -framework AppKit -framework ImageIO \
  "$ROOT"/Sources/*.swift \
  -o "$APP/Contents/MacOS/Utka"
cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Утка</string>
  <key>CFBundleDisplayName</key>
  <string>Утка</string>
  <key>CFBundleIdentifier</key>
  <string>dev.goncharov.utka</string>
  <key>CFBundleExecutable</key>
  <string>Utka</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.3</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF
echo "built $APP"
