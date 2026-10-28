#!/usr/bin/env bash
# Where: scripts/voxel-windows.sh [voxel arguments]  (`yarn voxel:windows`)
# When: in WSL2 on Windows, to run the voxel example on the GPU of the PC.
# Why: WSL has no Vulkan driver for the GPU, so a Linux build uses lavapipe
#   (the CPU). This script cross-compiles the voxel example to
#   x86_64-windows-gnu, with SDL2.dll and wgpu_native.dll next to the .exe
#   in zig-out/bin (REQ-BUILD-002). In WSL, it copies the three files to a
#   Windows folder (%TEMP%\swindowzig-voxel) and starts voxel.exe from
#   there. wgpu then uses D3D12 or Vulkan on the GPU.
# Environment: WINDOWS_DEPS=<dir> names the folder of the Windows files
#   (default ~/.local/windows). OPTIMIZE=<mode> sets -Doptimize (default
#   ReleaseFast).
set -euo pipefail

cd "$(dirname "$0")/.."

deps="${WINDOWS_DEPS:-$HOME/.local/windows}"
optimize="${OPTIMIZE:-ReleaseFast}"

./scripts/windows-deps.sh "$deps"

echo "voxel:windows: zig build native -Dexample=voxel -Dtarget=x86_64-windows-gnu -Doptimize=$optimize"
zig build native -Dexample=voxel -Dtarget=x86_64-windows-gnu -Doptimize="$optimize" -Dwindows-deps="$deps"

for f in voxel.exe SDL2.dll wgpu_native.dll; do
  if [ ! -f "zig-out/bin/$f" ]; then
    echo "voxel:windows: zig-out/bin/$f is missing after the build." >&2
    exit 1
  fi
done
echo "voxel:windows: built zig-out/bin/voxel.exe, SDL2.dll and wgpu_native.dll"

# WSL sets WSL_DISTRO_NAME, and its kernel name has "microsoft".
if [ -z "${WSL_DISTRO_NAME:-}" ] && ! grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
  echo "voxel:windows: this shell is not WSL, so the script cannot start voxel.exe."
  echo "voxel:windows: copy voxel.exe, SDL2.dll and wgpu_native.dll from zig-out/bin to a Windows PC, then start voxel.exe there."
  exit 0
fi
if ! command -v cmd.exe >/dev/null || ! command -v wslpath >/dev/null; then
  echo "voxel:windows: cmd.exe or wslpath is missing. Turn on the Windows interop of WSL, or start zig-out/bin/voxel.exe from Windows." >&2
  exit 1
fi

win_temp="$(cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')"
run_dir="$(wslpath -u "$win_temp")/swindowzig-voxel"
mkdir -p "$run_dir"
cp zig-out/bin/voxel.exe zig-out/bin/SDL2.dll zig-out/bin/wgpu_native.dll "$run_dir/"
echo "voxel:windows: starting $(wslpath -w "$run_dir")\\voxel.exe"
echo "voxel:windows: the log line \"sw_gpu: adapter\" names the GPU and the backend (d3d12 or vulkan)."
cd "$run_dir"
exec ./voxel.exe "$@"
