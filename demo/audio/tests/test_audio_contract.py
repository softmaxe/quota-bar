"""Test the public CLI with a timeline JSON and inspect its WAV output."""

import json
from pathlib import Path
import subprocess
import sys
import wave

import numpy as np
import pytest

CUE_DURATIONS = {
    "click": 0.08, "shortcut": 0.20, "robot_alert": 0.64,
    "reset_scale": 1.05, "pen_scribble": 0.65, "tick": 0.32,
}


def render_cli(tmp_path: Path, timeline: dict, name: str) -> tuple[int, np.ndarray]:
    source = tmp_path / f"{name}.json"
    output = tmp_path / f"{name}.wav"
    source.write_text(json.dumps(timeline), encoding="utf-8")
    subprocess.run([sys.executable, "-m", "quotabar_audio", str(source), str(output)], check=True)
    with wave.open(str(output), "rb") as stream:
        assert stream.getnchannels() == 2
        assert stream.getsampwidth() == 2
        sr = stream.getframerate()
        samples = np.frombuffer(stream.readframes(stream.getnframes()), dtype="<i2").reshape(-1, 2) / 32767
    return sr, samples


@pytest.mark.parametrize("duration", [4.25, 75])
def test_json_produces_a_wav_of_exact_duration(tmp_path, duration):
    sr, samples = render_cli(tmp_path, {"durationSeconds": duration, "beats": []}, "bed")
    assert sr == 48000
    assert len(samples) == round(duration * sr)
    assert np.max(np.abs(samples)) > 0.005
    assert np.max(np.abs(samples)) < 1


@pytest.mark.parametrize("kind", CUE_DURATIONS)
@pytest.mark.parametrize("duration", [None, 0.4513])
def test_each_cue_is_audible_at_its_time_and_not_before(tmp_path, kind, duration):
    params = {"pan": -0.6}
    if duration is not None:
        params["duration"] = duration
    cues = [{"type": kind, "at": at, "params": params} for at in [0.5, 1.75, 3.25]]
    timeline = {"durationSeconds": 6, "beats": [{"cues": cues}]}
    sr, track = render_cli(tmp_path, timeline, "cues")
    # Keep cue timing and score ducking identical, but silence the cue itself.
    # Subtracting this WAV cannot mistake the score for a missing sound effect.
    silent = [{**cue, "params": {**params, "gain": 0}} for cue in cues]
    _, bed = render_cli(tmp_path, {**timeline, "beats": [{"cues": silent}]}, "bed")
    difference = track - bed
    for cue in cues:
        start = round(cue["at"] * sr)
        assert np.max(np.abs(difference[start:start + round(0.08 * sr)])) > 0.04
        assert np.max(np.abs(difference[start - round(0.05 * sr):start])) <= 1 / 32767
        stop = start + round((duration or CUE_DURATIONS[kind]) * sr)
        assert np.max(np.abs(difference[stop:stop + round(0.05 * sr)])) <= 1 / 32767
        cue_audio = difference[start:stop]
        assert np.sqrt(np.mean(cue_audio[:, 0] ** 2)) > 2 * np.sqrt(np.mean(cue_audio[:, 1] ** 2))
    _, repeated = render_cli(tmp_path, timeline, "repeat")
    assert np.array_equal(track, repeated)


def test_long_late_cue_fades_before_the_last_second(tmp_path):
    timeline = {"durationSeconds": 5, "beats": [{"cues": [
        {"type": "reset_scale", "at": 2.7, "params": {"duration": 2.3}},
    ]}]}
    sr, track = render_cli(tmp_path, timeline, "fade")
    assert np.max(np.abs(track[round(2.7 * sr):round(3.2 * sr)])) > 0.05
    assert np.max(np.abs(track[-sr:])) < 10 ** (-40 / 20)


def test_score_changes_follow_shifted_story_moments(tmp_path):
    moments = {"runningLow": 3, "reset": 6, "night": 9, "outro": 13, "wave": 15}
    timeline = {"durationSeconds": 20, "beats": [], "quota": {"moments": moments}}
    sr, story = render_cli(tmp_path, timeline, "story")
    _, theme = render_cli(tmp_path, {"durationSeconds": 20, "beats": []}, "theme")
    # Notes release just before a section boundary instead of being cut mid-wave.
    assert np.array_equal(story[:round(2.7 * sr)], theme[:round(2.7 * sr)])
    for start, end in [(3, 6), (6, 9), (9, 13), (13, 15), (15, 18)]:
        section = story[start * sr:end * sr]
        assert np.sqrt(np.mean(section ** 2)) > 0.004
        assert np.max(np.abs(section - theme[start * sr:end * sr])) > 0.02
    assert np.max(np.abs(story[-sr:])) < 10 ** (-40 / 20)


def test_unknown_cue_fails_without_writing_a_wav(tmp_path):
    source = tmp_path / "unknown.json"
    output = tmp_path / "unknown.wav"
    source.write_text(json.dumps({"durationSeconds": 4, "beats": [{"cues": [{"type": "missing", "at": 1}]}]}))
    result = subprocess.run([sys.executable, "-m", "quotabar_audio", str(source), str(output)], capture_output=True)
    assert result.returncode != 0
    assert b"No synthesiser" in result.stderr
    assert not output.exists()
