// Where each instrument's recordings come from, and which pitch each file holds.
// Piano: Salamander Grand Piano (Alexander Holm, CC BY 3.0), as hosted for Tone.js.
// Strings and glockenspiel: Versilian Studios Chamber Orchestra 2 Community Edition (CC0).
// VSCO names octaves one lower than scientific pitch (its middle C is C3), so those files are
// shifted up an octave here.

import {midi} from './score.mjs';

const SALAMANDER = 'https://tonejs.github.io/audio/salamander/';
const VSCO = 'https://raw.githubusercontent.com/sgossner/VSCO-2-CE/master/';

const salamander = ['A1', 'C2', 'D#2', 'F#2', 'A2', 'C3', 'D#3', 'F#3', 'A3', 'C4', 'D#4', 'F#4', 'A4', 'C5', 'D#5', 'F#5', 'A5', 'C6', 'D#6', 'F#6', 'A6', 'C7']
  .map(name => ({midi: midi(name), url: `${SALAMANDER}${name.replace('#', 's')}.mp3`}));

const vsco = (folder, pattern, names) => names.map(name => {
  const [note, layer] = name.split(':');
  return {
    midi: midi(note) + 12,
    layer: Number(layer ?? 1),
    url: VSCO + encodeURI(`${folder}/${pattern.replace('{n}', note).replace('{v}', layer ?? '1')}`).replace(/#/g, '%23'),
  };
});

const both = notes => notes.flatMap(note => [`${note}:1`, `${note}:2`]);

export const SAMPLES = {
  piano: salamander,
  violins: vsco('Strings/Violin Section/susVib', 'VlnEns_susVib_{n}_v{v}.wav', both(['G2', 'A2', 'B2', 'D3', 'F#3', 'A3', 'C4', 'E4', 'G4', 'B4', 'D5'])),
  violas: vsco('Strings/Viola Section/susvib', 'ViolaEns_susvib_{n}_v{v}_1.wav', both(['C2', 'D2', 'E2', 'G2', 'B2', 'D3', 'F3', 'A3', 'C4', 'E4', 'G4'])),
  celli: vsco('Strings/Cello Section/susvib', 'susvib_{n}_v{v}_1.wav', ['C1:1', 'C1:3', 'E1:1', 'E1:3', 'G1:1', 'G1:3', 'B1:1', 'B1:3', 'D2:1', 'D2:3', 'F2:1', 'F2:3', 'A2:1', 'A2:3', 'C3:1', 'C3:3', 'E3:1', 'E3:3', 'G3:1', 'G3:3']),
  basses: vsco('Strings/Solo Contrabass/SusVib', 'BKCtbss_SusVib_{n}_v{v}_rr1.wav', ['F#0:1', 'F#0:3', 'A#0:1', 'A#0:3', 'C1:1', 'C1:3', 'D1:1', 'D1:3', 'E1:1', 'E1:3', 'F#1:1', 'F#1:3', 'A1:1', 'A1:3', 'C#2:1', 'C#2:3']),
  glock: vsco('Percussion/Glock', 'glock_medium_{n}.wav', ['G4', 'C5', 'G5', 'C6', 'G6', 'C7']),
};

/** The file a cache stores a sample under. */
export const cacheName = (instrument, sample) => `${instrument}/${decodeURIComponent(sample.url.split('/').pop())}`;
