"""Place each cue's synthesised mono clip at its absolute Film time."""

import importlib
import re

import numpy as np

from ..dsp import place, seconds
from ..timeline import all_cues, film_samples

GAIN = 1.0


def render(timeline: dict, sr: int) -> np.ndarray:
    out = np.zeros((film_samples(timeline, sr), 2))
    for cue in all_cues(timeline):
        kind = cue["type"]
        if not re.fullmatch(r"[a-z][a-z0-9_]*", kind):
            raise ValueError(f"Invalid cue type: {kind!r}")
        try:
            effect = importlib.import_module(f"quotabar_audio.sfx.{kind}")
        except ModuleNotFoundError as error:
            raise ValueError(f"No synthesiser for cue type {kind!r}") from error
        params = dict(cue.get("params", {}))
        pan = float(params.pop("pan", 0))
        clip = np.asarray(effect.synthesize(sr, **params), dtype=np.float64)
        if clip.ndim != 1 or not np.all(np.isfinite(clip)):
            raise ValueError(f"Cue {kind!r} did not produce finite mono audio")
        at = float(cue["at"])
        if at < 0 or at >= timeline["durationSeconds"]:
            raise ValueError(f"Cue time outside the Film: {at}")
        place(out, clip, seconds(at, sr), pan)
    return out
