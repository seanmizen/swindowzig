#!/usr/bin/env bash
# Sets up a Linux cloud sandbox for swindowzig work (docs/agent-batch-manual.md).
# It installs the same tools as the CI job in .github/workflows/swindowzig-check.yml:
# Zig (the version in build.zig.zon), wgpu-native, lavapipe, SDL2 and Bun,
# then the Yarn dependencies. It is safe to run again.
#
# Network access: ziglang.org, github.com, objects.githubusercontent.com,
# bun.sh and the Ubuntu apt mirrors.
set -euo pipefail

cd "$(dirname "$0")/.."

zig_version="$(sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' build.zig.zon)"
wgpu_version="v22.1.0.5"
prefix="$HOME/.local"
mkdir -p "$prefix/bin"
export PATH="$prefix/bin:$prefix/zig:$HOME/.bun/bin:$PATH"

echo "== apt: lavapipe, Vulkan tools, SDL2, unzip"
if command -v apt-get >/dev/null; then
  sudo_cmd=""
  if [ "$(id -u)" -ne 0 ]; then sudo_cmd="sudo"; fi
  $sudo_cmd apt-get update -q
  $sudo_cmd apt-get install -y -q --no-install-recommends \
    mesa-vulkan-drivers vulkan-tools libsdl2-dev unzip xz-utils curl ca-certificates
else
  echo "No apt-get. Install lavapipe, SDL2 and unzip by hand." >&2
fi

echo "== Zig $zig_version"
if ! command -v zig >/dev/null || [ "$(zig version)" != "$zig_version" ]; then
  url="https://ziglang.org/download/$zig_version/zig-x86_64-linux-$zig_version.tar.xz"
  rm -rf "$prefix/zig" && mkdir -p "$prefix/zig"
  curl -fsSL "$url" | tar -xJ -C "$prefix/zig" --strip-components=1
fi
zig version

echo "== wgpu-native $wgpu_version (build.zig links it from ~/.local/lib)"
if [ ! -f "$prefix/lib/libwgpu_native.so" ]; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/wgpu.zip" \
    "https://github.com/gfx-rs/wgpu-native/releases/download/$wgpu_version/wgpu-linux-x86_64-release.zip"
  unzip -q -o "$tmp/wgpu.zip" -d "$prefix"
  rm -rf "$tmp"
fi

echo "== Bun (a runtime for the web tests, never a package manager here)"
if ! command -v bun >/dev/null; then
  curl -fsSL https://bun.sh/install | bash
fi
bun --version

echo "== Yarn dependencies (the release in .yarn/releases)"
yarn install

echo "== Vulkan devices (lavapipe must be in the list for the native --check runs)"
vulkaninfo --summary 2>/dev/null | grep -E "deviceName|driverName" || echo "vulkaninfo found no device: skip the native --check runs"

echo
echo "Done. Add this line to the shell before you build:"
echo "  export PATH=\"$prefix/bin:$prefix/zig:\$HOME/.bun/bin:\$PATH\""
