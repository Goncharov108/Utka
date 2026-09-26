#!/bin/bash
# Собирает Utka.app без Xcode.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Utka.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/utka-mark.png" "$APP/Contents/Resources/utka-mark.png"
cp "$ROOT/Resources/shot-mark.png" "$APP/Contents/Resources/shot-mark.png"
swiftc -O -target x86_64-apple-macosx13.3 \
  -framework AppKit -framework ImageIO -framework CoreGraphics \
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
# Одна и та же подпись на каждую сборку, иначе macOS забывает разрешение и режет окна.
if ! security find-certificate -c "Utka Local" >/dev/null 2>&1; then
  CERT_DIR="$(mktemp -d)"
  cat > "$CERT_DIR/cert.cnf" << 'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Utka Local
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -config "$CERT_DIR/cert.cnf" -extensions ext \
    -keyout "$CERT_DIR/utka.key" -out "$CERT_DIR/utka.crt"
  openssl pkcs12 -export -legacy \
    -inkey "$CERT_DIR/utka.key" -in "$CERT_DIR/utka.crt" \
    -out "$CERT_DIR/utka.p12" -passout pass:utka
  security import "$CERT_DIR/utka.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P utka -A -T /usr/bin/codesign
  rm -rf "$CERT_DIR"
fi
codesign --force --sign "Utka Local" --identifier dev.goncharov.utka "$APP"
echo "built $APP"
