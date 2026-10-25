#!/usr/bin/env node
// Print the terrain block hash of each seed from the wasm build, one
// "<seed> <hash>" line for each seed. The native tool zig-out/bin/terrain_hash
// prints the same lines, so CI compares the two outputs with diff.
//
// Runs on Node and on Bun. It has no packages and no imports from the repo.
//
//   zig build terrain-hash -Doptimize=ReleaseFast
//   node examples/voxel/scripts/terrain_hash_wasm.mjs 0 1 12345
//   bun examples/voxel/scripts/terrain_hash_wasm.mjs 0 1 12345
//
// Set TERRAIN_HASH_WASM to use a different wasm file.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const wasmPath =
  process.env.TERRAIN_HASH_WASM ??
  resolve(here, '../../../zig-out/bin/terrain_hash.wasm');

const seeds = process.argv.slice(2);
if (seeds.length === 0) {
  console.error(
    'terrain_hash_wasm: give one or more seeds, for example: 0 1 12345',
  );
  process.exit(2);
}

const U64_MAX = (1n << 64n) - 1n;

const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), {});
const blockHash = instance.exports.terrain_hash_block;

for (const arg of seeds) {
  if (!/^[0-9]+$/.test(arg) || BigInt(arg) > U64_MAX) {
    console.error(`terrain_hash_wasm: '${arg}' is not a u64 seed`);
    process.exit(2);
  }
  // A u64 crosses the wasm boundary as an i64 BigInt. Read it back unsigned.
  const hash = BigInt.asUintN(64, blockHash(BigInt.asIntN(64, BigInt(arg))));
  if (hash === 0n) {
    console.error(
      `terrain_hash_wasm: generation failed for seed ${arg} (out of memory)`,
    );
    process.exit(1);
  }
  console.log(`${arg} ${hash.toString(16).padStart(16, '0')}`);
}
