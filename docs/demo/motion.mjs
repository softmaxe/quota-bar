// Pure easing and keyframe helpers. Every frame is a function of time alone, so any frame can be
// rendered on its own and the film renders the same way every time.

export const clamp = (value, low = 0, high = 1) => Math.min(high, Math.max(low, value));
export const lerp = (from, to, progress) => from + (to - from) * progress;
/** Progress of `time` through [start, end], clamped to 0...1. */
export const seg = (time, start, end) => clamp((time - start) / (end - start));

export const ease = {
  linear: p => p,
  in: p => p * p * p,
  out: p => 1 - Math.pow(1 - p, 3),
  inOut: p => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2),
  sine: p => -(Math.cos(Math.PI * p) - 1) / 2,
  expo: p => (p === 1 ? 1 : 1 - Math.pow(2, -10 * p)),
  /** A settle with a small overshoot, like a spring that is nearly critically damped. */
  back: p => {
    const c1 = 1.25;
    const c3 = c1 + 1;
    return 1 + c3 * Math.pow(p - 1, 3) + c1 * Math.pow(p - 1, 2);
  },
  /** Camera moves: slow to leave, slower to arrive. */
  glide: p => (p < 0.5 ? 16 * p ** 5 : 1 - Math.pow(-2 * p + 2, 5) / 2) * 0.35 + (-(Math.cos(Math.PI * p) - 1) / 2) * 0.65,
};

const mix = (from, to, progress) => {
  if (typeof from === 'number') return lerp(from, to, progress);
  const out = {};
  for (const key of Object.keys(from)) out[key] = mix(from[key], to[key] ?? from[key], progress);
  return out;
};

/**
 * Interpolates keyframes `[[time, value, ease?], ...]`, holding the first and last values
 * outside them. A key's ease shapes the move that arrives at it. Values are numbers or flat
 * objects of numbers.
 */
export function track(time, keys, fallback = ease.inOut) {
  if (time <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    const [end, value, curve] = keys[i];
    if (time < end) {
      const [start, previous] = keys[i - 1];
      return mix(previous, value, (curve ?? fallback)(seg(time, start, end)));
    }
  }
  return keys[keys.length - 1][1];
}

/** 0 → 1 over [inStart, inEnd], then 1 → 0 over [outStart, outEnd]. */
export const fade = (time, inStart, inEnd, outStart, outEnd, curve = ease.inOut) =>
  Math.min(curve(seg(time, inStart, inEnd)), 1 - curve(seg(time, outStart, outEnd)));

/** A smooth pseudo-random wobble in -1...1, stable for a given time and seed. */
export const wobble = (time, seed = 0, speed = 1) =>
  Math.sin(time * 1.3 * speed + seed * 12.9898) * 0.6 + Math.sin(time * 0.71 * speed + seed * 78.233) * 0.4;

export const mixColor = (from, to, progress) => {
  const parse = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
  const [a, b] = [parse(from), parse(to)];
  return `rgb(${a.map((channel, i) => Math.round(lerp(channel, b[i], progress))).join(',')})`;
};
