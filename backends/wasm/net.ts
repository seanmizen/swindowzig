// WebSocket bridge for wasm apps (wasm import module "net").
//
// A socket is a small integer handle. Received text messages wait in a queue
// until the app reads them with netRecv. Zig: apps/action/game/net.zig.
//
// netOpen takes a path such as "/api/ws". The bridge connects to the same
// host as the page, with wss: on an https: page and ws: otherwise.

interface Socket {
  ws: WebSocket;
  queue: Uint8Array[];
  state: number; // 0 connecting, 1 open, 2 closed
}

const sockets = new Map<number, Socket>();
let nextHandle = 1;

export function createNetImports(
  getMemory: () => WebAssembly.Memory,
): Record<string, (...args: number[]) => number | undefined> {
  const text = (ptr: number, len: number): string =>
    new TextDecoder().decode(new Uint8Array(getMemory().buffer, ptr, len));

  return {
    netOpen: (ptr: number, len: number): number => {
      const path = text(ptr, len);
      const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const url = /^wss?:/.test(path)
        ? path
        : `${scheme}//${location.host}${path}`;
      const handle = nextHandle++;
      const sock: Socket = { ws: new WebSocket(url), queue: [], state: 0 };
      sock.ws.binaryType = 'arraybuffer';
      sock.ws.onopen = () => {
        sock.state = 1;
      };
      sock.ws.onclose = () => {
        sock.state = 2;
      };
      sock.ws.onerror = () => {
        sock.state = 2;
      };
      sock.ws.onmessage = (ev: MessageEvent) => {
        const data =
          typeof ev.data === 'string'
            ? new TextEncoder().encode(ev.data)
            : new Uint8Array(ev.data as ArrayBuffer);
        sock.queue.push(data);
      };
      sockets.set(handle, sock);
      return handle;
    },
    netState: (handle: number): number => sockets.get(handle)?.state ?? 2,
    netSend: (handle: number, ptr: number, len: number): number => {
      const sock = sockets.get(handle);
      if (!sock || sock.state !== 1) return 0;
      sock.ws.send(text(ptr, len));
      return 1;
    },
    // Copy the next message into the buffer. Returns its length, 0 when the
    // queue is empty, or -1 when the message is larger than the buffer (the
    // bridge drops that message).
    netRecv: (handle: number, ptr: number, cap: number): number => {
      const sock = sockets.get(handle);
      const msg = sock?.queue.shift();
      if (!msg) return 0;
      if (msg.length > cap) return -1;
      new Uint8Array(getMemory().buffer, ptr, msg.length).set(msg);
      return msg.length;
    },
    netClose: (handle: number): number => {
      const sock = sockets.get(handle);
      if (sock) {
        sock.ws.close();
        sockets.delete(handle);
      }
      return 0;
    },
  };
}
