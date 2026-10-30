# Job requirements — `REQ-JOBS-*`

The worker pools of `sw_jobs`: native threads and Web Workers.

## REQ-JOBS-001 — A native worker runs its messages in order, and can stop

- **Status:** active
- **Source:** agent:SWZ-26
- **Origin:** #26
- **Type:** functional
- **Priority:** P2
- **Statement:** The `sw_jobs` `ThreadPool` shall run the messages of one
  worker in the order of `post`, remove a waiting message on `cancel`, and
  stop each thread after its current message on `deinit`.
- **Rationale:** A game sends state changes (for example an edit) before
  the jobs that read them, so the order of one worker must not change. A
  job that the game does not need must not use a thread. A shutdown must
  not wait for a long queue.
- **Verification:**
  - Test — `libs/sw_jobs/src/thread_pool.zig` › "jobs: a worker runs its
    messages in order (REQ-JOBS-001)"
  - Test — `libs/sw_jobs/src/thread_pool.zig` › "jobs: cancel removes the
    messages that wait, not the message that runs (REQ-JOBS-001)"
  - Test — `libs/sw_jobs/src/thread_pool.zig` › "jobs: shutdown stops
    after the message that runs, and frees the queue (REQ-JOBS-001)"
  - Test — `libs/sw_jobs/src/thread_pool.zig` › "jobs: no reply, a
    failure, and a broadcast (REQ-JOBS-001)"
- **Relations:** none

## REQ-JOBS-002 — Native threads and Web Workers have one Transport API

- **Status:** active
- **Source:** agent:SWZ-26
- **Origin:** #26
- **Type:** functional
- **Priority:** P2
- **Statement:** The `sw_jobs` library shall give a `Transport` for a native
  `ThreadPool` and for the Web Worker pool of the web build, with the same
  functions.
- **Rationale:** The main side of a game sends messages and takes results
  with the same code on both platforms. The web pool transfers each
  message as an ArrayBuffer, so it copies no bytes and needs no
  SharedArrayBuffer.
- **Verification:**
  - Test — `libs/sw_jobs/src/native_transport.zig` › "jobs: the native
    pool gives the Transport API (REQ-JOBS-002)"
  - Test — `backends/wasm/worker-pool.test.ts` › the voxel chunk pool on
    real Web Workers, through the "jobs" imports
- **Relations:** none

## REQ-JOBS-003 — The Web Worker pool starts again a worker that stops with no event

- **Status:** active
- **Source:** agent:SWZ-5
- **Origin:** #5
- **Type:** functional
- **Priority:** P3
- **Statement:** The Web Worker pool shall start again a worker that has
  jobs in flight and sends no reply for `STALL_TIMEOUT_MS` (5 s), with the
  same steps as after an `error` event: the Module, the Hello, the edits,
  then the jobs in flight.
- **Rationale:** A browser can stop a worker with no event, for example
  when the worker runs out of memory. Without this rule, the jobs of that
  worker stay in flight, and their chunks never load.
- **Verification:**
  - Test — `backends/wasm/worker-pool.test.ts` › "stall: a worker that
    stops with no event starts again, and its jobs run"
- **Relations:** depends-on REQ-JOBS-002
