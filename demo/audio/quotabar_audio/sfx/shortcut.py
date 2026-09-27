"""Two key presses with a short chip confirmation."""

import numpy as np

from ..dsp import seconds
from ..voices import chip
from .click import synthesize as click


def synthesize(sr: int, duration: float = 0.20, gain: float = 0.38) -> np.ndarray:
    out = np.zeros(seconds(duration, sr))
    for at, note in [(0.0, 79), (duration * 0.25, 84)]:
        start = seconds(at, sr)
        length = (len(out) - start) / sr
        tone = 0.6 * click(sr, duration=length, gain=1.0) + 0.22 * chip(note, length, sr)
        out[start:] += tone[:len(out) - start]
    return gain * out
