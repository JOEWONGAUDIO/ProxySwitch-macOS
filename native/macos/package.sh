#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

case "${1:-all}" in
  all) architectures=(x86_64 arm64) ;;
  x86_64|arm64) architectures=("$1") ;;
  *) printf 'Usage: %s [all|x86_64|arm64]\n' "$0" >&2; exit 2 ;;
esac

tmp="$(mktemp -d)"
mount="$tmp/mount"
mkdir "$mount"
mounted=false
cleanup() {
  if "$mounted"; then
    hdiutil detach "$mount" >/dev/null || hdiutil detach -force "$mount" >/dev/null || return
  fi
  rm -r "$tmp"
}
trap cleanup EXIT

mkdir -p dist
for architecture in "${architectures[@]}"; do
  app="build/native/macos/$architecture/Proxy Switch.app"
  [[ "$(xcrun lipo "$app/Contents/MacOS/ProxySwitch" -archs)" == "$architecture" ]]
  codesign --verify --strict "$app"
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  dmg="$PWD/dist/Proxy-Switch-$version-macOS-$architecture.dmg"

  hdiutil create -quiet -size 32m -fs HFS+ -volname "Proxy Switch $version ($architecture)" "$tmp/staging.dmg"
  hdiutil attach -quiet -nobrowse -mountpoint "$mount" "$tmp/staging.dmg"
  mounted=true
  mkdir "$mount/.background"
  cp assets/dmg/dmg_background.png "$mount/.background/dmg_background.png"
  ditto "$app" "$mount/Proxy Switch.app"
  ln -s /Applications "$mount/Applications"

  osascript - "$mount" <<'APPLESCRIPT'
on run argv
    set volumePath to (POSIX file (item 1 of argv)) as alias
    tell application "Finder"
        open volumePath
        delay 1
        set installer to container window of volumePath
        set current view of installer to icon view
        set toolbar visible of installer to false
        set statusbar visible of installer to false
        set bounds of installer to {160, 120, 880, 628}
        tell icon view options of installer
            set arrangement to not arranged
            set icon size to 100
            set text size to 13
            set background picture to file ".background:dmg_background.png" of volumePath
        end tell
        set position of item "Proxy Switch.app" of volumePath to {180, 232}
        set position of item "Applications" of volumePath to {540, 232}
        update volumePath without registering applications
        close installer
    end tell
end run
APPLESCRIPT
  test -s "$mount/.DS_Store"
  bless --folder "$mount" --openfolder "$mount"
  sync
  hdiutil detach -quiet "$mount"
  mounted=false
  hdiutil convert -quiet "$tmp/staging.dmg" -format UDZO -o "$tmp/final.dmg"
  hdiutil verify -quiet "$tmp/final.dmg"
  mv -f "$tmp/final.dmg" "$dmg"
  rm "$tmp/staging.dmg"
  printf '%s\n' "$dmg"
done
