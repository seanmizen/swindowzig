// DOM event forwarding to WASM
import { setKeysPressed, setMousePos } from './webgpu';

const keysDown = new Set<number>();

export function attachEventListeners(
  canvas: HTMLCanvasElement,
  wasmExports: any,
) {
  // Mouse move
  canvas.addEventListener('mousemove', (e) => {
    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    const dx = e.movementX;
    const dy = e.movementY;
    setMousePos(x, y);
    wasmExports.swindowzig_event_mouse_move?.(x, y, dx, dy);
  });

  // Mouse buttons
  canvas.addEventListener('mousedown', (e) => {
    wasmExports.swindowzig_event_mouse_button?.(e.button, true);
  });

  canvas.addEventListener('mouseup', (e) => {
    wasmExports.swindowzig_event_mouse_button?.(e.button, false);
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

  // Release all keys when window loses focus - prevents stuck keys
  // This is critical because the browser won't fire keyup if you switch tabs/apps
  // while holding a key
  const releaseAllKeys = () => {
    for (const keycode of keysDown) {
      wasmExports.swindowzig_event_key?.(keycode, false);
    }
    keysDown.clear();
    updateKeysDisplay();
  };

  window.addEventListener('blur', releaseAllKeys);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      releaseAllKeys();
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
  const keys = Array.from(keysDown)
    .map((code) => keyNames[String(code)] || String(code))
    .join(', ');
  setKeysPressed(keys);
}
