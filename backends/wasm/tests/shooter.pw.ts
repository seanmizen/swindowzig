// The screen-reader mirror of the pause menu of the shooter demo
// (REQ-A11Y-001, REQ-DEMO-027). Escape takes control from the script
// (REQ-DEMO-010) and pauses the fight. The test reads the menu from the
// mirror and from the Chromium accessibility tree.

import { type CDPSession, expect, type Page, test } from '@playwright/test';

interface AXValue {
  value?: unknown;
}
interface AXNode {
  ignored: boolean;
  role?: AXValue;
  name?: AXValue;
  properties?: { name: string; value: AXValue }[];
}

/** The role and the accessible name of the focused node, as "role: name". */
async function focusedNode(cdp: CDPSession): Promise<string | null> {
  const { nodes } = (await cdp.send('Accessibility.getFullAXTree')) as {
    nodes: AXNode[];
  };
  const focused = nodes.find(
    (n) =>
      !n.ignored &&
      n.role?.value !== 'RootWebArea' &&
      n.properties?.some((p) => p.name === 'focused' && p.value.value === true),
  );
  if (!focused) return null;
  return `${focused.role?.value}: ${focused.name?.value ?? ''}`;
}

/** Wait for `n` animation frames: the game gets the events from before. */
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
  await page.keyboard.press(key);
  await frames(page);
}

test('Escape pauses the shooter, and the mirror shows the pause menu', async ({
  page,
}) => {
  const logs: string[] = [];
  page.on('console', (m) => logs.push(`${m.type()}: ${m.text()}`));
  page.on('pageerror', (e) => logs.push(`pageerror: ${e.message}`));

  await page.goto('/');
  const mirror = page.locator('#swindowzig-a11y');
  await expect(mirror)
    .toBeAttached({ timeout: 45_000 })
    .catch((err: Error) => {
      throw new Error(`${err.message}\nConsole:\n${logs.join('\n')}`);
    });

  // Escape takes control and pauses the fight. events.ts drops an Escape
  // that comes less than 250 ms after the last one.
  const resume = mirror.getByRole('button', { name: 'Resume' });
  for (let i = 0; i < 6 && (await resume.count()) === 0; i++) {
    await press(page, 'Escape');
    await page.waitForTimeout(400);
  }
  await expect(resume).toHaveCount(1);
  for (const name of ['Graphics', 'Mouse', 'Audio']) {
    await expect(mirror.getByRole('button', { name })).toHaveCount(1);
  }
  // A page does not close the browser: no Quit on the web.
  await expect(mirror.getByRole('button', { name: 'Quit' })).toHaveCount(0);

  // The focus of the game is the DOM focus. Down goes to Graphics.
  const cdp = await page.context().newCDPSession(page);
  const focus = () => focusedNode(cdp);
  await expect.poll(focus).toBe('button: Resume');
  await press(page, 'ArrowDown');
  await expect.poll(focus).toBe('button: Graphics');

  // Graphics: each setting is a button that gives its value.
  await press(page, 'Enter');
  const graphics = mirror.getByRole('dialog', { name: 'Graphics' });
  await expect(graphics).toHaveCount(1);
  for (const name of [
    /^Preset: /,
    /^Shadows: /,
    /^Shadow quality: /,
    /^Anti-aliasing: /,
    /^Vsync: /,
    /^Frame limit: /,
  ]) {
    await expect(graphics.getByRole('button', { name })).toHaveCount(1);
  }
  // Right changes the preset at once.
  await expect.poll(focus).toMatch(/^button: Preset: /);
  const before = await focus();
  await press(page, 'ArrowRight');
  await expect.poll(focus).not.toBe(before);
  // The demo saves the settings in localStorage (REQ-DEMO-028).
  const saved = () =>
    page.evaluate(() =>
      atob(localStorage.getItem('swindowzig:shooter-settings') ?? ''),
    );
  const preset = (await focus())?.replace('button: Preset: ', '') ?? '';
  await expect.poll(saved).toContain(`preset ${preset.toLowerCase()}`);

  // Escape goes back to the main screen.
  await page.waitForTimeout(300);
  await press(page, 'Escape');
  await expect.poll(focus).toBe('button: Graphics');

  // Mouse: the sensitivity slider and invert Y.
  await press(page, 'ArrowDown');
  await press(page, 'Enter');
  const mouse = mirror.getByRole('dialog', { name: 'Mouse' });
  await expect(
    mouse.getByRole('slider', { name: 'Mouse sensitivity' }),
  ).toHaveAttribute('aria-valuetext', /x$/);
  await expect(mouse.getByRole('button', { name: /^Invert Y: / })).toHaveCount(
    1,
  );

  // Map changes the map at once, with no restart (REQ-DEMO-030).
  await page.waitForTimeout(300);
  await press(page, 'Escape');
  await expect.poll(focus).toBe('button: Mouse');
  await press(page, 'ArrowDown');
  await press(page, 'ArrowDown');
  await expect.poll(focus).toBe('button: Map: Snowy arena');
  await press(page, 'ArrowRight');
  await expect.poll(focus).toBe('button: Map: Indoor room');

  // A new page loads the saved settings.
  await page.reload();
  await expect(mirror).toBeAttached({ timeout: 45_000 });
  for (let i = 0; i < 6 && (await resume.count()) === 0; i++) {
    await press(page, 'Escape');
    await page.waitForTimeout(400);
  }
  await expect.poll(focus).toBe('button: Resume');
  await press(page, 'ArrowDown');
  await press(page, 'Enter');
  await expect(
    graphics.getByRole('button', { name: `Preset: ${preset}` }),
  ).toHaveCount(1);
});

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

/**
 * Press and release a button of the fake gamepad (standard mapping index).
 * Each state stays for 3 frames: the loader reads the gamepad one time in
 * each animation frame.
 */
async function tap(page: Page, index: number) {
  for (const down of [true, false]) {
    await page.evaluate(
      ([i, d]) => {
        window.fakePad.buttons[i as number] = {
          pressed: d as boolean,
          value: d ? 1 : 0,
        };
      },
      [index, down],
    );
    await frames(page);
  }
}

const SOUTH = 0;
const EAST = 1;
const START = 9;
const DPAD_DOWN = 13;

test('the gamepad Start button pauses the shooter, and the d-pad moves in the menu', async ({
  page,
}) => {
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
  await page.goto('/');
  const mirror = page.locator('#swindowzig-a11y');
  await expect(mirror).toBeAttached({ timeout: 45_000 });

  const resume = mirror.getByRole('button', { name: 'Resume' });
  for (let i = 0; i < 6 && (await resume.count()) === 0; i++) {
    await tap(page, START);
    await page.waitForTimeout(400);
  }
  await expect(resume).toHaveCount(1);

  const cdp = await page.context().newCDPSession(page);
  const focus = () => focusedNode(cdp);
  await expect.poll(focus).toBe('button: Resume');
  await tap(page, DPAD_DOWN);
  await expect.poll(focus).toBe('button: Graphics');
  await tap(page, SOUTH);
  await expect(mirror.getByRole('dialog', { name: 'Graphics' })).toHaveCount(1);
  await tap(page, EAST);
  await expect(mirror.getByRole('dialog', { name: 'Graphics' })).toHaveCount(0);
  await expect.poll(focus).toBe('button: Graphics');
});
