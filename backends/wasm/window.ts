// Window modes, cursor modes and the device pixel ratio for the web backend
// (libs/sw_platform/src/web_window.zig).
//
// Full screen: the page element goes to browser full screen, so the hidden
// text <input> and the screen-reader mirror stay in it. The browser asks
// for a user gesture. A refusal goes to the console, and the game
// continues. The window resize event that follows sends the new size.
//
// Cursor modes: normal, hidden (no cursor over the canvas) and locked (the
// pointer lock). The browser can refuse a pointer lock, or end it. A
// refusal must not stop the frame loop (REQ-PLATFORM-001).
//
// Device pixel ratio: a move to a monitor with another ratio does not always
// send a window resize event. A media query on the ratio does
// (REQ-PLATFORM-003).

/** The numbers of WindowMode in libs/sw_platform/src/platform.zig. */
export const WINDOW_MODE = { windowed: 0, fullscreen: 1 } as const;
/** The numbers of CursorMode in libs/sw_platform/src/platform.zig. */
export const CURSOR_MODE = { normal: 0, hidden: 1, locked: 2 } as const;

type LockOptions = { unadjustedMovement?: boolean };
type Lockable = {
  requestPointerLock: (options?: LockOptions) => Promise<void> | undefined;
};

/**
 * Request the pointer lock. This function never throws, and the promise
 * that it returns never rejects. The result is null when the browser
 * accepted the request, or the error when it refused. Some browsers throw
 * at once, some reject the promise, and old browsers return no promise.
 * Each case is safe here, so a refused lock cannot stop the game
 * (REQ-PLATFORM-001).
 */
export function requestPointerLockSafe(
  el: Lockable,
  options?: LockOptions,
): Promise<unknown> {
  let req: Promise<void> | undefined;
  try {
    req = (
      options === undefined
        ? el.requestPointerLock()
        : el.requestPointerLock(options)
    ) as Promise<void> | undefined;
  } catch (err) {
    return Promise.resolve(err ?? new Error('requestPointerLock threw'));
  }
  if (!req || typeof req.then !== 'function') return Promise.resolve(null);
  return req.then(
    () => null,
    (err: unknown) => err ?? new Error('requestPointerLock rejected'),
  );
}

type FullscreenDocument = {
  documentElement: {
    requestFullscreen?: (
      options?: FullscreenOptions,
    ) => Promise<void> | undefined;
    webkitRequestFullscreen?: () => void;
  };
  fullscreenElement?: Element | null;
  webkitFullscreenElement?: Element | null;
  exitFullscreen?: () => Promise<void> | undefined;
  webkitExitFullscreen?: () => void;
};

/** True while the page is in browser full screen. */
export function isFullscreen(doc: FullscreenDocument = document): boolean {
  return Boolean(doc.fullscreenElement ?? doc.webkitFullscreenElement);
}

/**
 * Go to browser full screen, or back. The promise never rejects. It gives
 * true when the browser accepted the request. Safari before 16.4 has only
 * the webkit-prefixed functions.
 */
export async function setFullscreen(
  on: boolean,
  doc: FullscreenDocument = document,
  logPrefix = '[swindowzig]',
): Promise<boolean> {
  if (on === isFullscreen(doc)) return true;
  try {
    if (on) {
      const el = doc.documentElement;
      if (el.requestFullscreen) {
        await el.requestFullscreen({ navigationUI: 'hide' });
      } else if (el.webkitRequestFullscreen) {
        el.webkitRequestFullscreen();
      } else {
        console.warn(`${logPrefix} full screen: this browser has no API`);
        return false;
      }
    } else if (doc.exitFullscreen) {
      await doc.exitFullscreen();
    } else {
      doc.webkitExitFullscreen?.();
    }
    return true;
  } catch (err) {
    console.warn(
      `${logPrefix} full screen: the browser refused (${errorName(err)}).`,
      'Ask for it on a key press or a click.',
    );
    return false;
  }
}

function errorName(err: unknown): string {
  if (err instanceof Error) return `${err.name}: ${err.message}`;
  return String(err);
}

type RatioWindow = {
  devicePixelRatio: number;
  matchMedia?: (query: string) => MediaQueryList;
};

/**
 * Call onChange each time the device pixel ratio changes: a move to a
 * monitor with another ratio, or a browser zoom. Returns a function that
 * stops the watch.
 */
export function watchDevicePixelRatio(
  onChange: () => void,
  win: RatioWindow = window,
): () => void {
  let query: MediaQueryList | null = null;
  const fire = (): void => {
    arm();
    onChange();
  };
  // A media query matches one ratio only. After each change, make a query
  // for the new ratio.
  const arm = (): void => {
    query?.removeEventListener('change', fire);
    query =
      win.matchMedia?.(`(resolution: ${win.devicePixelRatio || 1}dppx)`) ??
      null;
    query?.addEventListener('change', fire);
  };
  arm();
  return () => {
    query?.removeEventListener('change', fire);
    query = null;
  };
}

/**
 * The style.cursor of the canvas. The game sets a cursor mode. The loader
 * option cursorFollowsLock shows the cursor while the pointer is not
 * locked, and hides it while it is locked. Without that option and without
 * the hidden mode, this class does not change the style.
 */
export class CursorStyle {
  private hidden = false;
  private saved = '';

  constructor(
    private readonly canvas: { style: { cursor: string } },
    private readonly followsLock: boolean,
  ) {}

  /** The game turns the hidden mode on or off. */
  setHidden(hidden: boolean, locked = false): void {
    if (hidden === this.hidden) return;
    if (hidden) {
      this.saved = this.canvas.style.cursor;
      this.hidden = true;
      this.canvas.style.cursor = 'none';
    } else {
      this.hidden = false;
      this.canvas.style.cursor = this.saved;
      this.apply(locked);
    }
  }

  /** Set the style for a lock state. The hidden mode keeps the cursor hidden. */
  apply(locked: boolean): void {
    if (this.hidden) {
      this.canvas.style.cursor = 'none';
    } else if (this.followsLock) {
      this.canvas.style.cursor = locked ? 'none' : 'auto';
    }
  }
}

export interface WindowImportsOptions {
  canvas: HTMLCanvasElement;
  cursor: CursorStyle;
  /** events.ts setPointerLock: an exit that the game asks for sends no Escape. */
  setPointerLock: (canvas: HTMLCanvasElement, lock: boolean) => void;
  logPrefix?: string;
}

/** The "env" imports of web_window.zig for the window and cursor modes. */
export function createWindowImports(opts: WindowImportsOptions) {
  const { canvas, cursor, setPointerLock, logPrefix } = opts;
  return {
    jsSetWindowMode: (mode: number): void => {
      void setFullscreen(mode === WINDOW_MODE.fullscreen, document, logPrefix);
    },
    jsGetWindowMode: (): number =>
      isFullscreen() ? WINDOW_MODE.fullscreen : WINDOW_MODE.windowed,
    jsSetCursorMode: (mode: number): void => {
      if (mode === CURSOR_MODE.locked) {
        cursor.setHidden(false, true);
        setPointerLock(canvas, true);
        // Hide the cursor at once, as jsSetPointerLock does.
        cursor.apply(true);
      } else {
        setPointerLock(canvas, false);
        cursor.setHidden(mode === CURSOR_MODE.hidden);
        cursor.apply(false);
      }
    },
    jsCursorLocked: (): number =>
      document.pointerLockElement === canvas ? 1 : 0,
  };
}
