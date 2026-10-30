#!/usr/bin/env bash
# Where: scripts/windows-deps.sh [dir]
# When: before the first `zig build native -Dtarget=x86_64-windows-gnu`
#   (`yarn voxel:windows` runs it). It is safe to run again.
# Why: the Windows build links the Windows release of SDL2 (MinGW) and of
#   wgpu-native. This script downloads them to one folder (REQ-BUILD-002):
#     <dir>/include   SDL2/, webgpu/, wgpu/
#     <dir>/lib       libSDL2.dll.a, libwgpu_native.dll.a
#     <dir>/bin       SDL2.dll, wgpu_native.dll
#   The default folder is ~/.local/windows. build.zig reads the same default,
#   and -Dwindows-deps=<dir> names another folder.
# Network access: github.com and objects.githubusercontent.com.
set -euo pipefail

sdl_version="2.32.10"
wgpu_version="v22.1.0.5" # The same release as the Linux build (scripts/cloud-setup.sh).
dir="${1:-$HOME/.local/windows}"
stamp="$dir/.versions"
want="sdl2=$sdl_version wgpu=$wgpu_version"

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
  echo "windows-deps: $dir has $want"
  exit 0
fi

command -v curl >/dev/null || { echo "windows-deps: curl is missing. Install curl." >&2; exit 1; }
command -v unzip >/dev/null || { echo "windows-deps: unzip is missing. Install unzip." >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "windows-deps: SDL2 $sdl_version (MinGW development files)"
curl -fsSL -o "$tmp/sdl.tar.gz" \
  "https://github.com/libsdl-org/SDL/releases/download/release-$sdl_version/SDL2-devel-$sdl_version-mingw.tar.gz"
mkdir -p "$tmp/sdl"
tar -xzf "$tmp/sdl.tar.gz" -C "$tmp/sdl"
sdl="$tmp/sdl/SDL2-$sdl_version/x86_64-w64-mingw32"

echo "windows-deps: wgpu-native $wgpu_version (x86_64-gnu)"
curl -fsSL -o "$tmp/wgpu.zip" \
  "https://github.com/gfx-rs/wgpu-native/releases/download/$wgpu_version/wgpu-windows-x86_64-gnu-release.zip"
mkdir -p "$tmp/wgpu"
unzip -q "$tmp/wgpu.zip" -d "$tmp/wgpu"

rm -rf "$dir"
mkdir -p "$dir/include" "$dir/lib" "$dir/bin"
cp -R "$sdl/include/SDL2" "$dir/include/"
cp "$sdl/lib/libSDL2.dll.a" "$dir/lib/"
cp "$sdl/bin/SDL2.dll" "$dir/bin/"
cp -R "$tmp/wgpu/include/webgpu" "$tmp/wgpu/include/wgpu" "$dir/include/"
cp "$tmp/wgpu/lib/libwgpu_native.dll.a" "$dir/lib/"
cp "$tmp/wgpu/lib/wgpu_native.dll" "$dir/bin/"
echo "$want" >"$stamp"
echo "windows-deps: done: $dir"
