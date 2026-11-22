#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

case "${1:-all}" in
  all) architectures=(x86_64 arm64) ;;
  x86_64|arm64) architectures=("$1") ;;
  *) printf 'Usage: %s [all|x86_64|arm64]\n' "$0" >&2; exit 2 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT
iconset="$tmp/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  cp "assets/icons/macos/app_icon_${size}.png" "$iconset/icon_${size}x${size}.png"
  sips -z "$((size * 2))" "$((size * 2))" assets/images/proxy_switch_logo.png \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$tmp/AppIcon.icns"

for architecture in "${architectures[@]}"; do
  app="$PWD/build/native/macos/$architecture/Proxy Switch.app"
  mkdir -p "$app/Contents/"{MacOS,Resources}
  xcrun swiftc -parse-as-library -O -target "$architecture-apple-macosx13.0" \
    native/macos/main.swift -o "$app/Contents/MacOS/ProxySwitch"
  cp native/{strings,languages}.json "$app/Contents/Resources/"
  cp assets/images/proxy_switch_logo.png "$app/Contents/Resources/logo.png"
  cp assets/tray/*Template.png "$tmp/AppIcon.icns" "$app/Contents/Resources/"
  cp native/macos/Info.plist "$app/Contents/Info.plist"
  codesign --force --sign - "$app"
  codesign --verify --strict "$app"
  [[ "$(xcrun lipo "$app/Contents/MacOS/ProxySwitch" -archs)" == "$architecture" ]]
  printf '%s\n' "$app"
done
