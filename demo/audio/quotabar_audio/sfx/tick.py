"""A small two-part chime for a completed stroke or action."""

import numpy as np

from ..dsp import attack_release, midi_hz, seconds


def synthesize(sr: int, duration: float = 0.32, gain: float = 0.34) -> np.ndarray:
    t = np.arange(seconds(duration, sr)) / sr
    tone = (np.sin(2 * np.pi * midi_hz(84) * t)
            + 0.35 * np.sin(2 * np.pi * midi_hz(91) * t)) / 1.35
    env = attack_release(len(t), seconds(0.002, sr), seconds(min(0.09, duration / 3), sr))
    return gain * tone * np.exp(-t * 13) * env
