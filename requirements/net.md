# Network requirements — `REQ-NET-*`

The WebSocket client of `sw_net`, on the web and on native.

## REQ-NET-001 — The game polls network events

- **Status:** active
- **Source:** agent:SWZ-53
- **Origin:** #53
- **Type:** constraint
- **Priority:** P1
- **Statement:** The `sw_net` socket shall give each network event (open,
  message, closed) to the game only through `Socket.poll`, never through a
  callback into game code.
- **Rationale:** The game runs a fixed tick that it can record and replay.
  A callback from the browser or from a network thread runs at a time that
  the tick does not control. So the game state can change between two
  ticks, and a replay does not give the same result. The game reads the
  events at one point in its tick.
- **Verification:** Test — `libs/sw_net/src/socket_test.zig` › "socket:
  binary and text echo, fragments, ping, close (REQ-NET-001,
  REQ-NET-002)", and `backends/wasm/websocket.test.ts` › "binary and text
  echo, then a close from the client (REQ-NET-001)"
- **Relations:** none

## REQ-NET-002 — The native client masks each frame

- **Status:** active
- **Source:** agent:SWZ-53
- **Origin:** #53
- **Type:** functional
- **Priority:** P1
- **Statement:** The native `sw_net` client shall mask each frame that it
  sends with a new random key, as RFC 6455 section 5.3 tells.
- **Rationale:** A server must close a connection that sends a frame with
  no mask. The random key also stops cache poisoning attacks on proxies
  between the client and the server.
- **Verification:** Test — `libs/sw_net/src/socket_test.zig` › "socket:
  binary and text echo, fragments, ping, close (REQ-NET-001,
  REQ-NET-002)". The test server refuses a frame with no mask and counts
  the masked frames.
- **Relations:** none

## REQ-NET-003 — The reconnect delay doubles to a limit

- **Status:** active
- **Source:** agent:SWZ-53
- **Origin:** #53
- **Type:** functional
- **Priority:** P2
- **Statement:** When a socket with a reconnect option loses its
  connection, `sw_net` shall wait `initial_ms` before the first attempt,
  double the delay after each failed attempt to `max_ms` at most, and set
  the attempt count to zero when a connection opens.
- **Rationale:** Many clients can lose a server at the same time. A client
  that tries again at once, again and again, adds load to a server that
  starts again. A longer delay after each failure gives the server time.
- **Verification:** Test — `libs/sw_net/src/backoff.zig` › "backoff:
  doubles to the limit (REQ-NET-003)", and
  `libs/sw_net/src/socket_test.zig` › "socket: reconnect with backoff after
  a drop (REQ-NET-003)"
- **Relations:** none
