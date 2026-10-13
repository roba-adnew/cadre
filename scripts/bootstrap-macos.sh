#!/usr/bin/env bash
# One-shot host setup for building Cadre natively on a fresh Mac.
# Installs: Xcode CLT, Homebrew deps (SDL3/SDL3_ttf/tmux), pinned Zig, and
# checks the macOS 15.4 SDK the Zig 0.15.2 link workaround needs.
#
#   ./scripts/bootstrap-macos.sh            # set up THIS (new) machine, then build
#   ./scripts/bootstrap-macos.sh --pack-sdk # on your OLD machine: tar the 15.4 SDK to carry over
#
# Idempotent: every step is skipped if already satisfied.
set -euo pipefail

ZIG_VERSION="0.15.2"   # keep in sync with build.zig.zon minimum_zig_version
SDK_15_4="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
SDK_TARBALL="$HOME/cadre-MacOSX15.4.sdk.tar.gz"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --- --pack-sdk: run on the OLD machine to carry the SDK to the new one -------
if [[ "${1:-}" == "--pack-sdk" ]]; then
    [[ -d "$SDK_15_4" ]] || { echo "no $SDK_15_4 here to pack" >&2; exit 1; }
    say "Packing 15.4 SDK -> $SDK_TARBALL (copy this to the new machine)"
    tar -C "$(dirname "$SDK_15_4")" -czf "$SDK_TARBALL" "$(basename "$SDK_15_4")"
    echo "Done. On the new machine: sudo tar -C $(dirname "$SDK_15_4") -xzf <copied tarball>"
    exit 0
fi

# --- 1. Full Xcode (not just CLT) --------------------------------------------
# ghostty's build constructs its iOS xcframework graph on any macOS build, so it
# needs the iPhoneOS SDK — which ONLY ships with full Xcode.app, never with the
# Command Line Tools. Check the SDK directly; `xcode-select -p` passes on CLT.
if ! xcode-select -p >/dev/null 2>&1; then
    say "Installing Xcode Command Line Tools (finish the GUI prompt, then re-run)"
    xcode-select --install || true
    exit 1
fi
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    # Repoint at Xcode.app if it's installed but xcode-select still targets CLT.
    if [[ -d /Applications/Xcode.app ]]; then
        say "Pointing xcode-select at Xcode.app (needs sudo)"
        sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
        sudo xcodebuild -license accept
    else
        say "MISSING: full Xcode.app (no iPhoneOS SDK)"
        cat >&2 <<'EOF'
The ghostty dependency needs the iOS SDK, which only comes with full Xcode.app
(the Command Line Tools are not enough). Install Xcode from the App Store
(search "Xcode", ~15GB), then re-run this script:
    https://apps.apple.com/app/xcode/id497799835
EOF
        exit 1
    fi
fi

# --- 2. Homebrew + libs ------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    say "Installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
say "Installing SDL3 / SDL3_ttf / tmux"
brew install sdl3 sdl3_ttf tmux

# --- 3. Pinned Zig -----------------------------------------------------------
if [[ "$(zig version 2>/dev/null || true)" == "$ZIG_VERSION" ]]; then
    say "Zig $ZIG_VERSION already on PATH"
else
    arch="$(uname -m)"; [[ "$arch" == "arm64" ]] && arch="aarch64"
    dest="$HOME/.local/zig-$ZIG_VERSION"
    url="https://ziglang.org/download/$ZIG_VERSION/zig-$arch-macos-$ZIG_VERSION.tar.xz"
    say "Installing Zig $ZIG_VERSION -> $dest"
    mkdir -p "$dest"
    curl -fL "$url" | tar -xJ -C "$dest" --strip-components=1
    # /usr/local/bin is on PATH by default; needs sudo only if not writable.
    if [[ -w /usr/local/bin ]]; then ln -sfn "$dest/zig" /usr/local/bin/zig
    else sudo ln -sfn "$dest/zig" /usr/local/bin/zig; fi
    zig version
fi

# --- 4. The 15.4 SDK (the one thing brew can't give you) ---------------------
if [[ ! -d "$SDK_15_4" ]]; then
    if [[ -f "$SDK_TARBALL" ]]; then
        say "Unpacking carried-over 15.4 SDK into place"
        sudo tar -C "$(dirname "$SDK_15_4")" -xzf "$SDK_TARBALL"
    else
        say "MISSING: $SDK_15_4"
        cat >&2 <<EOF
Zig $ZIG_VERSION can't link the newer arm64e-only SDK, so the build needs the
15.4 SDK present. Fastest fix — on your OTHER Mac run:
    ./scripts/bootstrap-macos.sh --pack-sdk
copy ~/cadre-MacOSX15.4.sdk.tar.gz here, drop it at $SDK_TARBALL, and re-run this.
EOF
        exit 1
    fi
fi

# --- 5. Build ----------------------------------------------------------------
say "Building Cadre"
ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/dev-build-env.sh
source "$ROOT/scripts/dev-build-env.sh"
zig build

say "Done. Install as the daily app with: ./scripts/dev-reload.sh"
