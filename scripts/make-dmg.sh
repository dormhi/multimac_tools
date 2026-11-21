#!/bin/bash
# Kurulum DMG'si: uygulamayı derler, yanına /Applications kısayolu koyar ve sıkıştırılmış bir disk görüntüsü üretir.
#   ./scripts/make-dmg.sh   → build/MultiMac-<sürüm>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
STAGE="build/dmg.noindex"
OUT="build/MultiMac-$VERSION.dmg"

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
ditto build/app.noindex/MultiMac.app "$STAGE/MultiMac.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "MultiMac $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
codesign --force --sign "${SIGN_IDENTITY:--}" "$OUT"
rm -rf "$STAGE"

echo "✓ $OUT"
shasum -a 256 "$OUT"
