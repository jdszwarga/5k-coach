// GPS during a run: distance, pace and a route track.
//
// Fixes come from watchPosition while the app's JavaScript is running. In Music mix mode the
// screen stays on, so that's the whole run. In Screen off mode iOS suspends the page (and
// location) while the phone is locked, so fixes stop until she looks at the phone again.
// When a fix arrives after a long silence we join it to the last one with a straight line:
// it counts toward distance (a straight line is the shortest route, so this undercounts),
// and it's marked as a gap so the map draws it dashed.

export const M_PER_MI = 1609.344;
const MAX_ACC = 35;        // m: ignore fixes worse than this (cell/wifi guesses, cold starts)
const MAX_SPEED = 8;       // m/s (~3:20/mi): anything faster is a GPS jump, not her
const GAP_SEC = 20;        // no fix for this long = a gap (normal rate is ~1 per second)
const JUMP_RESET = 3;      // after this many "impossible" fixes in a row, trust the new spot
const PACE_WINDOW = 30;    // sec of recent track used for current pace

const R = 6371008.8;
const rad = d => d * Math.PI / 180;
export function haversine(lat1, lng1, lat2, lng2) {
  const dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)));
}

export const miles = m => m / M_PER_MI;
export const miText = m => miles(m).toFixed(2);
// Seconds per mile, or null when there isn't enough to say.
export function paceSec(m, sec) {
  if (!m || m < 40 || !sec) return null;
  const p = sec / miles(m);
  return p > 0 && p < 60 * 60 ? p : null;
}

export class GpsTracker {
  // clock() = seconds into the workout (pauses don't count), used to timestamp points.
  constructor(clock) {
    this.clock = clock;
    this.pts = [];          // { lat, lng, t, ts, kind: 'start' | 'line' | 'gap' | 'break' }
    this.distM = 0;
    this.sec = 0;           // workout seconds covered by the track (excludes breaks)
    this.status = 'off';    // off | searching | ok | denied | unavailable
    this.paused = false;
    this.needBreak = false;
    this.rejects = 0;
    this.lastFixAt = 0;
    this.watchId = null;
    this.onchange = null;
  }

  get available() { return 'geolocation' in navigator; }

  start() {
    if (!this.available) { this.set('unavailable'); return; }
    this.set('searching');
    try {
      this.watchId = navigator.geolocation.watchPosition(p => this.onFix(p), e => this.onError(e),
        { enableHighAccuracy: true, maximumAge: 0, timeout: 30000 });
    } catch (e) {
      console.warn('gps', e);
      this.set('unavailable');
    }
  }

  stop() {
    if (this.watchId != null) { try { navigator.geolocation.clearWatch(this.watchId); } catch {} }
    this.watchId = null;
  }

  // While the workout is paused we ignore fixes; the next one after resuming starts a new
  // piece of track instead of being joined up (she may have wandered off, or stopped).
  setPaused(p) {
    if (p && !this.paused) this.needBreak = true;
    this.paused = p;
  }

  set(status) {
    if (this.status === status) return;
    this.status = status;
    this.onchange?.();
  }

  onError(e) {
    if (e.code === 1) { this.set('denied'); this.stop(); return; }   // PERMISSION_DENIED
    if (this.status !== 'ok') this.set('searching');                  // unavailable / timeout: keep watching
  }

  onFix(pos) {
    const { latitude: lat, longitude: lng, accuracy } = pos.coords;
    const ts = pos.timestamp || Date.now();
    if (this.paused || !isFinite(lat) || !isFinite(lng)) return;
    if (!(accuracy <= MAX_ACC)) { if (this.status !== 'ok') this.set('searching'); return; }
    this.lastFixAt = Date.now();
    const t = Math.max(0, this.clock());
    const prev = this.pts[this.pts.length - 1];
    if (!prev) { this.add({ lat, lng, t, ts, kind: 'start' }); return; }
    if (this.needBreak) { this.needBreak = false; this.rejects = 0; this.add({ lat, lng, t, ts, kind: 'break' }); return; }

    const dt = (ts - prev.ts) / 1000;
    if (dt <= 0) return;
    const d = haversine(prev.lat, prev.lng, lat, lng);
    if (d / dt > MAX_SPEED) {
      // A jump. If it keeps happening the last point was the bad one (or she really moved):
      // start a fresh piece from here without counting the jump.
      if (++this.rejects >= JUMP_RESET) { this.rejects = 0; this.add({ lat, lng, t, ts, kind: 'break' }); }
      return;
    }
    this.rejects = 0;
    const gap = dt > GAP_SEC;
    // Standing still, GPS wanders a few meters: wait until she's clearly moved.
    if (!gap && d < Math.max(4, accuracy * 0.6)) return;
    this.distM += d;
    this.sec += Math.max(0, t - prev.t);
    this.add({ lat, lng, t, ts, kind: gap ? 'gap' : 'line' });
  }

  add(p) {
    this.pts.push(p);
    this.set('ok');
    this.onchange?.();
  }

  // Pace over the last ~30 s of continuous track (not across gaps or breaks).
  currentPace() {
    const pts = this.pts, last = pts[pts.length - 1];
    if (!last || Date.now() - this.lastFixAt > GAP_SEC * 1000) return null;
    let d = 0, i = pts.length - 1;
    while (i > 0 && pts[i].kind === 'line' && last.t - pts[i - 1].t <= PACE_WINDOW) {
      d += haversine(pts[i - 1].lat, pts[i - 1].lng, pts[i].lat, pts[i].lng);
      i--;
    }
    const span = last.t - pts[i].t;
    if (d < 15 || span <= 0) return null;
    const p = span / miles(d);
    return p < 60 * 60 ? p : null;
  }

  avgPace() { return paceSec(this.distM, this.sec); }
  hasGaps() { return this.pts.some(p => p.kind === 'gap'); }

  // What gets stored with the run, or null if nothing was recorded.
  summary() {
    if (this.pts.length < 2 || this.distM < 10) return null;
    return { distM: Math.round(this.distM), gpsSec: Math.round(this.sec), track: pack(this.pts) };
  }
}

// ---- Storage format ----
// track = { v: 1, pts: [[lat, lng, t], ...], gap: [i, ...], brk: [i, ...] }
//   lat/lng rounded to 5 decimals (~1 m), t = whole seconds into the workout.
//   gap: point i was reached after a GPS gap (line i-1 -> i is a straight-line guess, drawn dashed).
//   brk: point i starts a new piece (after a pause); no line from i-1 and not counted.
// The live track is thinned with Douglas-Peucker (3 m) so a 5K is a few hundred points.
const EPS = 3;

export function pack(pts) {
  const keep = new Set([0, pts.length - 1]);
  let s = 0;
  for (let i = 1; i <= pts.length; i++) {
    if (i === pts.length || pts[i].kind !== 'line') {
      // pts[s..i-1] is one continuous solid piece
      rdp(pts, s, i - 1, keep);
      if (i < pts.length) { keep.add(i - 1); keep.add(i); }
      s = i;
    }
  }
  const idx = [...keep].sort((a, b) => a - b);
  const out = { v: 1, pts: [], gap: [], brk: [] };
  idx.forEach((k, j) => {
    const p = pts[k];
    out.pts.push([+p.lat.toFixed(5), +p.lng.toFixed(5), Math.round(p.t)]);
    if (p.kind === 'gap') out.gap.push(j);
    if (p.kind === 'break') out.brk.push(j);
  });
  return out;
}

function rdp(pts, a, b, keep) {
  if (b - a < 2) return;
  const k = Math.cos(rad(pts[a].lat)) * 111320, ky = 110540;
  const ax = pts[a].lng * k, ay = pts[a].lat * ky, bx = pts[b].lng * k, by = pts[b].lat * ky;
  const len = Math.hypot(bx - ax, by - ay);
  let best = -1, far = 0;
  for (let i = a + 1; i < b; i++) {
    const px = pts[i].lng * k, py = pts[i].lat * ky;
    const dist = len < 1e-6 ? Math.hypot(px - ax, py - ay) : Math.abs((bx - ax) * (ay - py) - (ax - px) * (by - ay)) / len;
    if (dist > far) { far = dist; best = i; }
  }
  if (far > EPS) { keep.add(best); rdp(pts, a, best, keep); rdp(pts, best, b, keep); }
}

// Pieces to draw: [{ line: [[lat, lng], ...], dashed }]
export function pieces(track) {
  if (!track?.pts?.length) return [];
  const gap = new Set(track.gap || []), brk = new Set(track.brk || []);
  const out = [];
  let cur = { line: [track.pts[0].slice(0, 2)], dashed: false };
  for (let i = 1; i < track.pts.length; i++) {
    const p = track.pts[i].slice(0, 2);
    if (brk.has(i) || gap.has(i)) {
      if (cur.line.length > 1) out.push(cur);
      if (gap.has(i)) out.push({ line: [track.pts[i - 1].slice(0, 2), p], dashed: true });
      cur = { line: [p], dashed: false };
    } else cur.line.push(p);
  }
  if (cur.line.length > 1) out.push(cur);
  return out;
}
