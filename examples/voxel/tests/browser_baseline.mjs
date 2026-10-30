// browser_baseline.mjs: the browser baseline of the voxel web build
// (REQ-VOXEL-037). browser_baseline.sh starts it. It opens the page in a
// visible Chromium with WebGPU, and measures:
//   1. The load: a trace, and the time to "World ready".
//   2. A 10 s sprint in fly mode: a trace, and the chunk time on the main
//      thread in each frame ([PIPE] main_us). The install budget is 4 ms.
//   3. 30 block edits: the frames and the time to the screen ([EDIT]).
// The page needs info logs: build it with -Dweb-log=info.
//
// Usage: node browser_baseline.mjs <url> <out dir>
import fs from 'node:fs';
import { chromium } from '@playwright/test';

const [url, out] = process.argv.slice(2);

const browser = await chromium.launch({
  headless: false,
  args: ['--enable-unsafe-webgpu', '--use-angle=metal'],
});
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
// Automation gets no pointer lock, and a refused lock pauses the game. Like
// platform.pw.ts, remove the function: the game then runs with no lock.
await page.addInitScript(() => {
  delete Element.prototype.requestPointerLock;
});
const logs = [];
page.on('console', (m) => logs.push({ t: Date.now(), text: m.text() }));
page.on('pageerror', (e) =>
  logs.push({ t: Date.now(), text: `pageerror: ${e.message}` }),
);

const waitFor = async (re, ms) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (logs.some((l) => re.test(l.text))) return true;
    await page.waitForTimeout(100);
  }
  return false;
};

// 1. Load trace.
await browser.startTracing(page, {
  path: `${out}/trace-load.json`,
  screenshots: false,
});
const t0 = Date.now();
await page.goto(url);
const ready = await waitFor(/World ready/, 60000);
const loadMs = Date.now() - t0;
await page.waitForTimeout(2000);
await browser.stopTracing();

// Frame rate: rAF intervals over 2 s.
const fps = await page.evaluate(
  () =>
    new Promise((res) => {
      const ts = [];
      const f = (t) => {
        ts.push(t);
        if (ts.length < 121) requestAnimationFrame(f);
        else res(1000 / ((ts.at(-1) - ts[0]) / (ts.length - 1)));
      };
      requestAnimationFrame(f);
    }),
);

// 2. Sprint trace: Shift + W for 10 s.
await page.mouse.move(640, 360);
await page.mouse.click(640, 360); // focus (and maybe the pointer lock)
const sprintStart = logs.length;
await browser.startTracing(page, {
  path: `${out}/trace-sprint.json`,
  screenshots: false,
});
// Fly mode (double tap on Space), then climb above the hills for 1 s.
await page.keyboard.press('Space');
await page.waitForTimeout(120);
await page.keyboard.press('Space');
await page.keyboard.down('Space');
await page.waitForTimeout(1000);
await page.keyboard.up('Space');
await page.keyboard.down('Shift');
await page.keyboard.down('KeyW');
await page.waitForTimeout(10000);
await page.keyboard.up('KeyW');
await page.keyboard.up('Shift');
await browser.stopTracing();
const sprintLogs = logs.slice(sprintStart);

// 3. Edits: look down, then break blocks.
for (let i = 0; i < 12; i++)
  await page.mouse.move(640, 360 + (i + 1) * 40, { steps: 4 });
await page.waitForTimeout(500);
const editStart = logs.length;
let mx = 640;
for (let i = 0; i < 30; i++) {
  // Turn a little: the crosshair then targets another block.
  mx += i % 2 ? -35 : 25;
  await page.mouse.move(mx, 600, { steps: 2 });
  await page.mouse.down();
  await page.mouse.up();
  await page.waitForTimeout(400);
}
await page.waitForTimeout(1000);
const editLogs = logs.slice(editStart);
await page.screenshot({ path: `${out}/after-edits.png` });
await browser.close();

const mainUs = sprintLogs
  .map((l) => /\[PIPE\] jobs=.* main_us=(\d+)/.exec(l.text))
  .filter(Boolean)
  .map((m) => Number(m[1]))
  .sort((a, b) => a - b);
const pct = (p) =>
  mainUs.length
    ? mainUs[Math.min(mainUs.length - 1, Math.floor((p / 100) * mainUs.length))]
    : null;
const edits = editLogs.map((l) => l.text).filter((t) => t.includes('[EDIT]'));
const editFrames = {};
for (const e of edits) {
  const n = /after (\d+) frame/.exec(e)?.[1];
  if (n) editFrames[n] = (editFrames[n] ?? 0) + 1;
}
const editUs = edits
  .map((e) => Number(/(\d+) us/.exec(e)?.[1]))
  .filter((v) => !Number.isNaN(v))
  .sort((a, b) => a - b);
const errors = logs
  .map((l) => l.text)
  .filter(
    (t) => /pageerror|error|validation/i.test(t) && !/favicon|404/.test(t),
  );
const result = {
  ready,
  loadMs,
  fps: Math.round(fps * 10) / 10,
  sprintPipeFrames: mainUs.length,
  mainUs: {
    p50: pct(50),
    p90: pct(90),
    p99: pct(99),
    max: mainUs.at(-1) ?? null,
  },
  editCount: edits.length,
  editFrames,
  editMs: {
    p50: editUs.length ? editUs[Math.floor(editUs.length / 2)] / 1000 : null,
    max: editUs.length ? editUs.at(-1) / 1000 : null,
  },
  errors: errors.slice(0, 10),
};
fs.writeFileSync(
  `${out}/console.txt`,
  logs.map((l) => `${l.t} ${l.text}`).join('\n'),
);
fs.writeFileSync(`${out}/result.json`, JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
