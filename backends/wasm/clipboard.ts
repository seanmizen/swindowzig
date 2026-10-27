// The clipboard of the web backend (libs/sw_platform/src/web_window.zig).
//
// Each operation completes later. The result goes to the wasm as a
// clipboard event (REQ-PLATFORM-002):
// - Write: navigator.clipboard.writeText. Without the Clipboard API (a page
//   that is not a secure context) it uses document.execCommand('copy').
// - Read: navigator.clipboard.readText. The browser can ask the user for a
//   permission, and can refuse.
// - Paste: the user pastes (Ctrl+V or Cmd+V) into the hidden text <input>.
//   The browser gives the text in the paste event, with no permission. The
//   wasm gets the text before the frame that sees the key.
//
// When the browser refuses, the console tells why, and the event has the
// status `denied` or `unavailable`. The game continues.

/** The numbers of core.ClipboardEventKind (libs/sw_core/src/event.zig). */
export const CLIPBOARD_KIND = { paste: 0, read: 1, write: 2 } as const;
/** The numbers of core.ClipboardStatus (libs/sw_core/src/event.zig). */
export const CLIPBOARD_STATUS = {
  ok: 0,
  unavailable: 1,
  denied: 2,
  noText: 3,
  failed: 4,
} as const;

export interface ClipboardExports {
  memory: WebAssembly.Memory;
  swindowzig_clipboard_reserve?: (len: number) => number;
  swindowzig_clipboard_event?: (
    kind: number,
    status: number,
    len: number,
  ) => void;
}

/** What the clipboard code needs from the browser. Tests give a fake. */
export interface ClipboardHost {
  clipboard?: {
    writeText?: (text: string) => Promise<void>;
    readText?: () => Promise<string>;
  };
  /** document.execCommand('copy') of a temporary text area. */
  copyFallback?: (text: string) => boolean;
  isSecureContext: boolean;
  warn: (...args: unknown[]) => void;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** The status for an error of the Clipboard API. */
export function clipboardStatusOf(err: unknown): number {
  const name = err instanceof Error ? err.name : '';
  if (name === 'NotAllowedError' || name === 'SecurityError') {
    return CLIPBOARD_STATUS.denied;
  }
  return CLIPBOARD_STATUS.failed;
}

/** A message that tells the developer why the browser refused. */
function refusalMessage(op: string, err: unknown, secure: boolean): string {
  const why = err instanceof Error ? `${err.name}: ${err.message}` : err;
  const hint = secure
    ? 'The page must have the focus, and the call must follow a key press or a click.'
    : 'The page is not a secure context. Use https or localhost.';
  return `clipboard ${op}: the browser refused (${why}). ${hint}`;
}

/**
 * Give text to the wasm and send the event. `text` null sends the event
 * with no text.
 */
export function deliverClipboard(
  exports: ClipboardExports | null,
  kind: number,
  status: number,
  text: string | null,
): void {
  if (!exports?.swindowzig_clipboard_event) return;
  if (status !== CLIPBOARD_STATUS.ok || text === null) {
    exports.swindowzig_clipboard_event(kind, status, 0);
    return;
  }
  if (text.length === 0) {
    exports.swindowzig_clipboard_event(kind, CLIPBOARD_STATUS.noText, 0);
    return;
  }
  const bytes = encoder.encode(text);
  const ptr = exports.swindowzig_clipboard_reserve?.(bytes.length) ?? 0;
  if (ptr === 0) {
    // Larger than the limit of clipboard.zig, or no memory.
    exports.swindowzig_clipboard_event(kind, CLIPBOARD_STATUS.noText, 0);
    return;
  }
  // Reserve can grow the memory: read the buffer after it.
  new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes);
  exports.swindowzig_clipboard_event(kind, CLIPBOARD_STATUS.ok, bytes.length);
}

/** The state that the imports and the paste listener share. */
export class WebClipboard {
  exports: ClipboardExports | null = null;
  /** setPasteAsText: false stops the paste from typing into the input. */
  pasteAsText = true;

  constructor(
    private readonly host: ClipboardHost,
    private readonly logPrefix = '[swindowzig]',
  ) {}

  private deliver(kind: number, status: number, text: string | null): void {
    deliverClipboard(this.exports, kind, status, text);
  }

  private warn(op: string, err: unknown): void {
    this.host.warn(
      `${this.logPrefix} ${refusalMessage(op, err, this.host.isSecureContext)}`,
    );
  }

  /** Write text. The result arrives as a write event. */
  write(text: string): Promise<void> {
    const kind = CLIPBOARD_KIND.write;
    const api = this.host.clipboard?.writeText;
    if (!api) {
      const ok = this.host.copyFallback?.(text) ?? false;
      if (!ok) this.warn('write', new Error('no Clipboard API'));
      const status = ok ? CLIPBOARD_STATUS.ok : CLIPBOARD_STATUS.unavailable;
      return Promise.resolve().then(() => this.deliver(kind, status, null));
    }
    let p: Promise<void>;
    try {
      p = Promise.resolve(api.call(this.host.clipboard, text));
    } catch (err) {
      p = Promise.reject(err);
    }
    return p.then(
      () => this.deliver(kind, CLIPBOARD_STATUS.ok, null),
      (err: unknown) => {
        // Safari can refuse writeText after a key press. execCommand can
        // still copy in the same frame.
        if (this.host.copyFallback?.(text)) {
          this.deliver(kind, CLIPBOARD_STATUS.ok, null);
          return;
        }
        this.warn('write', err);
        this.deliver(kind, clipboardStatusOf(err), null);
      },
    );
  }

  /** Read text. The result arrives as a read event. */
  read(): Promise<void> {
    const kind = CLIPBOARD_KIND.read;
    const api = this.host.clipboard?.readText;
    if (!api) {
      this.warn('read', new Error('no Clipboard API'));
      return Promise.resolve().then(() =>
        this.deliver(kind, CLIPBOARD_STATUS.unavailable, null),
      );
    }
    let p: Promise<string>;
    try {
      p = Promise.resolve(api.call(this.host.clipboard));
    } catch (err) {
      p = Promise.reject(err);
    }
    return p.then(
      (text) => this.deliver(kind, CLIPBOARD_STATUS.ok, text),
      (err: unknown) => {
        this.warn('read', err);
        this.deliver(kind, clipboardStatusOf(err), null);
      },
    );
  }

  /**
   * A paste event of the page. Returns true when the default action must
   * stop: the game reads the paste from the clipboard event only.
   */
  paste(text: string, intoTextInput: boolean): boolean {
    this.deliver(CLIPBOARD_KIND.paste, CLIPBOARD_STATUS.ok, text);
    return intoTextInput && !this.pasteAsText;
  }

  /** The "env" imports of web_window.zig for the clipboard. */
  imports(getMemory: () => WebAssembly.Memory) {
    return {
      jsClipboardWrite: (ptr: number, len: number): void => {
        const bytes = new Uint8Array(getMemory().buffer, ptr, len);
        // Copy the text now: the wasm can change the bytes after the call.
        void this.write(decoder.decode(bytes.slice()));
      },
      jsClipboardRead: (): void => {
        void this.read();
      },
      jsSetPasteAsText: (on: number): void => {
        this.pasteAsText = on !== 0;
      },
    };
  }
}

/** Copy with document.execCommand: the fallback with no Clipboard API. */
export function execCommandCopy(text: string): boolean {
  const area = document.createElement('textarea');
  area.value = text;
  area.setAttribute('aria-hidden', 'true');
  Object.assign(area.style, { position: 'fixed', left: '-9999px', top: '0' });
  const previous = document.activeElement as HTMLElement | null;
  document.body.appendChild(area);
  area.select();
  let ok = false;
  try {
    ok = document.execCommand('copy');
  } catch {
    ok = false;
  }
  area.remove();
  previous?.focus?.({ preventScroll: true });
  return ok;
}

/** The clipboard of a browser page. */
export function browserClipboard(logPrefix?: string): WebClipboard {
  return new WebClipboard(
    {
      clipboard: navigator.clipboard,
      copyFallback: execCommandCopy,
      isSecureContext: window.isSecureContext,
      warn: (...args) => console.warn(...args),
    },
    logPrefix,
  );
}

/**
 * Send each paste of the page to the wasm. `isTextInput` tells if the
 * target is the hidden text <input> of events.ts.
 */
export function attachPasteListener(
  clip: WebClipboard,
  isTextInput: (target: EventTarget | null) => boolean,
): void {
  document.addEventListener(
    'paste',
    (e: ClipboardEvent) => {
      const text = e.clipboardData?.getData('text/plain') ?? '';
      if (clip.paste(text, isTextInput(e.target))) e.preventDefault();
    },
    { capture: true },
  );
}
