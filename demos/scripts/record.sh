#!/usr/bin/env bash
# record.sh: make the videos of the demos from their TAS scripts
# (`yarn demos:record`).
#
# Each demo plays its TAS script with no window for each preset, and writes
# each second tick as a frame (30 frames each second). ffmpeg makes an MP4
# file of the full run. A short loop of the run becomes an animated WebP
# file: ffmpeg with libwebp, or img2webp (the webp tools). The same command
# makes the same frames again (REQ-DEMO-002).
#
# Usage (from the repo root):
#   demos/scripts/record.sh                  # every demo, every preset
#   demos/scripts/record.sh --demo cow --preset medium
#   demos/scripts/record.sh --readme         # also copy the medium WebP
#                                            # files to docs/media/
#   demos/scripts/record.sh --out DIR        # default: zig-out/demo-media
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

DEMOS=(cow shooter menu)
PRESETS=(low medium high)
OUT="zig-out/demo-media"
README=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --demo) DEMOS=("$2"); shift 2 ;;
        --preset) PRESETS=("$2"); shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --readme) README=1; shift ;;
        *) echo "record.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

command -v ffmpeg > /dev/null || { echo "record.sh: ffmpeg is not installed" >&2; exit 2; }
WEBP_FFMPEG=0
if ffmpeg -hide_banner -encoders 2> /dev/null | grep -q libwebp; then
    WEBP_FFMPEG=1
elif ! command -v img2webp > /dev/null; then
    echo "record.sh: no WebP encoder: install ffmpeg with libwebp, or the webp tools (img2webp)" >&2
    exit 2
fi

mkdir -p "$OUT"
FRAMES="$(mktemp -d -t demo-frames.XXXXXX)"
trap 'rm -rf "$FRAMES"' EXIT

# The loop of each demo in the WebP file: the start second and the length.
loop_of() {
    case "$1" in
        cow) echo "5 9" ;;
        shooter) echo "11 8" ;;
        menu) echo "2 9" ;;
    esac
}

for demo in "${DEMOS[@]}"; do
    echo "[build] $demo"
    zig build native -Ddemo="$demo" -Doptimize=ReleaseFast
    for preset in "${PRESETS[@]}"; do
        dir="$FRAMES/$demo-$preset"
        rm -rf "$dir"
        echo "[run]   $demo $preset"
        ./zig-out/bin/"$demo" --tas "demos/$demo/$demo.tas" --preset "$preset" --capture "$dir" --capture-every 2 > "$FRAMES/$demo-$preset.log" 2>&1
        mp4="$OUT/$demo-$preset.mp4"
        ffmpeg -loglevel error -y -framerate 30 -i "$dir/frame_%05d.ppm" \
            -c:v libx264 -pix_fmt yuv420p -crf 30 -preset slow -movflags +faststart "$mp4"
        read -r start length <<< "$(loop_of "$demo")"
        webp="$OUT/$demo-$preset.webp"
        if [[ $WEBP_FFMPEG -eq 1 ]]; then
            ffmpeg -loglevel error -y -ss "$start" -t "$length" -i "$mp4" \
                -vf "fps=12,scale=480:-2:flags=lanczos" -c:v libwebp -lossless 0 -q:v 55 -loop 0 "$webp"
        else
            small="$dir/small"
            mkdir -p "$small"
            ffmpeg -loglevel error -y -ss "$start" -t "$length" -i "$mp4" \
                -vf "fps=12,scale=480:-2:flags=lanczos" "$small/f_%04d.png"
            img2webp -loop 0 -lossy -q 55 -m 6 -d 83 "$small"/f_*.png -o "$webp" > /dev/null
        fi
        rm -rf "$dir"
        echo "        $mp4 ($(du -h "$mp4" | cut -f1)), $webp ($(du -h "$webp" | cut -f1))"
        if [[ $README -eq 1 && "$preset" == medium ]]; then
            mkdir -p docs/media
            cp "$webp" "docs/media/$demo.webp"
        fi
    done
done
