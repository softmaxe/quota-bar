"""Test the public CLI with a timeline JSON and inspect its WAV output."""

import json
from pathlib import Path
import subprocess
import sys
import wave

import numpy as np
import pytest


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


def test_each_cue_is_audible_at_its_time_and_not_before(tmp_path):
    cues = [{"type": "click", "at": at} for at in [0.5, 1.75, 3.5]]
    timeline = {"durationSeconds": 5, "beats": [{"cues": cues}]}
    sr, track = render_cli(tmp_path, timeline, "cues")
    _, bed = render_cli(tmp_path, {"durationSeconds": 5, "beats": []}, "bed")
    difference = track - bed
    for cue in cues:
        start = round(cue["at"] * sr)
        assert np.max(np.abs(difference[start:start + round(0.08 * sr)])) > 0.08
        assert np.max(np.abs(difference[start - round(0.05 * sr):start])) <= 1 / 32767


def test_unknown_cue_fails_without_writing_a_wav(tmp_path):
    source = tmp_path / "unknown.json"
    output = tmp_path / "unknown.wav"
    source.write_text(json.dumps({"durationSeconds": 4, "beats": [{"cues": [{"type": "missing", "at": 1}]}]}))
    result = subprocess.run([sys.executable, "-m", "quotabar_audio", str(source), str(output)], capture_output=True)
    assert result.returncode != 0
    assert b"No synthesiser" in result.stderr
    assert not output.exists()
