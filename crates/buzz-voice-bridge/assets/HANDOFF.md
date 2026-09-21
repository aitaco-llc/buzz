---
title: Working-sound earcons for the rock voice bridge
author: rock
date: 2026-09-19
for: aldrin (buzz-voice-bridge)
source: Lloyd, DM 037c2272, 2026-09-19T23:02:20Z
---

# Working-sound earcons

Lloyd, in his own words: *"maybe we want to introduce some sort of nonverbal
jingle to reassure the user when there's work going on like a bubbling or
clicking something that evokes like thinking and working — it could even be
more like play the sound of typing for instance."*

Two loops. Pick on his ear, not mine; `WORKING_TYPING` is his suggestion taken
literally and is the default I would ship.

| file | what it is |
|---|---|
| `WORKING_TYPING.wav` | someone at a keyboard: bursts of 3–7 keys, short pauses, the odd spacebar |
| `WORKING_THINKING.wav` | the neutral alternative: sparse soft low blips, no keyboard imagery |

Both are synthesised from noise and sine envelopes by `make_earcons.py`. No
recording of anything, and no voice — nothing here is anyone's likeness.

## Format, chosen to drop straight into the bridge

- 24 kHz mono s16 — `gemini::OUTPUT_RATE`, the rate `out_pcm` already carries.
- 96000 samples = 4.000 s = exactly 200 × `OUT_FRAME` (480), so a loop never
  leaves a partial frame behind.
- Loudness-matched at **−38 dBFS RMS**, roughly 12 dB under ordinary VoIP
  speech, so swapping one for the other does not change the level under you.
  Peaks: typing −10.9 dBFS, thinking −19.9 dBFS.

## Measurements

Seam (the wrap point, two loops end to end), against the 99.9th-percentile
ordinary sample step in the same file — below it means no audible click:

| file | seam step | 99.9th-pct step |
|---|---|---|
| `WORKING_TYPING` | 0.02335 | 0.04340 |
| `WORKING_THINKING` | 0.00000 | 0.00748 |

Through the codec the bridge actually uses (`libopus`, 32 kbps, `-application
voip`, 24 kHz mono), transient structure survives:

| file | crest before | crest after | best xcorr vs source |
|---|---|---|---|
| `WORKING_TYPING` | 27.1 dB | 25.7 dB | 0.910 |
| `WORKING_THINKING` | 18.1 dB | 17.9 dB | 0.935 |

Measured at the earlier −20 dBFS peak normalisation; the level changed after,
the waveform did not.

## The one hard constraint

**The room track only. Never Gemini's input.** The room hears nothing at all
during a wait today, because `call.rs:381` sends a frame only when Gemini has
produced PCM — the bed is that `else`. Gemini's input is the separate path at
`call.rs:412` and must keep getting silence, or its VAD is listening to a
keyboard.

## Behaviour I am asking for

- Starts ~2 s after the ask lands, so a fast answer never triggers it.
- Stops the instant Gemini speaks or rock's answer arrives.
- Which loop, the gain, and whether it plays at all are config knobs.

## Reproducing or re-rendering

```
python3 make_earcons.py     # numpy only; writes both .wav in place
```

`sha256`:

```
db41b726ef0224a6b95bf871337191554020e58040976e055798aad58555185c  WORKING_TYPING.wav
822d1a2aea362d3e36d64ca60d5394bdd92974156675eb554e14b9a8d67ddfd6  WORKING_THINKING.wav
```

Relay Blossom refuses `audio/m4a`, so neither of these can be attached to a
Buzz message today. Lloyd hears them on a call.
