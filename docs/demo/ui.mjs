// The Mac's screen, rebuilt in HTML at 1440 × 900 points: wallpaper, menu bar, an editor,
// QuotaBar's card, its Settings window, the exported report, and the pointer. Layout, type
// sizes, and colors follow the app's SwiftUI views (MenuCardView, CostSectionView,
// ExportSettingsView) and the README screenshots. All readings are sample data.

import {clamp, lerp, ease, seg} from './motion.mjs';

export const SCREEN_W = 1440;
export const MENU_H = 26;
/** Centre of the robot in the menu bar, in screen points. */
export const ROBOT = {x: 1142, y: MENU_H / 2};
export const CARD = {x: ROBOT.x - 140, y: MENU_H + 6, w: 280};

// `robot-excited` from Material Design Icons 7.4.47 (Apache-2.0), the app's menu bar mark.
const ROBOT_PATH = 'M22 14H21C21 10.13 17.87 7 14 7H13V5.73C13.6 5.39 14 4.74 14 4C14 2.9 13.11 2 12 2S10 2.9 10 4C10 4.74 10.4 5.39 11 5.73V7H10C6.13 7 3 10.13 3 14H2C1.45 14 1 14.45 1 15V18C1 18.55 1.45 19 2 19H3V20C3 21.11 3.9 22 5 22H19C20.11 22 21 21.11 21 20V19H22C22.55 19 23 18.55 23 18V15C23 14.45 22.55 14 22 14M8.68 17.04L7.5 15.86L6.32 17.04L5.14 15.86L7.5 13.5L9.86 15.86L8.68 17.04M17.68 17.04L16.5 15.86L15.32 17.04L14.14 15.86L16.5 13.5L18.86 15.86L17.68 17.04Z';

export const ACCENT = {codex: '#49A3B0', claude: '#CC7C5E'};

const RESET_ICON = '<svg class="ic" viewBox="0 0 16 16"><path d="M13.2 8.2a5.2 5.2 0 1 1-1.6-3.8" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><path d="M12.6 1.8v3.3H9.3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const CHEVRON_DOWN = '<svg class="ic chev-d" viewBox="0 0 16 16"><path d="M4 6l4 4 4-4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
const CHEVRON_RIGHT = '<svg class="ic" viewBox="0 0 16 16"><path d="M6 3.5l4.5 4.5L6 12.5" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>';

/** Ten calendar days, Sep 15 - Sep 24, 2026. Tokens in millions and API-rate cost in USD. */
export const USAGE = {
  claude: {
    tokens: [3, 5, 21, 33, 17, 26, 2, 33, 15, 37],
    cost: [4.1, 6.3, 24.8, 39.6, 18.2, 30.1, 2.4, 41.3, 16.9, 44.6],
    month: {tokens: '637M', cost: '$712.40'},
    models: {
      7: [['claude-opus-5', '21M', '$28.40'], ['claude-sonnet-5', '9.6M', '$9.10'], ['claude-haiku-4-5', '2.4M', '$3.80']],
    },
  },
  codex: {
    tokens: [2, 1, 4, 6, 9, 11, 5, 8, 10, 24],
    cost: [2.2, 1.1, 4.6, 6.9, 10.4, 12.7, 5.8, 9.1, 11.5, 27.6],
    month: {tokens: '418M', cost: '$466.80'},
    models: {},
  },
};
const DAYS = ['Sep 15', 'Sep 16', 'Sep 17', 'Sep 18', 'Sep 19', 'Sep 20', 'Sep 21', 'Sep 22', 'Sep 23', 'Sep 24'];

const money = value => `$${value.toFixed(2)}`;
const tokens = value => `${value}M`;

// ----------------------------------------------------------------------------------------------
// Markup

const menuBar = () => `
  <div class="menubar">
    <div class="mb-left"><span class="apple"></span><b>Code</b><span>File</span><span>Edit</span><span>Selection</span><span>View</span><span>Go</span><span>Window</span><span>Help</span></div>
    <div class="mb-right">
      <span class="mb-robot"><svg viewBox="0 0 24 24"><path fill-rule="evenodd" d="${ROBOT_PATH}"/></svg><i class="robot-glow"></i></span>
      <svg class="mb-ic" viewBox="0 0 28 16"><rect x="1" y="2" width="22" height="12" rx="3.5" fill="none" stroke="currentColor" stroke-opacity=".5"/><rect x="3" y="4" width="15" height="8" rx="1.8" fill="currentColor"/><rect x="24.5" y="6" width="2" height="4" rx="1" fill="currentColor" opacity=".5"/></svg>
      <svg class="mb-ic" viewBox="0 0 20 16"><path d="M10 13.5l2.2-2.6a3.2 3.2 0 0 0-4.4 0zM5.4 8.4a6.8 6.8 0 0 1 9.2 0l-1.4 1.6a4.7 4.7 0 0 0-6.4 0zM2.2 5.2a11.3 11.3 0 0 1 15.6 0l-1.4 1.6a9.2 9.2 0 0 0-12.8 0z" fill="currentColor"/></svg>
      <svg class="mb-ic" viewBox="0 0 18 16"><rect x="1" y="2.5" width="16" height="4.5" rx="2.25" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="13.5" cy="4.75" r="1.4" fill="currentColor"/><rect x="1" y="9.5" width="16" height="4.5" rx="2.25" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="4.5" cy="11.75" r="1.4" fill="currentColor"/></svg>
      <span class="mb-clock"></span>
    </div>
  </div>`;

const codeLines = () => {
  // Abstract code: indentation and token widths, colored like a syntax theme.
  const lines = [
    [0, [['k', 46], ['f', 120], ['p', 30]]], [1, [['k', 36], ['v', 70], ['p', 16], ['s', 140]]], [1, [['k', 36], ['v', 96], ['p', 16], ['f', 84], ['p', 30]]],
    [1, []], [1, [['c', 260]]], [1, [['k', 20], ['v', 60], ['p', 60], ['n', 30], ['p', 14]]], [2, [['f', 110], ['p', 20], ['v', 60], ['p', 18]]],
    [2, [['k', 46], ['v', 80], ['p', 12], ['f', 90], ['p', 24]]], [1, [['p', 12]]], [1, []], [1, [['k', 46], ['f', 150], ['p', 24], ['v', 50], ['p', 20]]],
    [2, [['k', 36], ['v', 64], ['p', 16], ['s', 190]]], [2, [['f', 70], ['p', 12], ['v', 120], ['p', 14]]], [1, [['p', 12]]], [0, [['p', 12]]], [0, []],
    [0, [['c', 320]]], [0, [['k', 46], ['f', 90], ['p', 30]]], [1, [['k', 36], ['v', 48], ['p', 16], ['n', 22]]], [1, [['k', 30], ['v', 70], ['p', 30], ['f', 130], ['p', 20]]],
    [2, [['v', 80], ['p', 20], ['f', 70], ['p', 40]]], [1, [['p', 12]]], [1, [['k', 46], ['v', 60]]], [0, [['p', 12]]],
  ];
  return lines.map(([indent, parts], i) => `<div class="code-line" data-line="${i}"><span class="ln">${i + 1}</span><span style="width:${indent * 24}px"></span>${parts.map(([kind, width]) => `<i class="tk ${kind}" style="width:${width}px"></i>`).join('')}</div>`).join('');
};

const editor = () => `
  <div class="window editor">
    <div class="titlebar"><i class="tl r"></i><i class="tl y"></i><i class="tl g"></i><span class="wtitle">usage-pace.ts — quota-bar</span></div>
    <div class="ed-body">
      <div class="ed-side">${['src', 'quota', 'usage-pace.ts', 'reset-label.ts', 'cost', 'rate-card.ts', 'report.ts', 'tests', 'README.md'].map((name, i) => `<div class="ed-file ${i === 2 ? 'on' : ''}" style="padding-left:${[0, 1, 2, 2, 1, 2, 2, 0, 0][i] * 12 + 12}px">${name}</div>`).join('')}</div>
      <div class="ed-code">${codeLines()}<i class="caret"></i></div>
    </div>
  </div>`;

const quotaRow = kind => `
  <div class="q-row" data-q="${kind}">
    <div class="q-head"><span class="q-title">${kind === 'session' ? 'Session' : 'Weekly'}</span><span class="q-pct"></span></div>
    <div class="bar-box"><i class="bar-glow"></i><div class="bar"><i class="fill"></i><i class="sheen"></i></div></div>
    <div class="q-sub"><span class="q-sum"></span><span class="q-reset"><span class="q-reset-text"><span class="a"></span><span class="b"></span></span>${CHEVRON_DOWN}</span></div>
  </div>`;

const paceBlock = kind => `
  <div class="pace" data-pace="${kind}">
    <div class="pace-title"></div><div class="pace-l1"></div><div class="pace-l2"></div><div class="pace-l3"></div>
    <div class="bar small"><i class="fill"></i><i class="marker"></i></div>
  </div>`;

const card = () => `
  <div class="card">
    <div class="tabs"><i class="tab-sel"></i><span class="tab" data-tab="codex"><i class="dot"></i>Codex</span><span class="tab" data-tab="claude"><i class="dot"></i>Claude</span></div>
    <div class="card-body">
      <div class="meta"><span>Updated just now</span><span class="plan"></span></div>
      <div class="hr"></div>
      ${quotaRow('session')}
      ${quotaRow('weekly')}
      <div class="disclosure pace-toggle">${CHEVRON_RIGHT}<span>Usage pace details</span></div>
      <div class="pace-wrap"><div class="pace-inner">${paceBlock('session')}${paceBlock('weekly')}</div></div>
      <div class="hr"></div>
      <div class="lu-head"><span class="h">Local usage</span><span class="seg"><i class="seg-sel"></i><span>Tokens</span><span>Cost</span></span></div>
      <div class="totals"><div><span class="lbl">Today</span><b class="today"></b></div><div><span class="lbl">Last 30 days</span><b class="month"></b></div></div>
      <div class="chart-head"><span>Last 10 calendar days</span><span class="unit">Tokens</span></div>
      <div class="chart">${DAYS.map((_, i) => `<div class="col" data-col="${i}"><i class="b"></i><i class="u"></i></div>`).join('')}</div>
      <div class="axis"><span>${DAYS[0]}</span><span>${DAYS[9]}</span></div>
      <div class="day"><b class="day-date"></b><span class="day-models">3 models</span></div>
      <div class="day-total"><b class="big"></b><span class="small"></span></div>
      <div class="hr"></div>
      <div class="disclosure mb-toggle"><span>Model breakdown</span>${CHEVRON_RIGHT}</div>
      <div class="mb-wrap"><div class="mb-inner">${[0, 1, 2].map(i => `<div class="mb-row" data-model="${i}"><span class="name"></span><span class="val"></span></div>`).join('')}</div></div>
      <div class="foot">API-rate estimate · Not a bill</div>
      <div class="reset-menu"><span>Show reset date</span></div>
      <div class="credits"><div class="hr"></div><div class="cr-h">Credits</div><div class="bar"><i class="fill" style="width:64%"></i></div><div class="cr-sub"><span>640 left</span><span>1K tokens</span></div></div>
    </div>
  </div>`;

const settings = () => `
  <div class="window settings">
    <div class="titlebar"><i class="tl r"></i><i class="tl y"></i><i class="tl g"></i><span class="wtitle">Export</span></div>
    <div class="st-tabs"><span>General</span><span>Pricing</span><span class="on">Export</span></div>
    <div class="st-body">
      <div class="st-sec-h">Report</div>
      <div class="st-group">
        <div class="st-row"><span>Layout</span><span class="v">Usage trends</span></div>
        <div class="st-row"><span>Period</span><span class="v pop">Last 7 days <i>⌃⌄</i></span></div>
        <div class="st-row"><span>Scope</span><span class="v">All stored sources</span></div>
        <div class="st-row"><span>Format</span><span class="v">Bilingual HTML (offline)</span></div>
      </div>
      <div class="st-group">
        <div class="st-row note">Switch between Chinese and English in the report. Prices saved local usage at each day's rates; cache costs are included but not broken out.</div>
        <div class="st-row"><span>Open after export</span><span class="toggle on"><i></i></span></div>
      </div>
      <div class="st-group">
        <div class="st-row export-row"><span class="status"><span class="s-idle">Choose a period, then export an offline report.</span><span class="s-busy"><i class="spinner"></i>Exporting report…</span><span class="s-saved">✓ Saved QuotaBar-Usage-2026-09-25.html</span></span><span class="btn">⇪ Export Report…</span></div>
        <div class="st-row saved-actions"><span class="btn2">Open Report</span><span class="btn2">Show in Finder</span></div>
      </div>
    </div>
  </div>`;

/** Report copy, from the app's own report template (render.js and trend.html). */
const REPORT = {
  en: {version: 'Usage trend report', local: 'Local saved usage', headline: 'This report covers', total: 'Total tokens', cost: 'Estimated API cost', coverage: 'Pricing coverage', daily: 'When usage peaked', dailyNote: 'One point per day. Hollow points mark weekends.', models: 'Which models cost the most', composition: 'Where the tokens went', peak: 'Daily peak'},
  zh: {version: '用量趋势报告', local: '本地已存用量', headline: '本报告覆盖', total: 'Token 总用量', cost: '估算 API 费用', coverage: '定价覆盖', daily: '用量在哪天达到峰值', dailyNote: '一点代表一天，空心点表示周末。', models: '哪些模型费用最多', composition: 'Tokens 用在了哪里', peak: '单日峰值'},
};

/** Sep 19-25 across both providers, in millions: the chart's days plus Friday. Sep 19-20 are a weekend. */
const reportDays = [26, 37, 7, 41, 25, 61, 30];
const reportPoints = reportDays.map(value => (value / 61) * 0.93);
const report = () => {
  const text = key => `<span class="i18n" data-en="${REPORT.en[key]}" data-zh="${REPORT.zh[key]}">${REPORT.en[key]}</span>`;
  const chartW = 900;
  const pts = reportPoints.map((v, i) => [30 + i * (chartW - 60) / 6, 200 - v * 170]);
  return `
  <div class="window report">
    <div class="br-chrome"><i class="tl r"></i><i class="tl y"></i><i class="tl g"></i><span class="br-url">QuotaBar-Usage-2026-09-25.html</span></div>
    <div class="rp">
      <div class="rp-top"><span>QuotaBar</span><span class="rp-lang"><i class="rp-lang-sel"></i><span data-l="zh">中文</span><span data-l="en">English</span></span></div>
      <div class="rp-hero"><div class="rp-side"><i></i><div>${text('version')}</div><div class="dot">${text('local')}</div></div>
        <div class="rp-head">${text('headline')}<br>2026-09-19 → 2026-09-25</div></div>
      <div class="rp-kpis"><div><b class="gold">227.0M</b><div>${text('total')}</div></div><div><b>$261.80</b><div>${text('cost')}</div><small>${text('coverage')} · 100.00%</small></div></div>
      <div class="rp-fig"><div class="rp-h">${text('daily')}</div><div class="rp-sub">${text('dailyNote')}</div>
        <svg viewBox="0 0 ${chartW} 220" class="rp-line"><path d="M0 206 H${chartW}" stroke="#3A3F3C"/><polyline points="${pts.map(p => p.join(',')).join(' ')}" fill="none" stroke="#F2CF7E" stroke-width="2"/>${pts.map(([x, y], i) => `<circle cx="${x}" cy="${y}" r="${i === 5 ? 7 : 4.5}" fill="${i < 2 ? '#101412' : '#F2CF7E'}" stroke="#F2CF7E" stroke-width="2"/>`).join('')}<text x="${pts[5][0]}" y="${pts[5][1] - 16}" fill="#F2CF7E" font-size="15" text-anchor="middle">61.0M</text></svg></div>
      <div class="rp-two"><div><div class="rp-h">${text('models')}</div><div class="rp-bars">${[['claude-opus-5', 1], ['gpt-6-astra', 0.82], ['claude-sonnet-5', 0.6], ['Other', 0.42]].map(([name, v], i) => `<div><i style="height:${v * 150}px;background:${['#F2CF7E', '#D8D3A2', '#D2CFA0', '#B5BF8F'][i]}"></i><span>${name}</span></div>`).join('')}</div></div>
        <div><div class="rp-h">${text('composition')}</div><div class="rp-dots">${Array.from({length: 60}, (_, i) => `<i style="background:${i < 44 ? '#F2CF7E' : i < 52 ? '#D8D3A2' : '#8FA37A'}"></i>`).join('')}</div></div></div>
    </div>
  </div>`;
};

const pointer = () => `
  <div class="pointer"><i class="ripple"></i><svg viewBox="0 0 24 34" width="22" height="31"><path d="M2 2 L2 26 L8 20.5 L12.2 30.5 L16.4 28.7 L12.3 19 L20 19 Z" fill="#111" stroke="#fff" stroke-width="1.7" stroke-linejoin="round"/></svg></div>`;

export function screenHTML() {
  return `
    <div class="wallpaper"></div>
    ${editor()}
    ${settings()}
    ${report()}
    ${card()}
    ${menuBar()}
    ${pointer()}`;
}

// ----------------------------------------------------------------------------------------------
// Per-frame updates

export function bindScreen(root) {
  const $ = selector => root.querySelector(selector);
  const $$ = selector => [...root.querySelectorAll(selector)];
  const el = {
    root,
    wallpaper: $('.wallpaper'),
    clock: $('.mb-clock'),
    robot: $('.mb-robot'),
    editor: $('.editor'),
    lines: $$('.code-line'),
    caret: $('.caret'),
    card: $('.card'),
    tabSel: $('.tab-sel'),
    tabs: $$('.tab'),
    plan: $('.plan'),
    body: $('.card-body'),
    rows: Object.fromEntries(['session', 'weekly'].map(kind => {
      const row = $(`[data-q="${kind}"]`);
      return [kind, {
        pct: row.querySelector('.q-pct'), fill: row.querySelector('.fill'), sheen: row.querySelector('.sheen'),
        glow: row.querySelector('.bar-glow'), sum: row.querySelector('.q-sum'), a: row.querySelector('.q-reset-text .a'), b: row.querySelector('.q-reset-text .b'),
        reset: row.querySelector('.q-reset'),
      }];
    })),
    paceToggle: $('.pace-toggle'),
    paceWrap: $('.pace-wrap'),
    paceInner: $('.pace-inner'),
    pace: Object.fromEntries(['session', 'weekly'].map(kind => {
      const block = $(`[data-pace="${kind}"]`);
      return [kind, {
        title: block.querySelector('.pace-title'), l1: block.querySelector('.pace-l1'), l2: block.querySelector('.pace-l2'),
        l3: block.querySelector('.pace-l3'), fill: block.querySelector('.fill'), marker: block.querySelector('.marker'),
      }];
    })),
    seg: $('.seg'),
    segSel: $('.seg-sel'),
    today: $('.today'),
    month: $('.month'),
    unit: $('.unit'),
    cols: $$('.col'),
    dayDate: $('.day-date'),
    dayModels: $('.day-models'),
    big: $('.day-total .big'),
    small: $('.day-total .small'),
    mbToggle: $('.mb-toggle'),
    mbWrap: $('.mb-wrap'),
    mbInner: $('.mb-inner'),
    mbRows: $$('.mb-row'),
    credits: $('.credits'),
    resetMenu: $('.reset-menu'),
    savedActions: $('.saved-actions'),
    settings: $('.settings'),
    exportBtn: $('.btn'),
    export: {idle: $('.s-idle'), busy: $('.s-busy'), saved: $('.s-saved')},
    report: $('.report'),
    i18n: $$('.i18n'),
    langSel: $('.rp-lang-sel'),
    langs: $$('.rp-lang span'),
    pointer: $('.pointer'),
    ripple: $('.ripple'),
  };
  return el;
}

/** Where a named control sits, in screen points, for the pointer to aim at. */
export function targetOf(el, name) {
  const node = {
    'reset-label': el.rows.session.reset,
    'pace-details': el.paceToggle.querySelector('span'),
    cost: el.seg.children[2],
    'model-breakdown': el.mbToggle.querySelector('span'),
    'export-button': el.exportBtn,
    'report-language': el.langs[1],
    'show-reset-date': el.resetMenu.firstElementChild,
    robot: el.robot,
  }[name];
  if (name.startsWith('col-')) return centreOf(el, el.cols[Number(name.slice(4))]);
  return centreOf(el, node);
}

function centreOf(el, node) {
  // offsetParent chains break across transformed windows, so measure with rects and undo the
  // screen's own scale.
  const screen = el.root.getBoundingClientRect();
  const box = node.getBoundingClientRect();
  const scale = screen.width / SCREEN_W;
  return {x: (box.left + box.width / 2 - screen.left) / scale, y: (box.top + box.height / 2 - screen.top) / scale};
}

const set = (node, property, value) => {
  if (node.style[property] !== value) node.style[property] = value;
};
const text = (node, value) => {
  if (node.textContent !== value) node.textContent = value;
};

/**
 * Applies one frame of screen state. `s` is built by demo.mjs:
 * theme, wallpaper, clock, robot {red, pulse}, typed, card {...}, settings {...}, report {...}, pointer {...}.
 */
export function renderScreen(el, s) {
  el.root.dataset.theme = s.theme;
  el.wallpaper.dataset.scene = s.wallpaper;
  text(el.clock, s.clock);

  // Menu bar robot: labelColor normally, system red while the shown provider runs low.
  el.robot.style.setProperty('--red', s.robot.red.toFixed(3));
  el.robot.style.setProperty('--pulse', s.robot.pulse.toFixed(3));

  // The editor fills with code as the day's work goes on.
  el.lines.forEach((line, i) => set(line, 'opacity', String(clamp(s.typed - i))));
  const caretLine = Math.min(el.lines.length - 1, Math.floor(s.typed));
  set(el.caret, 'transform', `translate(${60 + (s.typed % 1) * 240}px, ${10 + caretLine * 22}px)`);
  set(el.caret, 'opacity', s.caretBlink ? '1' : '0');

  renderCard(el, s.card);

  set(el.settings, 'opacity', String(s.settings.open));
  set(el.settings, 'transform', `translate(-50%, 0) scale(${lerp(0.94, 1, ease.out(s.settings.open))})`);
  set(el.settings, 'visibility', s.settings.open > 0 ? 'visible' : 'hidden');
  set(el.exportBtn, 'transform', `scale(${1 - s.settings.press * 0.05})`);
  set(el.exportBtn, 'filter', `brightness(${1 - s.settings.press * 0.15})`);
  set(el.export.idle, 'opacity', String(s.settings.status === 'idle' ? 1 : 0));
  set(el.export.busy, 'opacity', String(s.settings.status === 'busy' ? 1 : 0));
  set(el.export.saved, 'opacity', String(s.settings.status === 'saved' ? 1 : 0));
  set(el.savedActions, 'opacity', String(s.settings.status === 'saved' ? 1 : 0));
  el.export.busy.querySelector('.spinner').style.transform = `rotate(${s.settings.spin * 360}deg)`;

  set(el.report, 'opacity', String(s.report.open));
  set(el.report, 'visibility', s.report.open > 0 ? 'visible' : 'hidden');
  set(el.report, 'transform', `translate(-50%, ${lerp(30, 0, ease.out(s.report.open))}px) scale(${lerp(0.92, 1, ease.out(s.report.open))})`);
  const zh = 1 - s.report.english;
  el.i18n.forEach(node => {
    text(node, zh >= 0.5 ? node.dataset.zh : node.dataset.en);
    set(node, 'opacity', String(Math.abs(zh - 0.5) * 2 * 0.999 + 0.001));
  });
  set(el.langSel, 'transform', `translateX(${lerp(el.langs[0].offsetWidth + 4, 0, ease.inOut(zh))}px)`);
  set(el.langSel, 'width', `${lerp(el.langs[1].offsetWidth, el.langs[0].offsetWidth, ease.inOut(zh))}px`);
  el.langs.forEach((node, i) => node.classList.toggle('on', (i === 0) === zh >= 0.5));

  const p = s.pointer;
  set(el.pointer, 'opacity', String(p.visible));
  set(el.pointer, 'transform', `translate(${p.x}px, ${p.y}px) scale(${1 - p.press * 0.12})`);
  set(el.ripple, 'opacity', String(p.ripple > 0 && p.ripple < 1 ? (1 - p.ripple) * 0.6 : 0));
  set(el.ripple, 'transform', `translate(-50%, -50%) scale(${0.4 + p.ripple * 1.6})`);
}

function renderCard(el, c) {
  set(el.card, 'opacity', String(c.open));
  set(el.card, 'visibility', c.open > 0 ? 'visible' : 'hidden');
  set(el.card, 'transform', `translateY(${lerp(-8, 0, ease.out(c.open))}px) scale(${lerp(0.97, 1, ease.out(c.open))})`);
  if (c.open <= 0) return;

  const r = c.reading;
  const accent = ACCENT[r.provider];
  el.card.style.setProperty('--accent', accent);
  el.card.style.setProperty('--codex', ACCENT.codex);
  el.card.style.setProperty('--claude', ACCENT.claude);

  // Provider tabs: equal widths, the highlight slides under the label.
  set(el.tabSel, 'transform', `translateX(${c.tab * 100}%)`);
  el.tabs.forEach((tab, i) => tab.classList.toggle('on', i === Math.round(c.tab)));
  set(el.body, 'opacity', String(c.bodyOpacity));
  set(el.body, 'transform', `translateX(${c.bodyShift}px)`);
  text(el.plan, r.plan);

  for (const kind of ['session', 'weekly']) {
    const row = el.rows[kind];
    const q = r[kind];
    text(row.pct, `${Math.round(q.pct)}% left`);
    set(row.fill, 'width', `${clamp((q.barPct ?? q.pct) / 100) * 100}%`);
    set(row.fill, 'background', accent);
    set(row.sheen, 'opacity', String(q.sheen ?? 0));
    set(row.sheen, 'transform', `translateX(${lerp(-120, 320, q.sheenAt ?? 0)}px)`);
    text(row.sum, q.summary);
    set(row.sum, 'color', q.summaryColor ?? '');
    if (row.a.dataset.text !== q.reset) {
      row.a.dataset.text = q.reset;
      row.a.innerHTML = `${RESET_ICON}<span>${q.reset}</span>`;
    }
    if (row.b.dataset.text !== q.resetClock) {
      row.b.dataset.text = q.resetClock;
      row.b.innerHTML = `${RESET_ICON}<span>${q.resetClock}</span>`;
    }
    set(row.glow, 'opacity', String(q.glow ?? 0));
    set(row.a, 'opacity', String(1 - c.resetMode));
    set(row.b, 'opacity', String(c.resetMode));
    set(row.a, 'transform', `translateY(${-c.resetMode * 6}px)`);
    set(row.b, 'transform', `translateY(${(1 - c.resetMode) * 6}px)`);
  }

  // Usage pace details.
  el.paceToggle.firstElementChild.style.transform = `rotate(${c.pace * 90}deg)`;
  set(el.paceWrap, 'height', `${el.paceInner.scrollHeight * ease.inOut(c.pace)}px`);
  set(el.paceInner, 'opacity', String(seg(c.pace, 0.3, 1)));
  for (const kind of ['session', 'weekly']) {
    const block = el.pace[kind];
    const detail = r.pace[kind];
    text(block.title, detail.title);
    text(block.l1, detail.l1);
    text(block.l2, detail.l2);
    text(block.l3, detail.l3);
    set(block.fill, 'width', `${r[kind].pct}%`);
    set(block.fill, 'background', accent);
    set(block.marker, 'left', `${detail.expected}%`);
  }

  // Local usage: Tokens / Cost.
  const mode = c.mode;
  set(el.segSel, 'transform', `translateX(${ease.inOut(mode) * 100}%)`);
  [...el.seg.children].slice(1).forEach((node, i) => node.classList.toggle('on', i === Math.round(mode)));
  const usage = USAGE[r.provider];
  const costShown = mode >= 0.5;
  const swap = 1 - Math.abs(mode - 0.5) * 2; // 1 at the midpoint of the switch
  const last = usage.tokens.length - 1;
  text(el.today, costShown ? money(usage.cost[last]) : tokens(usage.tokens[last]));
  text(el.month, costShown ? usage.month.cost : usage.month.tokens);
  text(el.unit, costShown ? 'Cost' : 'Tokens');
  for (const node of [el.today, el.month, el.big, el.small, el.unit]) set(node, 'opacity', String(1 - swap));

  const maxT = Math.max(...usage.tokens);
  const maxC = Math.max(...usage.cost);
  el.cols.forEach((col, i) => {
    const height = lerp(usage.tokens[i] / maxT, usage.cost[i] / maxC, ease.inOut(mode));
    const bar = col.firstElementChild;
    const selected = i === c.day;
    set(bar, 'height', `${Math.max(3, height * 58)}px`);
    set(bar, 'background', accent);
    set(bar, 'opacity', selected ? '1' : String(el.root.dataset.theme === 'dark' ? 0.5 : 0.45));
    set(col.lastElementChild, 'opacity', selected ? '1' : '0');
    set(col.lastElementChild, 'background', accent);
  });
  text(el.dayDate, DAYS[c.day]);
  const models = usage.models[c.day];
  text(el.dayModels, `${models ? models.length : 3} models`);
  const dayTokens = `${tokens(usage.tokens[c.day])} tokens`;
  const dayCost = money(usage.cost[c.day]);
  text(el.big, costShown ? dayCost : dayTokens);
  text(el.small, costShown ? dayTokens : dayCost);

  (models ?? []).forEach(([name, amount, cost], i) => {
    text(el.mbRows[i].querySelector('.name'), name);
    text(el.mbRows[i].querySelector('.val'), `${amount} · ${cost}`);
  });
  el.mbToggle.lastElementChild.style.transform = `rotate(${c.breakdown * 90}deg)`;
  set(el.mbWrap, 'height', `${el.mbInner.scrollHeight * ease.inOut(c.breakdown)}px`);
  set(el.mbInner, 'opacity', String(seg(c.breakdown, 0.3, 1)));

  set(el.credits, 'display', r.provider === 'codex' ? '' : 'none');

  // The reset label's menu, opened under the session label.
  const label = el.rows.session.reset;
  set(el.resetMenu, 'opacity', String(c.menu));
  set(el.resetMenu, 'visibility', c.menu > 0 ? 'visible' : 'hidden');
  set(el.resetMenu, 'left', `${label.offsetLeft + label.offsetWidth - 150}px`);
  set(el.resetMenu, 'top', `${label.offsetTop + label.offsetHeight + 4}px`);
  el.resetMenu.firstElementChild.classList.toggle('on', c.menuHover);
}
