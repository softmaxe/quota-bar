// Checks the contracts the picture, the score, and the render script share.
// Run with: node --test docs/demo/
import test from 'node:test';
import assert from 'node:assert/strict';
import {BPM, BAR, BARS, DURATION, SCENES, CUES, barTime, sceneAt, frameCount} from './timeline.mjs';
import {compose, INSTRUMENTS} from './score.mjs';
import {COPY, LANGUAGES} from './copy.mjs';

test('a bar lasts four beats at the agreed tempo', () => {
  assert.equal(BPM, 76);
  assert.ok(Math.abs(BAR - 240 / 76) < 1e-12);
  assert.equal(barTime(1), 0);
  assert.ok(Math.abs(barTime(21) - 20 * BAR) < 1e-9);
});

test('scenes tile all twenty bars in order, with nothing skipped', () => {
  assert.deepEqual(SCENES.map(scene => scene.id), ['title', 'morning', 'cafe', 'low', 'reset', 'night', 'export', 'outro']);
  let next = 1;
  for (const scene of SCENES) {
    assert.equal(scene.startBar, next, scene.id);
    assert.ok(scene.bars >= 2, scene.id);
    assert.equal(scene.start, barTime(scene.startBar));
    assert.equal(scene.end, barTime(scene.startBar + scene.bars));
    next += scene.bars;
  }
  assert.equal(next - 1, BARS);
  assert.equal(BARS, 20);
});

test('the video runs a short tail past the last bar so the final chord can ring', () => {
  assert.ok(DURATION > barTime(BARS + 1));
  assert.ok(DURATION - barTime(BARS + 1) <= 3);
  assert.ok(DURATION >= 60 && DURATION <= 70);
});

test('sceneAt finds the scene playing at a time and clamps outside the film', () => {
  assert.equal(sceneAt(0).id, 'title');
  assert.equal(sceneAt(barTime(3)).id, 'morning');
  assert.equal(sceneAt(barTime(3) - 1e-6).id, 'title');
  assert.equal(sceneAt(barTime(12)).id, 'reset');
  assert.equal(sceneAt(-5).id, 'title');
  assert.equal(sceneAt(DURATION + 5).id, 'outro');
});

test('frame count covers the whole duration', () => {
  assert.equal(frameCount(30), Math.ceil(DURATION * 30));
});

test('every cue falls inside the scene it belongs to', () => {
  assert.ok(CUES.length > 0);
  for (const cue of CUES) {
    const scene = SCENES.find(candidate => candidate.id === cue.scene);
    assert.ok(scene, `unknown scene ${cue.scene}`);
    assert.ok(cue.time >= scene.start && cue.time < scene.end, `${cue.kind} at ${cue.time} is outside ${scene.id}`);
    assert.ok(['click', 'key', 'reset', 'alert'].includes(cue.kind), cue.kind);
  }
  const times = CUES.map(cue => cue.time);
  assert.deepEqual(times, [...times].sort((a, b) => a - b));
});

test('the quota reset lands on a strong beat of the climax', () => {
  const reset = CUES.find(cue => cue.kind === 'reset');
  const beat = BAR / 4;
  const beats = (reset.time - barTime(12)) / beat;
  assert.equal(reset.scene, 'reset');
  assert.ok(Math.abs(beats - Math.round(beats)) < 1e-9);
  assert.ok(Math.round(beats) % 2 === 0, 'beat 1 or 3');
});

test('the score is deterministic and stays inside the film', () => {
  const first = compose();
  assert.deepEqual(compose(), first);
  assert.ok(first.length > 200);
  for (const note of first) {
    assert.ok(INSTRUMENTS.includes(note.instrument), note.instrument);
    assert.ok(note.time >= 0 && note.time + note.duration <= DURATION + 1e-9, `${note.instrument} ${note.time}`);
    assert.ok(note.velocity > 0 && note.velocity <= 1);
    assert.ok(Number.isInteger(note.midi) && note.midi >= 21 && note.midi <= 108);
  }
});

const pitchClasses = notes => new Set(notes.map(note => note.midi % 12));
const inBars = (notes, from, to) => notes.filter(note => note.time >= barTime(from) - 1e-9 && note.time < barTime(to + 1) - 1e-9);
const D_MAJOR = new Set([2, 4, 6, 7, 9, 11, 1]);

test('the opening stays in D major and the piano plays alone', () => {
  const opening = inBars(compose(), 1, 2);
  assert.ok(opening.length > 0);
  for (const pc of pitchClasses(opening)) assert.ok(D_MAJOR.has(pc), `pitch class ${pc}`);
  assert.deepEqual([...new Set(opening.map(note => note.instrument))], ['piano']);
});

test('the running-low bars lean on B minor with the pulse underneath', () => {
  const low = inBars(compose(), 9, 11);
  const firstBar = inBars(low, 9, 9);
  const bassPcs = firstBar.filter(note => note.midi < 55).map(note => note.midi % 12);
  assert.ok(bassPcs.includes(11), 'B in the bass');
  assert.ok(low.some(note => note.instrument === 'pulse'));
  assert.ok(!inBars(compose(), 1, 8).some(note => note.instrument === 'pulse'));
});

test('the reset rings a bell and the film ends on a D major chord', () => {
  const notes = compose();
  const reset = CUES.find(cue => cue.kind === 'reset');
  assert.ok(notes.some(note => note.instrument === 'glock' && Math.abs(note.time - reset.time) < 0.01));
  const last = Math.max(...notes.map(note => note.time));
  const finalChord = notes.filter(note => note.time > last - 0.5);
  assert.deepEqual([...pitchClasses(finalChord)].sort((a, b) => a - b), [2, 6, 9]);
});

test('English and Chinese copy cover the same lines and none is empty', () => {
  assert.deepEqual(LANGUAGES, ['en', 'zh']);
  const keys = Object.keys(COPY.en).sort();
  assert.deepEqual(Object.keys(COPY.zh).sort(), keys);
  for (const language of LANGUAGES) {
    for (const key of keys) assert.ok(String(COPY[language][key]).trim(), `${language}.${key}`);
  }
  for (const scene of SCENES) assert.ok(keys.includes(`caption.${scene.id}`), scene.id);
});
