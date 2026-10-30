// The screen-reader mirror of the menu demo (REQ-A11Y-001, REQ-DEMO-009).
// The test opens demos/menu, takes control from the script with a key
// press (REQ-DEMO-010), and reads the menu widgets from the mirror and from
// the Chromium accessibility tree.

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

test('the menu demo mirrors each screen for a screen reader', async ({
  page,
}) => {
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

  // A key press stops the script. The script can be on any screen, so
  // Escape goes back until the main menu shows. events.ts drops an Escape
  // that comes less than 250 ms after the last one.
  await press(page, 'Shift');
  const resume = mirror.getByRole('button', { name: 'Resume' });
  for (let i = 0; i < 8 && (await resume.count()) === 0; i++) {
    await press(page, 'Escape');
    await page.waitForTimeout(300);
  }
  await expect(resume).toHaveCount(1);

  // The main screen: the title, the live player line and the buttons.
  await expect(mirror.getByRole('button', { name: 'Player' })).toHaveCount(1);
  await expect(mirror.getByRole('button', { name: 'Settings' })).toHaveCount(1);
  await expect(mirror.locator('[aria-live="polite"]')).toContainText('Player');

  // The focus of the game is the DOM focus. Tab goes to Settings.
  const cdp = await page.context().newCDPSession(page);
  const focus = () => focusedNode(cdp);
  for (let i = 0; i < 4; i++) {
    if ((await focus()) === 'button: Settings') break;
    await press(page, 'Tab');
  }
  await expect.poll(focus).toBe('button: Settings');

  // The settings screen is a dialog with a button for each page.
  await press(page, 'Enter');
  const settings = mirror.getByRole('dialog', { name: 'Settings' });
  await expect(settings).toHaveCount(1);
  await expect.poll(focus).toBe('button: Graphics');
  for (const name of ['Audio', 'Controls', 'Gamepad', 'Interface', 'Back']) {
    await expect(settings.getByRole('button', { name })).toHaveCount(1);
  }

  // Graphics: the sliders give their values.
  await press(page, 'Enter');
  const graphics = mirror.getByRole('dialog', { name: 'Graphics' });
  await expect(graphics.getByRole('slider', { name: 'Exposure' })).toHaveCount(
    1,
  );
  await expect(
    graphics.getByRole('slider', { name: 'Time of day' }),
  ).toHaveAttribute('aria-valuetext', /\d\d:\d\d/);
  await page.waitForTimeout(300);
  await press(page, 'Escape');

  // Interface: the language list. Hebrew changes each name at once.
  await expect.poll(focus).toBe('button: Graphics');
  for (let i = 0; i < 4; i++) await press(page, 'ArrowDown');
  await expect.poll(focus).toBe('button: Interface');
  await press(page, 'Enter');
  const iface = mirror.getByRole('dialog', { name: 'Interface' });
  await expect(
    iface.getByRole('list', { name: 'Language' }).getByRole('listitem'),
  ).toHaveCount(2);
  await expect.poll(focus).toBe('listitem: English');
  await press(page, 'ArrowDown');
  await expect.poll(focus).toBe('listitem: עברית');
  await press(page, 'Enter');
  await expect(mirror.getByRole('dialog', { name: 'ממשק' })).toHaveCount(1);
  await expect(mirror.getByRole('button', { name: 'חזרה' })).toHaveCount(1);
});
