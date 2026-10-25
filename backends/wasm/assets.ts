// Asynchronous byte loading for the Zig side (libs/sw_assets/src/assets.zig).
//
// `jsFetchStart` begins a `fetch` and returns a request id. Zig polls with
// `jsFetchPoll` each frame, so a frame never waits. A relative URL resolves
// against the page. Nothing here throws into the wasm code: a failure becomes
// a negative return code.

// Return codes of jsFetchPoll. They match assets.zig.
const PENDING = -1;
const NETWORK_FAILED = -2;
const HTTP_ERROR = -3;
const NOT_FOUND = -4;
const TOO_LARGE = -5;

type Entry =
  | { state: 'pending' }
  | { state: 'ready'; bytes: Uint8Array }
  | { state: 'failed'; code: number };

export function createAssetImports(getMemory: () => WebAssembly.Memory) {
  const entries = new Map<number, Entry>();
  let nextId = 1;

  const readUrl = (ptr: number, len: number) =>
    new TextDecoder().decode(new Uint8Array(getMemory().buffer, ptr, len));

  return {
    jsFetchStart: (urlPtr: number, urlLen: number, maxSize: number): number => {
      const id = nextId++;
      const entry: Entry = { state: 'pending' };
      entries.set(id, entry);
      const finish = (next: Entry) => {
        // The Zig side may have dropped the request already.
        if (entries.get(id) === entry) entries.set(id, next);
      };
      fetch(readUrl(urlPtr, urlLen))
        .then(async (response) => {
          if (!response.ok) {
            finish({
              state: 'failed',
              code: response.status === 404 ? NOT_FOUND : HTTP_ERROR,
            });
            return;
          }
          const buffer = await response.arrayBuffer();
          if (buffer.byteLength > maxSize) {
            finish({ state: 'failed', code: TOO_LARGE });
            return;
          }
          finish({ state: 'ready', bytes: new Uint8Array(buffer) });
        })
        .catch(() => finish({ state: 'failed', code: NETWORK_FAILED }));
      return id;
    },
    jsFetchPoll: (id: number): number => {
      const entry = entries.get(id);
      if (!entry) return NETWORK_FAILED;
      if (entry.state === 'pending') return PENDING;
      if (entry.state === 'failed') return entry.code;
      return entry.bytes.length;
    },
    jsFetchTake: (id: number, dst: number) => {
      const entry = entries.get(id);
      if (entry?.state === 'ready') {
        new Uint8Array(getMemory().buffer, dst, entry.bytes.length).set(
          entry.bytes,
        );
      }
      entries.delete(id);
    },
    jsFetchDrop: (id: number) => {
      entries.delete(id);
    },
  };
}
