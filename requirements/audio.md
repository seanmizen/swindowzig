# Audio requirements — `REQ-AUDIO-*`

Sound output from `sw_audio`: the waveform API, decoded samples, streams,
the mixer and 3D sound.

## REQ-AUDIO-001 — The waveform API does not change

- **Status:** active
- **Source:** agent:SWZ-48
- **Origin:** #48
- **Type:** constraint
- **Priority:** P1
- **Statement:** The `sw_audio` `Audio` type shall keep the signature of
  each waveform function (`init`, `isReady`, `setMasterVolume`,
  `getMasterVolume`, `play`, `playBuffer`, `tone`, `sweep`, `noise` and the
  presets), and the fields and defaults of `Sound` and `Buffer`.
- **Rationale:** Games in other repositories (action.seanmizen.com) call the
  waveform API. A change to it breaks their build or changes their sound.
- **Verification:** Test — `libs/sw_audio/src/audio.zig` › "the waveform API
  keeps its signatures"
- **Relations:** none

## REQ-AUDIO-002 — A stream does not decode all of its data

- **Status:** active
- **Source:** agent:SWZ-48
- **Origin:** #48
- **Type:** quality
- **Priority:** P1
- **Statement:** While a `Stream` plays, the memory of the stream shall
  not increase with the length of the compressed data.
- **Rationale:** Music can be many minutes long. A full decode of each track
  uses tens of megabytes, which is too much for a browser tab. The stream
  decodes a small window of frames at a time.
- **Verification:** Test — `libs/sw_audio/src/vorbis.zig` › "Stream: memory
  does not grow with the length of the data"
- **Relations:** none
