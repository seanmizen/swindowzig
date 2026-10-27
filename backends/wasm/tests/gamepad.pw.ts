// A gamepad in a real browser (REQ-INPUT-005). The page gets a fake
// navigator.getGamepads. The loader reads it once per frame, the wasm gets
// the gamepad events, and flat2d moves its focus and its slider. The test
// reads the result from the screen-reader mirror.

import { expect, type Page, test } from '@playwright/test';

interface FakePad {
  index: number;
  id: string;
  connected: boolean;
  mapping: string;
  buttons: { pressed: boolean; value: number }[];
  axes: number[];
}

declare global {
  interface Window {
    fakePad: FakePad;
  }
}

/** Set a button of the fake gamepad (standard mapping index). */
async function setButton(page: Page, index: number, down: boolean) {
  await page.evaluate(
    ([i, d]) => {
      window.fakePad.buttons[i as number] = {
        pressed: d as boolean,
        value: d ? 1 : 0,
      };
    },
    [index, down],
  );
}

/** Press and release a button. Each state stays for some frames. */
async function tap(page: Page, index: number) {
  await setButton(page, index, true);
  await page.waitForTimeout(100);
  await setButton(page, index, false);
  await page.waitForTimeout(100);
}

const DPAD_DOWN = 13;
const SOUTH = 0;
const RIGHT_SHOULDER = 5;

test('a gamepad moves the focus and the slider of flat2d', async ({ page }) => {
  await page.addInitScript(() => {
    window.fakePad = {
      index: 0,
      id: 'fake gamepad',
      connected: true,
      mapping: 'standard',
      buttons: Array.from({ length: 17 }, () => ({ pressed: false, value: 0 })),
      axes: [0, 0, 0, 0],
    };
    Object.defineProperty(navigator, 'getGamepads', {
      value: () => [window.fakePad],
    });
  });
  const logs: string[] = [];
  page.on('console', (m) => logs.push(`${m.type()}: ${m.text()}`));
  page.on('pageerror', (e) => logs.push(`pageerror: ${e.message}`));

  await page.goto('/');
  const mirror = page.locator('#swindowzig-a11y');
  await expect(mirror)
    .toBeAttached({ timeout: 30_000 })
    .catch((err: Error) => {
      throw new Error(`${err.message}\nConsole:\n${logs.join('\n')}`);
    });
  const focus = () =>
    page.evaluate(() => document.activeElement?.textContent ?? '');
  await expect.poll(focus).toBe('Green');

  // The d-pad moves in the list, and the south button activates.
  const live = mirror.locator('[aria-live="polite"]');
  await tap(page, DPAD_DOWN);
  await expect.poll(focus).toBe('Orange');
  await tap(page, SOUTH);
  await expect(live).toHaveText('Accent: Orange');

  // The right shoulder button is Tab: Close menu, then Settings.
  await tap(page, RIGHT_SHOULDER);
  await tap(page, RIGHT_SHOULDER);
  await expect.poll(focus).toBe('Settings');
  await tap(page, SOUTH);
  const slider = mirror.getByRole('slider', { name: 'Volume' });
  await expect(slider).toHaveAttribute('aria-valuenow', '0.7');

  // The left stick to the right, past the dead zone: one step.
  await page.evaluate(() => {
    window.fakePad.axes[0] = 1;
  });
  await expect(slider).toHaveAttribute('aria-valuenow', '0.75');
  await page.evaluate(() => {
    window.fakePad.axes[0] = 0;
  });
});
