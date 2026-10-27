// The sw_audio mixer pump (audio.ts): it schedules the blocks that the wasm
// mixes on the audio clock, with no gap and no overlap. Run with
// `bun test backends/wasm/audio.test.ts`.
import { beforeAll, describe, expect, test } from 'bun:test';

const RATE = 48000;

class FakeBuffer {
  channels: Float32Array[];
  constructor(channels: number, frames: number) {
    this.channels = Array.from(
      { length: channels },
      () => new Float32Array(frames),
    );
  }
  getChannelData(i: number): Float32Array {
    return this.channels[i];
  }
}

const started: { at: number; buffer: FakeBuffer }[] = [];

class FakeContext {
  sampleRate = RATE;
  currentTime = 1;
  state = 'running';
  destination = {};
  createBuffer(channels: number, frames: number): FakeBuffer {
    return new FakeBuffer(channels, frames);
  }
  createBufferSource() {
    const source = {
      buffer: null as FakeBuffer | null,
      connect: () => {},
      start: (at: number) => {
        if (source.buffer) started.push({ at, buffer: source.buffer });
      },
    };
    return source;
  }
  resume() {}
}

let audio: typeof import('./audio');
let ctx: FakeContext;
let calls = 0;
let idle = false;
const memory = new WebAssembly.Memory({ initial: 1 });

beforeAll(async () => {
  (globalThis as Record<string, unknown>).AudioContext = class extends (
    FakeContext
  ) {
    constructor() {
      super();
      ctx = this;
    }
  };
  (globalThis as Record<string, unknown>).window = globalThis;
  audio = await import('./audio');
  audio.audioImports.audioInit();
  // A fake sw_audio_mix: block n has the value n on the left and -n on
  // the right.
  const mix = (frames: number): number => {
    if (idle) return 0;
    calls += 1;
    const out = new Float32Array(memory.buffer, 64, frames * 2);
    for (let i = 0; i < frames; i++) {
      out[i * 2] = calls;
      out[i * 2 + 1] = -calls;
    }
    return 64;
  };
  audio.setAudioExports({ sw_audio_mix: mix, memory });
});

describe('pumpMixer', () => {
  test('the sample rate comes from the audio context', () => {
    expect(audio.audioImports.audioSampleRate()).toBe(RATE);
  });

  test('blocks follow each other with no gap', () => {
    audio.pumpMixer();
    expect(started.length).toBeGreaterThan(1);
    const block = 1024 / RATE;
    for (let i = 1; i < started.length; i++) {
      expect(started[i].at).toBeCloseTo(started[i - 1].at + block, 9);
    }
    // The first block starts a little after now.
    expect(started[0].at).toBeGreaterThan(ctx.currentTime);
    // The pump splits the interleaved block into two channels.
    expect(started[0].buffer.getChannelData(0)[5]).toBe(1);
    expect(started[0].buffer.getChannelData(1)[5]).toBe(-1);
  });

  test('a second pump at the same time adds nothing', () => {
    const n = started.length;
    audio.pumpMixer();
    expect(started.length).toBe(n);
  });

  test('the pump continues from the last block as the clock moves', () => {
    const n = started.length;
    const last = started[n - 1].at;
    ctx.currentTime += 0.03;
    audio.pumpMixer();
    expect(started.length).toBeGreaterThan(n);
    expect(started[n].at).toBeCloseTo(last + 1024 / RATE, 9);
  });

  test('no voice: nothing is scheduled', () => {
    idle = true;
    ctx.currentTime += 1;
    const n = started.length;
    audio.pumpMixer();
    expect(started.length).toBe(n);
    idle = false;
  });

  test('a suspended context gets no blocks', () => {
    ctx.state = 'suspended';
    ctx.currentTime += 1;
    const n = started.length;
    audio.pumpMixer();
    expect(started.length).toBe(n);
    ctx.state = 'running';
  });
});
