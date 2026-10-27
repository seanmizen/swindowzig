// Player files and the cache: the Zig side (libs/sw_assets, built as
// libs/sw_assets/src/wasm_check.zig) with the JS bridge (files.ts).
// Run with `bun test backends/wasm/files.test.ts`. Zig must be on the PATH.
import { beforeAll, describe, expect, test } from 'bun:test';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  attachFileDrop,
  CACHE_DIR,
  createFileImports,
  type FileImportOptions,
  offerFiles,
} from './files';

const root = join(import.meta.dir, '../..');
let module: WebAssembly.Module;

beforeAll(() => {
  const out = join(mkdtempSync(join(tmpdir(), 'sw-files-')), 'check.wasm');
  const build = Bun.spawnSync(
    [
      'zig',
      'build-exe',
      '-target',
      'wasm32-freestanding',
      '-fno-entry',
      '-rdynamic',
      '--dep',
      'sw_assets',
      `-Mroot=${join(root, 'libs/sw_assets/src/wasm_check.zig')}`,
      `-Msw_assets=${join(root, 'libs/sw_assets/src/assets_root.zig')}`,
      `-femit-bin=${out}`,
    ],
    { cwd: root },
  );
  if (build.exitCode !== 0) throw new Error(build.stderr.toString());
  module = new WebAssembly.Module(readFileSync(out));
});

type Check = {
  memory: WebAssembly.Memory;
  check_alloc(len: number): number;
  check_out_ptr(): number;
  check_out_len(): number;
  check_name_ptr(): number;
  check_name_len(): number;
  check_zip(ptr: number, len: number): number;
  check_picker(ptr: number, len: number): number;
  check_file_poll(): number;
  check_cache_write(np: number, nl: number, p: number, l: number): void;
  check_cache_delete(np: number, nl: number): void;
  check_cache_write_poll(): number;
  check_cache_read(np: number, nl: number): void;
  check_cache_read_cancel(): void;
  check_cache_read_poll(): number;
};

function load(options: FileImportOptions = {}) {
  let memory: WebAssembly.Memory | null = null;
  const files = createFileImports(() => {
    if (!memory) throw new Error('no memory');
    return memory;
  }, options);
  const wasm = new WebAssembly.Instance(module, { files })
    .exports as unknown as Check;
  memory = wasm.memory;

  const put = (bytes: Uint8Array): [number, number] => {
    const ptr = wasm.check_alloc(bytes.length);
    if (bytes.length > 0) {
      new Uint8Array(wasm.memory.buffer, ptr >>> 0, bytes.length).set(bytes);
    }
    return [ptr, bytes.length];
  };
  const text = (s: string) => put(new TextEncoder().encode(s));
  const out = () =>
    wasm.check_out_len() === 0
      ? new Uint8Array(0)
      : new Uint8Array(
          wasm.memory.buffer,
          wasm.check_out_ptr() >>> 0,
          wasm.check_out_len(),
        ).slice();
  const outText = () => new TextDecoder().decode(out());
  const name = () =>
    new TextDecoder().decode(
      new Uint8Array(
        wasm.memory.buffer,
        wasm.check_name_ptr(),
        wasm.check_name_len(),
      ),
    );
  // Poll until the result is not 1 (pending), with a turn of the event
  // loop between polls, like one frame.
  const until = async (poll: () => number): Promise<number> => {
    for (let i = 0; i < 1000; i++) {
      const rc = poll();
      if (rc !== 1) return rc;
      await new Promise((r) => setTimeout(r, 0));
    }
    throw new Error('the request did not finish');
  };
  return { wasm, put, text, out, outText, name, until };
}

/** An OPFS folder in memory, with the methods that files.ts uses. */
function fakeOpfs() {
  const notFound = () => new DOMException('not found', 'NotFoundError');
  const makeDir = () => {
    const files = new Map<string, Uint8Array>();
    const dirs = new Map<string, unknown>();
    return {
      files,
      dirs,
      async getDirectoryHandle(name: string, opts?: { create?: boolean }) {
        if (!dirs.has(name)) {
          if (!opts?.create) throw notFound();
          dirs.set(name, makeDir());
        }
        return dirs.get(name);
      },
      async getFileHandle(name: string, opts?: { create?: boolean }) {
        if (!files.has(name)) {
          if (!opts?.create) throw notFound();
          files.set(name, new Uint8Array());
        }
        return {
          getFile: async () =>
            new File([files.get(name) as Uint8Array<ArrayBuffer>], name),
          createWritable: async () => {
            const parts: Uint8Array[] = [];
            return {
              write: async (b: Uint8Array) => {
                parts.push(b.slice());
              },
              close: async () => {
                files.set(name, Buffer.concat(parts));
              },
            };
          },
        };
      },
      async removeEntry(name: string) {
        if (!files.delete(name)) throw notFound();
      },
    };
  };
  return makeDir();
}

const standardZip = readFileSync(
  join(root, 'libs/sw_assets/testdata/standard.zip'),
);

describe('player files', () => {
  test('a file that the page offers arrives in the game, and the zip reader reads it', async () => {
    const t = load();
    expect(t.wasm.check_file_poll()).toBe(0);
    offerFiles([new File([standardZip], 'pack.zip')]);
    expect(await t.until(() => t.wasm.check_file_poll())).toBe(2);
    expect(t.name()).toBe('pack.zip');
    expect(Buffer.from(t.out()).equals(standardZip)).toBe(true);

    const [ptr, len] = t.put(t.out());
    expect(t.wasm.check_zip(ptr, len)).toBe(4);
    expect(t.outText()).toBe('stored entry\n');
    expect(t.wasm.check_file_poll()).toBe(0);
  });

  test('a large file arrives in chunks while the wasm memory grows', async () => {
    const t = load();
    const big = new Uint8Array(3 * 1024 * 1024 + 17);
    for (let i = 0; i < big.length; i++) big[i] = (i * 7919) & 0xff;
    offerFiles([new File([big], 'big.bin'), new File([], 'empty.bin')]);
    expect(await t.until(() => t.wasm.check_file_poll())).toBe(2);
    expect(t.name()).toBe('big.bin');
    expect(Buffer.from(t.out()).equals(Buffer.from(big))).toBe(true);
    expect(await t.until(() => t.wasm.check_file_poll())).toBe(2);
    expect(t.name()).toBe('empty.bin');
    expect(t.out().length).toBe(0);
  });

  test('a file over the size limit fails with TooLarge', async () => {
    const t = load();
    const huge = { name: 'huge.zip', size: 2 ** 31 } as unknown as File;
    offerFiles([huge]);
    expect(await t.until(() => t.wasm.check_file_poll())).toBe(-1);
    expect(t.outText()).toBe('TooLarge');
  });

  test('a dropped file goes to the game', async () => {
    const t = load();
    const target = new EventTarget();
    attachFileDrop(target);
    const drop = new Event('drop', { cancelable: true });
    Object.defineProperty(drop, 'dataTransfer', {
      value: { types: ['Files'], files: [new File(['abc'], 'a.txt')] },
    });
    target.dispatchEvent(drop);
    expect(drop.defaultPrevented).toBe(true);
    expect(await t.until(() => t.wasm.check_file_poll())).toBe(2);
    expect(t.name()).toBe('a.txt');
    expect(t.outText()).toBe('abc');
  });

  test('the file chooser needs a document', () => {
    const t = load();
    const [ptr, len] = t.text('.zip');
    expect(t.wasm.check_picker(ptr, len)).toBe(0);
  });
});

describe('cache', () => {
  test('write, read, delete in OPFS', async () => {
    const opfs = fakeOpfs();
    const t = load({
      isSecureContext: () => true,
      getDirectory: async () => opfs as unknown as FileSystemDirectoryHandle,
    });
    const [np, nl] = t.text('index-v1');
    const value = new Uint8Array(200_000).map((_, i) => i & 0xff);
    const [vp, vl] = t.put(value);

    t.wasm.check_cache_read(np, nl);
    expect(await t.until(() => t.wasm.check_cache_read_poll())).toBe(3);

    t.wasm.check_cache_write(np, nl, vp, vl);
    // The call copies the bytes before it returns.
    new Uint8Array(t.wasm.memory.buffer, vp, vl).fill(0);
    expect(await t.until(() => t.wasm.check_cache_write_poll())).toBe(2);
    expect(opfs.dirs.has(CACHE_DIR)).toBe(true);

    t.wasm.check_cache_read(np, nl);
    expect(await t.until(() => t.wasm.check_cache_read_poll())).toBe(2);
    expect(Buffer.from(t.out()).equals(Buffer.from(value))).toBe(true);

    // A read that the game stops before the end.
    t.wasm.check_cache_read(np, nl);
    expect(t.wasm.check_cache_read_poll()).toBe(1);
    t.wasm.check_cache_read_cancel();
    await new Promise((r) => setTimeout(r, 10));

    // An empty value.
    const [ep, el] = t.text('empty');
    const [zp, zl] = t.put(new Uint8Array(0));
    t.wasm.check_cache_write(ep, el, zp, zl);
    expect(await t.until(() => t.wasm.check_cache_write_poll())).toBe(2);
    t.wasm.check_cache_read(ep, el);
    expect(await t.until(() => t.wasm.check_cache_read_poll())).toBe(2);
    expect(t.out().length).toBe(0);

    t.wasm.check_cache_delete(np, nl);
    expect(await t.until(() => t.wasm.check_cache_write_poll())).toBe(2);
    t.wasm.check_cache_delete(np, nl);
    expect(await t.until(() => t.wasm.check_cache_write_poll())).toBe(2);
    t.wasm.check_cache_read(np, nl);
    expect(await t.until(() => t.wasm.check_cache_read_poll())).toBe(3);
  });

  test('a page that is not a secure context gets InsecureContext (REQ-ASSETS-002)', async () => {
    const t = load({ isSecureContext: () => false });
    const [np, nl] = t.text('index-v1');
    const [vp, vl] = t.text('value');
    t.wasm.check_cache_write(np, nl, vp, vl);
    expect(await t.until(() => t.wasm.check_cache_write_poll())).toBe(-1);
    expect(t.outText()).toBe('InsecureContext');
    t.wasm.check_cache_read(np, nl);
    expect(await t.until(() => t.wasm.check_cache_read_poll())).toBe(-1);
    expect(t.outText()).toBe('InsecureContext');
  });

  test('a browser with no OPFS gets Unavailable', async () => {
    const t = load({ isSecureContext: () => true });
    const [np, nl] = t.text('index-v1');
    t.wasm.check_cache_read(np, nl);
    expect(await t.until(() => t.wasm.check_cache_read_poll())).toBe(-1);
    expect(t.outText()).toBe('Unavailable');
  });

  test('a bad name fails in Zig', async () => {
    const t = load({ isSecureContext: () => true });
    const [np, nl] = t.text('../x');
    t.wasm.check_cache_read(np, nl);
    expect(t.wasm.check_cache_read_poll()).toBe(-1);
    expect(t.outText()).toBe('InvalidName');
  });
});

// Voxel region files (REQ-VOXEL-011): sw_voxel saves 4 regions to the
// OPFS cache and loads them again. `zig build region-check-wasm` builds
// libs/sw_voxel/testing/region_wasm_check.zig.
describe('voxel region files in OPFS', () => {
  type RegionCheck = {
    memory: WebAssembly.Memory;
    check_out_ptr(): number;
    check_out_len(): number;
    check_region_save(): number;
    check_region_save_poll(): number;
    check_region_load(): number;
    check_region_load_poll(): number;
  };
  let regionModule: WebAssembly.Module;

  beforeAll(() => {
    const prefix = mkdtempSync(join(tmpdir(), 'sw-region-'));
    const build = Bun.spawnSync(
      ['zig', 'build', 'region-check-wasm', '--prefix', prefix],
      { cwd: root },
    );
    if (build.exitCode !== 0) throw new Error(build.stderr.toString());
    regionModule = new WebAssembly.Module(
      readFileSync(join(prefix, 'bin/region_check.wasm')),
    );
  }, 600_000);

  test('a save and a load give the same blocks', async () => {
    const opfs = fakeOpfs();
    let memory: WebAssembly.Memory | null = null;
    const files = createFileImports(
      () => {
        if (!memory) throw new Error('no memory');
        return memory;
      },
      {
        isSecureContext: () => true,
        getDirectory: async () => opfs as unknown as FileSystemDirectoryHandle,
      },
    );
    const wasm = new WebAssembly.Instance(regionModule, { files })
      .exports as unknown as RegionCheck;
    memory = wasm.memory;
    const error = () =>
      new TextDecoder().decode(
        new Uint8Array(
          wasm.memory.buffer,
          wasm.check_out_ptr(),
          wasm.check_out_len(),
        ),
      );
    const until = async (poll: () => number): Promise<number> => {
      for (let i = 0; i < 1000; i++) {
        const rc = poll();
        if (rc !== 1) return rc;
        await new Promise((r) => setTimeout(r, 0));
      }
      throw new Error('the request did not finish');
    };

    // No file yet: the load gives "missing".
    expect(wasm.check_region_load()).toBe(0);
    expect(await until(() => wasm.check_region_load_poll())).toBe(3);

    expect(wasm.check_region_save()).toBe(0);
    const saved = await until(() => wasm.check_region_save_poll());
    expect(saved === 2 ? '' : error()).toBe('');
    const dir = opfs.dirs.get(CACHE_DIR) as { files: Map<string, Uint8Array> };
    expect([...dir.files.keys()].sort()).toEqual([
      'check.r.-1.-1',
      'check.r.-1.0',
      'check.r.0.-1',
      'check.r.0.0',
    ]);

    expect(wasm.check_region_load()).toBe(0);
    const loaded = await until(() => wasm.check_region_load_poll());
    expect(loaded === 2 ? '' : `${loaded} ${error()}`).toBe('');
  });
});
