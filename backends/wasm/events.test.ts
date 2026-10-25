// Key numbers and wheel deltas that events.ts sends to the game
// (REQ-INPUT-002). Run with `bun test backends/wasm/events.test.ts`.
import { describe, expect, test } from 'bun:test';
import { keyNumber, wheelDeltas } from './events';

describe('keyNumber', () => {
  test('letters and digits follow the layout', () => {
    // French AZERTY: the key at the US ";" position types "m".
    expect(keyNumber({ code: 'Semicolon', keyCode: 77 })).toBe(77);
    expect(keyNumber({ code: 'KeyA', keyCode: 65 })).toBe(65);
    expect(keyNumber({ code: 'Digit1', keyCode: 49 })).toBe(49);
  });

  test('the backtick key is 192 on every layout', () => {
    expect(keyNumber({ code: 'Backquote', keyCode: 192 })).toBe(192);
    // French AZERTY: the key types "²". Browsers give 222 or 0.
    expect(keyNumber({ code: 'Backquote', keyCode: 222 })).toBe(192);
    expect(keyNumber({ code: 'Backquote', keyCode: 0 })).toBe(192);
  });

  test('punctuation keys follow the physical key', () => {
    // German QWERTZ: the key at the US "/" position types "-".
    expect(keyNumber({ code: 'Slash', keyCode: 189 })).toBe(191);
    // Firefox gives 173 for "-" and 59 for ";".
    expect(keyNumber({ code: 'Minus', keyCode: 173 })).toBe(189);
    expect(keyNumber({ code: 'Semicolon', keyCode: 59 })).toBe(186);
  });

  test('a punctuation keyCode from another position is unknown', () => {
    // French AZERTY: the key at the US "M" position types ",".
    expect(keyNumber({ code: 'KeyM', keyCode: 188 })).toBe(0);
  });

  test('navigation keys', () => {
    expect(keyNumber({ code: 'Delete', keyCode: 46 })).toBe(46);
    expect(keyNumber({ code: 'Home', keyCode: 36 })).toBe(36);
    expect(keyNumber({ code: 'End', keyCode: 35 })).toBe(35);
    expect(keyNumber({ code: 'PageUp', keyCode: 33 })).toBe(33);
    expect(keyNumber({ code: 'PageDown', keyCode: 34 })).toBe(34);
    expect(keyNumber({ code: 'Insert', keyCode: 45 })).toBe(45);
    // The numeric keypad with Num Lock off keeps its keyCode.
    expect(keyNumber({ code: 'NumpadDecimal', keyCode: 46 })).toBe(46);
  });

  test('other keys keep their keyCode', () => {
    expect(keyNumber({ code: 'Escape', keyCode: 27 })).toBe(27);
    expect(keyNumber({ code: 'Space', keyCode: 32 })).toBe(32);
    expect(keyNumber({ code: 'MetaLeft', keyCode: 91 })).toBe(91);
  });
});

describe('wheelDeltas', () => {
  test('a scroll down gives a negative dy', () => {
    expect(wheelDeltas({ deltaX: 0, deltaY: 100, deltaMode: 0 })).toEqual([
      0, -100, 0,
    ]);
  });

  test('a scroll right gives a positive dx, and the mode stays', () => {
    expect(wheelDeltas({ deltaX: 3, deltaY: -3, deltaMode: 1 })).toEqual([
      3, 3, 1,
    ]);
  });
});
