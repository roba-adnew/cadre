# macOS icon asset

Place `Cadre.icns` in this directory to include a custom icon in the macOS
app bundle created by `scripts/bundle-macos.sh`.

The icon art lives in `icon/` (`cadre-light.svg` is the bundled one, `cadre-dark.svg`
is its dark-appearance twin). After editing an SVG, rebuild the `.icns` with
`scripts/build-icon.sh` (needs `rsvg-convert`: `brew install librsvg`).
