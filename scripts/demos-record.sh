#!/usr/bin/env bash
# demos-record.sh: record each demo in demos/ with each preset (REQ-DEMO-007).
#
# For each demo and preset, the demo writes each frame on the fixed timestep
# (--capture) into a named pipe. ffmpeg reads the pipe and writes an MP4
# file. Then ffmpeg makes an animated WebP loop from the MP4 file: a time
# lapse at a small size, not more than 4 MB, so GitHub shows it in a page.
#
# Usage (from the repo root, Linux with lavapipe or a GPU, and ffmpeg):
#   scripts/demos-record.sh                     # each demo, each preset
#   scripts/demos-record.sh --demo cow          # one demo
#   scripts/demos-record.sh --preset medium     # one preset
#   scripts/demos-record.sh --out DIR           # default: zig-out/demos
#   scripts/demos-record.sh --media             # also copy the medium WebP to docs/media/<demo>.webp
#
# Output: DIR/<demo>-<preset>.mp4 and DIR/<demo>-<preset>.webp. Do not
# commit the MP4 files: the demos-videos workflow attaches them to a release.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="zig-out/demos"
ONLY_DEMO=""
ONLY_PRESET=""
MEDIA=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --demo) ONLY_DEMO="$2"; shift 2 ;;
        --preset) ONLY_PRESET="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --media) MEDIA=1; shift ;;
        *) echo "demos-record.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

command -v ffmpeg > /dev/null || { echo "demos-record.sh: ffmpeg is not on PATH" >&2; exit 2; }

# The WebP loop: at most this size, in bytes.
WEBP_LIMIT=$((4 * 1024 * 1024))
# The time lapse: the WebP plays the video this many times faster.
WEBP_SPEED=4

mkdir -p "$OUT"

# Every folder in demos/ with a main.zig is a demo (common/ is the shared code).
DEMOS=()
for d in demos/*/; do
    name="$(basename "$d")"
    [[ -f "demos/$name/main.zig" ]] || continue
    [[ -z "$ONLY_DEMO" || "$ONLY_DEMO" == "$name" ]] || continue
    DEMOS+=("$name")
done
[[ ${#DEMOS[@]} -gt 0 ]] || { echo "demos-record.sh: no demo found" >&2; exit 2; }

PRESETS=(low medium high)
[[ -z "$ONLY_PRESET" ]] || PRESETS=("$ONLY_PRESET")

make_webp() {
    local mp4="$1" webp="$2"
    # Try smaller settings until the file is small enough.
    for opts in "480 12 60" "480 10 45" "400 10 40" "320 8 35"; do
        read -r width fps quality <<< "$opts"
        ffmpeg -hide_banner -loglevel error -y -i "$mp4" \
            -vf "setpts=PTS/${WEBP_SPEED},fps=${fps},scale=${width}:-2:flags=lanczos" \
            -an -c:v libwebp_anim -loop 0 -quality "$quality" -compression_level 6 "$webp"
        local size
        size=$(stat -c %s "$webp")
        if [[ $size -le $WEBP_LIMIT ]]; then
            echo "    webp: ${width} px, ${fps} fps, quality ${quality}: $((size / 1024)) KB"
            return 0
        fi
    done
    echo "demos-record.sh: $webp is larger than 4 MB" >&2
    return 1
}

for demo in "${DEMOS[@]}"; do
    echo "== $demo: build"
    zig build native -Ddemo="$demo" -Doptimize=ReleaseFast
    for preset in "${PRESETS[@]}"; do
        run="$OUT/$demo-$preset"
        echo "== $demo $preset: record"
        rm -rf "$run"
        mkdir -p "$run"
        mkfifo "$run/frames.bgra"
        "./zig-out/bin/$demo" --preset "$preset" --capture "$run" > "$run/demo.log" 2>&1 &
        pid=$!
        # The demo writes info.txt (width, height, frames each second)
        # before it opens the pipe.
        for _ in $(seq 1 600); do
            [[ -s "$run/info.txt" ]] && break
            kill -0 "$pid" 2> /dev/null || break
            sleep 0.1
        done
        if [[ ! -s "$run/info.txt" ]]; then
            echo "demos-record.sh: $demo did not start. See $run/demo.log" >&2
            tail -n 20 "$run/demo.log" >&2
            exit 1
        fi
        read -r w h fps < "$run/info.txt"
        ffmpeg -hide_banner -loglevel error -y \
            -f rawvideo -pix_fmt bgra -s "${w}x${h}" -r "$fps" -i "$run/frames.bgra" \
            -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart \
            "$OUT/$demo-$preset.mp4"
        wait "$pid" || { echo "demos-record.sh: $demo exited with an error. See $run/demo.log" >&2; exit 1; }
        echo "    mp4: $OUT/$demo-$preset.mp4 ($(( $(stat -c %s "$OUT/$demo-$preset.mp4") / 1024 )) KB)"
        make_webp "$OUT/$demo-$preset.mp4" "$OUT/$demo-$preset.webp"
        rm -f "$run/frames.bgra"
        if [[ $MEDIA -eq 1 && "$preset" == medium ]]; then
            mkdir -p docs/media
            cp "$OUT/$demo-$preset.webp" "docs/media/$demo.webp"
            echo "    copied to docs/media/$demo.webp"
        fi
    done
done
echo "== done: $OUT"
