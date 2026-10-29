// The voxel web build keeps its edits after a reload (REQ-VOXEL-035).
//
// app.wasm runs two times in Bun (headless-app.ts) with one fake
// localStorage. The first run places a block, and the save writes the edit
// log. The second run reads the log at start, and has the block.
//
//   zig build web -Dexample=voxel
//   bun test backends/wasm/save.test.ts

import { afterAll, beforeAll, expect, test } from 'bun:test';
import { checkMeshUploads, type HeadlessApp, startApp } from './headless-app';

const WASM = 'zig-out/bin/app.wasm';
const KEY = 'swindowzig:voxel-edits-hilly-0';
const MAX_LOADING_FRAMES = 60 * 120;
const STONE_Y = 200;

/** A localStorage with a Map, as storage.ts uses it. */
class FakeStorage {
  readonly items = new Map<string, string>();
  getItem(k: string): string | null {
    return this.items.get(k) ?? null;
  }
  setItem(k: string, v: string): void {
    this.items.set(k, v);
  }
  removeItem(k: string): void {
    this.items.delete(k);
  }
}

const g = globalThis as unknown as { window?: unknown };
const oldWindow = g.window;
const storage = new FakeStorage();

beforeAll(() => {
  g.window = { localStorage: storage };
});
afterAll(() => {
  g.window = oldWindow;
});

async function load(log: string[]): Promise<HeadlessApp> {
  const app = await startApp({
    wasm: WASM,
    pool: {},
    clock: 'sim',
    onLog: (text) => log.push(text),
  });
  while (app.counts(0).loading) {
    if (app.frameCount() >= MAX_LOADING_FRAMES)
      throw new Error('the loading screen did not stop');
    await app.frames(1);
  }
  return app;
}

test('an edit stays after a reload, through localStorage', async () => {
  const log1: string[] = [];
  const app1 = await load(log1);
  const c = app1.counts(0);
  const wx = c.cx * 16 + 8;
  const wz = c.cz * 16 + 8;
  expect(app1.block(wx, STONE_Y, wz)).toBe(0);
  // Block id 1: the first block after air.
  expect(app1.edit(wx, STONE_Y, wz, 1)).toBe(true);
  const placed = app1.block(wx, STONE_Y, wz);
  expect(placed).toBe(1);
  // The save waits at most 1 s of the game clock (SAVE_INTERVAL_NS).
  await app1.frames(90);
  app1.stop();
  // The header (22 bytes) and one record (13 bytes).
  expect(atob(storage.getItem(KEY) ?? '').length).toBe(22 + 13);

  const log2: string[] = [];
  const app2 = await load(log2);
  expect(app2.block(wx, STONE_Y, wz)).toBe(placed);
  // No warning: the wasm log has warnings and errors only.
  expect(log2.filter((l) => l.includes('[SAVE]'))).toEqual([]);
  app2.stop();
}, 300_000);

test('corrupt saved data gives an empty world and one warning', async () => {
  storage.setItem(KEY, btoa('SWZE\u0001garbage'));
  const log: string[] = [];
  const app = await load(log);
  expect(log.filter((l) => l.includes('cannot be read')).length).toBe(1);
  // The log of a corrupt value has no edit. The next save replaces it.
  const c = app.counts(0);
  expect(app.edit(c.cx * 16 + 8, STONE_Y, c.cz * 16 + 8, 1)).toBe(true);
  await app.frames(90);
  const saved = atob(storage.getItem(KEY) ?? '');
  // The header (22 bytes) and one record (13 bytes).
  expect(saved.length).toBe(22 + 13);
  app.stop();
}, 300_000);

test('New World deletes the saved edits and loads the seed terrain again', async () => {
  const log: string[] = [];
  const app = await load(log);
  const c = app.counts(0);
  const wx = c.cx * 16 + 8;
  const wz = c.cz * 16 + 8;
  expect(app.edit(wx, STONE_Y, wz, 1)).toBe(true);
  await app.frames(90);
  expect(storage.getItem(KEY)).not.toBeNull();
  // Jobs of the old executor are in flight now.
  expect(app.newWorld()).toBe(true);
  expect(storage.getItem(KEY)).toBeNull();
  expect(app.counts(0).loading).toBe(true);
  let n = 0;
  while (app.counts(0).loading || !app.pipeline()?.idle) {
    if (n++ >= MAX_LOADING_FRAMES)
      throw new Error('the new world did not load');
    await app.frames(1);
  }
  expect(app.block(wx, STONE_Y, wz)).toBe(0);
  const near = app.counts(1);
  expect(near.meshedNear).toBe(near.area);
  const p = app.pipeline();
  expect(p?.executor).toBe('web');
  await app.frames(1);
  const up = checkMeshUploads(app, true);
  expect(up.failures).toEqual([]);
  app.stop();
}, 300_000);
