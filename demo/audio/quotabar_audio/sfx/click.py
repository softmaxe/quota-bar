"""A short, deterministic mechanical click without recorded samples."""

import numpy as np

from ..dsp import attack_release, seconds


def synthesize(sr: int, duration: float = 0.08, gain: float = 0.42) -> np.ndarray:
    length = seconds(duration, sr)
    t = np.arange(length) / sr
    noise = np.random.default_rng(17).uniform(-1, 1, length)
    clip = (0.65 * noise + 0.35 * np.sin(2 * np.pi * 1550 * t)) * np.exp(-t * 85)
    return gain * clip * attack_release(length, seconds(0.001, sr), seconds(0.01, sr))
