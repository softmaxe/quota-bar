// Checks the contracts the picture, the score, and the render script share.
// Run with: node --test docs/demo/
import test from 'node:test';
import assert from 'node:assert/strict';
import {BARS, DURATION, SCENES, CUES, barTime, sceneAt} from './timeline.mjs';
import {compose, INSTRUMENTS} from './score.mjs';
import {COPY, LANGUAGES} from './copy.mjs';

test('scenes cover the musical timeline without gaps or overlaps', () => {
  let end = 0;
  for (const scene of SCENES) {
    assert.equal(scene.start, end, scene.id);
    assert.ok(scene.end > scene.start, scene.id);
    end = scene.end;
  }
  assert.equal(end, barTime(BARS + 1));
  assert.ok(DURATION >= end);
});

test('sceneAt finds the scene playing at a time and clamps outside the film', () => {
  for (const scene of SCENES) {
    assert.equal(sceneAt(scene.start), scene);
    assert.equal(sceneAt(scene.end - 1e-6), scene);
  }
  assert.equal(sceneAt(-5), SCENES[0]);
  assert.equal(sceneAt(DURATION + 5), SCENES.at(-1));
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

test('the score is deterministic and stays inside the film', () => {
  const first = compose();
  assert.deepEqual(compose(), first);
  assert.ok(first.length > 0);
  for (const note of first) {
    assert.ok(INSTRUMENTS.includes(note.instrument), note.instrument);
    assert.ok(note.time >= 0 && note.time + note.duration <= DURATION + 1e-9, `${note.instrument} ${note.time}`);
    assert.ok(note.velocity > 0 && note.velocity <= 1);
    assert.ok(Number.isInteger(note.midi) && note.midi >= 21 && note.midi <= 108);
  }
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
