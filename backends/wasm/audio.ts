// Web Audio API bridge for sw_audio (libs/sw_audio/src/audio.zig).
//
// - audioPlay: an oscillator or a noise burst, with a stereo position and a
//   start delay.
// - audioPlayBuffer: two channels of samples from the wasm memory. The
//   samples are copied during the call, so the caller can use the memory
//   again after the call.
// - audioStartMixer: a timer calls the wasm export sw_audio_mix, and plays
//   each mixed block on the audio clock, a short time ahead (pumpMixer).
//   The sw_audio mixer plays the decoded samples, the streams and the 3D
//   sound.
// The delays of the sounds of one task count from one audio time
// (startTime).

let audioContext: AudioContext | null = null;

// Waveform types matching Zig enum
const WAVEFORMS: OscillatorType[] = ['sine', 'square', 'sawtooth', 'triangle'];

function ensureContext(): AudioContext | null {
  if (!audioContext) {
    try {
      audioContext = new AudioContext();
    } catch (e) {
      console.error('Failed to create AudioContext:', e);
      return null;
    }
  }

  // Resume if suspended (browser autoplay policy)
  if (audioContext.state === 'suspended') {
    audioContext.resume();
  }

  return audioContext;
}

function audioInit(): void {
  ensureContext();
  console.log('🔊 Audio initialized');
}

/** The rate of the audio context, or 0 if it does not exist. */
function audioSampleRate(): number {
  return ensureContext()?.sampleRate ?? 0;
}

// The mixer of sw_audio (libs/sw_audio/src/web.zig).
type MixExport = (frames: number) => number;
let mixExport: MixExport | null = null;
let mixMemory: WebAssembly.Memory | null = null;
let mixTimer: ReturnType<typeof setInterval> | null = null;
// The audio time of the end of the last scheduled block. 0: no block.
let mixNextTime = 0;

/** Frames in one mixed block. */
const MIX_BLOCK = 1024;
/** Seconds of mixed audio to keep scheduled ahead of the audio clock. */
const MIX_LEAD = 0.06;
/** Milliseconds between two pumps. */
const MIX_INTERVAL_MS = 10;

/**
 * Give the wasm exports to the mixer pump. The loader calls it after the
 * wasm starts. A wasm with no sw_audio_mix export has no mixer.
 */
export function setAudioExports(exports: WebAssembly.Exports): void {
  const mix = exports.sw_audio_mix;
  const memory = exports.memory;
  mixExport = typeof mix === 'function' ? (mix as MixExport) : null;
  mixMemory = memory instanceof WebAssembly.Memory ? memory : null;
}

/**
 * Schedule mixed blocks until MIX_LEAD seconds are ready. When no voice
 * plays, sw_audio_mix gives 0 and the pump schedules nothing.
 */
export function pumpMixer(): void {
  const ctx = audioContext;
  const mix = mixExport;
  const memory = mixMemory ?? window.wasmMemory;
  if (!ctx || !mix || !memory || ctx.state !== 'running') return;
  const now = ctx.currentTime;
  // After a silence or a late timer, start a little after now.
  if (mixNextTime < now) mixNextTime = now + 0.01;
  while (mixNextTime < now + MIX_LEAD) {
    const ptr = mix(MIX_BLOCK);
    if (!ptr) {
      mixNextTime = 0;
      return;
    }
    const buffer = ctx.createBuffer(2, MIX_BLOCK, ctx.sampleRate);
    const frames = new Float32Array(memory.buffer, ptr, MIX_BLOCK * 2);
    const left = buffer.getChannelData(0);
    const right = buffer.getChannelData(1);
    for (let i = 0; i < MIX_BLOCK; i++) {
      left[i] = frames[i * 2];
      right[i] = frames[i * 2 + 1];
    }
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.connect(ctx.destination);
    source.start(mixNextTime);
    mixNextTime += MIX_BLOCK / ctx.sampleRate;
  }
}

/** Start the mixer pump. A browser starts the audio after a user gesture. */
function audioStartMixer(): void {
  if (mixTimer !== null) return;
  mixTimer = setInterval(pumpMixer, MIX_INTERVAL_MS);
  const resume = (): void => {
    if (audioContext?.state === 'suspended') audioContext.resume();
  };
  for (const name of ['pointerdown', 'keydown', 'touchend']) {
    window.addEventListener(name, resume, { capture: true });
  }
}

// The audio time of the first sound in this task. Every sound that the
// wasm starts in one frame (one task) counts its delay from it, so the
// times between the sounds of one event stay correct while the wasm makes
// the samples of the next sound.
let taskTime: number | null = null;

function startTime(ctx: AudioContext, delay: number): number {
  if (taskTime === null) {
    taskTime = ctx.currentTime;
    queueMicrotask(() => {
      taskTime = null;
    });
  }
  return taskTime + Math.max(0, delay || 0);
}

/** The node that a sound connects to: a stereo panner, or the output. */
function outputFor(ctx: AudioContext, pan: number): AudioNode {
  if (!pan) return ctx.destination;
  const panner = ctx.createStereoPanner();
  panner.pan.value = Math.max(-1, Math.min(1, pan));
  panner.connect(ctx.destination);
  return panner;
}

function audioPlay(
  freqStart: number,
  freqEnd: number,
  duration: number,
  waveform: number,
  volume: number,
  pan = 0,
  delay = 0,
): void {
  const ctx = ensureContext();
  if (!ctx) return;

  const now = startTime(ctx, delay);
  const out = outputFor(ctx, pan || 0);

  // Handle noise separately (waveform === 4)
  if (waveform === 4) {
    playNoise(ctx, duration, volume, now, out);
    return;
  }

  // Create oscillator for tonal sounds
  const oscillator = ctx.createOscillator();
  const gainNode = ctx.createGain();

  oscillator.type = WAVEFORMS[waveform] || 'sine';
  oscillator.frequency.setValueAtTime(freqStart, now);

  // Frequency sweep if start !== end
  if (freqStart !== freqEnd) {
    oscillator.frequency.exponentialRampToValueAtTime(
      Math.max(freqEnd, 1), // Prevent 0 or negative
      now + duration,
    );
  }

  // Volume envelope: quick attack, sustain, quick release
  gainNode.gain.setValueAtTime(0, now);
  gainNode.gain.linearRampToValueAtTime(volume, now + 0.005); // 5ms attack
  gainNode.gain.setValueAtTime(volume, now + duration - 0.01);
  gainNode.gain.linearRampToValueAtTime(0, now + duration); // 10ms release

  oscillator.connect(gainNode);
  gainNode.connect(out);

  oscillator.start(now);
  oscillator.stop(now + duration);
}

function playNoise(
  ctx: AudioContext,
  duration: number,
  volume: number,
  start: number,
  out: AudioNode,
): void {
  const sampleRate = ctx.sampleRate;
  const bufferSize = Math.floor(sampleRate * duration);
  if (bufferSize <= 0) return;

  // Create buffer with white noise
  const buffer = ctx.createBuffer(1, bufferSize, sampleRate);
  const data = buffer.getChannelData(0);

  for (let i = 0; i < bufferSize; i++) {
    // White noise with decay envelope
    const t = i / bufferSize;
    const envelope = (1 - t) ** 2; // Quadratic decay
    data[i] = (Math.random() * 2 - 1) * envelope;
  }

  const source = ctx.createBufferSource();
  const gainNode = ctx.createGain();

  source.buffer = buffer;
  gainNode.gain.setValueAtTime(volume, start);

  source.connect(gainNode);
  gainNode.connect(out);

  source.start(start);
}

function audioPlayBuffer(
  leftPtr: number,
  rightPtr: number,
  frames: number,
  sampleRate: number,
  volume: number,
  delay: number,
): void {
  const ctx = ensureContext();
  const mem = window.wasmMemory;
  if (!ctx || !mem || frames <= 0) return;
  let buffer: AudioBuffer;
  try {
    buffer = ctx.createBuffer(2, frames, sampleRate);
  } catch (e) {
    console.error('audioPlayBuffer: createBuffer failed:', e);
    return;
  }
  buffer.copyToChannel(new Float32Array(mem.buffer, leftPtr, frames), 0);
  buffer.copyToChannel(new Float32Array(mem.buffer, rightPtr, frames), 1);
  const source = ctx.createBufferSource();
  source.buffer = buffer;
  const gainNode = ctx.createGain();
  gainNode.gain.value = volume;
  source.connect(gainNode);
  gainNode.connect(ctx.destination);
  source.start(startTime(ctx, delay));
}

// Export for WASM imports
export const audioImports = {
  audioInit,
  audioPlay,
  audioPlayBuffer,
  audioSampleRate,
  audioStartMixer,
};
