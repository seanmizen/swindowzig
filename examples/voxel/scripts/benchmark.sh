#!/usr/bin/env bash
# =============================================================================
# benchmark.sh — Voxel demo performance benchmarking harness
# =============================================================================
#
# OVERVIEW
# --------
# Runs one or more TAS scripts under one or more engine configurations
# (setups), capturing --profile-csv timing data for each run. Runs each
# setup × TAS combination N times so statistical outliers can be averaged
# out. Produces a summary table of mean tick_ns, gen_ns, mesh_ns, and
# render_ns per setup.
#
# Designed to work like a sane games-studio profiling pipeline:
#   - Same TAS input → deterministic workload across every run
#   - Headless mode → no window / VSync / compositor interference
#   - Multiple repetitions → average away JIT warmup, thermal throttling
#   - Per-setup CSV output → keep raw data for offline analysis
#
# QUICK START
# -----------
# 1. Make sure the voxel binary is built (or pass --build to do it here):
#
#      cd utils/swindowzig
#      zig build native -Dexample=voxel
#
# 2. Run the built-in default benchmark (depth-stencil on vs off, 3 reps each
#    over the flatland_forward.tas fly-through):
#
#      ./examples/voxel/scripts/benchmark.sh
#
# 3. Override repetitions, TAS, or add your own setup flags:
#
#      ./examples/voxel/scripts/benchmark.sh \
#        --reps 5 \
#        --tas examples/voxel/tests/flatland_forward.tas \
#        --setup "baseline"            "" \
#        --setup "no-depth"            "--depth-stencil=off" \
#        --setup "no-depth-no-ao"      "--depth-stencil=off --ao=none" \
#        --setup "msaa4"               "--aa=msaa --msaa=4"
#
# USAGE
# -----
#   ./examples/voxel/scripts/benchmark.sh [OPTIONS]
#
# OPTIONS
#   --build               Build the voxel binary before benchmarking.
#   --reps N              Number of repetitions per setup × TAS combo
#                         (default: 3). More reps = quieter noise floor.
#   --tas <path>          Override the default TAS script (may be given
#                         multiple times for multi-TAS runs; each TAS is
#                         benchmarked under every setup).
#   --setup "<name>" "<flags>"
#                         Add a named setup with the given extra flags.
#                         Name must not contain spaces or pipe characters.
#                         Flags are passed directly to the voxel binary and
#                         may be empty (""). May be given multiple times.
#                         If no --setup flags are given, the built-in
#                         depth-stencil on/off comparison is used.
#   --outdir <dir>        Directory for raw CSV files (default: /tmp).
#   --world <preset>      World preset (flatland | hilly, default: flatland).
#   --help                Print this help and exit.
#
# OUTPUT
# ------
# Raw per-run CSV files are written to <outdir>/<name>_<tas_stem>_rep<N>.csv.
# After all runs complete, a summary table is printed to stdout:
#
#   SETUP              TAS           REPS  mean_tick_ns  mean_gen_ns  mean_mesh_ns  mean_render_ns
#   baseline           flatland_fwd  3     8412          1823         2011          4103
#   no-depth           flatland_fwd  3     7891          1821         2008          3601
#   ...
#
# The mean values are computed over all ticks from all repetitions of a
# given setup × TAS pair (excluding the loading phase ticks, i.e. where the
# CSV column `loading=1`).
#
# ADDING YOUR OWN SETUPS
# ----------------------
# Every voxel CLI flag is a valid setup dimension. Examples:
#
#   Depth-stencil on/off (the built-in default):
#     --setup "depth-on"   "--depth-stencil=on"
#     --setup "depth-off"  "--depth-stencil=off"
#
#   Anti-aliasing comparison:
#     --setup "aa-none"  "--aa=none"
#     --setup "aa-fxaa"  "--aa=fxaa"
#     --setup "aa-msaa4" "--aa=msaa --msaa=4"
#
#   Meshing strategy:
#     --setup "greedy"  "--meshing=greedy"
#     --setup "naive"   "--meshing=naive"
#
#   Full orthogonal matrix (creates N×M combos):
#     --tas examples/voxel/tests/flatland_forward.tas \
#     --tas examples/voxel/framespike.tas              \
#     --setup "greedy-depth-on"   "--meshing=greedy --depth-stencil=on"  \
#     --setup "greedy-depth-off"  "--meshing=greedy --depth-stencil=off" \
#     --setup "naive-depth-on"    "--meshing=naive  --depth-stencil=on"  \
#     --setup "naive-depth-off"   "--meshing=naive  --depth-stencil=off"
#
# REQUIREMENTS
# ------------
#   - zig       (to build the binary, if --build is passed)
#   - python3   (for the summary statistics at the end)
#
# Must be run from the swindowzig root (utils/swindowzig) or any subdirectory;
# the script resolves the root from its own path.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Locate swindowzig root regardless of invocation directory.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWINDOWZIG_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$SWINDOWZIG_ROOT"

BIN="./zig-out/bin/voxel"
OUTDIR="/tmp"
REPS=3
BUILD=0
WORLD="flatland"

# Parallel arrays for TAS paths and setup (name + flags).
declare -a TAS_PATHS=()
declare -a SETUP_NAMES=()
declare -a SETUP_FLAGS=()

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD=1
      shift
      ;;
    --reps)
      REPS="$2"
      shift 2
      ;;
    --tas)
      TAS_PATHS+=("$2")
      shift 2
      ;;
    --setup)
      SETUP_NAMES+=("$2")
      SETUP_FLAGS+=("$3")
      shift 3
      ;;
    --outdir)
      OUTDIR="$2"
      shift 2
      ;;
    --world)
      WORLD="$2"
      shift 2
      ;;
    --help|-h)
      # Print the header comment block (up to the first non-comment line).
      sed -n '2,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "benchmark.sh: unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# Apply defaults if caller did not specify TAS or setups.
# Use flatland_forward.tas as the default: it runs for 1400 post-loading ticks
# (10 wall-seconds of gameplay at 120 Hz) and exercises chunk generation,
# meshing, and rendering — all three are visible in the profile CSV.
if [[ ${#TAS_PATHS[@]} -eq 0 ]]; then
  TAS_PATHS=("examples/voxel/tests/flatland_forward.tas")
fi

if [[ ${#SETUP_NAMES[@]} -eq 0 ]]; then
  SETUP_NAMES=("depth-on" "depth-off")
  SETUP_FLAGS=("--depth-stencil=on" "--depth-stencil=off")
fi

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [[ $BUILD -eq 1 ]]; then
  echo "==> Building voxel..."
  zig build native -Dexample=voxel
fi

if [[ ! -x "$BIN" ]]; then
  echo "benchmark.sh: binary not found at $BIN" >&2
  echo "Run with --build to compile, or: zig build native -Dexample=voxel" >&2
  exit 1
fi

for tas_path in "${TAS_PATHS[@]}"; do
  if [[ ! -f "$tas_path" ]]; then
    echo "benchmark.sh: TAS file not found: $tas_path" >&2
    exit 1
  fi
done

mkdir -p "$OUTDIR"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo
echo "======================================================================"
echo " voxel benchmark harness"
echo "======================================================================"
echo " Binary  : $BIN"
echo " World   : $WORLD"
echo " Reps    : $REPS"
echo " TAS     : ${#TAS_PATHS[@]} script(s)"
for tp in "${TAS_PATHS[@]}"; do
  echo "           $tp"
done
echo " Setups  : ${#SETUP_NAMES[@]}"
for i in "${!SETUP_NAMES[@]}"; do
  flags="${SETUP_FLAGS[$i]}"
  if [[ -z "$flags" ]]; then
    flags="(no extra flags)"
  fi
  echo "           [${SETUP_NAMES[$i]}] $flags"
done
echo " Output  : $OUTDIR"
echo "======================================================================"
echo

# ---------------------------------------------------------------------------
# Main benchmark loop
# ---------------------------------------------------------------------------
# We collect CSV file paths keyed by "<setup_name>|<tas_stem>" for the
# summary phase.
declare -a RESULT_KEYS=()
declare -a RESULT_CSVS=()   # space-separated list of per-rep CSVs per key

for i in "${!SETUP_NAMES[@]}"; do
  setup_name="${SETUP_NAMES[$i]}"
  setup_flags="${SETUP_FLAGS[$i]}"

  for tas_path in "${TAS_PATHS[@]}"; do
    tas_stem="$(basename "$tas_path" .tas)"
    key="${setup_name}|${tas_stem}"
    RESULT_KEYS+=("$key")

    rep_csvs=()
    for rep in $(seq 1 "$REPS"); do
      csv_path="${OUTDIR}/bench_${setup_name}_${tas_stem}_rep${rep}.csv"
      rep_csvs+=("$csv_path")

      printf "  %-22s  %-30s  rep %d/%d ... " \
        "$setup_name" "$tas_stem" "$rep" "$REPS"

      # --headless + --dump-frame activates headless-offscreen GPU mode:
      # no window, but GPU renders to an offscreen texture and fires render
      # callbacks normally — so --profile-csv captures timing for every tick.
      # The frame PPM is discarded; we only keep the CSV.
      frame_path="${OUTDIR}/bench_${setup_name}_${tas_stem}_rep${rep}_frame.ppm"

      # shellcheck disable=SC2086
      "$BIN" \
        --headless \
        --world="$WORLD" \
        --tas "$tas_path" \
        --dump-frame="$frame_path" \
        --profile-csv="$csv_path" \
        $setup_flags \
        >/dev/null 2>&1

      rm -f "$frame_path"  # discard throw-away frame; only CSV matters
      printf "done  (csv: %s)\n" "$csv_path"
    done

    # Join rep CSV paths with a | so we can store them in a single array slot.
    RESULT_CSVS+=("$(IFS='|'; echo "${rep_csvs[*]}")")
  done
done

# ---------------------------------------------------------------------------
# Summary statistics
# ---------------------------------------------------------------------------
echo
echo "======================================================================"
echo " Summary"
echo "======================================================================"
printf "%-22s  %-30s  %5s  %14s  %12s  %13s  %14s\n" \
  "SETUP" "TAS" "REPS" "mean_tick_ns" "mean_gen_ns" "mean_mesh_ns" "mean_render_ns"
printf "%-22s  %-30s  %5s  %14s  %12s  %13s  %14s\n" \
  "-----" "---" "----" "------------" "-----------" "------------" "--------------"

python3 - "${RESULT_KEYS[@]}" "${RESULT_CSVS[@]}" "$REPS" "${SETUP_NAMES[@]}" "${TAS_PATHS[@]}" <<'PYEOF'
import sys, csv

args = sys.argv[1:]
n_setups = len([a for a in args if '|' in a and not a.endswith('.csv')])

# The Python receives: keys... csvs... REPS setup_names... tas_paths...
# We reconstruct: keys first, then per-key csv lists (|‐separated), then REPS.
# Layout: args = [key0, key1, ..., csv0, csv1, ..., REPS, setup0, ..., tas0, ...]
# We need to split at the right index.
# Count key entries (contain '|' and not csv suffix) — but easiest: REPS is the
# first purely numeric arg.
reps_idx = next(i for i, a in enumerate(args) if a.isdigit())
reps = int(args[reps_idx])
n_keys = reps_idx // 2  # keys and csv_lists come in pairs

keys     = args[:n_keys]
csv_lists = args[n_keys:reps_idx]

def parse_csvs(paths_str):
    """Read all CSV files in a |-separated string, return rows where loading=0."""
    rows = []
    for path in paths_str.split('|'):
        try:
            with open(path, newline='') as f:
                reader = csv.DictReader(f)
                for row in reader:
                    if row.get('loading', '1') == '0':
                        rows.append(row)
        except FileNotFoundError:
            pass
    return rows

def col_mean(rows, col):
    vals = [int(r[col]) for r in rows if col in r and r[col].strip()]
    return sum(vals) / len(vals) if vals else 0.0

for key, csv_list in zip(keys, csv_lists):
    setup_name, tas_stem = key.split('|', 1)
    rows = parse_csvs(csv_list)
    n_rows = len(rows)

    mean_tick   = col_mean(rows, 'tick_ns')
    mean_gen    = col_mean(rows, 'gen_ns')
    mean_mesh   = col_mean(rows, 'mesh_ns')
    mean_render = col_mean(rows, 'render_ns')

    print(f"  {setup_name:<22}  {tas_stem:<30}  {reps:>5}  "
          f"{mean_tick:>14.0f}  {mean_gen:>12.0f}  {mean_mesh:>13.0f}  {mean_render:>14.0f}"
          f"  ({n_rows} ticks)")
PYEOF

echo
echo "Raw CSVs are in: $OUTDIR/bench_*.csv"
echo "To analyse further:"
echo "  python3 -c \"import csv; ..."   # or your preferred tool
echo
