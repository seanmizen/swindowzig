// Window modes, cursor modes, the device pixel ratio and the clipboard in a
// real browser (REQ-PLATFORM-001, REQ-PLATFORM-002, REQ-PLATFORM-003). The
// test opens the flat2d example. Alt+Enter changes the window mode, Alt+M
// changes the cursor mode, and the text field uses the system clipboard.

import { expect, type Page, test } from '@playwright/test';

async function press(page: Page, key: string): Promise<void> {
  // A delay between the key down and the key up, so that the game sees the
  // key in a tick.
  await page.keyboard.press(key, { delay: 50 });
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
