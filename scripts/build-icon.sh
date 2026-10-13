#!/usr/bin/env bash
# Rebuilds assets/macos/Cadre.icns from an SVG master (default: the light variant).
# Needs rsvg-convert (brew install librsvg); iconutil ships with macOS.
set -euo pipefail
cd "$(dirname "$0")/.."

src="${1:-assets/macos/icon/cadre-light.svg}"
out="${2:-assets/macos/Cadre.icns}"
iconset="$(mktemp -d)/Cadre.iconset"
mkdir -p "$iconset"

for s in 16 32 128 256 512; do
    rsvg-convert -w "$s" -h "$s" "$src" -o "$iconset/icon_${s}x${s}.png"
    rsvg-convert -w "$((s * 2))" -h "$((s * 2))" "$src" -o "$iconset/icon_${s}x${s}@2x.png"
done

iconutil -c icns "$iconset" -o "$out"
echo "Wrote $out from $src"
