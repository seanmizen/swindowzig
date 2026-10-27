// Gamepads for the web backend (libs/sw_platform/src/web_gamepad.zig).
//
// The web Gamepad API has no events for buttons and axes. The loader calls
// GamepadPoller.poll once per frame, before swindowzig_frame. poll compares
// each gamepad with the last frame, and sends each change to the wasm as a
// gamepad event (REQ-INPUT-005):
// - A gamepad gets the lowest free slot from 0 to MAX_GAMEPADS - 1. The
//   slot is free again when the gamepad disconnects.
// - Buttons and sticks use the "standard" mapping of the Gamepad API. The
//   triggers are buttons 6 and 7 there. Their value goes to the trigger
//   axes, not to the buttons.
// - The axis values are raw. The game applies the dead zones.
//
// A browser shows a gamepad to the page only after the user presses a
// button on it. A permissions policy can block the API: then poll does
// nothing, and the game continues.

/** The numbers of core.GamepadButton (libs/sw_core/src/event.zig). */
export const GAMEPAD_BUTTON = {
  south: 0,
  east: 1,
  west: 2,
  north: 3,
  leftShoulder: 4,
  rightShoulder: 5,
  back: 6,
  start: 7,
  guide: 8,
  leftStick: 9,
  rightStick: 10,
  dpadUp: 11,
  dpadDown: 12,
  dpadLeft: 13,
  dpadRight: 14,
} as const;

/** The numbers of core.GamepadAxis (libs/sw_core/src/event.zig). */
export const GAMEPAD_AXIS = {
  leftX: 0,
  leftY: 1,
  rightX: 2,
  rightY: 3,
  leftTrigger: 4,
  rightTrigger: 5,
} as const;

/** core.max_gamepads. */
export const MAX_GAMEPADS = 4;

const B = GAMEPAD_BUTTON;

/**
 * The core button for each button index of the standard mapping. Indexes 6
 * and 7 are the triggers: they go to the trigger axes (null here).
 */
export const STANDARD_BUTTONS: readonly (number | null)[] = [
  B.south,
  B.east,
  B.west,
  B.north,
  B.leftShoulder,
  B.rightShoulder,
  null,
  null,
  B.back,
  B.start,
  B.leftStick,
  B.rightStick,
  B.dpadUp,
  B.dpadDown,
  B.dpadLeft,
  B.dpadRight,
  B.guide,
];

const BUTTON_COUNT = Object.keys(GAMEPAD_BUTTON).length;
const AXIS_COUNT = Object.keys(GAMEPAD_AXIS).length;
const LEFT_TRIGGER_BUTTON = 6;
const RIGHT_TRIGGER_BUTTON = 7;

/** The part of a browser Gamepad that the poller reads. */
export interface PadLike {
  index: number;
  id: string;
  connected: boolean;
  mapping: string;
  buttons: readonly { pressed: boolean; value: number }[];
  axes: readonly number[];
}

export interface GamepadExports {
  swindowzig_event_gamepad_connection?: (
    pad: number,
    connected: number,
  ) => void;
  swindowzig_event_gamepad_button?: (
    pad: number,
    button: number,
    down: number,
  ) => void;
  swindowzig_event_gamepad_axis?: (
    pad: number,
    axis: number,
    value: number,
  ) => void;
}

interface SlotState {
  /** Gamepad.index of the gamepad in this slot. */
  index: number;
  buttons: boolean[];
  axes: number[];
}

function finite(v: number | undefined): number {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0;
}

/** Reads the gamepads each frame and sends the changes to the wasm. */
export class GamepadPoller {
  private readonly slots: (SlotState | null)[] = new Array(MAX_GAMEPADS).fill(
    null,
  );
  private readonly warned = new Set<string>();

  constructor(
    private readonly exports: GamepadExports,
    private readonly warn: (msg: string) => void = () => {},
    private readonly logPrefix = '[swindowzig]',
  ) {}

  /** The slot of each connected gamepad, by Gamepad.index. */
  slotOf(index: number): number | null {
    const s = this.slots.findIndex((slot) => slot?.index === index);
    return s < 0 ? null : s;
  }

  /** Compare `pads` (navigator.getGamepads()) with the last frame. */
  poll(pads: readonly (PadLike | null | undefined)[]): void {
    const present = new Map<number, PadLike>();
    for (const pad of pads) {
      if (pad?.connected) present.set(pad.index, pad);
    }
    // Disconnect first, so a slot is free for a new gamepad in this frame.
    this.slots.forEach((slot, s) => {
      if (slot && !present.has(slot.index)) {
        this.slots[s] = null;
        this.exports.swindowzig_event_gamepad_connection?.(s, 0);
      }
    });
    for (const pad of present.values()) {
      const s = this.slotOf(pad.index) ?? this.connect(pad);
      if (s === null) continue;
      this.send(s, pad);
    }
  }

  private connect(pad: PadLike): number | null {
    const s = this.slots.indexOf(null);
    if (s < 0) {
      this.warnOnce(
        `full:${pad.index}`,
        `gamepad: ${MAX_GAMEPADS} gamepads are connected. The engine ignores "${pad.id}".`,
      );
      return null;
    }
    if (pad.mapping !== 'standard') {
      this.warnOnce(
        `mapping:${pad.id}`,
        `gamepad: "${pad.id}" has no standard mapping. The buttons can be in other positions.`,
      );
    }
    this.slots[s] = {
      index: pad.index,
      buttons: new Array(BUTTON_COUNT).fill(false),
      axes: new Array(AXIS_COUNT).fill(0),
    };
    this.exports.swindowzig_event_gamepad_connection?.(s, 1);
    return s;
  }

  private send(s: number, pad: PadLike): void {
    const slot = this.slots[s];
    if (!slot) return;
    STANDARD_BUTTONS.forEach((core, i) => {
      if (core === null) return;
      const down = pad.buttons[i]?.pressed ?? false;
      if (down === slot.buttons[core]) return;
      slot.buttons[core] = down;
      this.exports.swindowzig_event_gamepad_button?.(s, core, down ? 1 : 0);
    });
    const axes = [
      finite(pad.axes[0]),
      finite(pad.axes[1]),
      finite(pad.axes[2]),
      finite(pad.axes[3]),
      finite(pad.buttons[LEFT_TRIGGER_BUTTON]?.value),
      finite(pad.buttons[RIGHT_TRIGGER_BUTTON]?.value),
    ];
    axes.forEach((value, a) => {
      if (value === slot.axes[a]) return;
      slot.axes[a] = value;
      this.exports.swindowzig_event_gamepad_axis?.(s, a, value);
    });
  }

  private warnOnce(key: string, msg: string): void {
    if (this.warned.has(key)) return;
    this.warned.add(key);
    this.warn(`${this.logPrefix} ${msg}`);
  }
}

/**
 * A function that reads the gamepads of the browser. It never throws: a
 * browser with no Gamepad API, or a page that a permissions policy blocks,
 * gives no gamepads.
 */
export function browserGamepads(
  logPrefix = '[swindowzig]',
): () => readonly (PadLike | null)[] {
  let blocked = false;
  return () => {
    if (blocked || typeof navigator.getGamepads !== 'function') return [];
    try {
      return navigator.getGamepads();
    } catch (err) {
      blocked = true;
      console.warn(
        `${logPrefix} gamepad: the browser blocked the Gamepad API (${String(err)}).`,
      );
      return [];
    }
  };
}
