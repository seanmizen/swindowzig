// DOM event forwarding to WASM
//
// Input tracking strategy:
// - Track keys/buttons in Sets to detect stuck inputs on blur/visibility changes
// - Performance: negligible cost (Set operations are O(1), only on input events)
// - Alternative: polling every frame would be wasteful and miss edge cases
// - This approach catches: tab switches, alt-tab, context menus, dev tools opening, etc.

const keysDown = new Set<number>();
const buttonsDown = new Set<number>();

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

  // Keyboard
  window.addEventListener('keydown', (e) => {
    const keycode = e.keyCode || e.which;
    // Use keycode as the stable identifier for tracking
    keysDown.add(keycode);
    updateKeysDisplay();
    wasmExports.swindowzig_event_key?.(keycode, true);
  });

  window.addEventListener('keyup', (e) => {
    const keycode = e.keyCode || e.which;
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

// Map keycodes to readable names
const keyNames: Record<string, string> = {
  '32': 'Space',
  '37': 'Left',
  '38': 'Up',
  '39': 'Right',
  '40': 'Down',
  '87': 'W',
  '65': 'A',
  '83': 'S',
  '68': 'D',
  '16': 'Shift',
  '17': 'Ctrl',
  '18': 'Alt',
};

function updateKeysDisplay() {
  // Keys are tracked in keysDown Set for blur detection
  // Display handled by WASM debug info (if enabled)
}
