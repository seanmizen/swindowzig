// Local key-value storage for the Zig side (libs/sw_platform/src/storage.zig).
//
// Values are bytes. localStorage holds strings, so each value is base64. Every
// call is in try/catch: localStorage throws when the browser blocks it
// (private mode, site data off) and when the quota is full. Then the call
// returns an error code and the game continues.

const PREFIX = 'swindowzig:';

// Return codes. They match storage.zig.
const OK = 0;
const MISSING = -1;
const UNAVAILABLE = -2;

function toBase64(bytes: Uint8Array): string {
  let bin = '';
  // Chunks keep String.fromCharCode under the argument-count limit.
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

function fromBase64(text: string): Uint8Array {
  const bin = atob(text);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function createStorageImports(getMemory: () => WebAssembly.Memory) {
  // The value that jsStorageGet read, until jsStorageTake copies it.
  let pending: Uint8Array | null = null;

  const readKey = (ptr: number, len: number) =>
    new TextDecoder().decode(new Uint8Array(getMemory().buffer, ptr, len));

  return {
    jsStorageGet: (keyPtr: number, keyLen: number): number => {
      pending = null;
      try {
        const text = window.localStorage.getItem(
          PREFIX + readKey(keyPtr, keyLen),
        );
        if (text === null) return MISSING;
        pending = fromBase64(text);
        return pending.length;
      } catch {
        return UNAVAILABLE;
      }
    },
    jsStorageTake: (dst: number) => {
      if (!pending) return;
      new Uint8Array(getMemory().buffer, dst, pending.length).set(pending);
      pending = null;
    },
    jsStorageSet: (
      keyPtr: number,
      keyLen: number,
      valPtr: number,
      valLen: number,
    ): number => {
      try {
        const bytes = new Uint8Array(getMemory().buffer, valPtr, valLen);
        window.localStorage.setItem(
          PREFIX + readKey(keyPtr, keyLen),
          toBase64(bytes),
        );
        return OK;
      } catch {
        return UNAVAILABLE;
      }
    },
    jsStorageDelete: (keyPtr: number, keyLen: number): number => {
      try {
        window.localStorage.removeItem(PREFIX + readKey(keyPtr, keyLen));
        return OK;
      } catch {
        return UNAVAILABLE;
      }
    },
  };
}
