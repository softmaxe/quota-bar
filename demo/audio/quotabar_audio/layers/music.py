"""A quiet 88 BPM synthesised bed; the full score replaces this layer in #85."""

import numpy as np

from ..dsp import attack_release, midi_hz, place, seconds
from ..timeline import film_samples

GAIN = 1.0


def render(timeline: dict, sr: int) -> np.ndarray:
    out = np.zeros((film_samples(timeline, sr), 2))
    pulse = 60 / 88
    for index, at in enumerate(np.arange(0, timeline["durationSeconds"], pulse)):
        note = (48, 55, 60, 64)[index % 4]
        t = np.arange(seconds(pulse * 1.5, sr)) / sr
        tone = np.sin(2 * np.pi * midi_hz(note) * t) * np.exp(-3 * t)
        tone *= attack_release(len(t), seconds(0.025, sr), seconds(0.1, sr)) * 0.032
        place(out, tone, seconds(float(at), sr), pan=(-0.25 if index % 2 else 0.25))
    # Leave the last second below -40 dB while the picture returns to paper.
    t = np.arange(len(out)) / sr
    end = timeline["durationSeconds"]
    gain = np.interp(t, [0, 0.1, max(0.1, end - 3), end - 1, end], [0, 1, 1, 0.01, 0])
    return out * gain[:, None]
