
(function (global) {
  'use strict';
  const THEME = typeof CHART_THEME === 'undefined' ? global.CHART.palette('editorial') : CHART_THEME;


  const INK   = THEME.HERO;
  const PAPER = THEME.SURFACE;
  const MUTED = THEME.MUT;
  const FAINT = THEME.MUT;
  const GRID  = THEME.GRID;


  const L   = [THEME.RAMP[4], THEME.RAMP[4], THEME.RAMP[3], THEME.RAMP[2], THEME.RAMP[1], THEME.RAMP[0], THEME.RAMP[0]];

  const LAD = [THEME.RAMP[4], THEME.RAMP[3], THEME.RAMP[2], THEME.RAMP[1], THEME.RAMP[0]];


  const DARK = {
    bg: THEME.SURFACE,
    ink: THEME.INK,
    muted: THEME.MUT,
    faint: THEME.MUT,
    grid: THEME.GRID,
    gridSoft: THEME.QUIET,
    ladder: [THEME.RAMP[4], THEME.RAMP[4], THEME.RAMP[3], THEME.RAMP[2], THEME.RAMP[1], THEME.RAMP[0], THEME.RAMP[0]],
  };


  const FONT = {
    family: 'Inter',

    link: 'https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap',
    title:    { size: 16.5, weight: 700, spacing: '-.02em' },
    titleBig: { size: 19,   weight: 700, spacing: '-.02em' },
    sub:      { size: 11.5, weight: 400 },
    src:      { size: 9.5,  weight: 500, spacing: '.08em' },
    value:    { weight: 800 },
    axis:     { size: 9.5,  weight: 600 },

    minHalf: 6.5, minWide: 5.5,
  };


  const SHAPE = {
    cardRadius: 24,
    cardPad: '28px 28px 20px',
    barRadius: 99,
    tooltipRadius: 12,
  };


  const MOTION = {
    enter: 900,
    enterSlow: 1200,
    easing: 'quarticOut',
    staggerDot: 12,
    staggerBar: 100,

    css: `
  .pop{transform-box:fill-box;transform-origin:center;animation:pop .5s cubic-bezier(.2,.7,.3,1.3) both}
  @keyframes pop{from{transform:scale(0)}to{transform:none}}
  .fade{animation:fade .9s ease both}
  @keyframes fade{from{opacity:0}}
  .draw{stroke-dasharray:1;stroke-dashoffset:1;animation:draw 1s cubic-bezier(.4,0,.2,1) both}
  @keyframes draw{to{stroke-dashoffset:0}}
  @media (prefers-reduced-motion:reduce){
    .pop,.fade{animation:none}
    .draw{animation:none;stroke-dasharray:none;stroke-dashoffset:0}
  }`,
  };


  const tipLight = { backgroundColor: INK, borderWidth: 0, padding: [10, 14],
    textStyle: { color: THEME.ON_HI, fontFamily: 'Inter', fontSize: 12 } };
  const tipDark  = { backgroundColor: THEME.HERO, borderWidth: 0, padding: [10, 14],
    textStyle: { color: THEME.ON_HI, fontFamily: 'Inter', fontSize: 12 } };


  const rnd = (i, k) => Math.abs(((i * 73856093) ^ (k * 19349663)) % 1000) / 1000;


  const D2R = Math.PI / 180;
  const pol = (cx, cy, r, deg) => [cx + r * Math.cos(deg * D2R), cy + r * Math.sin(deg * D2R)];

  const sect = (cx, cy, r0, r1, a0, a1) => {
    const big = a1 - a0 > 180 ? 1 : 0;
    const [xa, ya] = pol(cx, cy, r1, a0), [xb, yb] = pol(cx, cy, r1, a1);
    const [xc, yc] = pol(cx, cy, r0, a1), [xd, yd] = pol(cx, cy, r0, a0);
    return `M${xa} ${ya} A${r1} ${r1} 0 ${big} 1 ${xb} ${yb} L${xc} ${yc} A${r0} ${r0} 0 ${big} 0 ${xd} ${yd} Z`;
  };

  const blob = (x, y, r, seed) => {
    const n = Math.max(14, Math.round(r * 1.6)), pts = [];
    for (let t = 0; t < n; t++) {
      const a = t / n * Math.PI * 2;
      const w = 1 + .055 * Math.sin(a * 2 + seed * 7) + .04 * Math.sin(a * 3 + seed * 13)
              + (rnd(seed + t, 3) - .5) * .03;
      pts.push([x + Math.cos(a) * r * w, y + Math.sin(a) * r * w]);
    }
    let d = `M${pts[0][0].toFixed(1)} ${pts[0][1].toFixed(1)}`;
    for (let t = 0; t < n; t++) {
      const p = pts[t], q = pts[(t + 1) % n];
      d += ` Q${p[0].toFixed(1)} ${p[1].toFixed(1)} ${((p[0]+q[0])/2).toFixed(1)} ${((p[1]+q[1])/2).toFixed(1)}`;
    }
    return d + ' Z';
  };


  const NS = 'http://www.w3.org/2000/svg';
  const el  = (p, t, a) => { const n = document.createElementNS(NS, t);
    for (const k in a) n.setAttribute(k, a[k]); p.appendChild(n); return n; };
  const txt = (p, a, s) => { const n = el(p, 'text', a); n.textContent = s; return n; };
  const tip = (n, s) => { const t = document.createElementNS(NS, 'title');
    t.textContent = s; n.appendChild(t); };


  const timers = {};
  const keep = (id, t) => { (timers[id] = timers[id] || []).push(t); };
  const obsReveal = (id, fn) => {
    const n = document.getElementById(id);
    const go = () => {
      (timers[id] || []).forEach(clearInterval); timers[id] = [];
      if (n.tagName === 'svg' || n.tagName === 'SVG') n.innerHTML = '';
      fn(n);
    };
    const io = new IntersectionObserver(es => {
      if (es[0].isIntersecting) { go(); io.disconnect(); }
    }, { threshold: .3 });
    io.observe(n);
    n.style.cursor = 'pointer';
    n.addEventListener('click', go);
  };

  const eReveal = (id, opt) => obsReveal(id, elDom => {
    const g = echarts.getInstanceByDom(elDom) || echarts.init(elDom);
    g.clear(); g.setOption(opt);
  });


  const CARD_CSS = `
  :root{--bg:${THEME.PAGE};--dark:${DARK.bg};--ink:${INK};--muted:${MUTED};--faint:${FAINT};--grid:${GRID}}
  *{margin:0;padding:0;box-sizing:border-box}
  body{background:var(--bg);font-family:'Inter',sans-serif;color:var(--ink);padding:40px;-webkit-font-smoothing:antialiased}
  .grid2{display:grid;grid-template-columns:1fr 1fr;gap:22px;max-width:1400px;margin:0 auto}
  .card{background:${THEME.SURFACE};border-radius:${SHAPE.cardRadius}px;padding:${SHAPE.cardPad}}
  .card.dark{background:var(--dark);color:${THEME.INK}}
  .card.dark .sub{color:${MUTED}}
  .card.dark .src{color:${DARK.faint}}
  .card.wide{grid-column:1/-1}
  h2{font-weight:${FONT.title.weight};font-size:${FONT.title.size}px;letter-spacing:${FONT.title.spacing};margin-bottom:3px}
  .sub{font-size:${FONT.sub.size}px;color:var(--muted);margin-bottom:14px}
  .src{font-size:${FONT.src.size}px;color:var(--faint);margin-top:10px;letter-spacing:${FONT.src.spacing};font-weight:${FONT.src.weight}}
  .ch{height:320px}
  svg text{font-family:'Inter',sans-serif}` + MOTION.css;

  global.MONO = { INK, PAPER, MUTED, FAINT, GRID, L, LAD, DARK,
    FONT, SHAPE, MOTION, tipLight, tipDark,
    rnd, pol, sect, blob, el, txt, tip, obsReveal, eReveal, keep, CARD_CSS };
})(typeof window !== 'undefined' ? window : globalThis);
