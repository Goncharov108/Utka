#!/bin/bash
# Собирает Utka.app без Xcode: универсальный бинарник и иконка утки.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Чёрный квадрат с уткой во всех размерах, которые ждёт Finder.
write_icon() {
  local src="$1"
  local dest="$2"
  local set
  set="$(mktemp -d)/Utka.iconset"
  mkdir -p "$set"
  local spec px name
  for spec in \
    "16:icon_16x16.png" \
    "32:icon_16x16@2x.png" \
    "32:icon_32x32.png" \
    "64:icon_32x32@2x.png" \
    "128:icon_128x128.png" \
    "256:icon_128x128@2x.png" \
    "256:icon_256x256.png" \
    "512:icon_256x256@2x.png" \
    "512:icon_512x512.png" \
    "1024:icon_512x512@2x.png"
  do
    px="${spec%%:*}"
    name="${spec#*:}"
    sips -z "$px" "$px" "$src" --out "$set/$name" >/dev/null
  done
  iconutil -c icns "$set" -o "$dest"
  rm -rf "$(dirname "$set")"
}
APP="$ROOT/Utka.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/utka-mark.png" "$APP/Contents/Resources/utka-mark.png"
cp "$ROOT/Resources/shot-mark.png" "$APP/Contents/Resources/shot-mark.png"
write_icon "$ROOT/Resources/utka-mark.png" "$APP/Contents/Resources/Utka.icns"

BIN_DIR="$(mktemp -d)"
trap 'rm -rf "$BIN_DIR"' EXIT
BINS=()
DRIVER_BINS=()
for arch in arm64 x86_64; do
  play="$BIN_DIR/UtkaPlay-$arch.o"
  out="$BIN_DIR/Utka-$arch"
  driver="$BIN_DIR/UtkaAudio-$arch"
  if clang -c -O2 -target "${arch}-apple-macosx13.3" \
    -I "$ROOT/AudioDriver" \
    "$ROOT/Sources/UtkaPlay.c" \
    -o "$play" \
    && swiftc -O -target "${arch}-apple-macosx13.3" \
    -import-objc-header "$ROOT/Sources/UtkaPlay.h" \
    -framework AppKit -framework AVFoundation -framework ImageIO -framework CoreGraphics -framework CoreAudio -framework AudioToolbox -framework CoreFoundation \
    "$play" \
    "$ROOT"/Sources/*.swift \
    -o "$out"
  then
    BINS+=("$out")
  else
    echo "сборка $arch пропущена" >&2
  fi
  if clang -bundle -O2 -target "${arch}-apple-macosx13.3" \
    -framework CoreAudio -framework CoreFoundation \
    -I "$ROOT/AudioDriver" \
    "$ROOT/AudioDriver/UtkaAudio.c" \
    -o "$driver"
  then
    DRIVER_BINS+=("$driver")
  else
    echo "плагин $arch пропущен" >&2
  fi
done
if [ "${#BINS[@]}" -eq 0 ]; then
  echo "не собралось ни для одной архитектуры" >&2
  exit 1
fi
if [ "${#BINS[@]}" -eq 1 ]; then
  cp "${BINS[0]}" "$APP/Contents/MacOS/Utka"
else
  lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Utka"
fi
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
  <key>NSMicrophoneUsageDescription</key>
  <string>Утка слушает свой виртуальный выход, чтобы регулировать громкость наушников. Микрофон компьютера не включается.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleIconFile</key>
  <string>Utka</string>
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

# Виртуальный выход. Его грузит системный звук из ~/Library, не из .app.
if [ "${#DRIVER_BINS[@]}" -gt 0 ]; then
  DRIVER="$BIN_DIR/UtkaAudio.driver"
  mkdir -p "$DRIVER/Contents/MacOS"
  if [ "${#DRIVER_BINS[@]}" -eq 1 ]; then
    cp "${DRIVER_BINS[0]}" "$DRIVER/Contents/MacOS/UtkaAudio"
  else
    lipo -create "${DRIVER_BINS[@]}" -output "$DRIVER/Contents/MacOS/UtkaAudio"
  fi
  cat > "$DRIVER/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Утка звук</string>
  <key>CFBundleIdentifier</key>
  <string>dev.goncharov.utka.audio</string>
  <key>CFBundleExecutable</key>
  <string>UtkaAudio</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFPlugInDynamicRegistration</key>
  <false/>
  <key>CFPlugInFactories</key>
  <dict>
    <key>8C1E5A20-4B7D-4E3A-9F16-2D8A6C0B71E4</key>
    <string>Utka_Create</string>
  </dict>
  <key>CFPlugInTypes</key>
  <dict>
    <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key>
    <array>
      <string>8C1E5A20-4B7D-4E3A-9F16-2D8A6C0B71E4</string>
    </array>
  </dict>
</dict>
</plist>
EOF
  codesign --force --sign "Utka Local" --identifier dev.goncharov.utka.audio "$DRIVER"
  HAL="/Library/Audio/Plug-Ins/HAL"
  mkdir -p "$HAL" 2>/dev/null || true
  if [ -w "$HAL" ]; then
    rm -rf "$HAL/UtkaAudio.driver"
    cp -R "$DRIVER" "$HAL/UtkaAudio.driver"
    echo "installed $HAL/UtkaAudio.driver"
  else
    echo "плагин собран, но $HAL закрыт для записи: нужен один раз пароль администратора" >&2
    osascript -e "do shell script \"mkdir -p '$HAL' && rm -rf '$HAL/UtkaAudio.driver' && cp -R '$DRIVER' '$HAL/UtkaAudio.driver' && chown -R $(id -un):staff '$HAL'\" with prompt \"Утке нужно поставить выход звука в системную папку.\" with administrator privileges"
    echo "installed $HAL/UtkaAudio.driver"
  fi
fi
echo "built $APP"
