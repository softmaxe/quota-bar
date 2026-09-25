// The film's clock. The picture and the score both read their timing from here, so a cut, a
// click, and the note under it stay on the same beat when either side changes.

export const BPM = 76;
/** One 4/4 bar, in seconds. */
export const BAR = 240 / BPM;
export const BEAT = BAR / 4;
export const BARS = 20;
/** Room after the last bar for the final chord and its reverb to die away. */
export const TAIL = 2;

/** Start of a 1-based bar, plus an optional 1-based beat inside it. */
export const barTime = (bar, beat = 1) => (bar - 1) * BAR + (beat - 1) * BEAT;
export const at = barTime;

export const DURATION = barTime(BARS + 1) + TAIL;

const LAYOUT = [
  ['title', 2],
  ['morning', 3],
  ['cafe', 3],
  ['low', 3],
  ['reset', 2],
  ['night', 3],
  ['export', 2],
  ['outro', 2],
];

export const SCENES = (() => {
  let startBar = 1;
  return LAYOUT.map(([id, bars]) => {
    const scene = {id, startBar, bars, start: barTime(startBar), end: barTime(startBar + bars)};
    startBar += bars;
    return Object.freeze(scene);
  });
})();

export function sceneAt(time) {
  for (const scene of SCENES) if (time < scene.end) return scene;
  return SCENES[SCENES.length - 1];
}

export const frameCount = fps => Math.ceil(DURATION * fps);

/**
 * Moments the viewer should hear as well as see. `kind` picks the sound: a trackpad click, a
 * keyboard shortcut, the menu bar robot turning red, or a quota window resetting.
 */
export const CUES = Object.freeze([
  {scene: 'morning', kind: 'click', id: 'open-card', time: at(4, 2)},
  {scene: 'morning', kind: 'click', id: 'reset-menu', time: at(5, 1)},
  {scene: 'morning', kind: 'click', id: 'show-reset-date', time: at(5, 2)},
  {scene: 'cafe', kind: 'key', id: 'show-claude', keys: ['⌘', '2'], time: at(7, 2)},
  {scene: 'cafe', kind: 'click', id: 'pace-details', time: at(7, 4)},
  {scene: 'low', kind: 'alert', id: 'robot-red', time: at(10, 1)},
  {scene: 'low', kind: 'click', id: 'open-card', time: at(10, 3)},
  {scene: 'low', kind: 'key', id: 'show-codex', keys: ['⌘', '1'], time: at(11, 3)},
  {scene: 'reset', kind: 'click', id: 'open-card', time: at(12, 3)},
  {scene: 'reset', kind: 'reset', id: 'refill', time: at(13, 1)},
  {scene: 'night', kind: 'click', id: 'cost-mode', time: at(15, 1)},
  {scene: 'night', kind: 'click', id: 'pin-day', time: at(15, 4)},
  {scene: 'night', kind: 'click', id: 'model-breakdown', time: at(16, 2)},
  {scene: 'export', kind: 'key', id: 'open-settings', keys: ['⌘', ','], time: at(17, 2)},
  {scene: 'export', kind: 'click', id: 'export-report', time: at(17, 4)},
  {scene: 'export', kind: 'click', id: 'report-language', time: at(18, 3)},
].map(Object.freeze));

export const cue = (scene, id) => CUES.find(candidate => candidate.scene === scene && candidate.id === id).time;
