// Workout audio engine.
//
// iOS suspends JavaScript when the screen locks, so timers can't trigger cues.
// Instead, the whole workout is rendered up front into ONE audio track
// (silence + spoken cues + countdown beeps at exact timestamps) and played
// with a normal <audio> element, which iOS keeps playing in the background.
// The on-screen timer simply reads audio.currentTime, so it can never drift.

import { segmentsFor } from './plan.js';

export const SR = 11025; // matches the cue clips; ~22 KB per second of workout
const CUE_NAMES = ['warmup', 'run', 'walk', 'lastrun', 'halfway', 'oneminute', 'cooldown', 'done'];

let clips = null;
let clipsPromise = null;

export function loadClips() {
  if (clips) return Promise.resolve(clips);
  if (!clipsPromise) {
    clipsPromise = Promise.all(CUE_NAMES.map(async name => {
      const res = await fetch(`audio/${name}.wav`);
      if (!res.ok) throw new Error(`Missing cue: ${name}`);
      return [name, prepare(parseWav(await res.arrayBuffer()))];
    })).then(entries => (clips = Object.fromEntries(entries)));
  }
  return clipsPromise;
}

export const clipsReady = () => !!clips;

function parseWav(buf) {
  const v = new DataView(buf);
  let off = 12;
  while (off + 8 <= v.byteLength) {
    const id = String.fromCharCode(v.getUint8(off), v.getUint8(off + 1), v.getUint8(off + 2), v.getUint8(off + 3));
    const size = v.getUint32(off + 4, true);
    if (id === 'data') {
      const n = Math.floor(Math.min(size, v.byteLength - off - 8) / 2);
      return new Int16Array(buf.slice(off + 8, off + 8 + n * 2));
    }
    off += 8 + size + (size & 1);
  }
  throw new Error('Bad WAV');
}

// Trim silence and normalise loudness so cues cut through music.
function prepare(pcm) {
  const thr = 400;
  let a = 0, b = pcm.length - 1;
  while (a < b && Math.abs(pcm[a]) < thr) a++;
  while (b > a && Math.abs(pcm[b]) < thr) b--;
  a = Math.max(0, a - Math.round(SR * 0.02));
  b = Math.min(pcm.length - 1, b + Math.round(SR * 0.08));
  const out = pcm.slice(a, b + 1);
  let peak = 1;
  for (let i = 0; i < out.length; i++) peak = Math.max(peak, Math.abs(out[i]));
  const g = (32767 * 0.97) / peak;
  for (let i = 0; i < out.length; i++) out[i] = Math.max(-32768, Math.min(32767, Math.round(out[i] * g)));
  return out;
}

function tone(freq, secs, amp = 0.55) {
  const n = Math.round(SR * secs);
  const out = new Int16Array(n);
  const fade = Math.round(SR * 0.012);
  for (let i = 0; i < n; i++) {
    const env = Math.min(1, i / fade, (n - 1 - i) / fade);
    out[i] = Math.round(Math.sin(2 * Math.PI * freq * i / SR) * env * amp * 32767);
  }
  return out;
}

const BEEP = tone(880, 0.11);

function wavHeader(numSamples) {
  const dataBytes = numSamples * 2;
  const h = new DataView(new ArrayBuffer(44));
  const w = (o, s) => { for (let i = 0; i < s.length; i++) h.setUint8(o + i, s.charCodeAt(i)); };
  w(0, 'RIFF'); h.setUint32(4, 36 + dataBytes, true); w(8, 'WAVE');
  w(12, 'fmt '); h.setUint32(16, 16, true); h.setUint16(20, 1, true); h.setUint16(22, 1, true);
  h.setUint32(24, SR, true); h.setUint32(28, SR * 2, true); h.setUint16(32, 2, true); h.setUint16(34, 16, true);
  w(36, 'data'); h.setUint32(40, dataBytes, true);
  return h.buffer;
}

// Builds the cue schedule for a workout. Exported so the UI/tests can inspect it.
export function cueEvents(wk, opts = {}) {
  const { beeps = true, halfway = true } = opts;
  const segs = segmentsFor(wk);
  const ev = [];
  const runs = segs.filter(s => s.type === 'run');
  const lastRun = runs[runs.length - 1];

  segs.forEach((s, i) => {
    let cue = s.type;
    if (s.type === 'run' && s === lastRun && runs.length > 1) cue = 'lastrun';
    if (beeps && i > 0 && segs[i - 1].dur >= 6) {
      for (const d of [3, 2, 1]) ev.push({ t: s.start - d, kind: 'beep' });
    }
    ev.push({ t: s.start, kind: cue });
    if (s.type === 'run' && s.dur >= 180) ev.push({ t: s.end - 60, kind: 'oneminute' });
  });

  if (halfway && runs.length) {
    const mid = (runs[0].start + lastRun.end) / 2;
    const clash = ev.some(e => e.kind !== 'beep' && Math.abs(e.t - mid) < 6) || ev.some(e => e.kind === 'beep' && Math.abs(e.t - mid) < 4);
    if (!clash && runs[0].start < mid) ev.push({ t: mid, kind: 'halfway' });
  }

  const end = segs.length ? segs[segs.length - 1].end : 0;
  ev.push({ t: end, kind: 'done' });
  ev.sort((a, b) => a.t - b.t);
  return { segs, events: ev, end };
}

// Renders the workout into a WAV blob URL.
export function render(wk, opts = {}) {
  if (!clips) throw new Error('Cues not loaded yet');
  const { segs, events, end } = cueEvents(wk, opts);
  const doneLen = clips.done.length;
  const totalSamples = Math.round(end * SR) + doneLen + SR; // tail for the final message

  const zeros = new Int16Array(SR * 10);
  const parts = [wavHeader(totalSamples)];
  let cursor = 0;
  const pushSilence = n => {
    while (n > 0) { const k = Math.min(n, zeros.length); parts.push(zeros.subarray(0, k)); n -= k; }
  };

  for (const e of events) {
    const pcm = e.kind === 'beep' ? BEEP : clips[e.kind];
    const at = Math.max(cursor, Math.round(e.t * SR));
    if (at + pcm.length > totalSamples) continue;
    pushSilence(at - cursor);
    parts.push(pcm);
    cursor = at + pcm.length;
  }
  pushSilence(totalSamples - cursor);

  const blob = new Blob(parts, { type: 'audio/wav' });
  return { url: URL.createObjectURL(blob), segs, end, duration: totalSamples / SR, bytes: blob.size };
}

// Plays a single cue (for the Settings "Test voice" button).
export async function testCue(mode) {
  await loadClips();
  const gap = new Int16Array(Math.round(SR * 0.9));
  const seq = [BEEP, gap, BEEP, gap, BEEP, gap, clips.run, new Int16Array(Math.round(SR * 0.5))];
  const n = seq.reduce((a, x) => a + x.length, 0);
  setAudioSession(mode);
  const a = new Audio(URL.createObjectURL(new Blob([wavHeader(n), ...seq], { type: 'audio/wav' })));
  await a.play();
}

export function setAudioSession(mode) {
  // 'ambient' mixes with Spotify/Podcasts but iOS silences it when the screen locks
  // (and when the Ring/Silent switch is on Silent).
  // 'playback' keeps going with the screen locked but pauses other apps' audio.
  try {
    if (navigator.audioSession) navigator.audioSession.type = mode === 'locked' ? 'playback' : 'ambient';
  } catch (e) { console.warn('audioSession not supported', e); }
}

export class WorkoutPlayer extends EventTarget {
  constructor() {
    super();
    this.audio = new Audio();
    this.audio.preload = 'auto';
    this.audio.setAttribute('playsinline', '');
    this.wakeLock = null;
    for (const t of ['play', 'pause', 'ended']) this.audio.addEventListener(t, () => this.dispatchEvent(new Event(t)));
    this._onVis = () => { if (document.visibilityState === 'visible' && this.mode === 'mix' && !this.audio.paused) this.lockScreenOn(); };
  }

  load(wk, opts, meta) {
    this.unload();
    this.rendered = render(wk, opts);
    this.mode = opts.mode;
    this.audio.src = this.rendered.url;
    this.meta = meta;
    this.setupMediaSession();
    document.addEventListener('visibilitychange', this._onVis);
    return this.rendered;
  }

  async play() {
    setAudioSession(this.mode);
    await this.audio.play();
    if (this.mode === 'mix') this.lockScreenOn();
  }

  pause() { this.audio.pause(); }

  get time() { return this.audio.currentTime || 0; }
  get paused() { return this.audio.paused; }
  // True once the final "Workout complete" message has finished playing.
  get ended() { return !!this.rendered && (this.audio.ended || this.time >= this.rendered.duration - 0.05); }

  async lockScreenOn() {
    try { if ('wakeLock' in navigator && !this.wakeLock) {
      this.wakeLock = await navigator.wakeLock.request('screen');
      this.wakeLock.addEventListener('release', () => { this.wakeLock = null; });
    } } catch (e) { console.warn('wake lock', e); }
  }

  setupMediaSession() {
    if (!('mediaSession' in navigator)) return;
    navigator.mediaSession.metadata = new MediaMetadata({
      title: this.meta.title,
      artist: this.meta.subtitle,
      album: '5K Coach',
      artwork: [{ src: 'icons/icon-512.png', sizes: '512x512', type: 'image/png' }],
    });
    navigator.mediaSession.setActionHandler('play', () => this.play());
    navigator.mediaSession.setActionHandler('pause', () => this.pause());
    for (const a of ['seekbackward', 'seekforward', 'previoustrack', 'nexttrack']) {
      try { navigator.mediaSession.setActionHandler(a, null); } catch {}
    }
  }

  unload() {
    this.audio.pause();
    if (this.rendered) URL.revokeObjectURL(this.rendered.url);
    this.rendered = null;
    this.audio.removeAttribute('src');
    document.removeEventListener('visibilitychange', this._onVis);
    if (this.wakeLock) { this.wakeLock.release().catch(() => {}); this.wakeLock = null; }
    if ('mediaSession' in navigator) navigator.mediaSession.metadata = null;
  }
}
