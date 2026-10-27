// The browser WebSocket for libs/sw_net (wasm import module "sw_net").
//
// Each socket keeps its events (open, message, closed) in a queue. Zig reads
// the queue when the game polls the socket. So no event handler calls into
// the wasm code (REQ-NET-001). Nothing here throws into the wasm code.
//
// The old module "net" (net.ts) stays for apps that use it. This module is
// separate: it sends binary messages, and it gives the close code.

// Event kinds. They match libs/sw_net/src/web.zig.
const EV_NONE = 0;
const EV_OPEN = 1;
const EV_MESSAGE = 2;
const EV_CLOSED = 3;

// The close causes. They match the order of `Cause` in
// libs/sw_net/src/types.zig.
const CAUSE_CLOSED = 0;
const CAUSE_CONNECT_FAILED = 1;
const CAUSE_CONNECTION_LOST = 3;
const CAUSE_PROTOCOL_ERROR = 4;

type Event =
  | { kind: typeof EV_OPEN }
  | { kind: typeof EV_MESSAGE; data: Uint8Array; text: boolean }
  | { kind: typeof EV_CLOSED; code: number; cause: number };

interface Socket {
  ws: WebSocket | null;
  events: Event[];
  opened: boolean;
  closed: boolean;
}

export interface WebSocketImportOptions {
  /** The WebSocket class. The default is globalThis.WebSocket. */
  WebSocket?: typeof WebSocket;
  /**
   * The page URL, for a path such as "/api/ws". The default is
   * globalThis.location.
   */
  location?: { protocol: string; host: string };
}

/**
 * Make the full URL. A path such as "/api/ws" goes to the host of the page,
 * with wss: on an https: page and ws: on another page.
 */
export function resolveUrl(
  text: string,
  location?: { protocol: string; host: string },
): string {
  if (!text.startsWith('/')) return text;
  if (!location) throw new Error('a path needs a page location');
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${scheme}//${location.host}${text}`;
}

export function createWebSocketImports(
  getMemory: () => WebAssembly.Memory,
  options: WebSocketImportOptions = {},
): Record<string, (...args: number[]) => number | undefined> {
  const sockets = new Map<number, Socket>();
  let nextId = 1;
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const bytes = (ptr: number, len: number): Uint8Array =>
    new Uint8Array(getMemory().buffer, ptr >>> 0, len >>> 0);

  const finish = (sock: Socket, code: number, cause: number): void => {
    if (sock.closed) return;
    sock.closed = true;
    sock.events.push({ kind: EV_CLOSED, code, cause });
    const ws = sock.ws;
    sock.ws = null;
    if (ws) {
      ws.onopen = ws.onmessage = ws.onclose = ws.onerror = null;
    }
  };

  return {
    swNetOpen: (urlPtr: number, urlLen: number, maxSize: number): number => {
      const id = nextId++;
      const sock: Socket = {
        ws: null,
        events: [],
        opened: false,
        closed: false,
      };
      sockets.set(id, sock);
      const WS = options.WebSocket ?? globalThis.WebSocket;
      let ws: WebSocket;
      try {
        const url = resolveUrl(
          decoder.decode(bytes(urlPtr, urlLen)),
          options.location ?? globalThis.location,
        );
        ws = new WS(url);
      } catch {
        finish(sock, 1006, CAUSE_CONNECT_FAILED);
        return id;
      }
      ws.binaryType = 'arraybuffer';
      sock.ws = ws;
      ws.onopen = () => {
        sock.opened = true;
        sock.events.push({ kind: EV_OPEN });
      };
      ws.onmessage = (ev: MessageEvent) => {
        const text = typeof ev.data === 'string';
        const data = text
          ? encoder.encode(ev.data as string)
          : new Uint8Array(ev.data as ArrayBuffer);
        if (data.length > maxSize >>> 0) {
          // The same rule as the native client: the game sees 1009. A
          // page cannot send 1009, so the server gets 4009.
          finish(sock, 1009, CAUSE_PROTOCOL_ERROR);
          ws.close(4009);
          return;
        }
        sock.events.push({ kind: EV_MESSAGE, data, text });
      };
      ws.onclose = (ev: CloseEvent) => {
        // The browser does not tell a refused upgrade from a failed connect.
        // Code 1006 means that no close frame arrived.
        const code = ev.code || 1006;
        let cause = CAUSE_CONNECT_FAILED;
        if (sock.opened) {
          cause = code === 1006 ? CAUSE_CONNECTION_LOST : CAUSE_CLOSED;
        }
        finish(sock, code, cause);
      };
      return id;
    },

    swNetSend: (id: number, ptr: number, len: number, text: number): number => {
      const sock = sockets.get(id);
      const ws = sock?.ws;
      if (!ws || ws.readyState !== 1) return -1;
      const data = bytes(ptr, len);
      try {
        if (text) ws.send(decoder.decode(data));
        else ws.send(data.slice());
      } catch {
        return -1;
      }
      return 0;
    },

    swNetPeek: (id: number, infoPtr: number): number => {
      const ev = sockets.get(id)?.events[0];
      if (!ev) return EV_NONE;
      const info = new Uint32Array(getMemory().buffer, infoPtr >>> 0, 2);
      if (ev.kind === EV_MESSAGE) {
        info[0] = ev.data.length;
        info[1] = ev.text ? 1 : 0;
      } else if (ev.kind === EV_CLOSED) {
        info[0] = ev.code;
        info[1] = ev.cause;
      }
      return ev.kind;
    },

    swNetTake: (id: number, dst: number): void => {
      const ev = sockets.get(id)?.events.shift();
      if (ev?.kind === EV_MESSAGE && dst !== 0 && ev.data.length > 0) {
        bytes(dst, ev.data.length).set(ev.data);
      }
    },

    swNetClose: (
      id: number,
      code: number,
      reasonPtr: number,
      reasonLen: number,
    ): void => {
      const ws = sockets.get(id)?.ws;
      if (!ws) return;
      try {
        ws.close(code, decoder.decode(bytes(reasonPtr, reasonLen)));
      } catch {
        // Zig checks the code and the reason. Ignore a browser
        // that refuses them.
      }
    },

    swNetFree: (id: number): void => {
      const sock = sockets.get(id);
      if (!sock) return;
      sockets.delete(id);
      const ws = sock.ws;
      if (ws) {
        ws.onopen = ws.onmessage = ws.onclose = ws.onerror = null;
        try {
          ws.close();
        } catch {
          // A socket that closes already.
        }
      }
    },

    swNetNow: (): number => performance.now(),
  };
}
