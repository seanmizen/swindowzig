// The screen-reader mirror in a real browser (REQ-A11Y-001 to REQ-A11Y-005).
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

async function press(page: Page, key: string): Promise<void> {
  // A delay between the key down and the key up, so that the game sees the
  // key in a tick.
  await page.keyboard.press(key, { delay: 50 });
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
    - textbox "Name"
  `);

  // REQ-A11Y-002: the focus of the game is the DOM focus. flat2d starts
  // with the focus on the first list item.
  const cdp = await page.context().newCDPSession(page);
  const focus = () => focusedNode(cdp);
  await expect.poll(focus).toBe('listitem: Green');

  await press(page, 'Tab');
  await expect.poll(focus).toBe('button: Close menu');

  await press(page, 'Tab');
  await expect.poll(focus).toBe('textbox: Name');

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

  // A node that goes away leaves the mirror. Escape closes the menu, and
  // the focus moves to the button that opens it.
  await press(page, 'Escape');
  await expect.poll(focus).toBe('button: Open menu (Esc)');
  await expect(mirror.getByRole('button', { name: 'Close menu' })).toHaveCount(
    0,
  );
});
