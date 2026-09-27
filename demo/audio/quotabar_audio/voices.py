"""Deterministic instruments made from oscillators and noise, without samples."""

import numpy as np

from .dsp import attack_release, fft_filter, midi_hz, seconds


def chip(note: float, duration: float, sr: int) -> np.ndarray:
    t = np.arange(seconds(duration, sr)) / sr
    frequency = midi_hz(note)
    tone = np.zeros_like(t)
    # Add only harmonics below Nyquist to keep the square wave's edge clean.
    for harmonic in range(1, 16, 2):
        if harmonic * frequency < sr * 0.45:
            tone += np.sin(2 * np.pi * harmonic * frequency * t) / harmonic
    env = attack_release(len(t), seconds(0.006, sr), seconds(min(0.08, duration / 3), sr))
    return tone * env * np.exp(-t * 1.5)


def piano(note: float, duration: float, sr: int) -> np.ndarray:
    t = np.arange(seconds(duration, sr)) / sr
    phase = 2 * np.pi * midi_hz(note) * t
    tine = np.sin(phase + 1.2 * np.exp(-t * 8) * np.sin(phase * 2))
    body = 0.78 * tine + 0.22 * np.sin(phase * 2) * np.exp(-t * 3)
    env = attack_release(len(t), seconds(0.008, sr), seconds(min(0.25, duration / 3), sr))
    return body * np.exp(-t * 1.8) * env


def pad(note: float, duration: float, sr: int) -> np.ndarray:
    t = np.arange(seconds(duration, sr)) / sr
    frequency = midi_hz(note)
    tone = (np.sin(2 * np.pi * frequency * t)
            + 0.32 * np.sin(2 * np.pi * frequency * 1.002 * t)
            + 0.16 * np.sin(2 * np.pi * frequency * 2 * t)) / 1.48
    env = attack_release(len(t), seconds(min(0.7, duration / 3), sr), seconds(min(1.0, duration / 3), sr))
    return tone * env


def drum(kind: str, sr: int) -> np.ndarray:
    duration = {"kick": 0.20, "brush": 0.13, "hat": 0.055}[kind]
    t = np.arange(seconds(duration, sr)) / sr
    if kind == "kick":
        phase = 2 * np.pi * (52 * t + 42 * (1 - np.exp(-30 * t)) / 30)
        tone = np.sin(phase) * np.exp(-t * 22)
    else:
        noise = np.random.default_rng(301 if kind == "brush" else 302).uniform(-1, 1, len(t))
        tone = fft_filter(noise, sr, highpass=1200 if kind == "brush" else 4800)
        tone *= np.exp(-t * (32 if kind == "brush" else 75))
    return tone * attack_release(len(t), seconds(0.001, sr), seconds(0.015, sr))
