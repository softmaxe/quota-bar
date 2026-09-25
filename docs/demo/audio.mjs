// Renders the score to a stereo buffer in an OfflineAudioContext: sampled piano, strings, and
// glockenspiel, a synthesized low pulse and interface ticks, a generated hall reverb, and a
// gentle master bus. Runs in the browser; the render script reads the samples back out.

const MIX = {
  piano: {gain: 0.95, pan: 0, send: 0.26, attack: 0.002, release: 0.5},
  violins: {gain: 0.6, pan: -0.28, send: 0.42, attack: 0.28, release: 0.7},
  violas: {gain: 0.42, pan: 0.18, send: 0.42, attack: 0.4, release: 0.8},
  celli: {gain: 0.5, pan: 0.32, send: 0.38, attack: 0.34, release: 0.8},
  basses: {gain: 0.5, pan: 0.08, send: 0.3, attack: 0.3, release: 0.6},
  glock: {gain: 0.3, pan: -0.12, send: 0.55, attack: 0.001, release: 2.5},
  pulse: {gain: 0.5, pan: 0, send: 0.12},
  tick: {gain: 0.1, pan: 0.12, send: 0.12},
};

const hz = midi => 440 * Math.pow(2, (midi - 69) / 12);

/** A decaying, darkening stereo tail with a few early reflections. */
function hallImpulse(ctx, seconds = 3.6) {
  const rate = ctx.sampleRate;
  const length = Math.floor(seconds * rate);
  const buffer = ctx.createBuffer(2, length, rate);
  let seed = 1;
  const noise = () => {
    seed = (seed * 16807) % 2147483647;
    return seed / 1073741823.5 - 1;
  };
  for (let channel = 0; channel < 2; channel++) {
    const data = buffer.getChannelData(channel);
    let low = 0;
    for (let i = 0; i < length; i++) {
      const t = i / rate;
      const decay = Math.exp((-6.9 * t) / (seconds * 0.92));
      // Higher frequencies die sooner: the one-pole filter closes as the tail ages.
      const coefficient = 0.08 + 0.85 * Math.min(1, t / (seconds * 0.7));
      low += (noise() - low) * (1 - coefficient);
      const predelay = t < 0.022 ? 0 : 1;
      data[i] = low * decay * predelay * 0.9;
    }
    for (const [time, level] of [[0.011, 0.5], [0.019, 0.34], [0.027, 0.26], [0.041, 0.18]]) {
      data[Math.floor((time + channel * 0.003) * rate)] += level;
    }
  }
  return buffer;
}

function nearest(samples, midi, layer) {
  let best = null;
  for (const sample of samples) {
    const distance = Math.abs(sample.midi - midi) + (sample.layer && sample.layer !== layer ? 0.5 : 0);
    if (!best || distance < best.distance) best = {sample, distance};
  }
  return best.sample;
}

async function loadSamples(ctx, manifest) {
  const loaded = {};
  await Promise.all(Object.entries(manifest).map(async ([instrument, samples]) => {
    loaded[instrument] = await Promise.all(samples.map(async sample => {
      const response = await fetch(sample.src);
      if (!response.ok) throw new Error(`sample ${sample.src}: HTTP ${response.status}`);
      return {...sample, buffer: await ctx.decodeAudioData(await response.arrayBuffer())};
    }));
  }));
  return loaded;
}

/**
 * @param notes from score.mjs compose()
 * @param manifest instrument → [{midi, layer?, src}] with fetchable sample URLs
 * @returns interleaved stereo Float32Array
 */
export async function renderSoundtrack({notes, manifest, duration, sampleRate = 48000}) {
  const ctx = new OfflineAudioContext(2, Math.ceil(duration * sampleRate), sampleRate);
  const samples = await loadSamples(ctx, manifest);

  // Master: warm the lows a touch, add air, glue, then catch peaks.
  const rumble = new BiquadFilterNode(ctx, {type: 'highpass', frequency: 32, Q: 0.7});
  const lowShelf = new BiquadFilterNode(ctx, {type: 'lowshelf', frequency: 140, gain: 0.5});
  const mud = new BiquadFilterNode(ctx, {type: 'peaking', frequency: 280, Q: 0.9, gain: -2});
  const highShelf = new BiquadFilterNode(ctx, {type: 'highshelf', frequency: 9000, gain: 2});
  const glue = new DynamicsCompressorNode(ctx, {threshold: -20, knee: 12, ratio: 2.4, attack: 0.03, release: 0.3});
  const limiter = new DynamicsCompressorNode(ctx, {threshold: -3, knee: 0, ratio: 20, attack: 0.002, release: 0.1});
  const master = new GainNode(ctx, {gain: 0});
  master.gain.setValueAtTime(0, 0);
  master.gain.linearRampToValueAtTime(0.9, 0.02);
  master.gain.setValueAtTime(0.9, duration - 1.4);
  master.gain.linearRampToValueAtTime(0, duration - 0.05);
  const mix = new GainNode(ctx, {gain: 0.8});
  mix.connect(rumble).connect(lowShelf).connect(mud).connect(highShelf).connect(glue).connect(limiter).connect(master).connect(ctx.destination);

  const reverb = new ConvolverNode(ctx, {buffer: hallImpulse(ctx), disableNormalization: false});
  const reverbReturn = new GainNode(ctx, {gain: 0.55});
  const reverbTone = new BiquadFilterNode(ctx, {type: 'highpass', frequency: 180});
  reverb.connect(reverbTone).connect(reverbReturn).connect(mix);

  const buses = {};
  for (const [instrument, settings] of Object.entries(MIX)) {
    const bus = new GainNode(ctx, {gain: settings.gain});
    const pan = new StereoPannerNode(ctx, {pan: settings.pan});
    const send = new GainNode(ctx, {gain: settings.send});
    bus.connect(pan).connect(mix);
    pan.connect(send).connect(reverb);
    buses[instrument] = bus;
  }

  for (const note of notes) {
    const settings = MIX[note.instrument];
    const out = buses[note.instrument];
    const start = note.time;
    const end = note.time + note.duration;

    if (note.instrument === 'pulse') {
      // A soft sine thump with a little second harmonic, closed down low.
      const gain = new GainNode(ctx, {gain: 0});
      const filter = new BiquadFilterNode(ctx, {type: 'lowpass', frequency: 320, Q: 0.4});
      for (const [multiple, level] of [[1, 1], [2, 0.22]]) {
        const osc = new OscillatorNode(ctx, {type: 'sine', frequency: hz(note.midi) * multiple});
        const partial = new GainNode(ctx, {gain: level});
        osc.connect(partial).connect(filter);
        osc.start(start);
        osc.stop(end + 0.4);
      }
      filter.connect(gain).connect(out);
      const peak = note.velocity * 0.9;
      gain.gain.setValueAtTime(0, start);
      gain.gain.linearRampToValueAtTime(peak, start + 0.006);
      gain.gain.exponentialRampToValueAtTime(Math.max(0.0005, peak * 0.05), end + 0.3);
      continue;
    }

    if (note.instrument === 'tick') {
      // A trackpad click: a brief filtered noise tap over a tiny pitched blip.
      const length = Math.floor(0.03 * ctx.sampleRate);
      const burst = ctx.createBuffer(1, length, ctx.sampleRate);
      const data = burst.getChannelData(0);
      for (let i = 0; i < length; i++) data[i] = (Math.sin(i * 12.9898) * 43758.5453 % 1) * Math.exp(-i / (length * 0.18));
      const source = new AudioBufferSourceNode(ctx, {buffer: burst});
      const band = new BiquadFilterNode(ctx, {type: 'bandpass', frequency: hz(note.midi) * 0.6, Q: 1.2});
      const gain = new GainNode(ctx, {gain: note.velocity});
      source.connect(band).connect(gain).connect(out);
      source.start(start);
      const blip = new OscillatorNode(ctx, {type: 'sine', frequency: hz(note.midi) / 2});
      const blipGain = new GainNode(ctx, {gain: 0});
      blip.connect(blipGain).connect(out);
      blipGain.gain.setValueAtTime(note.velocity * 0.35, start);
      blipGain.gain.exponentialRampToValueAtTime(0.0001, start + 0.05);
      blip.start(start);
      blip.stop(start + 0.06);
      continue;
    }

    const layer = note.instrument === 'celli' || note.instrument === 'basses' ? (note.velocity > 0.55 ? 3 : 1) : note.velocity > 0.6 ? 2 : 1;
    const sample = nearest(samples[note.instrument], note.midi, layer);
    const source = new AudioBufferSourceNode(ctx, {buffer: sample.buffer, playbackRate: Math.pow(2, (note.midi - sample.midi) / 12)});
    const gain = new GainNode(ctx, {gain: 0});
    let node = source;
    if (note.instrument === 'piano') {
      // Softer strikes are darker as well as quieter.
      const tone = new BiquadFilterNode(ctx, {type: 'lowpass', frequency: 1800 + note.velocity * 9000, Q: 0.3});
      node = source.connect(tone);
    }
    node.connect(gain).connect(out);

    const level = note.instrument === 'piano' ? Math.pow(note.velocity, 1.5) : Math.pow(note.velocity, 1.2);
    const attack = note.instrument === 'violins' && note.duration < 0.7 ? 0.1 : settings.attack;
    gain.gain.setValueAtTime(0, start);
    gain.gain.linearRampToValueAtTime(level, start + attack);
    if (note.instrument !== 'piano' && note.instrument !== 'glock') {
      // Bowed notes swell slightly into the middle of their length.
      gain.gain.linearRampToValueAtTime(level * 1.12, start + Math.max(attack + 0.01, note.duration * 0.55));
    }
    gain.gain.setValueAtTime(level * (note.instrument === 'piano' || note.instrument === 'glock' ? 1 : 1.05), Math.max(start + attack + 0.01, end));
    gain.gain.setTargetAtTime(0, Math.max(start + attack + 0.01, end), settings.release / 4);
    source.start(start);
    source.stop(Math.min(duration, end + settings.release * 2));
  }

  const rendered = await ctx.startRendering();
  const [left, right] = [rendered.getChannelData(0), rendered.getChannelData(1)];
  const interleaved = new Float32Array(left.length * 2);
  for (let i = 0; i < left.length; i++) {
    interleaved[2 * i] = left[i];
    interleaved[2 * i + 1] = right[i];
  }
  return interleaved;
}
