// "A Day in the Menu Bar": a neo-classical piece for piano, strings, glockenspiel, and a low
// synth pulse, 76 BPM in D major. The piano's broken chords follow the shape of a Baroque
// prelude; the pulse and the space around it are the modern part. The film's scenes sit on its
// bar lines (see timeline.mjs), and bars 9-11 turn to B minor while the quota runs low.

import {BAR, BEAT, DURATION, CUES, barTime} from './timeline.mjs';

export const INSTRUMENTS = ['piano', 'violins', 'violas', 'celli', 'basses', 'glock', 'pulse', 'tick'];

const S = BEAT / 4; // a sixteenth note

const NOTE = {C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11};
/** 'F#4' → 66. */
export function midi(name) {
  const match = /^([A-G])(#|b)?(-?\d)$/.exec(name);
  if (!match) throw new Error(`bad note ${name}`);
  const [, letter, accidental, octave] = match;
  return 12 * (Number(octave) + 1) + NOTE[letter] + (accidental === '#' ? 1 : accidental === 'b' ? -1 : 0);
}
const m = names => names.split(' ').map(midi);

/** Five-voice broken-chord voicings: bass, tenor, then three upper voices. */
const V = {
  D: m('D3 F#3 A3 D4 F#4'),
  'A/C#': m('C#3 E3 A3 C#4 E4'),
  Bm7: m('B2 F#3 A3 D4 F#4'),
  'Bm7/A': m('A2 F#3 B3 D4 F#4'),
  Gmaj7: m('G2 D3 B3 D4 F#4'),
  'D/F#': m('F#2 D3 A3 D4 F#4'),
  Em7: m('E2 B2 G3 D4 G4'),
  A7sus4: m('A2 E3 G3 D4 E4'),
  A7: m('A2 E3 G3 C#4 E4'),
  Bm: m('B2 F#3 B3 D4 F#4'),
  'F#7/A#': m('A#2 F#3 A#3 C#4 E4'),
  Dhigh: m('D3 A3 D4 F#4 A4'),
  'G/B': m('B2 G3 B3 D4 G4'),
  'A/C#high': m('C#3 A3 C#4 E4 A4'),
  Em9: m('E2 B2 G3 D4 F#4'),
};

/** Bars 3-20: one or two chords per bar, each [voicing, beats]. */
const HARMONY = {
  3: [['D', 4]],
  4: [['A/C#', 4]],
  5: [['Bm7', 2], ['Bm7/A', 2]],
  6: [['Gmaj7', 4]],
  7: [['D/F#', 4]],
  8: [['Em7', 2], ['A7sus4', 1], ['A7', 1]],
  9: [['Bm', 4]],
  10: [['F#7/A#', 4]],
  11: [['Gmaj7', 2], ['A7', 2]],
  12: [['Dhigh', 4]],
  13: [['G/B', 2], ['A/C#high', 2]],
  14: [['Bm7', 4]],
  15: [['Gmaj7', 4]],
  16: [['Em9', 2], ['A7sus4', 2]],
  17: [['D/F#', 4]],
  18: [['Gmaj7', 2], ['A7sus4', 1], ['A7', 1]],
  19: [['D', 4]],
  20: [['D', 2]],
};

/** How loud each bar is played, before accents. */
const DYNAMICS = {
  1: 0.42, 2: 0.46, 3: 0.48, 4: 0.52, 5: 0.56, 6: 0.58, 7: 0.6, 8: 0.64,
  9: 0.6, 10: 0.68, 11: 0.74, 12: 0.86, 13: 0.84, 14: 0.52, 15: 0.52, 16: 0.54,
  17: 0.54, 18: 0.58, 19: 0.56, 20: 0.5,
};

/** A seeded generator, so every render humanizes the same way. */
function random(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let x = state;
    x = Math.imul(x ^ (x >>> 15), x | 1);
    x ^= x + Math.imul(x ^ (x >>> 7), x | 61);
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
}

export function compose() {
  const rand = random(76);
  const jitter = amount => (rand() * 2 - 1) * amount;
  const notes = [];
  const add = (instrument, note, time, duration, velocity) => {
    const start = Math.max(0, time);
    notes.push({
      instrument,
      midi: typeof note === 'string' ? midi(note) : note,
      time: start,
      duration: Math.min(duration, DURATION - start),
      velocity: Math.min(1, Math.max(0.02, velocity)),
    });
  };
  const piano = (note, time, duration, velocity) =>
    add('piano', note, time + jitter(0.006), duration, velocity + jitter(0.04));

  // Bars 1-2, the title: the motif alone over a sparse left hand.
  const motif = [
    [1, 1, 'F#5', 1.5], [1, 2.5, 'E5', 0.5], [1, 3, 'D5', 1], [1, 4, 'A4', 1],
    [2, 1, 'B4', 1], [2, 2, 'D5', 0.5], [2, 2.5, 'E5', 0.5], [2, 3, 'F#5', 1], [2, 4, 'E5', 1],
  ];
  for (const [bar, beat, note, beats] of motif) {
    piano(note, barTime(bar, beat), beats * BEAT * 1.6, DYNAMICS[bar] + 0.12);
  }
  for (const [bar, left] of [[1, m('D2 A2 F#3 A3')], [2, m('G2 D3 B3 D4')]]) {
    left.forEach((note, i) => piano(note, barTime(bar, 1 + i * 0.5), BAR * 1.1, DYNAMICS[bar] - 0.05));
  }

  // Bars 3-20: the broken chords. Sixteenths by day, calmer eighths at night (bars 14-16).
  for (const [barKey, chords] of Object.entries(HARMONY)) {
    const bar = Number(barKey);
    const night = bar >= 14 && bar <= 16;
    let beat = 1;
    for (const [name, beats] of chords) {
      const [bass, tenor, ...upper] = V[name];
      const start = barTime(bar, beat);
      const span = beats * BEAT;
      const level = DYNAMICS[bar];
      if (night) {
        const figure = [bass, upper[0], upper[1], upper[2], upper[1], upper[0], upper[1], upper[2]];
        for (let i = 0; i < beats * 2; i++) {
          const note = figure[i % figure.length];
          piano(note, start + i * 2 * S, note === bass ? span : 4 * S, level - (i % 2 ? 0.08 : 0));
        }
      } else {
        // Bass and tenor are struck and held; the upper voices ripple above them.
        const group = 8; // two beats: bass, tenor, then the three upper voices twice
        for (let i = 0; i < beats * 4; i++) {
          const step = i % group;
          const time = start + i * S;
          if (step === 0) piano(bass, time, Math.min(span, 2 * BEAT) - i * 0, level + 0.06);
          else if (step === 1) piano(tenor, time, 2 * BEAT - S, level - 0.04);
          else {
            const note = upper[(step - 2) % 3];
            const accent = step === 2 || step === 5 ? 0.02 : -0.06;
            piano(note, time, 3 * S, level + accent);
          }
        }
      }
      beat += beats;
    }
  }

  // Piano melody an octave above the violins in the climax, and the motif again at the end.
  const pianoTop = [
    [12, 1, 'F#6', 3], [12, 4, 'A6', 1], [13, 1, 'B6', 2], [13, 3, 'A6', 1], [13, 4, 'E6', 1],
    [19, 1, 'F#5', 1.5], [19, 2.5, 'E5', 0.5], [19, 3, 'D5', 1], [19, 4, 'A4', 1], [20, 1, 'D5', 2],
  ];
  for (const [bar, beat, note, beats] of pianoTop) {
    piano(note, barTime(bar, beat), beats * BEAT * 1.4, DYNAMICS[bar] + 0.05);
  }

  // Strings. Violas and celli sustain the harmony from bar 6; violins sing from the café on.
  for (const [barKey, chords] of Object.entries(HARMONY)) {
    const bar = Number(barKey);
    if (bar < 6) continue;
    let beat = 1;
    for (const [name, beats] of chords) {
      const [bass, tenor, a, b] = V[name];
      const start = barTime(bar, beat);
      const span = beats * BEAT + 0.12; // a little legato into the next chord
      const level = DYNAMICS[bar] * (bar >= 14 && bar <= 16 ? 0.7 : 0.85);
      add('celli', bass + (bass < midi('C3') ? 12 : 0), start, span, level);
      add('violas', tenor < midi('A3') ? a : tenor, start, span, level * 0.9);
      if (bar >= 12 && bar <= 13) add('violas', b, start, span, level * 0.8);
      beat += beats;
    }
  }
  const violins = [
    [6, 1, 'D5', 2], [6, 3, 'F#5', 1], [6, 4, 'E5', 1],
    [7, 1, 'D5', 2], [7, 3, 'A4', 2],
    [8, 1, 'B4', 1], [8, 2, 'C#5', 1], [8, 3, 'D5', 1], [8, 4, 'E5', 1],
    [9, 1, 'F#5', 3], [9, 4, 'D5', 1],
    [10, 1, 'C#5', 2], [10, 3, 'E5', 2],
    [11, 1, 'D5', 2], [11, 3, 'C#5', 1], [11, 4, 'E5', 1],
    [12, 1, 'F#5', 3], [12, 4, 'A5', 1],
    [13, 1, 'B5', 2], [13, 3, 'A5', 1], [13, 4, 'E5', 1],
    [17, 1, 'A4', 2], [17, 3, 'D5', 2],
    [18, 1, 'D5', 2], [18, 3, 'E5', 2],
    [19, 1, 'F#5', 1.5], [19, 2.5, 'E5', 0.5], [19, 3, 'D5', 1], [19, 4, 'A4', 1],
    [20, 1, 'D5', 2],
  ];
  for (const [bar, beat, note, beats] of violins) {
    add('violins', note, barTime(bar, beat), beats * BEAT + 0.1, DYNAMICS[bar] * 0.95);
  }

  // Contrabasses under the low turn and the climax, and again for the ending.
  const bassLine = [
    [9, 1, 'B1', 4], [10, 1, 'A#1', 4], [11, 1, 'G1', 2], [11, 3, 'A1', 2],
    [12, 1, 'D2', 4], [13, 1, 'B1', 2], [13, 3, 'C#2', 2],
    [17, 1, 'F#1', 4], [18, 1, 'G1', 2], [18, 3, 'A1', 2], [19, 1, 'D2', 4], [20, 1, 'D2', 2],
  ];
  for (const [bar, beat, note, beats] of bassLine) {
    add('basses', note, barTime(bar, beat), beats * BEAT + 0.1, DYNAMICS[bar] * 0.8);
  }

  // The modern pulse: eighth notes while the quota runs low, quarters through the climax.
  const pulse = [
    [9, 'B1', 4], [10, 'A#1', 4], [11, 'G1', 2], [11.5, 'A1', 2], [12, 'D2', 4], [13, 'B1', 2], [13.5, 'C#2', 2],
  ];
  for (const [position, note, beats] of pulse) {
    const bar = Math.floor(position);
    const startBeat = position % 1 ? 3 : 1;
    const eighths = bar <= 11;
    const step = eighths ? BEAT / 2 : BEAT;
    const count = beats * (eighths ? 2 : 1);
    for (let i = 0; i < count; i++) {
      const strong = eighths ? i % 2 === 0 : true;
      add('pulse', note, barTime(bar, startBeat) + i * step, step * 0.8, (strong ? 0.7 : 0.45) * DYNAMICS[bar]);
    }
  }

  // Bells: a warning when the robot turns red, a bright run when the quota refills.
  for (const cue of CUES) {
    if (cue.kind === 'alert') {
      add('glock', 'C#6', cue.time, 2, 0.32);
      add('glock', 'F#5', cue.time + S, 2, 0.24);
    } else if (cue.kind === 'reset') {
      ['D6', 'F#6', 'A6', 'D7', 'A6', 'D7'].forEach((note, i) => add('glock', note, cue.time + i * S, 2.5, 0.55 - i * 0.05));
    } else if (cue.kind === 'click') {
      add('tick', 'C8', cue.time, 0.05, 0.5);
    } else if (cue.kind === 'key') {
      add('tick', 'G7', cue.time - 0.07, 0.04, 0.35);
      add('tick', 'A7', cue.time, 0.04, 0.4);
    }
  }
  add('glock', 'D6', barTime(19), 3, 0.28);

  // The last chord, rung on beat 3 of bar 20 and left to fade into the tail.
  const final = barTime(20, 3);
  const ring = DURATION - final;
  for (const note of m('D2 A2 D3 F#3 A3 D4 F#4 A4 D5')) add('piano', note, final + (note - 38) * 0.004, ring - 0.2, 0.5);
  add('celli', 'D3', final, ring, 0.4);
  add('violas', 'A3', final, ring, 0.36);
  add('violins', 'F#4', final, ring, 0.34);
  add('violins', 'D5', final, ring, 0.3);
  add('basses', 'D2', final, ring, 0.36);
  add('glock', 'A6', final + 0.02, ring, 0.2);

  return notes.sort((a, b) => a.time - b.time || a.midi - b.midi);
}
