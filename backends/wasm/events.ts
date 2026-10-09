// DOM event forwarding to WASM
//
// Input tracking strategy:
// - Track keys/buttons in Sets to detect stuck inputs on blur/visibility changes
// - Performance: negligible cost (Set operations are O(1), only on input events)
// - Alternative: polling every frame would be wasteful and miss edge cases
// - This approach catches: tab switches, alt-tab, context menus, dev tools opening, etc.

const keysDown = new Set<number>();
const buttonsDown = new Set<number>();
let pointerLocked = false;

// Text input (IME) strategy:
// - A hidden <input> takes focus while the game has text input on. The
//   browser then runs the platform input method (dead keys, IME) on it.
// - compositionupdate -> text_composition; compositionend and plain input
//   -> text_input. Input events inside a composition are ignored, because
//   the composition events already carry that text.
// - Printable keys do not become key events while text input is on.

const encoder = new TextEncoder();
let textInputActive = false;
let applyTextInput: ((active: boolean) => void) | null = null;

/** Imported by WASM as env.jsSetTextInput. Safe to call before attach. */
export function setTextInputActive(active: boolean) {
  textInputActive = active;
  applyTextInput?.(active);
}

/** Does this key press make text? True also for dead keys and IME keys. */
function isTextKey(e: KeyboardEvent): boolean {
  if (e.isComposing || e.keyCode === 229 || e.key === 'Dead') return true;
  if (e.ctrlKey || e.metaKey) return false;
  // One code point: a letter, digit, symbol or space. Not "Enter", "Tab"...
  return [...e.key].length === 1;
}

/** Split `text` into UTF-8 chunks of at most `max` bytes, on code points. */
export function utf8Chunks(text: string, max: number): Uint8Array[] {
  const bytes = encoder.encode(text);
  const chunks: Uint8Array[] = [];
  let start = 0;
  while (start < bytes.length) {
    let end = Math.min(start + max, bytes.length);
    // 0b10xxxxxx is a continuation byte: step back to the lead byte.
    while (end < bytes.length && end > start && (bytes[end] & 0xc0) === 0x80) {
      end--;
    }
    if (end === start) break;
    chunks.push(bytes.subarray(start, end));
    start = end;
  }
  return chunks;
}

export interface WasmExports {
  swindowzig_init: () => void;
  swindowzig_frame: (timestamp: number) => void;
  swindowzig_event_resize?: (
    width: number,
    height: number,
    dpiScale: number,
  ) => void;
  swindowzig_event_mouse_move?: (
    x: number,
    y: number,
    dx: number,
    dy: number,
  ) => void;
  swindowzig_event_mouse_button?: (button: number, down: boolean) => void;
  swindowzig_event_key?: (keycode: number, down: boolean) => void;
  swindowzig_text_buffer_ptr?: () => number;
  swindowzig_text_buffer_len?: () => number;
  swindowzig_event_text_input?: (len: number) => void;
  swindowzig_event_text_composition?: (
    len: number,
    cursor: number,
    selectionLen: number,
  ) => void;
  memory?: WebAssembly.Memory;
}

export interface EventListenerConfig {
  disableContextMenu?: boolean;
}

export function attachEventListeners(
  canvas: HTMLCanvasElement,
  wasmExports: WasmExports,
  config: EventListenerConfig = {},
) {
  // Use window for mouse events if canvas is hidden (debug viewer)
  const canvasVisible = canvas.offsetParent !== null;
  const mouseTarget = canvasVisible ? canvas : window;

  // Prevent context menu on right-click (if configured)
  const { disableContextMenu = true } = config;
  if (disableContextMenu) {
    const preventContextMenu = (e: Event) => {
      e.preventDefault();
    };
    canvas.addEventListener('contextmenu', preventContextMenu);
    window.addEventListener('contextmenu', preventContextMenu);
  }

  // Mouse move
  mouseTarget.addEventListener('mousemove', (e: Event) => {
    const mouseEvent = e as MouseEvent;
    let x: number, y: number;
    if (canvasVisible) {
      const rect = canvas.getBoundingClientRect();
      x = mouseEvent.clientX - rect.left;
      y = mouseEvent.clientY - rect.top;
    } else {
      x = mouseEvent.clientX;
      y = mouseEvent.clientY;
    }
    const dx = mouseEvent.movementX;
    const dy = mouseEvent.movementY;
    wasmExports.swindowzig_event_mouse_move?.(x, y, dx, dy);
  });

  // Mouse buttons
  mouseTarget.addEventListener('mousedown', (e: Event) => {
    const mouseEvent = e as MouseEvent;
    buttonsDown.add(mouseEvent.button);
    wasmExports.swindowzig_event_mouse_button?.(mouseEvent.button, true);
  });

  mouseTarget.addEventListener('mouseup', (e: Event) => {
    const mouseEvent = e as MouseEvent;
    buttonsDown.delete(mouseEvent.button);
    wasmExports.swindowzig_event_mouse_button?.(mouseEvent.button, false);
  });

  // Track pointer lock state — when locked, the game has focus and we
  // block browser shortcuts. When unlocked (pause menu), browser defaults work.
  document.addEventListener('pointerlockchange', () => {
    pointerLocked = document.pointerLockElement === canvas;
  });

  attachTextInput(wasmExports);

  // Keyboard — prevent browser defaults only while pointer is locked (gameplay).
  // When the pause menu is open (pointer unlocked), browser shortcuts work normally.
  window.addEventListener('keydown', (e) => {
    // While text input is on, the hidden <input> handles printable keys.
    // Backspace, Enter, arrows and the like still reach the game.
    if (textInputActive && isTextKey(e)) return;
    if (pointerLocked) {
      e.preventDefault();
    }
    const keycode = e.keyCode || e.which;
    // Use keycode as the stable identifier for tracking
    keysDown.add(keycode);
    updateKeysDisplay();
    wasmExports.swindowzig_event_key?.(keycode, true);
  });

  window.addEventListener('keyup', (e) => {
    const keycode = e.keyCode || e.which;
    // Release a key the game saw go down, even if it is a text key now.
    if (!keysDown.has(keycode) && textInputActive && isTextKey(e)) return;
    keysDown.delete(keycode);
    updateKeysDisplay();
    wasmExports.swindowzig_event_key?.(keycode, false);
  });

  // Release all keys and buttons when window loses focus - prevents stuck inputs
  // This is critical because the browser won't fire keyup/mouseup if you switch tabs/apps
  // while holding a key or button (e.g., right-click opens context menu = focus loss)
  const releaseAllInputs = () => {
    // Release all keys
    for (const keycode of keysDown) {
      wasmExports.swindowzig_event_key?.(keycode, false);
    }
    keysDown.clear();
    updateKeysDisplay();

    // Release all mouse buttons
    for (const button of buttonsDown) {
      wasmExports.swindowzig_event_mouse_button?.(button, false);
    }
    buttonsDown.clear();
  };

  window.addEventListener('blur', releaseAllInputs);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      releaseAllInputs();
    }
  });

  // Resize is handled in boot.ts via window resize listener
}

function attachTextInput(wasmExports: WasmExports) {
  const input = document.createElement('input');
  input.type = 'text';
  input.setAttribute('aria-hidden', 'true');
  input.tabIndex = -1;
  input.autocomplete = 'off';
  input.autocapitalize = 'off';
  input.spellcheck = false;
  input.setAttribute('autocorrect', 'off');
  // Not display:none: a hidden element cannot take focus. 16px font stops
  // iOS from zooming in on focus.
  Object.assign(input.style, {
    position: 'fixed',
    left: '0',
    top: '0',
    width: '1px',
    height: '1px',
    padding: '0',
    border: '0',
    opacity: '0',
    pointerEvents: 'none',
    fontSize: '16px',
  });
  document.body.appendChild(input);

  // Write UTF-8 into the WASM text buffer, then call the export.
  const send = (
    text: string,
    call: (len: number) => void,
    maxBytes: number,
  ) => {
    const ptr = wasmExports.swindowzig_text_buffer_ptr?.();
    const memory = wasmExports.memory;
    if (ptr === undefined || !memory) return;
    const capacity = wasmExports.swindowzig_text_buffer_len?.() ?? 0;
    for (const chunk of utf8Chunks(text, Math.min(capacity, maxBytes))) {
      new Uint8Array(memory.buffer, ptr, chunk.length).set(chunk);
      call(chunk.length);
    }
  };

  const sendCommitted = (text: string) => {
    if (!text) return;
    send(text, (len) => wasmExports.swindowzig_event_text_input?.(len), 256);
  };

  const sendComposition = (text: string) => {
    const bytes = encoder.encode(text).length;
    // The browser does not tell where the caret is inside a composition:
    // put it at the end, with no selection.
    const ptr = wasmExports.swindowzig_text_buffer_ptr?.();
    const memory = wasmExports.memory;
    if (ptr === undefined || !memory) return;
    const capacity = wasmExports.swindowzig_text_buffer_len?.() ?? 0;
    const chunk = utf8Chunks(text, capacity)[0] ?? new Uint8Array(0);
    new Uint8Array(memory.buffer, ptr, chunk.length).set(chunk);
    wasmExports.swindowzig_event_text_composition?.(
      chunk.length,
      Math.min(bytes, chunk.length),
      0,
    );
  };

  input.addEventListener('compositionupdate', (e) => {
    sendComposition((e as CompositionEvent).data ?? '');
  });

  input.addEventListener('compositionend', (e) => {
    // End the composition, then commit what the user accepted.
    sendComposition('');
    sendCommitted((e as CompositionEvent).data ?? '');
    // The browser may still fire an input event for this text. It is
    // ignored below (isComposing or a composition inputType).
    setTimeout(() => {
      input.value = '';
    }, 0);
  });

  input.addEventListener('input', (e) => {
    const ie = e as InputEvent;
    // Composition text comes from the composition events.
    if (
      ie.isComposing ||
      ie.inputType === 'insertCompositionText' ||
      ie.inputType === 'insertFromComposition'
    ) {
      return;
    }
    // Typed text has e.data. A paste has only the value.
    sendCommitted(ie.data ?? input.value);
    input.value = '';
  });

  // A click on the canvas moves focus away. Take it back.
  input.addEventListener('blur', () => {
    if (textInputActive) {
      setTimeout(() => {
        if (textInputActive) input.focus({ preventScroll: true });
      }, 0);
    }
  });

  applyTextInput = (active: boolean) => {
    if (active) {
      input.value = '';
      input.focus({ preventScroll: true });
    } else {
      input.value = '';
      input.blur();
    }
  };
  applyTextInput(textInputActive);
}

function updateKeysDisplay() {
  // Keys are tracked in keysDown Set for blur detection
  // Display handled by WASM debug info (if enabled)
}
