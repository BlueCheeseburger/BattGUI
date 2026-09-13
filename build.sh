#!/bin/bash
# Rebuilds BattGUI.app and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=/Applications/BattGUI.app

# -target is required: without it swiftc stamps a deployment target newer than
# the running OS, and LaunchServices refuses to launch the app (-10825), showing
# a prohibitory badge over the icon instead.
echo "Compiling..."
swiftc -O -parse-as-library -target arm64-apple-macos14.0 main.swift -o BattGUI_bin

echo "Generating icons..."
swiftc -O -target arm64-apple-macos14.0 icon_gen.swift -o icon_gen_bin
rm -rf AppIcon.iconset AppIcon-Dark.iconset
./icon_gen_bin .
iconutil -c icns AppIcon.iconset -o AppIcon.icns
iconutil -c icns AppIcon-Dark.iconset -o AppIcon-Dark.icns

echo "Assembling bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv BattGUI_bin "$APP/Contents/MacOS/BattGUI"
chmod +x "$APP/Contents/MacOS/BattGUI"
cp AppIcon.icns AppIcon-Dark.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>BattGUI</string>
    <key>CFBundleDisplayName</key>
    <string>BattGUI</string>
    <key>CFBundleIdentifier</key>
    <string>local.battgui</string>
    <key>CFBundleVersion</key>
    <string>1.1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>BattGUI</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# IMPORTANT: must sign AFTER adding Info.plist/icon, or Gatekeeper sees a
# signature that doesn't match the bundle contents and shows a "damaged app"
# no-entry badge instead of the real icon.
echo "Signing..."
codesign --force --deep --sign - "$APP"

echo "Registering with Launch Services..."
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "Done: $APP"
