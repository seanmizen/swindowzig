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
