"""Three short descending chip beeps when quota becomes low."""

import numpy as np

from ..dsp import seconds
from ..voices import chip


def synthesize(sr: int, duration: float = 0.64, gain: float = 0.34) -> np.ndarray:
    out = np.zeros(seconds(duration, sr))
    for index, note in enumerate((84, 80, 77)):
        start = seconds(index * duration / 3, sr)
        tone = chip(note, duration * 0.22, sr)
        end = min(start + len(tone), len(out))
        out[start:end] += tone[:end - start]
    return gain * out
