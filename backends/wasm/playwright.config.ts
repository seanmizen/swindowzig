// Playwright runs the browser tests of the web backend (tests/*.pw.ts) in
// Chromium. Run them from the repo root:
//
//   yarn test:a11y
//
// The web server builds the flat2d example for the web, then serves it with
// the dev server on port 3020.

import { defineConfig } from '@playwright/test';

const port = 3020;

export default defineConfig({
  testDir: './tests',
  testMatch: '*.pw.ts',
  timeout: 60_000,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? 'list' : 'line',
  use: {
    baseURL: `http://localhost:${port}`,
    browserName: 'chromium',
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
  webServer: {
    command:
      'zig build web -Dexample=flat2d && bun backends/wasm/dev-server.ts --example flat2d --no-build',
    cwd: '../..',
    port,
    timeout: 300_000,
    reuseExistingServer: !process.env.CI,
  },
});
