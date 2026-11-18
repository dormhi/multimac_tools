#!/bin/bash
# MultiMac'i Xcode ve SwiftPM olmadan, doğrudan swiftc ile derleyip .app paketi oluşturur.
#   ./scripts/build.sh            → build/app.noindex/MultiMac.app
#   ./scripts/build.sh --install  → ayrıca /Applications'a kopyalar ve başlatır
#   DEBUG=1 ./scripts/build.sh    → optimizasyonsuz, hızlı derleme
set -euo pipefail
cd "$(dirname "$0")/.."

# ".noindex" klasörü Spotlight'ın bu kopyayı bulup ikinci bir "MultiMac" olarak kaydetmesini engeller.
APP="build/app.noindex/MultiMac.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
OPT="-O"
[[ "${DEBUG:-}" == "1" ]] && OPT="-Onone -g"

mkdir -p build
SOURCES=$(find Sources -name '*.swift' | sort)

# Bozuk CLT geçici çözümü: eski CLT'den kalan module.modulemap, yenisindeki bridging.modulemap ile
# çakışıyor ("redefinition of module 'SwiftBridging'"). Varsa VFS overlay ile gizle.
# Kalıcı çözüm: sudo rm /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
EXTRA=()
STALE=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ -f "$STALE" && -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]; then
    sed "s#@EMPTY@#$PWD/scripts/toolchain-fix/empty.modulemap#" scripts/toolchain-fix/overlay.yaml.in > build/overlay.yaml
    EXTRA=(-vfsoverlay build/overlay.yaml -Xcc -ivfsoverlay -Xcc build/overlay.yaml)
    echo "! Bozuk CLT tespit edildi, overlay ile derleniyor"
fi

# shellcheck disable=SC2086
swiftc $OPT ${EXTRA[@]+"${EXTRA[@]}"} -parse-as-library -swift-version 5 \
    -target arm64-apple-macos15.0 \
    -module-name MultiMac \
    -o build/MultiMac.bin \
    $SOURCES

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv build/MultiMac.bin "$APP/Contents/MacOS/MultiMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sabit bir imza kimliği varsa onu kullan (Tam Disk Erişimi gibi izinler derlemeler arasında korunur), yoksa ad-hoc.
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$APP"
echo "✓ $APP hazır"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x MultiMac 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/MultiMac.app
    ditto "$APP" /Applications/MultiMac.app
    # Build kopyasını LaunchServices'ten çıkar: Spotlight / "Birlikte Aç" yalnızca kurulu olanı görsün.
    "$LSREGISTER" -u "$APP" 2>/dev/null || true
    open /Applications/MultiMac.app
    echo "✓ /Applications/MultiMac.app kuruldu ve başlatıldı"
fi
