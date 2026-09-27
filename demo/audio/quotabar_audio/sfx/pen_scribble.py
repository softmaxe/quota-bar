"""Filtered noise in short strokes for a pen moving across paper."""

import numpy as np

from ..dsp import attack_release, fft_filter, seconds


def synthesize(sr: int, duration: float = 0.65, gain: float = 0.40) -> np.ndarray:
    t = np.arange(seconds(duration, sr)) / sr
    noise = np.random.default_rng(731).uniform(-1, 1, len(t))
    grain = fft_filter(noise, sr, highpass=1300, lowpass=6500)
    strokes = 0.25 + 0.75 * np.sin(np.pi * (5.5 * t + 0.8 * t * t)) ** 2
    env = attack_release(len(t), seconds(0.012, sr), seconds(min(0.08, duration / 3), sr))
    return gain * grain * strokes * env
