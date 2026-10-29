// The world seed of the page URL (REQ-VOXEL-034).
//
// The loader (loader.ts) and the headless runner (headless-app.ts) use
// these functions, so the two read the seed in the same way. The query
// `?seed=12345` gives seed 12345. No `seed` parameter gives seed 0. A value
// that is not a u64 (decimal digits, at most 2^64 - 1) gives seed 0 and one
// warning.
//
// The seed crosses the wasm boundary as an i64 BigInt: a Zig `u64`
// parameter of an export is an i64 in wasm. The game exports
// `swindowzig_set_seed(seed: u64)`. The loader calls it before
// swindowzig_init, so the world and the Hello to the chunk workers (the
// GenConfig) get the seed.

export const U64_MAX = (1n << 64n) - 1n;

/** The name of the optional wasm export that takes the seed. */
export const SET_SEED_EXPORT = 'swindowzig_set_seed';

export interface SeedParse {
  seed: bigint;
  /** Null when the value is a u64. Else the text of the warning. */
  warning: string | null;
}

/**
 * Parse the text of a `seed` parameter. Null (no parameter) gives seed 0
 * with no warning. Only decimal digits are a u64: no sign, no space, no
 * prefix.
 */
export function parseSeed(value: string | null): SeedParse {
  if (value === null) return { seed: 0n, warning: null };
  if (/^[0-9]+$/.test(value)) {
    const seed = BigInt(value);
    if (seed <= U64_MAX) return { seed, warning: null };
  }
  const shown = value.length > 40 ? `${value.slice(0, 40)}...` : value;
  return {
    seed: 0n,
    warning: `seed '${shown}' is not a u64 (0 to ${U64_MAX}). The world uses seed 0.`,
  };
}

/**
 * The seed of a URL query (`location.search`, with or without the `?`).
 * Calls `warn` one time when the value is not a u64.
 */
export function seedFromQuery(
  search: string,
  warn: (message: string) => void,
): bigint {
  const params = new URLSearchParams(search);
  const { seed, warning } = parseSeed(params.get('seed'));
  if (warning) warn(warning);
  return seed;
}

/**
 * Give `seed` to the wasm before swindowzig_init. Returns false when the
 * wasm has no `swindowzig_set_seed` export (a game with no seed).
 */
export function passSeed(exports: WebAssembly.Exports, seed: bigint): boolean {
  const fn = exports[SET_SEED_EXPORT];
  if (typeof fn !== 'function') return false;
  (fn as (seed: bigint) => void)(BigInt.asIntN(64, seed));
  return true;
}
