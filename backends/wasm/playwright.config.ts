// Playwright runs the browser tests of the web backend (tests/*.pw.ts) in
// Chromium. Run them from the repo root:
//
//   yarn test:browser
//
// Three web servers build three programs for the web and serve them with
// the dev server: flat2d on port 3023 (the other tests), justabox on port
// 3021 (the frame graph on the canvas, canvas.pw.ts), and the menu demo on
// port 3022 (menu.pw.ts). Each program has its own install prefix, so the
// builds do not write the same app.wasm. No test port is 3020, the port of
// `yarn dev`: away from CI, Playwright uses a server that already runs on
// a port, and a dev server there serves another program.

import { defineConfig } from '@playwright/test';

const flat2dPort = 3023;
const canvasPort = 3021;
const menuPort = 3022;

// WebGPU in headless Chromium. On Linux (CI) it uses the SwiftShader Vulkan
// driver of Chromium. Do not set VK_LOADER_DRIVERS_SELECT for the browser: a
// filter such as '*lvp*' hides SwiftShader, and then Chromium has no WebGPU
// adapter.
const webgpuArgs = [
  '--enable-unsafe-webgpu',
  '--enable-features=Vulkan',
  '--ignore-gpu-blocklist',
];

// --use-angle=swiftshader gives the headless shell a GL for the compositor.
// Without it, the shell gives no valid canvas texture to a WebGPU page, on
// Linux and on macOS. WebGPU then stops on the first frame ("A valid
// external Instance reference no longer exists"). The canvas stays black,
// also for a page with no swindowzig code.
const canvasArgs = [
  ...webgpuArgs,
  '--use-angle=swiftshader',
  '--enable-unsafe-swiftshader',
];

export default defineConfig({
  testDir: './tests',
  testMatch: '*.pw.ts',
  timeout: 60_000,
  retries: process.env.CI ? 1 : 0,
  // One browser at a time. SwiftShader draws each frame on the CPU, and
  // pages in parallel make the frames slow.
  workers: 1,
  reporter: process.env.CI ? 'list' : 'line',
  use: { browserName: 'chromium' },
  projects: [
    // Each test that does not name an example opens flat2d, with a working
    // canvas. On the CPU of CI, flat2d draws a few frames each second, so
    // a key press can be shorter than one frame. The input snapshot keeps
    // such a press and its modifiers (REQ-INPUT-007).
    {
      name: 'flat2d',
      testIgnore: ['canvas.pw.ts', 'menu.pw.ts'],
      use: {
        baseURL: `http://localhost:${flat2dPort}`,
        launchOptions: { args: canvasArgs },
      },
    },
    // A small window, so SwiftShader draws more frames each second.
    {
      name: 'canvas',
      testMatch: 'canvas.pw.ts',
      use: {
        baseURL: `http://localhost:${canvasPort}`,
        viewport: { width: 640, height: 360 },
        launchOptions: { args: canvasArgs },
      },
    },
    // The menu demo: its screen-reader mirror.
    {
      name: 'menu',
      testMatch: 'menu.pw.ts',
      use: {
        baseURL: `http://localhost:${menuPort}`,
        viewport: { width: 960, height: 540 },
        launchOptions: { args: canvasArgs },
      },
    },
  ],
  webServer: [
    {
      command: `zig build web -Dexample=flat2d -p zig-out/flat2d && bun backends/wasm/dev-server.ts --example flat2d --no-build --port ${flat2dPort} --out zig-out/flat2d`,
      cwd: '../..',
      port: flat2dPort,
      timeout: 300_000,
      reuseExistingServer: !process.env.CI,
    },
    {
      command: `zig build web -Dexample=justabox -p zig-out/justabox && bun backends/wasm/dev-server.ts --example justabox --no-build --port ${canvasPort} --out zig-out/justabox`,
      cwd: '../..',
      port: canvasPort,
      timeout: 300_000,
      reuseExistingServer: !process.env.CI,
    },
    {
      command: `zig build web -Ddemo=menu -Doptimize=ReleaseFast -p zig-out/menu && bun backends/wasm/dev-server.ts --demo menu --no-build --port ${menuPort} --out zig-out/menu`,
      cwd: '../..',
      port: menuPort,
      timeout: 300_000,
      reuseExistingServer: !process.env.CI,
    },
  ],
});
