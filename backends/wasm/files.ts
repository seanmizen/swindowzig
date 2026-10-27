// Files from the player and the data cache, for the Zig side
// (libs/sw_assets/src/files.zig, cache.zig and web_blob.zig). The wasm
// import module is "files".
//
// A player file and a cache value are both a Blob here. Zig asks for the
// size, allocates a buffer, and JS copies the blob into it in chunks
// (Blob.stream). So JS never holds a second full copy of a large file.
//
// The cache is in OPFS (navigator.storage.getDirectory). OPFS needs a secure
// context: on another page each cache request fails with INSECURE, and the
// console tells why (REQ-ASSETS-002). Nothing here throws into the wasm
// code: a failure is a negative return code.

// Return codes. They match libs/sw_assets/src/web_blob.zig.
const PENDING = -1;
const MISSING = -2;
const FAILED = -3;
const TOO_LARGE = -4;
const INSECURE = -5;
const UNAVAILABLE = -6;
const NO_SPACE = -7;

/// The OPFS folder of the cache.
export const CACHE_DIR = 'swindowzig-cache';

type Copy = 'none' | 'pending' | 'done' | number;

type Entry =
  | { state: 'pending' }
  | { state: 'blob'; blob: Blob; name: string; copy: Copy }
  | { state: 'done' }
  | { state: 'failed'; code: number };

// The files that the player gave, in order. One wasm program runs on a page,
// so the queue is for the page.
const inbox: File[] = [];

/**
 * Give files to the game. The drop handler and the file chooser call this.
 * A page with its own file input can call it too. The game gets the files
 * one at a time from files.poll().
 */
export function offerFiles(files: Iterable<File> | ArrayLike<File>): void {
  for (const file of Array.from(files)) inbox.push(file);
}

/**
 * Give the files that the player drops on `target` to the game. Without
 * this, a dropped file makes the browser leave the page.
 */
export function attachFileDrop(target: EventTarget): void {
  const hasFiles = (e: Event): boolean =>
    (e as DragEvent).dataTransfer?.types.includes('Files') ?? false;
  target.addEventListener('dragover', (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    const dt = (e as DragEvent).dataTransfer;
    if (dt) dt.dropEffect = 'copy';
  });
  target.addEventListener('drop', (e) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    const files = (e as DragEvent).dataTransfer?.files;
    if (files) offerFiles(files);
  });
}

let picker: HTMLInputElement | null = null;

/** Open the file chooser. Returns false when the page has no document. */
function showPicker(accept: string): boolean {
  if (typeof document === 'undefined') return false;
  if (!picker) {
    picker = document.createElement('input');
    picker.type = 'file';
    picker.multiple = true;
    picker.style.display = 'none';
    picker.addEventListener('change', () => {
      if (picker?.files) offerFiles(picker.files);
      // Clear the value, so the same file can be chosen again.
      if (picker) picker.value = '';
    });
    document.body.appendChild(picker);
  }
  picker.accept = accept;
  try {
    // The browser opens the chooser only after a recent click or key press.
    picker.click();
    return true;
  } catch {
    return false;
  }
}

export interface FileImportOptions {
  /** True when the page is a secure context. The default reads the page. */
  isSecureContext?: () => boolean;
  /** The OPFS root folder. The default is navigator.storage.getDirectory. */
  getDirectory?: () => Promise<FileSystemDirectoryHandle>;
}

let insecureWarned = false;

export function createFileImports(
  getMemory: () => WebAssembly.Memory,
  options: FileImportOptions = {},
) {
  const entries = new Map<number, Entry>();
  let nextId = 1;
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();

  // A view of wasm memory. A pointer arrives as an i32, so `>>> 0` makes it
  // unsigned. Zig gives a non-null pointer with no meaning for a zero
  // length, so a zero length gets an empty view.
  const view = (ptr: number, len: number): Uint8Array =>
    len === 0
      ? new Uint8Array(0)
      : new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0);
  const readText = (ptr: number, len: number): string =>
    decoder.decode(view(ptr, len));

  const isSecure =
    options.isSecureContext ??
    (() =>
      (globalThis as { isSecureContext?: boolean }).isSecureContext === true);

  const add = (entry: Entry): number => {
    const id = nextId++;
    entries.set(id, entry);
    return id;
  };
  // The Zig side may have dropped the entry already.
  const finish = (id: number, from: Entry, to: Entry): void => {
    if (entries.get(id) === from) entries.set(id, to);
  };

  // The cache folder, or a return code when OPFS is not available.
  const cacheDir = async (): Promise<FileSystemDirectoryHandle | number> => {
    if (!isSecure()) {
      if (!insecureWarned) {
        insecureWarned = true;
        console.error(
          '[swindowzig] The cache needs a secure context (HTTPS or http://localhost). This page is not in a secure context, so the browser does not give OPFS.',
        );
      }
      return INSECURE;
    }
    const getDirectory =
      options.getDirectory ??
      (typeof navigator !== 'undefined' && navigator.storage?.getDirectory
        ? () => navigator.storage.getDirectory()
        : null);
    if (!getDirectory) return UNAVAILABLE;
    try {
      const root = await getDirectory();
      return await root.getDirectoryHandle(CACHE_DIR, { create: true });
    } catch {
      return UNAVAILABLE;
    }
  };

  const errorCode = (err: unknown): number => {
    const name = (err as { name?: string } | null)?.name;
    if (name === 'NotFoundError') return MISSING;
    if (name === 'QuotaExceededError') return NO_SPACE;
    return FAILED;
  };

  // Start an async cache operation. Its entry is pending until it ends.
  const cacheOp = (
    run: (dir: FileSystemDirectoryHandle) => Promise<Entry>,
  ): number => {
    const entry: Entry = { state: 'pending' };
    const id = add(entry);
    cacheDir()
      .then(async (dir) => {
        if (typeof dir === 'number') {
          finish(id, entry, { state: 'failed', code: dir });
          return;
        }
        finish(id, entry, await run(dir));
      })
      .catch((err) =>
        finish(id, entry, { state: 'failed', code: errorCode(err) }),
      );
    return id;
  };

  // Copy the blob into wasm memory at dst, one chunk at a time. The wasm
  // memory can grow between chunks, so get its buffer for each chunk.
  const copyBlob = async (
    id: number,
    entry: Extract<Entry, { state: 'blob' }>,
    dst: number,
  ): Promise<void> => {
    const alive = () => entries.get(id) === entry;
    try {
      const reader = entry.blob.stream().getReader();
      let offset = 0;
      for (;;) {
        const { done, value } = await reader.read();
        if (!alive()) {
          await reader.cancel();
          return;
        }
        if (done) break;
        if (offset + value.length > entry.blob.size) {
          entry.copy = FAILED;
          return;
        }
        view(dst + offset, value.length).set(value);
        offset += value.length;
      }
      entry.copy = offset === entry.blob.size ? 'done' : FAILED;
    } catch {
      if (alive()) entry.copy = FAILED;
    }
  };

  return {
    jsFileNext: (): number => {
      const file = inbox.shift();
      if (!file) return 0;
      return add({ state: 'blob', blob: file, name: file.name, copy: 'none' });
    },
    jsFilePicker: (acceptPtr: number, acceptLen: number): number =>
      showPicker(readText(acceptPtr, acceptLen)) ? 1 : 0,
    jsBlobPoll: (id: number, maxSize: number): number => {
      const entry = entries.get(id);
      if (!entry) return FAILED;
      switch (entry.state) {
        case 'pending':
          return PENDING;
        case 'failed':
          return entry.code;
        case 'done':
          return 0;
        case 'blob':
          return entry.blob.size > maxSize ? TOO_LARGE : entry.blob.size;
      }
    },
    jsBlobName: (id: number, dst: number, cap: number): number => {
      const entry = entries.get(id);
      if (entry?.state !== 'blob') return 0;
      return encoder.encodeInto(entry.name, view(dst, cap)).written;
    },
    jsBlobRead: (id: number, dst: number): void => {
      const entry = entries.get(id);
      if (entry?.state !== 'blob' || entry.copy !== 'none') return;
      entry.copy = 'pending';
      void copyBlob(id, entry, dst >>> 0);
    },
    jsBlobReadPoll: (id: number): number => {
      const entry = entries.get(id);
      if (entry?.state !== 'blob') return FAILED;
      if (entry.copy === 'done') return 0;
      if (entry.copy === 'pending') return PENDING;
      if (entry.copy === 'none') return FAILED;
      return entry.copy;
    },
    jsBlobDrop: (id: number): void => {
      entries.delete(id);
    },
    jsCacheOpen: (namePtr: number, nameLen: number): number => {
      const name = readText(namePtr, nameLen);
      return cacheOp(async (dir) => {
        try {
          const handle = await dir.getFileHandle(name);
          const file = await handle.getFile();
          return { state: 'blob', blob: file, name, copy: 'none' };
        } catch (err) {
          return { state: 'failed', code: errorCode(err) };
        }
      });
    },
    jsCacheWrite: (
      namePtr: number,
      nameLen: number,
      ptr: number,
      len: number,
    ): number => {
      const name = readText(namePtr, nameLen);
      // Copy now: the Zig side can change or free the bytes after the call.
      const bytes = view(ptr, len).slice();
      return cacheOp(async (dir) => {
        try {
          const handle = await dir.getFileHandle(name, { create: true });
          // A writable writes to a swap file. close() replaces the old
          // value, so a stop in the middle leaves the old value.
          const writable = await handle.createWritable();
          await writable.write(bytes);
          await writable.close();
          return { state: 'done' };
        } catch (err) {
          const code = errorCode(err);
          return { state: 'failed', code: code === MISSING ? FAILED : code };
        }
      });
    },
    jsCacheDelete: (namePtr: number, nameLen: number): number => {
      const name = readText(namePtr, nameLen);
      return cacheOp(async (dir) => {
        try {
          await dir.removeEntry(name);
          return { state: 'done' };
        } catch (err) {
          const code = errorCode(err);
          // A name with no value is not an error.
          return code === MISSING
            ? { state: 'done' }
            : { state: 'failed', code };
        }
      });
    },
  };
}
