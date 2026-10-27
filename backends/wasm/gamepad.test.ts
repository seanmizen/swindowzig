// The gamepad events that gamepad.ts sends to the wasm (REQ-INPUT-005).
// events.test.ts imports this file, so CI runs it.
import { describe, expect, test } from 'bun:test';
import {
  GAMEPAD_AXIS,
  GAMEPAD_BUTTON,
  GamepadPoller,
  MAX_GAMEPADS,
  type PadLike,
  STANDARD_BUTTONS,
} from './gamepad';

type Sent = [string, ...number[]];

function recorder() {
  const sent: Sent[] = [];
  return {
    sent,
    exports: {
      swindowzig_event_gamepad_connection: (p: number, c: number) => {
        sent.push(['connection', p, c]);
      },
      swindowzig_event_gamepad_button: (p: number, b: number, d: number) => {
        sent.push(['button', p, b, d]);
      },
      swindowzig_event_gamepad_axis: (p: number, a: number, v: number) => {
        sent.push(['axis', p, a, v]);
      },
    },
  };
}

function pad(index: number, change: Partial<PadLike> = {}): PadLike {
  return {
    index,
    id: `pad ${index}`,
    connected: true,
    mapping: 'standard',
    buttons: Array.from({ length: 17 }, () => ({ pressed: false, value: 0 })),
    axes: [0, 0, 0, 0],
    ...change,
  };
}

function withButton(p: PadLike, i: number, value = 1): PadLike {
  const buttons = p.buttons.map((b, j) =>
    j === i ? { pressed: value > 0.5, value } : b,
  );
  return { ...p, buttons };
}

describe('GamepadPoller', () => {
  test('a new gamepad connects to the lowest free slot', () => {
    const r = recorder();
    const poller = new GamepadPoller(r.exports);
    poller.poll([null, pad(1)]);
    expect(r.sent).toEqual([['connection', 0, 1]]);
    expect(poller.slotOf(1)).toBe(0);
    // No change: poll sends nothing.
    r.sent.length = 0;
    poller.poll([null, pad(1)]);
    expect(r.sent).toEqual([]);
  });

  test('buttons follow the standard mapping', () => {
    const r = recorder();
    const poller = new GamepadPoller(r.exports);
    poller.poll([pad(0)]);
    r.sent.length = 0;
    // Button 0 is south, 12 is up on the d-pad, 16 is the guide button.
    let p = withButton(pad(0), 0);
    p = withButton(p, 12);
    p = withButton(p, 16);
    poller.poll([p]);
    expect(r.sent).toEqual([
      ['button', 0, GAMEPAD_BUTTON.south, 1],
      ['button', 0, GAMEPAD_BUTTON.dpadUp, 1],
      ['button', 0, GAMEPAD_BUTTON.guide, 1],
    ]);
    r.sent.length = 0;
    poller.poll([pad(0)]);
    expect(r.sent.map((s) => s[3])).toEqual([0, 0, 0]);
  });

  test('the triggers are axes, and the sticks are raw', () => {
    const r = recorder();
    const poller = new GamepadPoller(r.exports);
    poller.poll([pad(0)]);
    r.sent.length = 0;
    const p = withButton(pad(0, { axes: [0.25, -1, 0, 0.05] }), 7, 0.4);
    poller.poll([p]);
    expect(r.sent).toEqual([
      ['axis', 0, GAMEPAD_AXIS.leftX, 0.25],
      ['axis', 0, GAMEPAD_AXIS.leftY, -1],
      ['axis', 0, GAMEPAD_AXIS.rightY, 0.05],
      ['axis', 0, GAMEPAD_AXIS.rightTrigger, 0.4],
    ]);
    // A trigger is never a button event.
    expect(r.sent.some((s) => s[0] === 'button')).toBe(false);
    expect(STANDARD_BUTTONS[6]).toBeNull();
    expect(STANDARD_BUTTONS[7]).toBeNull();
  });

  test('a disconnect frees the slot, and the next gamepad gets it', () => {
    const r = recorder();
    const poller = new GamepadPoller(r.exports);
    poller.poll([pad(0), pad(1)]);
    r.sent.length = 0;
    poller.poll([null, pad(1)]);
    expect(r.sent).toEqual([['connection', 0, 0]]);
    expect(poller.slotOf(0)).toBeNull();
    r.sent.length = 0;
    poller.poll([null, pad(1), pad(2)]);
    expect(r.sent).toEqual([['connection', 0, 1]]);
    expect(poller.slotOf(2)).toBe(0);
    expect(poller.slotOf(1)).toBe(1);
    // A gamepad that says it is not connected is a disconnect.
    r.sent.length = 0;
    poller.poll([null, pad(1, { connected: false }), pad(2)]);
    expect(r.sent).toEqual([['connection', 1, 0]]);
  });

  test('more gamepads than slots: the extra one is ignored, with one warning', () => {
    const r = recorder();
    const warnings: string[] = [];
    const poller = new GamepadPoller(r.exports, (m) => warnings.push(m));
    const pads = Array.from({ length: MAX_GAMEPADS + 1 }, (_, i) => pad(i));
    poller.poll(pads);
    poller.poll(pads);
    const connects = r.sent.filter((s) => s[0] === 'connection');
    expect(connects.length).toBe(MAX_GAMEPADS);
    expect(poller.slotOf(MAX_GAMEPADS)).toBeNull();
    expect(warnings.length).toBe(1);
  });

  test('a gamepad with no standard mapping still works, with a warning', () => {
    const r = recorder();
    const warnings: string[] = [];
    const poller = new GamepadPoller(r.exports, (m) => warnings.push(m));
    poller.poll([pad(0, { mapping: '' })]);
    expect(r.sent).toEqual([['connection', 0, 1]]);
    expect(warnings.length).toBe(1);
  });

  test('a wasm with no gamepad exports does not throw', () => {
    const poller = new GamepadPoller({});
    expect(() => poller.poll([withButton(pad(0), 0)])).not.toThrow();
  });
});
