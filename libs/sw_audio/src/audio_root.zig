// Audio module root
pub const audio = @import("audio.zig");
pub const mixer = @import("mixer.zig");

pub const Audio = audio.Audio;
pub const AudioState = audio.AudioState;
pub const Sound = audio.Sound;
pub const Buffer = audio.Buffer;
pub const Waveform = audio.Waveform;

// Decoded samples, streams, the mixer and 3D sound.
pub const Sample = audio.Sample;
pub const Stream = audio.Stream;
pub const PlayOptions = audio.PlayOptions;
pub const Voice = audio.Voice;
pub const Listener = audio.Listener;
pub const Attenuation = audio.Attenuation;
pub const Vec3 = audio.Vec3;
pub const group_count = audio.group_count;
pub const max_voices = audio.max_voices;
pub const DecodeError = audio.DecodeError;
pub const decode = audio.decode;
pub const decodeWav = audio.decodeWav;
pub const decodeVorbis = audio.decodeVorbis;
