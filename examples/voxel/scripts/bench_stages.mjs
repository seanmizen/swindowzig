// bench_stages.mjs: run the wasm chunk stage benchmark (stage_bench.zig).
//
// Usage, from utils/swindowzig:
//   zig build bench-stages-wasm -Doptimize=ReleaseFast
//   node examples/voxel/scripts/bench_stages.mjs zig-out/bin/stage_bench.wasm
//   bun examples/voxel/scripts/bench_stages.mjs zig-out/bin/stage_bench.wasm
//
// The script supplies the imports benchNowMs and benchLog, then calls the
// export benchRun. The benchmark prints the time for each stage and the
// three terrain hashes. The exit code is 1 if benchRun returns an error.
import { readFileSync } from 'node:fs';

const path = process.argv[2] ?? 'zig-out/bin/stage_bench.wasm';
const bytes = readFileSync(path);
let mem;
const decoder = new TextDecoder();
const imports = {
  env: {
    benchNowMs: () => performance.now(),
    benchLog: (ptr, len) =>
      console.log(decoder.decode(new Uint8Array(mem.buffer, ptr, len))),
  },
};
const { instance } = await WebAssembly.instantiate(bytes, imports);
mem = instance.exports.memory;
if (instance.exports.benchRun() !== 0) {
  console.error('benchRun returned an error');
  process.exit(1);
}
