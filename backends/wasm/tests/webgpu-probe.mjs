// TEMPORARY CI probe: which Chromium flags give a WebGPU adapter on the runner.
import http from 'node:http';
import { chromium } from '@playwright/test';

const server = http
  .createServer((_req, res) => {
    res.setHeader('content-type', 'text/html');
    res.end('<html><body>probe</body></html>');
  })
  .listen(4567);

const base = ['--enable-unsafe-webgpu', '--ignore-gpu-blocklist'];
const sets = {
  current: [...base, '--enable-features=Vulkan'],
  sw_adapter: [
    ...base,
    '--use-webgpu-adapter=swiftshader',
    '--enable-unsafe-swiftshader',
  ],
  sw_vulkan: [
    ...base,
    '--enable-features=Vulkan',
    '--use-vulkan=swiftshader',
    '--use-webgpu-adapter=swiftshader',
    '--enable-unsafe-swiftshader',
  ],
  sw_all: [
    ...base,
    '--enable-features=Vulkan',
    '--use-vulkan=swiftshader',
    '--use-angle=swiftshader',
    '--use-gl=angle',
    '--enable-unsafe-swiftshader',
    '--disable-vulkan-fallback-to-gl-for-testing',
  ],
  angle_vk: [
    ...base,
    '--enable-features=Vulkan,VulkanFromANGLE,DefaultANGLEVulkan',
    '--use-angle=vulkan',
  ],
  native_vk: [
    ...base,
    '--enable-features=Vulkan',
    '--use-vulkan=native',
    '--disable-vulkan-surface',
  ],
};

const lvp = process.env.VK_LOADER_DRIVERS_SELECT;
const envs = {
  lvp: { ...process.env, VK_LOADER_DRIVERS_SELECT: lvp ?? '*lvp*' },
  noselect: Object.fromEntries(
    Object.entries(process.env).filter(
      ([k]) => k !== 'VK_LOADER_DRIVERS_SELECT',
    ),
  ),
};

async function probe(page, options) {
  return page.evaluate(async (opts) => {
    if (!navigator.gpu) return 'no navigator.gpu';
    const timeout = new Promise((r) => setTimeout(() => r('timeout'), 15000));
    const work = (async () => {
      const a = await navigator.gpu.requestAdapter(opts);
      if (!a) return 'no adapter';
      const info = a.info ?? {};
      const d = await a.requestDevice().catch(() => null);
      return `ADAPTER ${info.vendor}/${info.architecture}/${info.description} fallback=${a.isFallbackAdapter ?? info.isFallbackAdapter} device=${!!d}`;
    })();
    return Promise.race([work, timeout]);
  }, options);
}

for (const channel of [undefined, 'chromium']) {
  for (const [envName, env] of Object.entries(envs)) {
    for (const [name, args] of Object.entries(sets)) {
      let result;
      try {
        const browser = await chromium.launch({
          channel,
          args,
          env,
          timeout: 30000,
        });
        const page = await browser.newPage();
        await page.goto('http://localhost:4567/');
        const plain = await probe(page, undefined);
        const fallback = await probe(page, { forceFallbackAdapter: true });
        result = `default: ${plain} | fallback: ${fallback}`;
        await browser.close();
      } catch (e) {
        result = `launch error: ${String(e).slice(0, 300)}`;
      }
      console.log(`PROBE ${channel ?? 'shell'} ${envName} ${name}: ${result}`);
    }
  }
}
server.close();
