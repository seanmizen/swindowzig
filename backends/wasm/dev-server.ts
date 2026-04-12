// Simple dev server for testing WASM build with live Zig rebuilds

import { watch } from 'node:fs';
import { serve, spawn } from 'bun';

// Parse --example flag from CLI args (e.g. bun dev-server.ts --example voxel)
const exampleArg = (() => {
  const idx = process.argv.indexOf('--example');
  return idx !== -1 && process.argv[idx + 1]
    ? process.argv[idx + 1]
    : undefined;
})();

// Watch Zig source files and rebuild on change
let buildInProgress = false;
let buildQueued = false;

async function rebuildZig() {
  if (buildInProgress) {
    buildQueued = true;
    return;
  }

  buildInProgress = true;
  console.log('\n🔨 Rebuilding Zig...');

  const start = performance.now();
  const buildArgs = ['zig', 'build', 'web'];
  if (exampleArg) {
    buildArgs.push(`-Dexample=${exampleArg}`, '-Doptimize=ReleaseFast');
  }
  const proc = spawn(buildArgs, {
    cwd: process.cwd(),
    stdout: 'inherit',
    stderr: 'inherit',
  });

  const exitCode = await proc.exited;
  const elapsed = (performance.now() - start).toFixed(0);

  if (exitCode === 0) {
    console.log(`✅ Zig build complete (${elapsed}ms)`);
  } else {
    console.log(`❌ Zig build failed (exit code ${exitCode})`);
  }

  buildInProgress = false;

  if (buildQueued) {
    buildQueued = false;
    rebuildZig();
  }
}

// Watch directories for .zig file changes
const watchDirs = ['libs', 'examples'];
for (const dir of watchDirs) {
  try {
    watch(dir, { recursive: true }, (_event, filename) => {
      if (filename?.endsWith('.zig')) {
        console.log(`\n📝 Changed: ${dir}/${filename}`);
        rebuildZig();
      }
    });
    console.log(`👀 Watching ${dir}/ for .zig changes`);
  } catch (_e) {
    console.log(`⚠️  Could not watch ${dir}/ (may not exist)`);
  }
}

// Initial build
console.log('🚀 Initial Zig build...');
await rebuildZig();

const server = serve({
  port: 3020,
  async fetch(req) {
    const url = new URL(req.url);
    let path = url.pathname;

    // Default to index.html
    if (path === '/') path = '/index.html';

    // Map common paths (with and without .js extension for ES modules)
    const fileMap: Record<string, string> = {
      '/index.html': './backends/wasm/index.html',
      '/debug.html': './backends/wasm/debug.html',
      '/boot.js': './backends/wasm/boot.ts',
      '/boot': './backends/wasm/boot.ts',
      '/webgpu.js': './backends/wasm/webgpu.ts',
      '/webgpu': './backends/wasm/webgpu.ts',
      '/events.js': './backends/wasm/events.ts',
      '/events': './backends/wasm/events.ts',
      '/audio.js': './backends/wasm/audio.ts',
      '/audio': './backends/wasm/audio.ts',
      '/app.wasm': './zig-out/bin/app.wasm',
      '/zig-out/bin/app.wasm': './zig-out/bin/app.wasm',
    };

    const filePath = fileMap[path];
    if (!filePath) {
      return new Response('Not found', { status: 404 });
    }

    try {
      const file = Bun.file(filePath);
      const exists = await file.exists();
      if (!exists) {
        return new Response(`File not found: ${filePath}`, { status: 404 });
      }

      // Set appropriate content type
      const contentTypes: Record<string, string> = {
        '.html': 'text/html',
        '.js': 'application/javascript',
        '.ts': 'application/javascript',
        '.wasm': 'application/wasm',
      };

      const ext = filePath.substring(filePath.lastIndexOf('.'));
      const contentType = contentTypes[ext] || 'application/octet-stream';

      // Transpile TypeScript files
      let responseBody: BlobPart;
      if (ext === '.ts') {
        const transpiler = new Bun.Transpiler({ loader: 'ts' });
        const code = await file.text();
        responseBody = transpiler.transformSync(code);
      } else {
        responseBody = file;
      }

      return new Response(responseBody, {
        headers: {
          'Content-Type': contentType,
          'Cross-Origin-Embedder-Policy': 'require-corp',
          'Cross-Origin-Opener-Policy': 'same-origin',
        },
      });
    } catch (error) {
      console.error('Error serving file:', error);
      return new Response('Internal server error', { status: 500 });
    }
  },
});

console.log(`🚀 Dev server running at http://localhost:${server.port}`);
console.log(
  '   Open in a WebGPU-capable browser (Chrome/Edge/Firefox Nightly)',
);
