// The screen-reader mirror in a real browser (REQ-A11Y-001 to REQ-A11Y-006).
// The test opens the flat2d example, moves the focus of the game with the
// keyboard, and reads the focused node from the Chromium accessibility tree.

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

test('the semantic tree of flat2d is in the accessibility tree', async ({
  page,
}) => {
  const logs: string[] = [];
  page.on('console', (m) => logs.push(`${m.type()}: ${m.text()}`));
  page.on('pageerror', (e) => logs.push(`pageerror: ${e.message}`));

  await page.goto('/');
  const mirror = page.locator('#swindowzig-a11y');
  // With no WebGPU, flat2d makes no UI. The console then tells why.
  await expect(mirror)
    .toBeAttached({ timeout: 30_000 })
    .catch((err: Error) => {
      throw new Error(`${err.message}\nConsole:\n${logs.join('\n')}`);
    });

  // REQ-A11Y-004: visually hidden, but not display: none.
  const style = await mirror.evaluate((el) => {
    const s = getComputedStyle(el);
    const r = el.getBoundingClientRect();
    return { display: s.display, clipPath: s.clipPath, w: r.width };
  });
  expect(style.display).not.toBe('none');
  expect(style.clipPath).toBe('inset(50%)');
  expect(style.w).toBeLessThanOrEqual(1);

  // REQ-A11Y-001: the roles and the names of the flat2d UI.
  await expect(mirror).toMatchAriaSnapshot(`
    - group "Menu":
      - text: "Menu: Tab, arrows, Enter, Esc"
      - list "Accent colour":
        - listitem: Green
        - listitem: Orange
        - listitem: Pink
      - text: "Accent: Green"
      - button "Close menu"
      - button "Settings"
    - textbox "Name"
    - button "Keyboard"
  `);

  // REQ-A11Y-002: the focus of the game is the DOM focus. flat2d starts
  // with the focus on the first list item.
  const cdp = await page.context().newCDPSession(page);
  const focus = () => focusedNode(cdp);
  await expect.poll(focus).toBe('listitem: Green');

  await press(page, 'Tab');
  await expect.poll(focus).toBe('button: Close menu');

  await press(page, 'Tab');
  await expect.poll(focus).toBe('button: Settings');

  await press(page, 'Tab');
  await expect.poll(focus).toBe('textbox: Name');

  await press(page, 'Shift+Tab');
  await expect.poll(focus).toBe('button: Settings');

  await press(page, 'Shift+Tab');
  await expect.poll(focus).toBe('button: Close menu');

  await press(page, 'Shift+Tab');
  await expect.poll(focus).toBe('listitem: Green');

  // REQ-A11Y-003: the live region. Select Orange, and the status text in the
  // aria-live element changes.
  const live = mirror.locator('[aria-live="polite"]');
  await expect(live).toHaveText('Accent: Green');
  await press(page, 'ArrowDown');
  await expect.poll(focus).toBe('listitem: Orange');
  await press(page, 'Enter');
  await expect(live).toHaveText('Accent: Orange');

  // REQ-A11Y-006: the widgets. The Settings button has a tooltip: it is
  // the description of the button, and a tooltip element while it shows.
  await press(page, 'Tab');
  await press(page, 'Tab');
  await expect.poll(focus).toBe('button: Settings');
  const settingsButton = mirror.getByRole('button', { name: 'Settings' });
  await expect(settingsButton).toHaveAttribute(
    'aria-description',
    'A slider and a long list',
  );
  await expect(mirror.getByRole('tooltip')).toHaveText(
    'A slider and a long list',
  );

  // The settings screen is a modal dialog. The menu under it leaves the
  // mirror, and the focus goes to the slider.
  await press(page, 'Enter');
  const dialog = mirror.getByRole('dialog', { name: 'Settings' });
  await expect(dialog).toHaveAttribute('aria-modal', 'true');
  await expect.poll(focus).toBe('slider: Volume');
  await expect(mirror.getByRole('button', { name: 'Close menu' })).toHaveCount(
    0,
  );
  const slider = dialog.getByRole('slider', { name: 'Volume' });
  await expect(slider).toHaveAttribute('aria-valuenow', '0.7');
  await press(page, 'ArrowRight');
  await expect(slider).toHaveAttribute('aria-valuenow', '0.75');
  await expect(slider).toHaveAttribute('aria-valuetext', '75%');

  // The scroll list is a list with all its items, also the hidden ones.
  await press(page, 'Tab');
  await expect.poll(focus).toBe('listitem: Level 1');
  await expect(
    dialog.getByRole('list', { name: 'Level' }).getByRole('listitem'),
  ).toHaveCount(30);
  await press(page, 'End');
  await expect.poll(focus).toBe('listitem: Level 30');

  // Escape closes the screen, and the focus goes back to Settings.
  await press(page, 'Escape');
  await expect(dialog).toHaveCount(0);
  await expect.poll(focus).toBe('button: Settings');
  await press(page, 'Shift+Tab');
  await expect.poll(focus).toBe('button: Close menu');
  // events.ts drops an Escape that comes less than 250 ms after the last one.
  await page.waitForTimeout(300);

  // A node that goes away leaves the mirror. Escape closes the menu, and
  // the focus moves to the button that opens it.
  await press(page, 'Escape');
  await expect.poll(focus).toBe('button: Open menu (Esc)');
  await expect(mirror.getByRole('button', { name: 'Close menu' })).toHaveCount(
    0,
  );

  // The on-screen keyboard fills the text field. Its keys are buttons.
  await press(page, 'Tab');
  await press(page, 'Tab');
  await expect.poll(focus).toBe('button: Keyboard');
  await press(page, 'Enter');
  const osk = mirror.getByRole('dialog', { name: 'On-screen keyboard' });
  await expect(osk).toHaveCount(1);
  await expect.poll(focus).toBe('textbox: Name');
  await press(page, 'Tab');
  await expect.poll(focus).toBe('button: 1');
  await press(page, 'ArrowDown');
  await expect.poll(focus).toBe('button: q');
  await press(page, 'Enter');
  await expect(osk.getByRole('textbox', { name: 'Name' })).toHaveValue('q');
  await page.waitForTimeout(300);
  await press(page, 'Escape');
  await expect(osk).toHaveCount(0);
  await expect.poll(focus).toBe('button: Keyboard');
});
