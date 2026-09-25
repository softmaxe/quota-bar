// Renders the README demo film (docs/demo) to MP4: the score through an OfflineAudioContext,
// the picture frame by frame in headless Chromium, then ffmpeg to a file small enough for a
// GitHub README attachment.
//
//   node Scripts/demo_video.mjs                 both languages
//   node Scripts/demo_video.mjs zh              one language
//   node Scripts/demo_video.mjs --stills 9.5,31 selected frames as PNG, both languages
//   node Scripts/demo_video.mjs --audio         the soundtrack only
//   node Scripts/demo_video.mjs --encode-only   re-encode existing masters and soundtrack
//
// Output lands in build/demo/. Samples download once into build/demo/samples/.
import {createServer} from 'node:http';
import {createReadStream, existsSync, mkdirSync, realpathSync, statSync, writeFileSync} from 'node:fs';
import {dirname, extname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {execFileSync, spawn} from 'node:child_process';
import {DURATION, frameCount} from '../docs/demo/timeline.mjs';
import {LANGUAGES} from '../docs/demo/copy.mjs';
import {SAMPLES, cacheName} from '../docs/demo/samples.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'build/demo');
const CACHE = join(OUT, 'samples');
const FPS = 30;
/** GitHub accepts README video attachments up to 10 MB on free plans; leave headroom. */
const BUDGET_BYTES = 9.2 * 1024 * 1024;
const AUDIO_KBPS = 128;

const args = process.argv.slice(2);
const flag = name => args.includes(name);
const option = name => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};
const languages = args.filter(arg => LANGUAGES.includes(arg));
const targets = languages.length ? languages : LANGUAGES;

const run = (command, commandArgs) => execFileSync(command, commandArgs, {stdio: ['ignore', 'inherit', 'inherit']});
const log = message => console.log(`==> ${message}`);

async function downloadSamples() {
  let fetched = 0;
  for (const [instrument, samples] of Object.entries(SAMPLES)) {
    for (const sample of samples) {
      const file = join(CACHE, cacheName(instrument, sample));
      if (existsSync(file)) continue;
      mkdirSync(dirname(file), {recursive: true});
      const response = await fetch(sample.url);
      if (!response.ok) throw new Error(`${sample.url}: HTTP ${response.status}`);
      writeFileSync(file, Buffer.from(await response.arrayBuffer()));
      fetched++;
    }
  }
  if (fetched) log(`downloaded ${fetched} samples`);
}

const TYPES = {'.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.wav': 'audio/wav', '.mp3': 'audio/mpeg', '.m4a': 'audio/mp4', '.json': 'application/json'};

/** Serves the repository, since ES modules do not load from file:// URLs. */
function serve() {
  const server = createServer((request, response) => {
    const path = decodeURIComponent(new URL(request.url, 'http://x').pathname);
    const file = join(ROOT, path);
    if (!file.startsWith(ROOT) || !existsSync(file) || !statSync(file).isFile()) {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, {'content-type': TYPES[extname(file)] ?? 'application/octet-stream'});
    createReadStream(file).pipe(response);
  });
  return new Promise(done => server.listen(0, '127.0.0.1', () => done(server)));
}

async function launch() {
  const modulePath = process.env.PLAYWRIGHT_MODULE || realpathSync(execFileSync('which', ['playwright-cli'], {encoding: 'utf8'}).trim());
  const {chromium} = createRequire(modulePath)('playwright');
  // Same browser as Scripts/report_image.mjs, so no Playwright browser download is needed.
  return chromium.launch({
    headless: true,
    executablePath: process.env.CHROMIUM_PATH || '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
    args: ['--force-color-profile=srgb', '--font-render-hinting=none'],
  });
}

async function renderAudio(browser, origin) {
  await downloadSamples();
  log('rendering soundtrack');
  const page = await browser.newPage();
  page.on('pageerror', error => console.error(error));
  await page.goto(`${origin}/docs/demo/demo.html?render=1`);
  const manifest = Object.fromEntries(Object.entries(SAMPLES).map(([instrument, samples]) => [
    instrument, samples.map(sample => ({midi: sample.midi, layer: sample.layer, src: `/build/demo/samples/${encodeURI(cacheName(instrument, sample)).replace(/#/g, '%23')}`})),
  ]));
  const base64 = await page.evaluate(async ({manifest, duration}) => {
    const {renderSoundtrack} = await import('./audio.mjs');
    const {compose} = await import('./score.mjs');
    const pcm = await renderSoundtrack({notes: compose(), manifest, duration});
    const bytes = new Uint8Array(pcm.buffer);
    let binary = '';
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  }, {manifest, duration: DURATION});
  await page.close();

  const raw = join(OUT, 'soundtrack.f32');
  writeFileSync(raw, Buffer.from(base64, 'base64'));
  // Loudness-normalize for small speakers and headphones alike, then encode once for muxing.
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'f32le', '-ar', '48000', '-ac', '2', '-i', raw,
    '-af', 'loudnorm=I=-16:TP=-1.5:LRA=11', '-ar', '48000', '-c:a', 'aac', '-b:a', `${AUDIO_KBPS}k`, join(OUT, 'soundtrack.m4a')]);
  run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'f32le', '-ar', '48000', '-ac', '2', '-i', raw,
    '-af', 'loudnorm=I=-16:TP=-1.5:LRA=11', '-ar', '48000', '-c:a', 'pcm_s16le', join(OUT, 'soundtrack.wav')]);
  log('build/demo/soundtrack.m4a');
}

async function openFilm(browser, origin, language) {
  const page = await browser.newPage({viewport: {width: 1920, height: 1080}, deviceScaleFactor: 1});
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(`${origin}/docs/demo/demo.html?lang=${language}&render=1`);
  await page.evaluate(() => window.demoReady);
  if (errors.length) throw new Error(errors.join('\n'));
  return page;
}

async function renderStills(browser, origin, times) {
  const dir = join(OUT, 'stills');
  mkdirSync(dir, {recursive: true});
  for (const language of targets) {
    const page = await openFilm(browser, origin, language);
    for (const time of times) {
      await page.evaluate(t => window.seek(t), time);
      const file = join(dir, `${language}-${time.toFixed(2)}.png`);
      await page.screenshot({path: file});
      console.log(file);
    }
    await page.close();
  }
}

function write(stream, chunk) {
  return stream.write(chunk) ? Promise.resolve() : new Promise(done => stream.once('drain', done));
}

async function renderFilm(browser, origin, language) {
  const master = join(OUT, `master-${language}.mp4`);
  const final = join(OUT, `quotabar-demo-${language}.mp4`);
  if (!(flag('--encode-only') && existsSync(master))) await renderFrames(browser, origin, language, master);
  await encode(language, master, final);
}

async function renderFrames(browser, origin, language, master) {
  const page = await openFilm(browser, origin, language);
  const frames = frameCount(FPS);
  log(`rendering ${frames} frames (${language})`);
  const encoder = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'png', '-i', '-',
    '-c:v', 'libx264', '-preset', 'medium', '-crf', '10', '-pix_fmt', 'yuv420p', master], {stdio: ['pipe', 'inherit', 'inherit']});
  const finished = new Promise((done, fail) => encoder.on('close', code => (code === 0 ? done() : fail(new Error(`ffmpeg exited ${code}`)))));
  const started = Date.now();
  for (let frame = 0; frame < frames; frame++) {
    await page.evaluate(t => window.seek(t), frame / FPS);
    await write(encoder.stdin, await page.screenshot({type: 'png'}));
    if (frame % 150 === 0) process.stdout.write(`  ${frame}/${frames} (${((Date.now() - started) / 1000).toFixed(0)}s)\n`);
  }
  encoder.stdin.end();
  await finished;
  await page.close();
}

async function encode(language, master, final) {
  // Two-pass to a bitrate that fits the attachment budget with the soundtrack.
  const videoKbps = Math.floor((BUDGET_BYTES * 8) / DURATION / 1000 - AUDIO_KBPS - 8);
  log(`encoding ${language} at ${videoKbps} kb/s video`);
  const passlog = join(OUT, `pass-${language}`);
  const quiet = ['-hide_banner', '-loglevel', 'error', '-y'];
  const video = ['-c:v', 'libx264', '-preset', 'veryslow', '-tune', 'animation', '-b:v', `${videoKbps}k`, '-maxrate', `${videoKbps * 3}k`,
    '-bufsize', `${videoKbps * 6}k`, '-pix_fmt', 'yuv420p', '-passlogfile', passlog];
  run('ffmpeg', [...quiet, '-i', master, ...video, '-pass', '1', '-an', '-f', 'mp4', '/dev/null']);
  run('ffmpeg', [...quiet, '-i', master, '-i', join(OUT, 'soundtrack.m4a'), '-map', '0:v', '-map', '1:a', ...video, '-pass', '2',
    '-c:a', 'copy', '-shortest', '-movflags', '+faststart', final]);
  const size = statSync(final).size;
  log(`${final.replace(ROOT + '/', '')}: ${(size / 1024 / 1024).toFixed(2)} MB`);
  if (size > 10 * 1024 * 1024) throw new Error(`${final} is over GitHub's 10 MB attachment limit`);
}

mkdirSync(OUT, {recursive: true});
const server = await serve();
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await launch();
try {
  const stills = option('--stills');
  if (stills) {
    await renderStills(browser, origin, stills.split(',').map(Number));
  } else {
    if (flag('--audio') || !existsSync(join(OUT, 'soundtrack.m4a')) || !flag('--encode-only')) await renderAudio(browser, origin);
    if (!flag('--audio')) for (const language of targets) await renderFilm(browser, origin, language);
  }
} finally {
  await browser.close();
  server.close();
}
