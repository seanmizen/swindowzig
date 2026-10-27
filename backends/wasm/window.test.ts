// Window modes, cursor modes, the device pixel ratio and the clipboard of
// the web backend (REQ-PLATFORM-001, REQ-PLATFORM-002, REQ-PLATFORM-003).
// Run with `bun test backends/wasm/window.test.ts`.
import { describe, expect, test } from 'bun:test';
import {
  CLIPBOARD_KIND,
  CLIPBOARD_STATUS,
  type ClipboardExports,
  type ClipboardHost,
  WebClipboard,
} from './clipboard';
import { lockPointer } from './events';
import {
  CursorStyle,
  isFullscreen,
  requestPointerLockSafe,
  setFullscreen,
  watchDevicePixelRatio,
} from './window';

describe('requestPointerLockSafe', () => {
  test('a refused pointer lock does not throw', async () => {
    // A browser that throws at once (no pointer lock, or a sandbox).
    const throws = {
      requestPointerLock: (): Promise<void> => {
        throw new DOMException('no lock', 'NotSupportedError');
      },
    };
    const err = await requestPointerLockSafe(throws);
    expect(err).toBeInstanceOf(DOMException);

    // A browser that rejects the promise.
    const rejects = {
      requestPointerLock: () =>
        Promise.reject(new DOMException('too soon', 'SecurityError')),
    };
    expect(await requestPointerLockSafe(rejects)).toBeInstanceOf(DOMException);
  });

  test('an accepted lock and an old browser with no promise give null', async () => {
    expect(
      await requestPointerLockSafe({
        requestPointerLock: () => Promise.resolve(),
      }),
    ).toBeNull();
    expect(
      await requestPointerLockSafe({ requestPointerLock: () => undefined }),
    ).toBeNull();
  });

  test('the options go to the browser', async () => {
    let seen: unknown = 'none';
    await requestPointerLockSafe(
      {
        requestPointerLock: (o) => {
          seen = o;
          return Promise.resolve();
        },
      },
      { unadjustedMovement: true },
    );
    expect(seen).toEqual({ unadjustedMovement: true });
  });
});

describe('lockPointer', () => {
  test('a browser with no pointer lock does not stop the game', async () => {
    const warn = console.warn;
    const warnings: string[] = [];
    console.warn = (...a: unknown[]) => warnings.push(a.join(' '));
    try {
      // iOS Safari: no requestPointerLock. Each call throws a TypeError.
      const none = {} as HTMLCanvasElement;
      expect(() => lockPointer(none)).not.toThrow();
      // A browser that rejects each request (a lock too soon after Esc).
      let calls = 0;
      const refuses = {
        requestPointerLock: () => {
          calls++;
          return Promise.reject(new DOMException('too soon', 'SecurityError'));
        },
      } as unknown as HTMLCanvasElement;
      expect(() => lockPointer(refuses)).not.toThrow();
      // No unhandled rejection: wait for the promises to settle.
      await new Promise((r) => setTimeout(r, 0));
      expect(calls).toBe(1);
      expect(warnings.some((w) => w.includes('pointer lock'))).toBe(true);
    } finally {
      console.warn = warn;
    }
  });

  test('a browser with no raw input asks again with no options', async () => {
    const seen: unknown[] = [];
    const canvas = {
      requestPointerLock: (o?: unknown) => {
        seen.push(o);
        if (o) {
          return Promise.reject(new DOMException('raw', 'NotSupportedError'));
        }
        return Promise.resolve();
      },
    } as unknown as HTMLCanvasElement;
    lockPointer(canvas);
    await new Promise((r) => setTimeout(r, 0));
    expect(seen).toEqual([{ unadjustedMovement: true }, undefined]);
  });
});

describe('full screen', () => {
  const fakeDoc = (refuse: boolean) => {
    const doc = {
      fullscreenElement: null as Element | null,
      documentElement: {
        requestFullscreen: () => {
          if (refuse) return Promise.reject(new TypeError('no gesture'));
          doc.fullscreenElement = {} as Element;
          return Promise.resolve();
        },
      },
      exitFullscreen: () => {
        doc.fullscreenElement = null;
        return Promise.resolve();
      },
    };
    return doc;
  };

  test('a game can go to full screen and back', async () => {
    const doc = fakeDoc(false);
    expect(isFullscreen(doc)).toBe(false);
    expect(await setFullscreen(true, doc)).toBe(true);
    expect(isFullscreen(doc)).toBe(true);
    expect(await setFullscreen(false, doc)).toBe(true);
    expect(isFullscreen(doc)).toBe(false);
  });

  test('a refused request gives false and does not throw', async () => {
    const doc = fakeDoc(true);
    const warn = console.warn;
    console.warn = () => {};
    try {
      expect(await setFullscreen(true, doc)).toBe(false);
    } finally {
      console.warn = warn;
    }
    expect(isFullscreen(doc)).toBe(false);
  });
});

describe('watchDevicePixelRatio', () => {
  test('a change of monitor calls the watcher, and the watch follows the new ratio', () => {
    const queries: { query: string; fire?: () => void }[] = [];
    const win = {
      devicePixelRatio: 2,
      matchMedia: (query: string) => {
        const q: { query: string; fire?: () => void } = { query };
        queries.push(q);
        return {
          addEventListener: (_: string, fn: () => void) => {
            q.fire = fn;
          },
          removeEventListener: () => {
            q.fire = undefined;
          },
        } as unknown as MediaQueryList;
      },
    };
    let calls = 0;
    const stop = watchDevicePixelRatio(() => {
      calls++;
    }, win);
    expect(queries[0].query).toBe('(resolution: 2dppx)');

    // The window moves to a monitor with a ratio of 1.
    win.devicePixelRatio = 1;
    queries[0].fire?.();
    expect(calls).toBe(1);
    expect(queries[1].query).toBe('(resolution: 1dppx)');
    expect(queries[0].fire).toBeUndefined();

    stop();
    expect(queries[1].fire).toBeUndefined();
  });
});

describe('CursorStyle', () => {
  test('the hidden mode hides the cursor and gives back the old style', () => {
    const canvas = { style: { cursor: 'crosshair' } };
    const cursor = new CursorStyle(canvas, false);
    cursor.setHidden(true);
    expect(canvas.style.cursor).toBe('none');
    // A lock change does not show the cursor in the hidden mode.
    cursor.apply(false);
    expect(canvas.style.cursor).toBe('none');
    cursor.setHidden(false);
    expect(canvas.style.cursor).toBe('crosshair');
  });

  test('cursorFollowsLock keeps its behaviour', () => {
    const canvas = { style: { cursor: '' } };
    const cursor = new CursorStyle(canvas, true);
    cursor.apply(true);
    expect(canvas.style.cursor).toBe('none');
    cursor.apply(false);
    expect(canvas.style.cursor).toBe('auto');
  });

  test('without cursorFollowsLock a lock change does not touch the style', () => {
    const canvas = { style: { cursor: 'none' } };
    const cursor = new CursorStyle(canvas, false);
    cursor.apply(false);
    expect(canvas.style.cursor).toBe('none');
  });
});

/** A fake wasm: a memory, the reserve export and the event export. */
function fakeWasm() {
  const memory = new WebAssembly.Memory({ initial: 1 });
  const events: { kind: number; status: number; text: string }[] = [];
  let reserved = 0;
  const exports: ClipboardExports = {
    memory,
    swindowzig_clipboard_reserve: (len) => {
      reserved = len;
      return len > 1000 ? 0 : 16;
    },
    swindowzig_clipboard_event: (kind, status, len) => {
      const text = new TextDecoder().decode(
        new Uint8Array(memory.buffer, 16, Math.min(len, reserved)),
      );
      events.push({ kind, status, text });
    },
  };
  return { exports, events };
}

function clipboardWith(host: Partial<ClipboardHost>) {
  const warnings: string[] = [];
  const clip = new WebClipboard({
    isSecureContext: true,
    warn: (...args) => warnings.push(args.join(' ')),
    ...host,
  });
  const wasm = fakeWasm();
  clip.exports = wasm.exports;
  return { clip, events: wasm.events, warnings };
}

describe('WebClipboard', () => {
  test('a paste arrives as an event with its text', () => {
    const { clip, events } = clipboardWith({});
    // The default: the paste also types into the text input.
    expect(clip.paste('héllo', true)).toBe(false);
    expect(events).toEqual([
      {
        kind: CLIPBOARD_KIND.paste,
        status: CLIPBOARD_STATUS.ok,
        text: 'héllo',
      },
    ]);
    // setPasteAsText(false): the paste goes only to the event.
    clip
      .imports(() => new WebAssembly.Memory({ initial: 1 }))
      .jsSetPasteAsText(0);
    expect(clip.paste('x', true)).toBe(true);
    expect(clip.paste('x', false)).toBe(false);
  });

  test('a read gives the text as an event, not as a return value', async () => {
    const { clip, events } = clipboardWith({
      clipboard: { readText: () => Promise.resolve('from another app') },
    });
    const done = clip.read();
    expect(events).toEqual([]);
    await done;
    expect(events).toEqual([
      {
        kind: CLIPBOARD_KIND.read,
        status: CLIPBOARD_STATUS.ok,
        text: 'from another app',
      },
    ]);
  });

  test('a refused read gives the status denied and a clear warning', async () => {
    const { clip, events, warnings } = clipboardWith({
      clipboard: {
        readText: () =>
          Promise.reject(new DOMException('no permission', 'NotAllowedError')),
      },
    });
    await clip.read();
    expect(events[0].status).toBe(CLIPBOARD_STATUS.denied);
    expect(warnings[0]).toContain('clipboard read: the browser refused');
    expect(warnings[0]).toContain('NotAllowedError');
  });

  test('no Clipboard API gives the status unavailable', async () => {
    const { clip, events, warnings } = clipboardWith({
      isSecureContext: false,
    });
    await clip.read();
    expect(events[0]).toEqual({
      kind: CLIPBOARD_KIND.read,
      status: CLIPBOARD_STATUS.unavailable,
      text: '',
    });
    expect(warnings[0]).toContain('not a secure context');
  });

  test('a write sends a write event', async () => {
    let written = '';
    const { clip, events } = clipboardWith({
      clipboard: {
        writeText: (t) => {
          written = t;
          return Promise.resolve();
        },
      },
    });
    await clip.write('copied');
    expect(written).toBe('copied');
    expect(events[0].kind).toBe(CLIPBOARD_KIND.write);
    expect(events[0].status).toBe(CLIPBOARD_STATUS.ok);
  });

  test('a refused write uses execCommand when it can', async () => {
    const refuse = () =>
      Promise.reject(new DOMException('no gesture', 'NotAllowedError'));
    const ok = clipboardWith({
      clipboard: { writeText: refuse },
      copyFallback: () => true,
    });
    await ok.clip.write('a');
    expect(ok.events[0].status).toBe(CLIPBOARD_STATUS.ok);

    const no = clipboardWith({
      clipboard: { writeText: refuse },
      copyFallback: () => false,
    });
    await no.clip.write('a');
    expect(no.events[0].status).toBe(CLIPBOARD_STATUS.denied);
    expect(no.warnings[0]).toContain('clipboard write: the browser refused');
  });

  test('text over the limit and empty text give no_text', () => {
    const { clip, events } = clipboardWith({});
    clip.paste('', true);
    clip.paste('x'.repeat(2000), true);
    expect(events.map((e) => e.status)).toEqual([
      CLIPBOARD_STATUS.noText,
      CLIPBOARD_STATUS.noText,
    ]);
  });
});
