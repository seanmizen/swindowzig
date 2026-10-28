// The JS bundles of the web backend: `yarn build:js` runs
// `rsbuild build`. RSBuild is the frontend build tool of seanorepo, and the
// consumers there (apps/action, apps/voxel.seanmizen.com) bundle the same
// files with it.
//
//   backends/wasm/boot.ts          -> zig-out/bin/boot.js
//   backends/wasm/chunk-worker.ts  -> zig-out/bin/chunk-worker.js
//
// Each bundle is one minified ES module file with a fixed name, and no
// HTML. index.html loads boot.js with <script type="module">, and the
// worker pool starts the worker with `new Worker(url, { type: 'module' })`.
// The dev server does not use these files: it transpiles each .ts file
// when the browser asks for it.

import { defineConfig } from '@rsbuild/core';

export default defineConfig({
  source: {
    entry: {
      boot: './backends/wasm/boot.ts',
      'chunk-worker': './backends/wasm/chunk-worker.ts',
    },
    tsconfigPath: './backends/wasm/tsconfig.json',
  },
  output: {
    target: 'web',
    distPath: { root: 'zig-out/bin', js: '' },
    filename: { js: '[name].js' },
    // zig-out/bin holds the wasm files of zig build.
    cleanDistPath: false,
    legalComments: 'none',
    sourceMap: false,
  },
  // The repo has no public/ directory to copy.
  server: { publicDir: false },
  performance: { chunkSplit: { strategy: 'all-in-one' } },
  tools: {
    htmlPlugin: false,
    // ES module output: one file for each entry, no runtime chunk loading.
    rspack: {
      experiments: { outputModule: true },
      output: { module: true, chunkFormat: 'module', chunkLoading: 'import' },
    },
  },
});
