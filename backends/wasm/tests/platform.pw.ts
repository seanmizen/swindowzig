// Window modes, cursor modes, the device pixel ratio and the clipboard in a
// real browser (REQ-PLATFORM-001, REQ-PLATFORM-002, REQ-PLATFORM-003). The
// test opens the flat2d example. Alt+Enter changes the window mode, Alt+M
// changes the cursor mode, and the text field uses the system clipboard.

import { expect, type Page, test } from '@playwright/test';

/**
 * Wait for `n` animation frames. The loader runs one game frame in each
 * animation frame, so the game gets the events from before the wait.
 */
async function frames(page: Page, n = 3): Promise<void> {
  await page.evaluate(
    (count) =>
      new Promise<void>((resolve) => {
        let left = count;
        const step = () => {
          left -= 1;
          if (left <= 0) resolve();
          else requestAnimationFrame(step);
        };
        requestAnimationFrame(step);
      }),
    n,
  );
}

async function press(page: Page, key: string): Promise<void> {
  // The game keeps a press that is shorter than one tick (REQ-INPUT-007).
  // Two presses of one key in one tick are one press, so the test waits
  // for game frames after each press. SwiftShader draws a few frames each
  // second, and a fixed delay is not sufficient.
  await page.keyboard.press(key);
  await frames(page);
}

/** Open flat2d, and wait for its UI. Returns the page errors. */
async function openFlat2d(page: Page): Promise<string[]> {
  const errors: string[] = [];
  const logs: string[] = [];
  page.on('console', (m) => logs.push(`${m.type()}: ${m.text()}`));
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto('/');
  await expect(page.locator('#swindowzig-a11y'))
    .toBeAttached({ timeout: 30_000 })
    .catch((err: Error) => {
      throw new Error(`${err.message}\nConsole:\n${logs.join('\n')}`);
    });
  return errors;
}

/** The accessible name of the focused node of the mirror. */
async function focusedName(page: Page): Promise<string | null> {
  return page.evaluate(() => {
    const el = document.activeElement;
    if (!el?.closest('#swindowzig-a11y')) return null;
    return el.getAttribute('aria-label') ?? el.textContent;
  });
}

test('the text field copies to the system clipboard and pastes from it', async ({
  page,
  context,
}) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  const errors = await openFlat2d(page);
  const field = page
    .locator('#swindowzig-a11y')
    .getByRole('textbox', { name: 'Name' });

  // The focus starts on the first list item. Tab three times to the field.
  for (let i = 0; i < 3; i++) await press(page, 'Tab');
  await page.keyboard.type('hello', { delay: 30 });
  await frames(page);
  await expect(field).toHaveValue('hello');

  // Copy: the system clipboard gets the text (REQ-PLATFORM-002).
  await press(page, 'ControlOrMeta+A');
  await press(page, 'ControlOrMeta+C');
  await expect
    .poll(() => page.evaluate(() => navigator.clipboard.readText()))
    .toBe('hello');

  // Another program puts text on the clipboard. Paste replaces the
  // selection with it, one time only.
  await page.evaluate(() => navigator.clipboard.writeText('from outside'));
  await press(page, 'ControlOrMeta+V');
  await expect(field).toHaveValue('from outside');
  await page.waitForTimeout(200);
  await expect(field).toHaveValue('from outside');
  expect(errors).toEqual([]);
});

test('a browser with no pointer lock does not stop the game', async ({
  page,
}) => {
  // iOS Safari has no requestPointerLock (REQ-PLATFORM-001).
  await page.addInitScript(() => {
    // biome-ignore lint/suspicious/noExplicitAny: remove a DOM function.
    delete (Element.prototype as any).requestPointerLock;
  });
  const errors = await openFlat2d(page);

  // Alt+M two times: normal, hidden, locked.
  await press(page, 'Alt+M');
  await expect
    .poll(() =>
      page.evaluate(() => document.querySelector('canvas')?.style.cursor),
    )
    .toBe('none');
  await press(page, 'Alt+M');
  await page.waitForTimeout(200);
  // The game still runs: the focus moves on Tab.
  await press(page, 'Tab');
  await expect.poll(() => focusedName(page)).toBe('Close menu');
  // Back to normal: the cursor shows again.
  await press(page, 'Alt+M');
  await expect
    .poll(() =>
      page.evaluate(() => document.querySelector('canvas')?.style.cursor),
    )
    .not.toBe('none');
  expect(errors).toEqual([]);
});

test('a game goes to full screen and back', async ({ page }) => {
  const errors = await openFlat2d(page);
  const fullscreen = () =>
    page.evaluate(() => document.fullscreenElement !== null);
  await press(page, 'Alt+Enter');
  await expect.poll(fullscreen).toBe(true);
  await press(page, 'Alt+Enter');
  await expect.poll(fullscreen).toBe(false);
  expect(errors).toEqual([]);
});

test('the canvas follows the device pixel ratio', async ({ page }) => {
  const errors = await openFlat2d(page);
  const size = () =>
    page.evaluate(() => {
      const c = document.querySelector('canvas');
      return {
        ratio: window.devicePixelRatio,
        width: c?.width ?? 0,
        css: window.innerWidth,
      };
    });
  const before = await size();
  expect(before.width).toBe(Math.floor(before.css * before.ratio));

  // A move to a monitor with a ratio of 2 (REQ-PLATFORM-003).
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Emulation.setDeviceMetricsOverride', {
    width: before.css,
    height: await page.evaluate(() => window.innerHeight),
    deviceScaleFactor: 2,
    mobile: false,
  });
  await expect.poll(async () => (await size()).width).toBe(before.css * 2);
  expect(errors).toEqual([]);
});

test('flat2d draws frames on a working canvas', async ({ page }) => {
  // Count the canvas textures that the page gets: one for each frame. In
  // the headless shell with no GL for the compositor, WebGPU stops on the
  // first frame, and the count stays at 1 or 0.
  await page.addInitScript(() => {
    const hooks = window as unknown as { swCanvasFrames: number };
    hooks.swCanvasFrames = 0;
    let current: GPUTexture | null = null;
    const get = GPUCanvasContext.prototype.getCurrentTexture;
    GPUCanvasContext.prototype.getCurrentTexture = function () {
      const t = get.call(this);
      if (t !== current) hooks.swCanvasFrames++;
      current = t;
      return t;
    };
  });
  const gpuErrors: string[] = [];
  page.on('console', (m) => {
    if (m.type() === 'error' && /webgpu|GPU/i.test(m.text()))
      gpuErrors.push(m.text());
  });
  const errors = await openFlat2d(page);
  const count = () =>
    page.evaluate(
      () => (window as unknown as { swCanvasFrames: number }).swCanvasFrames,
    );
  await expect.poll(count, { timeout: 15_000 }).toBeGreaterThan(5);
  expect(gpuErrors).toEqual([]);
  expect(errors).toEqual([]);
});
