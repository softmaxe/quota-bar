// The director: builds the stage once, then turns any moment of the film into a frame.
// `window.seek(seconds)` draws that moment; nothing depends on wall-clock time, so the render
// script can step through frames one by one.

import {SCENES, DURATION, at, cue} from './timeline.mjs';
import {COPY} from './copy.mjs';
import {clamp, lerp, seg, ease, track, fade, wobble} from './motion.mjs';
import {roomSVG, ROOM_IDS} from './rooms.mjs';
import {screenHTML, bindScreen, renderScreen, targetOf, SCREEN_W, ROBOT, ACCENT} from './ui.mjs';

const params = new URLSearchParams(location.search);
const LANG = params.get('lang') === 'zh' ? 'zh' : 'en';
const copy = key => COPY[LANG][key];
document.documentElement.lang = LANG;

const S = Object.fromEntries(SCENES.map(scene => [scene.id, scene]));

// ----------------------------------------------------------------------------------------------
// World geometry. The screen shows 1440 × 900 points inside an 800 × 500 panel.

const PANEL = {x: 560, y: 136, w: 800};
const K = PANEL.w / SCREEN_W;
const world = (px, py) => ({x: PANEL.x + px * K, y: PANEL.y + py * K});
/** A camera that puts screen point (px, py) at frame point (ax, ay), magnified z times. */
const shot = (px, py, z, ax = 1150, ay = 540) => ({...world(px, py), z, ax, ay});

const ENV = {x: 960, y: 540, z: 1, ax: 960, ay: 540};
const ENV_NEAR = {x: 960, y: 470, z: 1.14, ax: 960, ay: 540};
const ENV_FAR = {x: 960, y: 500, z: 0.86, ax: 960, ay: 540};
const drift = (camera, amount = 1.04) => ({...camera, z: camera.z * amount});

const ROBOT_SHOT = shot(ROBOT.x, 70, 4.2, 1160, 400);
const ROBOT_RED = shot(ROBOT.x, 36, 5.4, 1040, 470);
const CARD_TOP = shot(ROBOT.x, 190, 2.9, 1260, 520);
const CARD_WIDE = shot(ROBOT.x, 200, 2.55, 1260, 520);
const CARD_PACE = shot(ROBOT.x, 300, 2.7, 1260, 520);
const CARD_USAGE = shot(ROBOT.x, 410, 2.85, 1260, 540);
const CARD_BREAKDOWN = shot(ROBOT.x, 480, 2.8, 1260, 540);
const SETTINGS_SHOT = shot(720, 400, 2.4, 960, 520);
const REPORT_SHOT = shot(720, 400, 2.25, 1000, 560);

const CAMERA = [
  [0, ENV_NEAR], [5.3, ENV_NEAR], [7.9, ENV, ease.glide],
  // Morning: into the menu bar, open the card, flip the reset labels.
  [8.4, ENV], [9.8, ROBOT_SHOT, ease.glide], [10.45, ROBOT_SHOT], [11.5, CARD_TOP, ease.glide], [14.6, drift(CARD_TOP)], [15.95, ENV, ease.glide],
  // Café: ⌘2, then the pace details.
  [17.2, drift(ENV, 1.02)], [18.6, CARD_TOP, ease.glide], [21.25, CARD_TOP], [22.3, CARD_PACE, ease.glide], [24.2, drift(CARD_PACE)], [25.4, ENV, ease.glide],
  // Afternoon: the robot turns red, the card says why, ⌘1.
  [26.5, drift(ENV, 1.02)], [27.9, ROBOT_RED, ease.glide], [30.05, drift(ROBOT_RED, 1.05)], [31.05, CARD_TOP, ease.glide], [33.75, drift(CARD_TOP, 1.02)], [34.85, ENV, ease.glide],
  // 6 PM: the session resets.
  [35.4, ENV], [36.45, CARD_WIDE, ease.glide], [37.7, CARD_WIDE], [39.8, drift(CARD_WIDE, 1.12)], [41.1, ENV, ease.glide],
  // Night: cost, a pinned day, its models.
  [42.2, drift(ENV, 1.02)], [43.45, CARD_USAGE, ease.glide], [48.0, drift(CARD_USAGE, 1.02)], [48.9, CARD_BREAKDOWN, ease.glide], [49.6, CARD_BREAKDOWN], [50.65, ENV, ease.glide],
  // Friday: export the report and read it in Chinese.
  [51.0, ENV], [52.0, SETTINGS_SHOT, ease.glide], [53.7, drift(SETTINGS_SHOT, 1.02)], [54.55, REPORT_SHOT, ease.glide], [56.1, drift(REPORT_SHOT, 1.03)], [57.5, ENV, ease.glide],
  [61, ENV_FAR, ease.sine],
];

/** Multipliers for the laptop and hands, so they sit in each room's light. */
const TINT = {
  morning: [1, 0.97, 0.92], cafe: [1, 0.95, 0.88], low: [0.9, 0.94, 1], reset: [1.04, 0.86, 0.74],
  night: [0.44, 0.46, 0.64], export: [0.54, 0.48, 0.66],
};
const GLOW = {morning: 0.1, cafe: 0.1, low: 0.14, reset: 0.12, night: 0.6, export: 0.5};

// ----------------------------------------------------------------------------------------------
// Readings. What each provider shows in each scene (sample data).

const reading = (provider, plan, session, weekly, pace) => ({provider, plan, session, weekly, pace: pace ?? NO_PACE});
const q = (pct, summary, reset, resetClock = '', summaryColor = '') => ({pct, summary, reset, resetClock, summaryColor});
const ORANGE = '#e8871e';
const RED = '#ff3b30';
const NO_PACE = {
  session: {title: 'Session · On pace', l1: 'Lasts until reset', l2: 'Expected 70% left now', l3: '1.2× headroom at current pace', expected: 70},
  weekly: {title: 'Weekly · On pace', l1: 'Lasts until reset', l2: 'Expected 80% left now', l3: '1.1× headroom at current pace', expected: 80},
};

const READINGS = {
  morning: reading('codex', 'Plus', q(88, 'Lasts until reset', 'in 2h 59m', '10:49 AM'), q(86, 'Lasts until reset', 'in 4d 23h', 'Tue 6:49 AM')),
  cafeCodex: reading('codex', 'Plus', q(71, 'Lasts until reset', 'in 19m'), q(84, 'Lasts until reset', 'in 4d 20h')),
  cafeClaude: reading('claude', 'Pro', q(62, 'Lasts until reset', 'in 3h 40m'), q(58, 'Runs out in 1d 18h', 'in 2d 4h', '', ORANGE), {
    session: {title: 'Session · 12% in reserve', l1: 'Lasts until reset', l2: 'Expected 50% left now', l3: '1.6× headroom at current pace', expected: 50},
    weekly: {title: 'Weekly · 6% in deficit', l1: 'Runs out in 1d 18h', l2: 'Expected 64% left now', l3: '0.8× headroom at current pace', expected: 64},
  }),
  lowClaude: reading('claude', 'Pro', q(0, 'Limit reached', 'in 2h 50m', '', RED), q(31, 'Runs out in 1d 2h', 'in 1d 23h', '', ORANGE)),
  lowCodex: reading('codex', 'Plus', q(64, 'Lasts until reset', 'in 2h 41m'), q(79, 'Lasts until reset', 'in 4d 15h')),
  reset: reading('claude', 'Pro', q(100, 'Lasts until reset', 'in 5h'), q(30, 'Lasts until reset', 'in 1d 23h')),
  night: reading('claude', 'Pro', q(78, 'Lasts until reset', 'in 1h 20m'), q(27, 'Lasts until reset', 'in 1d 20h')),
};

const CLOCK = {
  title: 'Thu Sep 24  7:50 AM', morning: 'Thu Sep 24  7:50 AM', cafe: 'Thu Sep 24  10:30 AM', low: 'Thu Sep 24  3:10 PM',
  night: 'Thu Sep 24  9:40 PM', export: 'Fri Sep 25  6:30 PM', outro: 'Fri Sep 25  6:30 PM',
};

// ----------------------------------------------------------------------------------------------
// Stage

/** The back of a hand resting on the keys, fingers curled away from the viewer. */
const hand = (side, x, y, angle) => {
  const inner = side === 'left' ? 1 : -1;
  const fingers = [0, 1, 2, 3].map(i => `<rect data-finger="${side}-${i}" x="${-39 + i * 20}" y="${-104 + Math.abs(i - 1.5) * 4}" width="18" height="34" rx="9" fill="#DDA784"/>`).join('');
  return `<g data-hand="${side}" transform="translate(${x} ${y}) rotate(${angle}) scale(.95)">
    <g class="h">${fingers}
      <path d="M-44 6 C-50 -26 -48 -58 -40 -80 Q0 -94 40 -80 C48 -58 50 -26 44 6 Z" fill="#E5B492"/>
      ${[0, 1, 2, 3].map(i => `<ellipse cx="${-30 + i * 20}" cy="${-80 + Math.abs(i - 1.5) * 3}" rx="7" ry="4" fill="#F0C6A6" opacity=".7"/>`).join('')}
      <path d="M${inner * 38} -20 q${inner * 20} -14 ${inner * 22} -46 q${inner * 2} -12 ${inner * -10} -10 q${inner * -14} 22 ${inner * -24} 34 z" fill="#D9A480"/>
    </g>
  </g>`;
};

/** Forearms in a soft sage sweater, reaching in from below the frame. */
const handsSVG = () => `
  <svg id="hands" viewBox="0 0 1920 1080" width="1920" height="1080">
    <path d="M430 1080 L716 812 Q764 780 812 812 L700 1080 Z" fill="#7F9A8A"/>
    <path d="M1480 1080 L1156 824 Q1106 794 1060 830 L1210 1080 Z" fill="#7F9A8A"/>
    ${hand('left', 768, 806, 22)}
    ${hand('right', 1104, 826, -26)}
    <path d="M704 824 Q760 776 826 812 L812 850 Q762 822 716 862 Z" fill="#6C8777"/>
    <path d="M1170 838 Q1110 796 1046 832 L1060 868 Q1110 840 1160 876 Z" fill="#6C8777"/>
  </svg>`;

const stage = document.getElementById('stage');
stage.innerHTML = `
  <div id="camera">
    <div id="rooms" class="layer">${ROOM_IDS.map(roomSVG).join('')}</div>
    <div id="rig">
      <svg width="0" height="0" style="position:absolute"><filter id="tint" color-interpolation-filters="sRGB"><feColorMatrix id="tint-matrix" type="matrix" values="1 0 0 0 0 0 1 0 0 0 0 0 1 0 0 0 0 0 1 0"/></filter></svg>
      <div id="body" class="layer" style="filter:url(#tint)">
        <div class="deck"><div class="keys">${'<i></i>'.repeat(75)}</div><div class="trackpad"></div></div>
        <div class="hinge"></div>
        <div class="bezel"></div>
        ${handsSVG()}
      </div>
      <div id="screen" data-theme="light">${screenHTML()}</div>
      <div id="screen-glow"></div>
    </div>
  </div>
  <div id="void">
    <div class="titlecard">
      <img class="icon" src="../../Resources/AppIcon.png" alt="">
      <div class="wordmark">QuotaBar</div>
      <div class="tagline">${copy('caption.title')}</div>
      <div class="title-bars">
        ${['codex', 'claude'].map(p => `<div><div class="tb-l"><span>${p === 'codex' ? 'Codex' : 'Claude'}</span><span class="tb-v" data-tb="${p}"></span></div><div class="tb"><i data-tb-fill="${p}" style="background:${ACCENT[p]}"></i></div></div>`).join('')}
      </div>
    </div>
    <div class="outro">
      <img class="icon" src="../../Resources/AppIcon.png" alt="">
      <div class="wordmark">QuotaBar</div>
      <div class="tagline">${copy('caption.outro')}</div>
      <div class="install"><span class="lbl">${copy('outro.install')}</span><code><span class="dim">$</span>brew install --cask softmaxe/tap/quota-bar</code></div>
      <div class="repo">github.com/softmaxe/quota-bar</div>
      <div class="requires">${copy('outro.requires')}</div>
    </div>
  </div>
  <div id="overlay">
    <div class="vignette"></div>
    <div class="scrim"></div>
    <div class="timecard"><div class="place"></div><div class="time"></div><div class="rule"></div></div>
    <div class="caption"><span class="accent"></span><span class="text"></span></div>
    <div class="keycaps"></div>
  </div>
  <div id="blackout"></div>`;

const $ = selector => stage.querySelector(selector);
const $$ = selector => [...stage.querySelectorAll(selector)];
const dom = {
  camera: $('#camera'),
  rooms: Object.fromEntries(ROOM_IDS.map(id => [id, $(`[data-room="${id}"]`)])),
  tint: $('#tint-matrix'),
  glow: $('#screen-glow'),
  void: $('#void'),
  title: $('.titlecard'),
  titleParts: [...$('.titlecard').children],
  tb: Object.fromEntries(['codex', 'claude'].map(p => [p, {value: $(`[data-tb="${p}"]`), fill: $(`[data-tb-fill="${p}"]`)}])),
  outro: $('.outro'),
  outroParts: [...$('.outro').children],
  timecard: $('.timecard'),
  place: $('.timecard .place'),
  time: $('.timecard .time'),
  caption: $('.caption'),
  captionText: $('.caption .text'),
  keycaps: $('.keycaps'),
  scrim: $('.scrim'),
  overlay: $('#overlay'),
  blackout: $('#blackout'),
  fingers: $$('[data-finger]'),
  hands: {left: $('[data-hand="left"] .h'), right: $('[data-hand="right"] .h')},
  anim: {
    steam: $$('[data-steam]'), beams: $$('[data-beam]'), bokeh: $$('[data-bokeh]'), lamps: $$('[data-lamp]'),
    blinds: $$('[data-blinds]'), stars: $$('[data-star]'), bulbs: $$('[data-bulb]'), suns: $$('[data-sun]'),
    clocks: ['low', 'reset'].map(id => ({
      id, hour: dom0(`[data-room="${id}"] [data-clock-hour]`), minute: dom0(`[data-room="${id}"] [data-clock-minute]`),
    })),
  },
};
function dom0(selector) { return stage.querySelector(selector); }
const screen = bindScreen($('#screen'));

// ----------------------------------------------------------------------------------------------
// Frame

const style = (node, property, value) => {
  if (node.style[property] !== value) node.style[property] = value;
};
const setText = (node, value) => {
  if (node.textContent !== value) node.textContent = value;
};

/** Pointer targets, measured once from the laid-out screen. */
let T = null;

const pulse = (time, moment, width = 0.09) => clamp(1 - Math.abs(time - moment) / width);

/** The card's reading, tab, and body transition around a provider switch at `moment`. */
function providerSwitch(time, moment, before, after) {
  const p = seg(time, moment, moment + 0.36);
  const toClaude = after.provider === 'claude';
  return {
    reading: p < 0.5 ? before : after,
    tab: lerp(toClaude ? 0 : 1, toClaude ? 1 : 0, ease.inOut(p)),
    bodyOpacity: 1 - Math.sin(Math.PI * p) * 0.9,
    bodyShift: Math.sin(Math.PI * p) * (toClaude ? -12 : 12) * (p < 0.5 ? 1 : -1),
  };
}

function cardState(time) {
  const base = {open: 0, tab: 0, bodyOpacity: 1, bodyShift: 0, resetMode: 0, pace: 0, mode: 0, day: 9, breakdown: 0, reading: READINGS.morning};
  const opened = (start, end) => fade(time, start, start + 0.28, end, end + 0.3, ease.out);

  if (time < S.cafe.start) {
    const open = cue('morning', 'open-card');
    const r = structuredClone(READINGS.morning);
    // Bars fill in as the card opens.
    const fill = ease.out(seg(time, open + 0.15, open + 1.05));
    r.session.pct *= fill;
    r.weekly.pct *= fill;
    return {...base, open: opened(open, 15.2), reading: r, resetMode: ease.inOut(seg(time, cue('morning', 'reset-mode'), cue('morning', 'reset-mode') + 0.32))};
  }
  if (time < S.low.start) {
    return {
      ...base, open: opened(17.75, 24.9),
      ...providerSwitch(time, cue('cafe', 'show-claude'), READINGS.cafeCodex, READINGS.cafeClaude),
      pace: seg(time, cue('cafe', 'pace-details'), cue('cafe', 'pace-details') + 0.5),
    };
  }
  if (time < S.reset.start) {
    return {...base, open: opened(cue('low', 'open-card'), 34.3), ...providerSwitch(time, cue('low', 'show-codex'), READINGS.lowClaude, READINGS.lowCodex)};
  }
  if (time < S.night.start) {
    const refill = cue('reset', 'refill');
    const r = structuredClone(READINGS.reset);
    // The headline shows the new reading at once; the bar climbs from empty to full.
    r.session.barPct = 100 * ease.out(seg(time, refill, refill + 0.95));
    r.session.sheen = fade(time, refill + 0.15, refill + 0.35, refill + 1.1, refill + 1.4);
    r.session.sheenAt = seg(time, refill + 0.15, refill + 1.35);
    r.session.glow = fade(time, refill, refill + 0.25, refill + 0.9, refill + 1.8);
    const before = time < refill;
    if (before) Object.assign(r.session, {summary: 'Limit reached', summaryColor: RED, reset: 'in 0m', barPct: 0});
    return {...base, open: opened(cue('reset', 'open-card'), 40.6), tab: 1, reading: r};
  }
  if (time < S.export.start) {
    const cost = cue('night', 'cost-mode');
    return {
      ...base, open: opened(42.55, 50.1), tab: 1, reading: READINGS.night,
      mode: seg(time, cost, cost + 0.36), day: hoveredDay(time),
      breakdown: seg(time, cue('night', 'model-breakdown'), cue('night', 'model-breakdown') + 0.5),
    };
  }
  return base;
}

/** The chart day under the pointer while it sweeps the bars, then the pinned day. */
function hoveredDay(time) {
  if (time < 44.75 || !T) return 9;
  if (time >= cue('night', 'pin-day')) return 7;
  const x = pointerAt(time).x;
  let best = 0;
  for (let i = 0; i < 10; i++) if (Math.abs(T[`col-${i}`].x - x) < Math.abs(T[`col-${best}`].x - x)) best = i;
  return best;
}

function pointerKeys() {
  const r = T.robot;
  const click = (point, dx = 1, dy = 2) => ({x: point.x + dx, y: point.y + dy});
  return [
    [0, {x: 900, y: 460}],
    // Morning
    [8.7, {x: 900, y: 460}], [10.12, click(r), ease.out], [11.35, click(r)], [12.5, click(T['reset-label']), ease.inOut], [13.7, {x: T['reset-label'].x - 50, y: T['reset-label'].y + 70}],
    // Café
    [18.2, {x: T['pace-details'].x - 170, y: T['pace-details'].y + 150}], [20.2, {x: T['pace-details'].x - 170, y: T['pace-details'].y + 150}], [21.18, click(T['pace-details']), ease.out], [22.4, {x: T['pace-details'].x + 50, y: T['pace-details'].y + 30}],
    // Afternoon
    [28.7, {x: r.x - 220, y: 210}], [29.87, click(r), ease.out], [31.2, {x: r.x - 70, y: 300}],
    // 6 PM
    [35.3, {x: r.x - 240, y: 280}], [36.18, click(r), ease.out], [37.4, {x: r.x - 100, y: 340}],
    // Night
    [42.9, {x: T.cost.x - 170, y: T.cost.y + 110}], [44.07, click(T.cost), ease.out], [44.85, click(T['col-2'], 0, 10), ease.inOut],
    [46.0, click(T['col-8'], 0, 10), ease.sine], [46.45, click(T['col-7'], 0, 10), ease.inOut], [47.1, click(T['col-7'], 0, 10)],
    [48.02, click(T['model-breakdown']), ease.inOut], [49.1, {x: T['model-breakdown'].x - 30, y: T['model-breakdown'].y + 60}],
    // Friday
    [51.6, {x: 700, y: 640}], [52.75, click(T['export-button']), ease.out], [53.7, {x: T['export-button'].x - 90, y: T['export-button'].y + 90}],
    [54.4, {x: T['export-button'].x - 90, y: T['export-button'].y + 90}], [55.12, click(T['report-chinese']), ease.inOut], [56.2, {x: T['report-chinese'].x - 60, y: T['report-chinese'].y + 70}],
  ];
}
let POINTER = null;
const pointerAt = time => track(time, POINTER, ease.inOut);

function pointerState(time) {
  if (!POINTER) return {x: 900, y: 460, visible: 0, press: 0, ripple: 0};
  const {x, y} = pointerAt(time);
  const visible = Math.max(
    fade(time, 8.7, 9.0, 14.6, 15.0), fade(time, 18.2, 18.5, 24.2, 24.6), fade(time, 28.7, 29.0, 33.8, 34.2),
    fade(time, 35.3, 35.6, 39.8, 40.2), fade(time, 42.9, 43.2, 49.5, 49.9), fade(time, 51.6, 51.9, 56.2, 56.6),
  );
  const clicks = [cue('morning', 'open-card'), cue('morning', 'reset-mode'), cue('cafe', 'pace-details'), cue('low', 'open-card'), cue('reset', 'open-card'),
    cue('night', 'cost-mode'), cue('night', 'pin-day'), cue('night', 'model-breakdown'), cue('export', 'export-report'), cue('export', 'report-chinese')];
  let press = 0;
  let ripple = 0;
  for (const moment of clicks) {
    press = Math.max(press, pulse(time, moment));
    if (time >= moment && time < moment + 0.5) ripple = seg(time, moment, moment + 0.5);
  }
  return {x, y, visible, press, ripple};
}

function screenState(time) {
  const scene = currentScene(time);
  const dark = time >= 40.75;
  const redOn = seg(time, cue('low', 'robot-red'), cue('low', 'robot-red') + 0.25) * (1 - seg(time, cue('low', 'show-codex') + 0.1, cue('low', 'show-codex') + 0.4));
  const redAt = cue('low', 'robot-red');
  const pulses = time >= redAt && time < redAt + 2.4 ? Math.pow(Math.sin(((time - redAt) / 1.2) * Math.PI), 2) : 0;
  let clock = CLOCK[scene] ?? CLOCK.morning;
  if (scene === 'reset') clock = time < at(12, 2) ? 'Thu Sep 24  5:59 PM' : 'Thu Sep 24  6:00 PM';
  const card = cardState(time);
  if (card.reading.session.barPct !== undefined) {
    // Headline keeps the new reading while the bar animates.
    card.reading = structuredClone(card.reading);
  }
  const exportClick = cue('export', 'export-report');
  return {
    theme: dark ? 'dark' : 'light',
    wallpaper: scene === 'title' ? 'morning' : scene === 'outro' ? 'export' : scene,
    clock,
    robot: {red: redOn, pulse: pulses * redOn},
    typed: track(time, [[0, 3], [S.morning.end, 8], [S.cafe.end, 13], [26.4, 14], [33, 22], [S.night.start, 24]], ease.linear),
    caretBlink: Math.floor(time * 1.8) % 2 === 0,
    card,
    settings: {
      open: fade(time, cue('export', 'open-settings'), cue('export', 'open-settings') + 0.35, 57.6, 58.2, ease.out),
      status: time < exportClick + 0.08 ? 'idle' : time < exportClick + 0.7 ? 'busy' : 'saved',
      spin: time * 1.4,
      press: pulse(time, exportClick, 0.1),
    },
    report: {open: fade(time, 53.8, 54.35, 57.6, 58.2, ease.out), zh: ease.inOut(seg(time, cue('export', 'report-chinese'), cue('export', 'report-chinese') + 0.28))},
    pointer: pointerState(time),
  };
}

function currentScene(time) {
  for (const scene of SCENES) if (time < scene.end) return scene.id;
  return 'outro';
}

function roomOpacities(time) {
  const rooms = ['morning', 'cafe', 'low', 'reset', 'night', 'export'];
  return rooms.map((id, i) => {
    const scene = S[id];
    const next = S[rooms[i + 1]];
    const incoming = i === 0 ? 1 : seg(time, scene.start - 0.6, scene.start + 0.45);
    const covered = next && time > next.start + 0.5 ? 0 : 1;
    return [id, incoming * covered];
  });
}

function frame(time) {
  // Camera.
  const cam = track(time, CAMERA, ease.glide);
  style(dom.camera, 'transform', `translate(${(cam.ax - cam.x * cam.z).toFixed(2)}px, ${(cam.ay - cam.y * cam.z).toFixed(2)}px) scale(${cam.z.toFixed(4)})`);

  // Rooms, and the laptop's light.
  let tint = TINT.morning;
  let glow = GLOW.morning;
  for (const [id, opacity] of roomOpacities(time)) {
    style(dom.rooms[id], 'opacity', opacity.toFixed(3));
    style(dom.rooms[id], 'visibility', opacity > 0 ? 'visible' : 'hidden');
    tint = tint.map((channel, i) => lerp(channel, TINT[id][i], opacity));
    glow = lerp(glow, GLOW[id], opacity);
  }
  const [r, g, b] = tint.map(channel => channel.toFixed(3));
  const matrix = `${r} 0 0 0 0 0 ${g} 0 0 0 0 0 ${b} 0 0 0 0 0 1 0`;
  if (dom.tint.getAttribute('values') !== matrix) dom.tint.setAttribute('values', matrix);
  style(dom.glow, 'opacity', glow.toFixed(3));
  animateRooms(time);
  animateHands(time);

  renderScreen(screen, screenState(time));

  // Title and closing cards.
  const voidOpacity = Math.max(1 - ease.inOut(seg(time, 5.1, 6.5)), ease.inOut(seg(time, 57.3, 58.7)));
  style(dom.void, 'opacity', voidOpacity.toFixed(3));
  style(dom.void, 'visibility', voidOpacity > 0 ? 'visible' : 'hidden');
  const titleOut = ease.inOut(seg(time, 4.8, 5.9));
  style(dom.title, 'opacity', String(time < S.morning.start ? 1 - titleOut : 0));
  style(dom.title, 'transform', `translateY(${-titleOut * 30}px) scale(${1 + time * 0.004})`);
  style(dom.title, 'filter', `blur(${titleOut * 8}px)`);
  for (const [p, target, start] of [['codex', 88, 42], ['claude', 72, 28]]) {
    const value = lerp(start, target, ease.out(seg(time, 0.4, 3.6)));
    style(dom.tb[p].fill, 'width', `${value}%`);
    setText(dom.tb[p].value, `${Math.round(value)}% left`);
  }
  const outroIn = time >= S.outro.start;
  style(dom.outro, 'opacity', outroIn ? '1' : '0');
  dom.outroParts.forEach((part, i) => {
    const p = ease.out(seg(time, 58.2 + i * 0.22, 59.2 + i * 0.22));
    style(part, 'opacity', p.toFixed(3));
    style(part, 'transform', `translateY(${(1 - p) * 22}px)`);
  });
  style(dom.blackout, 'opacity', ease.inOut(seg(time, DURATION - 1.3, DURATION - 0.05)).toFixed(3));

  // Time of day, caption, shortcuts.
  const cards = {morning: [6.4, 8.7], cafe: [15.9, 17.5], low: [25.4, 26.8], reset: [34.95, 36.1], night: [41.25, 42.5], export: [50.75, 51.55]};
  const scene = currentScene(time);
  let timecard = 0;
  if (cards[scene]) {
    const [start, end] = cards[scene];
    timecard = fade(time, start, start + 0.45, end, end + 0.4);
    setText(dom.place, copy(`place.${scene}`));
    setText(dom.time, scene === 'reset' && time >= at(12, 2) ? copy('time.resetAfter') : copy(`time.${scene}`));
  }
  style(dom.timecard, 'opacity', timecard.toFixed(3));
  style(dom.timecard, 'transform', `translateY(${(1 - timecard) * 16}px)`);

  dom.overlay.dataset.ink = ['night', 'export'].includes(scene) ? 'light' : 'dark';
  const captionScene = S[scene];
  let caption = 0;
  if (scene !== 'title' && scene !== 'outro') {
    caption = fade(time, captionScene.start + 0.4, captionScene.start + 1.0, captionScene.end - 0.55, captionScene.end - 0.1);
    setText(dom.captionText, copy(`caption.${scene}`));
  }
  style(dom.caption, 'opacity', caption.toFixed(3));
  style(dom.caption, 'transform', `translateY(${(1 - caption) * 14}px)`);
  style(dom.scrim, 'opacity', String(Math.max(caption, timecard * 0.6) * (1 - voidOpacity)));

  renderKeycaps(time);
}

function renderKeycaps(time) {
  const cues = [['cafe', 'show-claude', ['⌘', '2']], ['low', 'show-codex', ['⌘', '1']], ['export', 'open-settings', ['⌘', ',']]];
  let shown = null;
  for (const [scene, id, keys] of cues) {
    const moment = cue(scene, id);
    const opacity = fade(time, moment - 0.45, moment - 0.2, moment + 0.75, moment + 1.05);
    if (opacity > 0) shown = {moment, keys, opacity};
  }
  if (!shown) {
    style(dom.keycaps, 'opacity', '0');
    return;
  }
  const key = shown.keys.join('');
  if (dom.keycaps.dataset.keys !== key) {
    dom.keycaps.dataset.keys = key;
    dom.keycaps.innerHTML = shown.keys.map(k => `<span class="keycap">${k}</span>`).join('');
  }
  style(dom.keycaps, 'opacity', shown.opacity.toFixed(3));
  const caps = [...dom.keycaps.children];
  caps.forEach((cap, i) => {
    const press = pulse(time, shown.moment - (i === 0 ? 0.12 : 0), 0.14);
    const held = i === 0 ? clamp(seg(time, shown.moment - 0.2, shown.moment - 0.12) - seg(time, shown.moment + 0.35, shown.moment + 0.5)) : press;
    style(cap, 'transform', `translateY(${held * 5}px) scale(${lerp(0.94, 1, shown.opacity)})`);
    style(cap, 'boxShadow', `inset 0 0 0 1.5px rgba(255,255,255,${0.35 + held * 0.4}), inset 0 ${-5 + held * 3}px 0 rgba(0,0,0,.25), 0 ${18 - held * 8}px 40px rgba(0,0,0,.3)`);
  });
}

function animateRooms(time) {
  const a = dom.anim;
  a.steam.forEach((path, i) => {
    const phase = (time * 0.32 + (Number(path.dataset.steam) / 3)) % 1;
    style(path, 'opacity', (Math.sin(phase * Math.PI) * 0.5).toFixed(3));
    path.setAttribute('transform', `translate(${wobble(time, i, 1.4) * 6} ${-phase * 46})`);
  });
  a.beams.forEach((beam, i) => style(beam, 'opacity', (0.78 + wobble(time, i + 3, 0.8) * 0.18).toFixed(3)));
  a.suns.forEach((sun, i) => style(sun, 'opacity', (0.9 + wobble(time, i + 5, 0.6) * 0.1).toFixed(3)));
  a.bokeh.forEach((dot, i) => dot.setAttribute('transform', `translate(${wobble(time, i, 0.5) * 12} ${wobble(time, i + 9, 0.4) * 6})`));
  a.lamps.forEach((lamp, i) => style(lamp, 'opacity', (0.9 + wobble(time, i + 11, 2.2) * 0.06).toFixed(3)));
  a.blinds.forEach(blinds => blinds.setAttribute('transform', `translate(${(time - 25) * 3} 0)`));
  a.stars.forEach((star, i) => style(star, 'opacity', (0.45 + 0.55 * Math.abs(Math.sin(time * (0.8 + (i % 5) * 0.3) + i))).toFixed(3)));
  a.bulbs.forEach((bulb, i) => style(bulb, 'opacity', (0.72 + 0.28 * Math.sin(time * 2.1 + i * 1.7)).toFixed(3)));
  for (const c of a.clocks) {
    let hour;
    let minute;
    if (c.id === 'low') [hour, minute] = [15, 10 + seg(time, 25, 35) * 2];
    else [hour, minute] = time < at(12, 2) ? [17, 59] : [18, 0];
    if (c.id === 'reset' && time >= at(12, 2)) minute = lerp(-1, 0, ease.back(seg(time, at(12, 2), at(12, 2) + 0.3)));
    c.minute.setAttribute('transform', `rotate(${minute * 6})`);
    c.hour.setAttribute('transform', `rotate(${((hour % 12) + minute / 60) * 30})`);
  }
}

function animateHands(time) {
  const typing = time > S.cafe.start && time < 34 ? 1 : 0.35;
  dom.fingers.forEach((finger, i) => {
    const [side, index] = finger.dataset.finger.split('-');
    const tap = Math.max(0, Math.sin(time * (9 + i * 1.3) + i * 2.1)) ** 6;
    let lift = tap * 6 * typing * (side === 'left' ? 1 : 0.35);
    if (side === 'right' && index === '1' && POINTER) lift = Math.max(lift, pointerState(time).press * 10);
    finger.setAttribute('transform', `translate(0 ${lift.toFixed(2)})`);
  });
  const move = POINTER ? pointerAt(time) : {x: 900, y: 460};
  dom.hands.right.setAttribute('transform', `translate(${((move.x - 900) * 0.03).toFixed(2)} ${((move.y - 460) * 0.02).toFixed(2)})`);
  dom.hands.left.setAttribute('transform', `translate(0 ${(wobble(time, 4, 0.6) * 2).toFixed(2)})`);
}

// ----------------------------------------------------------------------------------------------
// Boot

function measure() {
  // Lay the screen out with every window open so each control has a position to aim at.
  const state = screenState(0);
  state.card = {...cardState(22), open: 1, pace: 0, reading: READINGS.night, tab: 1, mode: 0, breakdown: 0};
  state.settings.open = 1;
  state.report.open = 1;
  state.theme = 'dark';
  renderScreen(screen, state);
  const names = ['robot', 'reset-label', 'pace-details', 'cost', 'model-breakdown', 'export-button', 'report-chinese', ...Array.from({length: 10}, (_, i) => `col-${i}`)];
  // Measure at scale 1 so rects map straight to screen points.
  style(dom.camera, 'transform', 'none');
  T = Object.fromEntries(names.map(name => [name, targetOf(screen, name)]));
  POINTER = pointerKeys();
}

function fit() {
  const scale = Math.min(innerWidth / 1920, innerHeight / 1080);
  stage.style.transform = `translate(${(innerWidth - 1920 * scale) / 2}px, ${(innerHeight - 1080 * scale) / 2}px) scale(${scale})`;
}

async function boot() {
  await document.fonts.load('60px "Instrument Serif"');
  await document.fonts.ready;
  await Promise.all([...stage.querySelectorAll('img')].map(img => img.decode().catch(() => {})));
  measure();
  window.seek = time => frame(clamp(time, 0, DURATION));
  window.DEMO_DURATION = DURATION;

  if (params.has('render')) {
    window.seek(0);
    return;
  }
  fit();
  addEventListener('resize', fit);
  if (params.has('t')) {
    window.seek(Number(params.get('t')));
    return;
  }
  // Preview: loop in real time. Click to restart with the soundtrack, if one has been rendered.
  const audio = new Audio(params.get('audio') ?? '../../build/demo/soundtrack.m4a');
  let origin = performance.now();
  addEventListener('click', () => {
    origin = performance.now();
    audio.currentTime = 0;
    audio.play().catch(() => {});
  });
  const loop = now => {
    window.seek(((now - origin) / 1000) % DURATION);
    requestAnimationFrame(loop);
  };
  requestAnimationFrame(loop);
}

window.demoReady = boot();
