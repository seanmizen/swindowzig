// Playwright runs the browser tests of the web backend (tests/*.pw.ts) in
// Chromium. Run them from the repo root:
//
//   yarn test:browser
//
// Two web servers build two examples for the web and serve them with the
// dev server: flat2d on port 3020 (the screen-reader mirror) and justabox
// on port 3021 (the frame graph on the canvas). Each example has its own
// install prefix, so the two builds do not write the same app.wasm.

import { defineConfig } from '@playwright/test';

const a11yPort = 3020;
const canvasPort = 3021;

// The headless shell of Chromium on macOS has no GPU. Its SwiftShader
// adapter cannot give a canvas texture. A WebGPU canvas then stays black on
// each page, also on a page with no swindowzig code. On macOS, use the full
// Chromium (new headless mode) with Metal. On Linux (CI), the headless shell
// uses the SwiftShader Vulkan driver.
const channel = process.platform === 'darwin' ? 'chromium' : undefined;

export default defineConfig({
  testDir: './tests',
  testMatch: '*.pw.ts',
  timeout: 60_000,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? 'list' : 'line',
  use: {
    browserName: 'chromium',
    channel,
    launchOptions: {
      // WebGPU in headless Chromium. On Linux (CI) it uses the SwiftShader
      // Vulkan driver of Chromium. Do not set VK_LOADER_DRIVERS_SELECT for
      // the browser: a filter such as '*lvp*' hides SwiftShader, and then
      // Chromium has no WebGPU adapter.
      args: [
        '--enable-unsafe-webgpu',
        '--enable-features=Vulkan',
        '--ignore-gpu-blocklist',
      ],
    },
  },
  projects: [
    {
      name: 'a11y',
      testMatch: 'a11y.pw.ts',
      use: { baseURL: `http://localhost:${a11yPort}` },
    },
    {
      name: 'canvas',
      testMatch: 'canvas.pw.ts',
      use: { baseURL: `http://localhost:${canvasPort}` },
    },
  ],
  webServer: [
    {
      command:
        'zig build web -Dexample=flat2d && bun backends/wasm/dev-server.ts --example flat2d --no-build',
      cwd: '../..',
      port: a11yPort,
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
  ],
});
