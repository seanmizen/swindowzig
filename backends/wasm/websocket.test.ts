// sw_net on the web: the Zig side (libs/sw_net, built as
// libs/sw_net/src/wasm_check.zig) with the JS bridge (websocket.ts), against
// a local Bun WebSocket server. The test needs no network.
// Run with `bun test backends/wasm/websocket.test.ts`. Zig must be on the PATH.
import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { Server, ServerWebSocket } from 'bun';
import { createWebSocketImports, resolveUrl } from './websocket';

const root = join(import.meta.dir, '../..');
let module: WebAssembly.Module;
let server: Server<undefined>;

// Event kinds of check_poll, and the states and causes of sw_net.
const OPEN = 1;
const MESSAGE = 2;
const CLOSED = 3;
const STATE = { connecting: 0, open: 1, closing: 2, waiting: 3, closed: 4 };
const CAUSE = {
  closed: 0,
  connect_failed: 1,
  connection_lost: 3,
  protocol_error: 4,
};

beforeAll(() => {
  const out = join(mkdtempSync(join(tmpdir(), 'sw-net-')), 'check.wasm');
  const build = Bun.spawnSync(
    [
      'zig',
      'build-exe',
      '-target',
      'wasm32-freestanding',
      '-fno-entry',
      '-rdynamic',
      '--dep',
      'sw_net',
      `-Mroot=${join(root, 'libs/sw_net/src/wasm_check.zig')}`,
      `-Msw_net=${join(root, 'libs/sw_net/src/net_root.zig')}`,
      `-femit-bin=${out}`,
    ],
    { cwd: root },
  );
  if (build.exitCode !== 0) throw new Error(build.stderr.toString());
  module = new WebAssembly.Module(readFileSync(out));

  // An echo server. Some text messages are commands: "bye" closes with
  // 4001, "drop" stops the TCP connection with no close frame, "big" sends
  // 2000 bytes.
  server = Bun.serve({
    port: 0,
    hostname: '127.0.0.1',
    fetch(req, srv) {
      if (new URL(req.url).pathname === '/reject') {
        return new Response('no', { status: 404 });
      }
      if (srv.upgrade(req)) return undefined;
      return new Response('upgrade only', { status: 400 });
    },
    websocket: {
      message(ws: ServerWebSocket<undefined>, msg: string | Buffer) {
        if (msg === 'bye') ws.close(4001, 'bye');
        else if (msg === 'drop') ws.terminate();
        else if (msg === 'big') ws.send(new Uint8Array(2000));
        else ws.send(msg);
      },
    },
  });
});

afterAll(() => {
  server.stop(true);
});

type Check = {
  memory: WebAssembly.Memory;
  check_alloc(len: number): number;
  check_open(
    ptr: number,
    len: number,
    reconnectMs: number,
    maxSize: number,
  ): number;
  check_poll(): number;
  check_msg_ptr(): number;
  check_msg_len(): number;
  check_msg_text(): number;
  check_closed_code(): number;
  check_closed_cause(): number;
  check_retry_ms(): number;
  check_state(): number;
  check_send(ptr: number, len: number, text: number): number;
  check_close(code: number, ptr: number, len: number): number;
  check_deinit(): void;
};

function load() {
  let memory: WebAssembly.Memory | null = null;
  const sw_net = createWebSocketImports(() => {
    if (!memory) throw new Error('no memory');
    return memory;
  });
  const wasm = new WebAssembly.Instance(module, { sw_net })
    .exports as unknown as Check;
  memory = wasm.memory;

  const put = (bytes: Uint8Array): [number, number] => {
    const ptr = wasm.check_alloc(bytes.length);
    new Uint8Array(wasm.memory.buffer, ptr >>> 0, bytes.length).set(bytes);
    return [ptr, bytes.length];
  };
  const text = (s: string) => put(new TextEncoder().encode(s));
  const message = () =>
    new Uint8Array(
      wasm.memory.buffer,
      wasm.check_msg_ptr() >>> 0,
      wasm.check_msg_len(),
    ).slice();
  // Poll until an event comes. The socket events need the event loop, so
  // the test waits between polls, as a game waits between ticks.
  const next = async (): Promise<number> => {
    for (let i = 0; i < 2000; i++) {
      const kind = wasm.check_poll();
      if (kind !== 0) return kind;
      await Bun.sleep(2);
    }
    throw new Error('no event in 4 s');
  };
  const open = (path: string, reconnectMs = 0, maxSize = 1 << 20) =>
    wasm.check_open(
      ...text(`ws://127.0.0.1:${server.port}${path}`),
      reconnectMs,
      maxSize,
    );
  return { wasm, put, text, message, next, open };
}

describe('sw_net web bridge', () => {
  test('binary and text echo, then a close from the client (REQ-NET-001)', async () => {
    const t = load();
    expect(t.open('/echo')).toBe(0);
    expect(t.wasm.check_state()).toBe(STATE.connecting);
    // A send before the open event fails.
    expect(t.wasm.check_send(...t.text('early'), 0)).toBe(1);
    // No event arrives without a poll: the bridge only queues them.
    await Bun.sleep(50);
    expect(await t.next()).toBe(OPEN);
    expect(t.wasm.check_state()).toBe(STATE.open);

    const bytes = new Uint8Array([0, 1, 2, 250, 255]);
    expect(t.wasm.check_send(...t.put(bytes), 0)).toBe(0);
    expect(await t.next()).toBe(MESSAGE);
    expect(t.wasm.check_msg_text()).toBe(0);
    expect(t.message()).toEqual(bytes);

    expect(t.wasm.check_send(...t.text('héllo'), 1)).toBe(0);
    expect(await t.next()).toBe(MESSAGE);
    expect(t.wasm.check_msg_text()).toBe(1);
    expect(new TextDecoder().decode(t.message())).toBe('héllo');

    expect(t.wasm.check_close(1001, ...t.text(''))).toBe(1);
    expect(t.wasm.check_close(1000, ...t.text('done'))).toBe(0);
    expect(t.wasm.check_state()).toBe(STATE.closing);
    expect(await t.next()).toBe(CLOSED);
    expect(t.wasm.check_closed_code()).toBe(1000);
    expect(t.wasm.check_closed_cause()).toBe(CAUSE.closed);
    expect(t.wasm.check_retry_ms()).toBe(-1);
    expect(t.wasm.check_state()).toBe(STATE.closed);
    t.wasm.check_deinit();
  });

  test('a close from the server, a drop, and the reconnect (REQ-NET-003)', async () => {
    const t = load();
    expect(t.open('/echo', 20)).toBe(0);
    expect(await t.next()).toBe(OPEN);

    expect(t.wasm.check_send(...t.text('drop'), 1)).toBe(0);
    expect(await t.next()).toBe(CLOSED);
    expect(t.wasm.check_closed_code()).toBe(1006);
    expect(t.wasm.check_closed_cause()).toBe(CAUSE.connection_lost);
    expect(t.wasm.check_retry_ms()).toBe(20);
    expect(t.wasm.check_state()).toBe(STATE.waiting);

    expect(await t.next()).toBe(OPEN);
    expect(t.wasm.check_send(...t.text('bye'), 1)).toBe(0);
    expect(await t.next()).toBe(CLOSED);
    expect(t.wasm.check_closed_code()).toBe(4001);
    expect(t.wasm.check_closed_cause()).toBe(CAUSE.closed);
    expect(t.wasm.check_retry_ms()).toBe(20);

    expect(t.wasm.check_close(1000, ...t.text(''))).toBe(0);
    expect(t.wasm.check_state()).toBe(STATE.closed);
    t.wasm.check_deinit();
  });

  test('a message larger than max_message_size closes with 1009', async () => {
    const t = load();
    expect(t.open('/echo', 0, 1000)).toBe(0);
    expect(await t.next()).toBe(OPEN);
    expect(t.wasm.check_send(...t.text('big'), 1)).toBe(0);
    expect(await t.next()).toBe(CLOSED);
    expect(t.wasm.check_closed_code()).toBe(1009);
    expect(t.wasm.check_closed_cause()).toBe(CAUSE.protocol_error);
    t.wasm.check_deinit();
  });

  test('a refused upgrade and a bad URL', async () => {
    const t = load();
    expect(t.open('/reject')).toBe(0);
    expect(await t.next()).toBe(CLOSED);
    expect(t.wasm.check_closed_cause()).toBe(CAUSE.connect_failed);
    expect(t.wasm.check_state()).toBe(STATE.closed);
    t.wasm.check_deinit();
    expect(t.wasm.check_open(...t.text('http://example.com/'), 0, 1000)).toBe(
      1,
    );
  });

  test('resolveUrl uses the page host for a path', () => {
    expect(resolveUrl('/api/ws', { protocol: 'https:', host: 'a.com' })).toBe(
      'wss://a.com/api/ws',
    );
    expect(resolveUrl('/x', { protocol: 'http:', host: 'b:8' })).toBe(
      'ws://b:8/x',
    );
    expect(resolveUrl('ws://c/', undefined)).toBe('ws://c/');
  });
});
