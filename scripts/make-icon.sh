#!/bin/bash
# scripts/make-icon.swift ile ikonu çizer ve Resources/AppIcon.icns üretir.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
EXTRA=()
if [[ -f /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap && -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]; then
    sed "s#@EMPTY@#$PWD/scripts/toolchain-fix/empty.modulemap#" scripts/toolchain-fix/overlay.yaml.in > build/overlay.yaml
    EXTRA=(-vfsoverlay build/overlay.yaml -Xcc -ivfsoverlay -Xcc build/overlay.yaml)
fi
swiftc "${EXTRA[@]}" -O scripts/make-icon.swift -o build/make-icon
build/make-icon build/icon_1024.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "✓ Resources/AppIcon.icns"
