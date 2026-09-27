"""A rising C-major scale that lands on the home tonic at reset."""

import numpy as np

from ..dsp import seconds
from ..voices import piano, chip


def synthesize(sr: int, duration: float = 1.05, gain: float = 0.30) -> np.ndarray:
    out = np.zeros(seconds(duration, sr))
    for index, note in enumerate((60, 62, 64, 67, 72, 76, 79, 84)):
        start = seconds(index * duration * 0.075, sr)
        length = (len(out) - start) / sr
        tone = 0.60 * piano(note, length, sr) + 0.26 * chip(note, length, sr)
        out[start:] += tone
    return gain * out
