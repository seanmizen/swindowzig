// Bytes that JS holds for the wasm, by handle (C5).
//
// The chunk worker pool sends each result as a transferred ArrayBuffer.
// app.wasm copies only the first bytes of a result (the header and the
// fixed part) into its memory. JS keeps the whole result here, under a
// handle. For a mesh, app.wasm then asks the WebGPU bridge to write the
// quads to a GPU buffer from the held bytes (webgpuWriteBufferHeld), and
// releases the handle. So the mesh bytes never go into the wasm memory.
//
// The counters let the Bun tests prove it: they count each byte that JS
// writes into the wasm memory for a held result, by kind.

const HEADER_LEN = 16;
const KIND_RESULT = 4;
const STAGE_MESH = 2;

/** True when `bytes` is a protocol Result of the mesh stage. */
export function isMeshResult(bytes: Uint8Array): boolean {
  return (
    bytes.byteLength > HEADER_LEN &&
    bytes[6] === KIND_RESULT &&
    bytes[HEADER_LEN] === STAGE_MESH
  );
}

export interface HeldStats {
  /** Results held. */
  held: number;
  /** Mesh results held. */
  meshes: number;
  released: number;
  /** Bytes that JS wrote into the wasm memory: the heads of the results. */
  headBytes: number;
  /** Bytes after the head that JS wrote into the wasm memory. */
  payloadBytes: number;
  /** The part of payloadBytes that was mesh quads. Must stay 0 (C5). */
  meshPayloadBytes: number;
  /** GPU writes from held bytes, and their bytes. */
  gpuWrites: number;
  gpuBytes: number;
}

export class HeldBytes {
  private items = new Map<number, Uint8Array>();
  private nextHandle = 1;
  readonly stats: HeldStats = {
    held: 0,
    meshes: 0,
    released: 0,
    headBytes: 0,
    payloadBytes: 0,
    meshPayloadBytes: 0,
    gpuWrites: 0,
    gpuBytes: 0,
  };

  /** Hold `bytes`. Returns the handle, never 0. */
  hold(bytes: Uint8Array): number {
    const handle = this.nextHandle++;
    this.items.set(handle, bytes);
    this.stats.held++;
    if (isMeshResult(bytes)) this.stats.meshes++;
    return handle;
  }

  /** The bytes of `handle`. Throws for a handle that is not held. */
  get(handle: number): Uint8Array {
    const bytes = this.items.get(handle);
    if (!bytes) throw new Error(`no held bytes for handle ${handle}`);
    return bytes;
  }

  release(handle: number): void {
    if (!this.items.delete(handle)) {
      throw new Error(`no held bytes for handle ${handle}`);
    }
    this.stats.released++;
  }

  /** The number of results that JS holds now. */
  get count(): number {
    return this.items.size;
  }

  /** The bytes that JS holds now. */
  get bytes(): number {
    let n = 0;
    for (const b of this.items.values()) n += b.byteLength;
    return n;
  }

  /**
   * Copy `len` bytes of `handle`, from `offset`, into `out`. Counts the
   * bytes. `offset` 0 is the head of the result.
   */
  copyTo(handle: number, offset: number, out: Uint8Array): void {
    const bytes = this.get(handle);
    out.set(bytes.subarray(offset, offset + out.byteLength));
    if (offset === 0) {
      this.stats.headBytes += out.byteLength;
    } else {
      this.stats.payloadBytes += out.byteLength;
      if (isMeshResult(bytes)) this.stats.meshPayloadBytes += out.byteLength;
    }
  }

  /** Count a GPU write of `size` held bytes. */
  countGpuWrite(size: number): void {
    this.stats.gpuWrites++;
    this.stats.gpuBytes += size;
  }
}
