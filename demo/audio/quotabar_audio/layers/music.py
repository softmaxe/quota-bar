"""An 88 BPM chip, electric-piano and drum score following the quota story."""

import numpy as np

from ..dsp import place, seconds
from ..timeline import film_samples
from ..voices import chip, drum, pad, piano

GAIN = 1.0
PULSE = 60 / 88
MAJOR = [(48, 55, 59, 64), (53, 60, 64, 69), (45, 52, 55, 60), (43, 50, 55, 59)]
MINOR = [(48, 55, 60, 63), (44, 51, 56, 60), (43, 50, 59, 65), (47, 53, 56, 62)]


def _add(out, voice, at, duration, sr, note, gain, pan=0.0, end=None):
    if end is not None:
        duration = min(duration, end - at)
    if duration <= 0:
        return
    place(out, gain * voice(note, duration, sr), seconds(at, sr), pan)


def _day(out, start, end, sr, minor=False):
    chords = MINOR if minor else MAJOR
    bar = 4 * PULSE
    for index, at in enumerate(np.arange(start, end, bar)):
        chord = chords[index % len(chords)]
        for voice, note in enumerate(chord):
            _add(out, piano, at, bar * 0.95, sr, note, 0.034, (voice - 1.5) * 0.22, end)
        # Bass and soft backbeat leave space for short mechanical sound cues.
        for step in range(4):
            when = at + step * PULSE
            if when >= end:
                break
            _add(out, piano, when, PULSE * 0.75, sr, chord[0] - 12, 0.040, 0, end)
            kind = "kick" if step % 2 == 0 else "brush"
            clip = 0.070 * drum(kind, sr)
            place(out, clip[:max(0, seconds(end - when, sr))], seconds(when, sr), -0.12)
        subdivision = PULSE / (2 if minor else 1)
        for step, when in enumerate(np.arange(at, min(end, at + bar), subdivision)):
            motif = (0, 2, 1, 3, 2, 1, 3, 1) if minor else (0, 2, 3, 1)
            note = chord[motif[step % len(motif)]] + 12
            _add(out, chip, when, subdivision * 0.68, sr, note, 0.053, 0.18, end)
            hat_at = when + subdivision / 2
            if hat_at < end:
                clip = drum("hat", sr) * (0.037 if minor else 0.026)
                place(out, clip[:max(0, seconds(end - hat_at, sr))], seconds(hat_at, sr), 0.3)


def _night(out, start, end, sr):
    bar = 4 * PULSE
    for index, at in enumerate(np.arange(start, end, bar * 2)):
        chord = MAJOR[index % len(MAJOR)]
        for voice, note in enumerate(chord):
            _add(out, pad, at, bar * 2.15, sr, note, 0.025, (voice - 1.5) * 0.30, end)
        # Widely spaced piano notes retain the daytime motif above the pad.
        _add(out, piano, at + PULSE, bar, sr, chord[2] + 12, 0.045, -0.25, end)
        _add(out, piano, at + 4 * PULSE, bar, sr, chord[3] + 12, 0.035, 0.25, end)


def _outro(out, start, cadence, end, sr):
    for at, stop, chord in [(start, cadence, (43, 53, 59, 62)), (cadence, end, MAJOR[0])]:
        for voice, note in enumerate(chord):
            pan = (voice - 1.5) * 0.28
            _add(out, pad, at, stop - at, sr, note, 0.032, pan)
            _add(out, piano, at, min(stop - at, PULSE * 4), sr, note + 12, 0.045, pan)
    for step, note in enumerate((79, 76, 74, 72)):
        at = cadence + step * PULSE / 2
        _add(out, chip, at, PULSE * (2 if step == 3 else 0.42), sr, note, 0.045, 0.10, end)


def render(timeline: dict, sr: int) -> np.ndarray:
    out = np.zeros((film_samples(timeline, sr), 2))
    end = float(timeline["durationSeconds"])
    moments = timeline.get("quota", {}).get("moments", {})
    # Small external test timelines may omit the story and receive the main theme.
    low = min(float(moments.get("runningLow", end)), end)
    reset = min(float(moments.get("reset", end)), end)
    night = min(float(moments.get("night", end)), end)
    outro = min(float(moments.get("outro", end)), end)
    cadence = min(float(moments.get("wave", outro + (end - outro) / 2)), end)
    _day(out, 0, low, sr)
    _day(out, low, reset, sr, minor=True)
    _day(out, reset, night, sr)
    # The reset scale cue adds its own clear attack at the same timeline moment.
    for step, note in enumerate((48, 52, 55, 60, 64, 67, 72)):
        at = reset + step * PULSE / 4
        _add(out, piano, at, PULSE * 1.4, sr, note, 0.070, -0.25 + step / 12, night)
    _night(out, night, outro, sr)
    _outro(out, outro, cadence, end, sr)

    t = np.arange(len(out)) / sr
    # Thin the score before cues so a short click or pen stroke stays distinct.
    duck = np.ones(len(out))
    for beat in timeline["beats"]:
        for cue in beat["cues"]:
            at = float(cue["at"])
            duration = float(cue.get("params", {}).get("duration", 0.65))
            envelope = np.interp(t, [at - 0.04, at, at + duration, at + duration + 0.18], [1, 0.60, 0.60, 1])
            duck = np.minimum(duck, envelope)
    fade_start = max(0.1, end - 3.5)
    fade_end = max(fade_start + 0.01, end - 1)
    gain = np.interp(t, [0, 0.1, fade_start, fade_end], [0, 1, 1, 0])
    return out * (duck * gain)[:, None]
