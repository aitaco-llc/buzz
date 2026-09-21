#!/usr/bin/env python3
"""Working-sound earcons for the rock voice bridge.

Two seamless loops, 24 kHz mono s16 — the bridge's own `gemini::OUTPUT_RATE`,
so a frame drops straight into `out_pcm` (480 samples = one 20 ms Opus frame).
Both loop lengths are exact multiples of 480.

No voice, no sample of any real recording: everything below is synthesised
from noise and sine envelopes.
"""
import numpy as np
import wave

SR = 24_000
FRAME = 480


def one_pole_lp(x, cutoff, sr=SR):
    a = 1.0 - np.exp(-2.0 * np.pi * cutoff / sr)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += (v - acc) * a
        y[i] = acc
    return y


def one_pole_hp(x, cutoff, sr=SR):
    return x - one_pole_lp(x, cutoff, sr)


def add_wrap(buf, at, seg):
    n = len(buf)
    idx = (np.arange(len(seg)) + at) % n
    np.add.at(buf, idx, seg)


def keystroke(rng, space=False):
    """A key: a bright click transient plus a short lowpassed body thump."""
    click_n = int(0.006 * SR)
    t = np.arange(click_n) / SR
    click = rng.standard_normal(click_n) * np.exp(-t / (0.0011 if not space else 0.0016))
    click = one_pole_hp(click, 2200.0)
    click *= 0.55 if not space else 0.30

    body_n = int((0.045 if not space else 0.075) * SR)
    tb = np.arange(body_n) / SR
    body = rng.standard_normal(body_n) * np.exp(-tb / (0.010 if not space else 0.020))
    body = one_pole_lp(body, 1500.0 if not space else 700.0)
    body *= 1.0 if not space else 1.5

    n = max(click_n, body_n)
    seg = np.zeros(n)
    seg[:click_n] += click
    seg[:body_n] += body
    seg *= rng.uniform(0.62, 1.0)
    return seg


def typing(seconds=4.0, seed=7):
    """Someone at a keyboard: bursts of keys, short pauses, the odd spacebar."""
    rng = np.random.default_rng(seed)
    n = int(round(seconds * SR / FRAME)) * FRAME
    buf = np.zeros(n)
    at = 0.0
    while at < n:
        for _ in range(int(rng.integers(3, 8))):
            add_wrap(buf, int(at), keystroke(rng))
            at += rng.uniform(0.072, 0.155) * SR
            if at >= n:
                break
        if rng.random() < 0.45 and at < n:
            add_wrap(buf, int(at), keystroke(rng, space=True))
            at += rng.uniform(0.13, 0.22) * SR
        at += rng.uniform(0.26, 0.62) * SR
    return buf


def thinking(seconds=4.0, seed=11):
    """The quieter alternative: soft irregular low blips, no keyboard imagery."""
    rng = np.random.default_rng(seed)
    n = int(round(seconds * SR / FRAME)) * FRAME
    buf = np.zeros(n)
    at = rng.uniform(0.0, 0.3) * SR
    while at < n:
        f = rng.uniform(190.0, 330.0)
        dur = int(rng.uniform(0.09, 0.16) * SR)
        t = np.arange(dur) / SR
        env = np.exp(-t / 0.035) * (1.0 - np.exp(-t / 0.004))
        blip = np.sin(2 * np.pi * f * t) * env
        blip += 0.22 * np.sin(2 * np.pi * f * 2.02 * t) * env
        blip = one_pole_lp(blip, 2600.0)
        add_wrap(buf, int(at), blip * rng.uniform(0.7, 1.0))
        at += rng.uniform(0.34, 0.72) * SR
    return buf


def write(path, x, rms_dbfs=-38.0):
    # Loudness-matched, not peak-matched: the two options must be swappable on a
    # call without the level changing under them. -38 dBFS RMS sits roughly 12 dB
    # under ordinary VoIP speech.
    x = x / np.sqrt(np.mean(x ** 2))
    x *= 10.0 ** (rms_dbfs / 20.0)
    assert np.max(np.abs(x)) < 0.5, "peaks too hot"
    pcm = np.clip(np.round(x * 32767.0), -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    return len(pcm)


if __name__ == "__main__":
    for name, x in (("WORKING_TYPING", typing()), ("WORKING_THINKING", thinking())):
        n = write(f"/home/lth/.buzz/OUTBOX/voice-earcons/{name}.wav", x)
        print(f"{name}.wav  {n} samples  {n/SR:.3f}s  {n//FRAME} frames  remainder {n%FRAME}")
