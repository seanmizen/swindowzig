// Web Audio API bridge for sw_audio

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

function audioPlay(
  freqStart: number,
  freqEnd: number,
  duration: number,
  waveform: number,
  volume: number,
): void {
  const ctx = ensureContext();
  if (!ctx) return;

  const now = ctx.currentTime;

  // Handle noise separately (waveform === 4)
  if (waveform === 4) {
    playNoise(ctx, duration, volume);
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
  gainNode.connect(ctx.destination);

  oscillator.start(now);
  oscillator.stop(now + duration);
}

function playNoise(ctx: AudioContext, duration: number, volume: number): void {
  const now = ctx.currentTime;
  const sampleRate = ctx.sampleRate;
  const bufferSize = Math.floor(sampleRate * duration);

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
  gainNode.gain.setValueAtTime(volume, now);

  source.connect(gainNode);
  gainNode.connect(ctx.destination);

  source.start(now);
}

// Export for WASM imports
export const audioImports = {
  audioInit,
  audioPlay,
};
