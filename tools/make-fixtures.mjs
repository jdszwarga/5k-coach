// Writes JSON fixtures from the web app's JS so the Swift port (ios/CoachCore) can be
// checked against it. Run from the repo root:  node tools/make-fixtures.mjs
//
// js/audio.js and js/store.js touch browser globals (fetch, localStorage, Blob URLs);
// those are stubbed here so only the pure logic runs.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolveObjectURL } from 'node:buffer';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outDir = path.join(root, 'ios/CoachCore/Tests/CoachCoreTests/Fixtures');
mkdirSync(outDir, { recursive: true });
const write = (name, data) => {
  writeFileSync(path.join(outDir, name), JSON.stringify(data, null, 1) + '\n');
  console.log('wrote', name);
};
const mod = rel => pathToFileURL(path.join(root, rel)).href;

// fetch('audio/x.wav') -> the real clip from disk.
globalThis.fetch = async url => {
  const buf = readFileSync(path.join(root, url));
  return { ok: true, arrayBuffer: async () => buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength) };
};

const plan = await import(mod('js/plan.js'));
const audio = await import(mod('js/audio.js'));
const gps = await import(mod('js/gps.js'));

// FNV-1a 32-bit over bytes; the Swift tests compute the same.
function fnv(bytes) {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) { h ^= bytes[i]; h = Math.imul(h, 0x01000193) >>> 0; }
  return h >>> 0;
}
const int16Bytes = a => new Uint8Array(a.buffer, a.byteOffset, a.byteLength);

// ---------------- plan.js ----------------
const profiles = [];
for (const level of ['new', 'some', 'regular', 'strong', 'bogus'])
  for (const [weeks, perWeek] of [[1, 1], [1, 3], [2, 2], [4, 3], [8, 3], [10, 4], [12, 3], [16, 5], [6, 2]])
    for (const paceMi of [8, 11.25, 14.5])
      profiles.push({ weeks, perWeek, level, paceMi });
profiles.push({ weeks: 8, perWeek: 3 });                  // defaults for level/pace
profiles.push({ weeks: 9, perWeek: 3, level: 'new', paceMi: 22 }); // goal clamps at 55 min
profiles.push({ weeks: 5, perWeek: 3, level: 'strong', paceMi: 5 }); // goal clamps at 20 min

write('plans.json', profiles.map(profile => {
  const p = plan.generatePlan(profile);
  delete p.createdAt;
  return { profile, plan: p };
}));

const workouts = [
  { runSec: 90, walkSec: 90, repeats: 8 },
  { runSec: 60, walkSec: 90, repeats: 6 },
  { runSec: 300, walkSec: 120, repeats: 3 },
  { runSec: 1800, walkSec: 90, repeats: 1 },
  { runSec: 1200, walkSec: 0, repeats: 1 },
  { runSec: 600, walkSec: 0, repeats: 3 },
  { runSec: 5, walkSec: 4, repeats: 3 },
  { runSec: 180, walkSec: 60, repeats: 2 },
  { runSec: 15, walkSec: 15, repeats: 1 },
  { runSec: 45, walkSec: 75, repeats: 10 },
  { runSec: 240, walkSec: 5, repeats: 4 },
  { runSec: 7, walkSec: 0, repeats: 2 },
  { runSec: 30, walkSec: 30, repeats: 0 },
];

const helpers = {
  goalSeconds: [5, 6, 8, 9.5, 11.25, 12, 13.75, 17.7, 18, 25].map(p => ({ paceMi: p, out: plan.goalSeconds(p) })),
  paceText: [8, 9.5, 11.25, 11.99, 12.0833, 13.75, 10.999].map(p => ({ p, out: plan.paceText(p) })),
  fmt: [0, -5, 0.4, 0.5, 59.5, 60, 61, 89.4, 599, 3600, 3725.6].map(s => ({ sec: s, out: plan.fmt(s) })),
  dur: [0, 15, 45, 59, 60, 90, 120, 135, 600, 3600, 3690].map(s => ({ sec: s, out: plan.dur(s) })),
  workouts: workouts.map(wk => ({
    wk, segs: plan.segmentsFor(wk), total: plan.totalSeconds(wk), describe: plan.describe(wk),
  })),
  normWorkout: [
    { in: { runSec: 60 }, out: plan.normWorkout({ runSec: 60 }) },
    { in: { runSec: 60, walkSec: 30, repeats: 4, id: 'w1s1', title: 'Run 1', note: 'x', week: 1 }, out: plan.normWorkout({ runSec: 60, walkSec: 30, repeats: 4, id: 'w1s1', title: 'Run 1', note: 'x', week: 1 }) },
    { in: { runSec: 600, walkSec: 0 }, out: plan.normWorkout({ runSec: 600, walkSec: 0 }) },
  ],
  suggestions: [
    [null, null],
    [{ runSec: 60, walkSec: 90, repeats: 6, id: 'w1s1' }, null],
    [{ runSec: 60, walkSec: 90, repeats: 6 }, { runSec: 60, walkSec: 90, repeats: 6 }],
    [{ runSec: 90, walkSec: 90, repeats: 8 }, null],
    [{ runSec: 15, walkSec: 15, repeats: 3 }, { runSec: 120, walkSec: 60, repeats: 5 }],
    [{ runSec: 1500, walkSec: 90, repeats: 1 }, { runSec: 600, walkSec: 0, repeats: 1 }],
    [null, { runSec: 90, walkSec: 0, repeats: 1 }],
    [null, { runSec: 75, walkSec: 105, repeats: 7 }],
    [{ runSec: 105, walkSec: 75, repeats: 8 }, null],
  ].map(([planned, last]) => ({ planned, last, out: plan.suggestions(planned, last) })),
};
write('plan-helpers.json', helpers);

// ---------------- audio.js ----------------
const optsList = [{}, { beeps: false }, { halfway: false }, { beeps: false, halfway: false }];
write('cues.json', workouts.flatMap(wk => optsList.map(opts => {
  const { events, end } = audio.cueEvents(wk, opts);
  return { wk, opts, events, end };
})));

// Whole-workout render with the real clips (audio/*.wav), compared by checksum.
await audio.loadClips();
// render() returns a blob URL; read the bytes back with resolveObjectURL.
const renders = [];
for (const [wk, opts] of [
  [{ runSec: 90, walkSec: 90, repeats: 8 }, {}],
  [{ runSec: 60, walkSec: 90, repeats: 6 }, { beeps: false }],
  [{ runSec: 300, walkSec: 120, repeats: 3 }, {}],
  [{ runSec: 5, walkSec: 4, repeats: 3 }, {}],
  [{ runSec: 1200, walkSec: 0, repeats: 1 }, { halfway: false }],
  [{ runSec: 240, walkSec: 5, repeats: 4 }, {}],
]) {
  const r = audio.render(wk, opts);
  const bytes = new Uint8Array(await resolveObjectURL(r.url).arrayBuffer());
  renders.push({ wk, opts, duration: r.duration, end: r.end, bytes: bytes.length, fnv: fnv(bytes), header: [...bytes.slice(0, 44)] });
}

// The prepared (trimmed + normalised) clips, so a mismatch can be pinned on prepare() vs render.
const clips = await audio.loadClips();
const clipSums = Object.fromEntries(Object.entries(clips).map(([k, v]) => [k, { length: v.length, fnv: fnv(int16Bytes(v)) }]));
write('render.json', { renders, clips: clipSums });

// ---------------- gps.js ----------------
// A scripted fake run around a start point. Fake clocks: workout clock (pauses excluded) and Date.now().
let nowMs = 1_700_000_000_000;
let workoutSec = 0;
const realNow = Date.now;
Date.now = () => nowMs;

const LAT0 = 41.88123, LNG0 = -87.62345;
const M_LAT = 111_320; // rough metres per degree latitude for scripting
const mLng = M_LAT * Math.cos(LAT0 * Math.PI / 180);
// pos at metres north/east of start
const at = (n, e) => ({ lat: LAT0 + n / M_LAT, lng: LNG0 + e / mLng });

const steps = []; // { dt (s), fix: {...} | null, pause?: true|false, note }
let north = 0, east = 0;
let heading = 0; // radians
const fix = (o = {}) => ({ ...at(north, east), accuracy: 8, ...o });
const move = (secs, speed, turn = 0, acc = 8) => {
  for (let i = 0; i < secs; i++) {
    heading += turn;
    north += Math.cos(heading) * speed; east += Math.sin(heading) * speed;
    steps.push({ dt: 1, fix: fix({ accuracy: acc }) });
  }
};
// cold start: junk accuracy, missing accuracy, NaN position
steps.push({ dt: 1, fix: fix({ accuracy: 120 }) });
steps.push({ dt: 1, fix: fix({ accuracy: null }) });
steps.push({ dt: 1, fix: { lat: NaN, lng: LNG0, accuracy: 5 } });
// standing still with jitter
steps.push({ dt: 1, fix: fix({ accuracy: 10 }) });
for (let i = 0; i < 5; i++) steps.push({ dt: 1, fix: { ...at(north + (i % 2 ? 1.5 : -1.2), east + 0.8), accuracy: 10 } });
// walk, then run with gentle curves
move(60, 1.5, 0.01);
move(120, 3.0, -0.02);
// a single GPS jump (rejected), then back on track
steps.push({ dt: 1, fix: { ...at(north + 400, east + 300), accuracy: 12 } });
move(30, 3.0, 0.0);
// same-timestamp duplicate (dt 0)
steps.push({ dt: 0, fix: fix() });
// a bad patch of poor accuracy
move(5, 3.0, 0, 50);
move(20, 3.1, 0.05);
// gap: no fixes for 45 s while moving (fixes resume farther on)
for (let i = 0; i < 45; i++) { north += 2.8; steps.push({ dt: 1, fix: null }); }
steps.push({ dt: 0, fix: fix() });
move(40, 2.9, -0.03);
// pause: clock stops, she wanders, then resumes
steps.push({ dt: 0, fix: null, pause: true });
for (let i = 0; i < 20; i++) { north += 1; east -= 2; steps.push({ dt: 1, fix: fix(), paused: true }); }
steps.push({ dt: 0, fix: null, pause: false });
move(60, 3.0, 0.015);
// three impossible jumps in a row -> reset to the new spot
north += 900;
for (let i = 0; i < 3; i++) { north += 3; steps.push({ dt: 1, fix: fix({ accuracy: 9 }) }); }
move(90, 2.5, 0.02);
// straight out-and-back
move(30, 3.0, 0);
heading += Math.PI;
move(30, 3.0, 0);

const tracker = new gps.GpsTracker(() => workoutSec);
tracker.status = 'searching';
const fixes = [];
const checkpoints = [];
let paused = false;
steps.forEach((s, i) => {
  if (s.pause === true) { paused = true; tracker.setPaused(true); fixes.push({ pause: true }); return; }
  if (s.pause === false) { paused = false; tracker.setPaused(false); fixes.push({ pause: false }); return; }
  nowMs += s.dt * 1000;
  if (!paused) workoutSec += s.dt;
  if (s.fix) {
    const f = { lat: s.fix.lat, lng: s.fix.lng, accuracy: s.fix.accuracy, timestamp: nowMs };
    tracker.onFix({ coords: { latitude: f.lat, longitude: f.lng, accuracy: f.accuracy ?? undefined }, timestamp: f.timestamp });
    fixes.push({ ...f, now: nowMs, clock: workoutSec });
  } else {
    fixes.push({ now: nowMs, clock: workoutSec });
  }
  if (i % 25 === 0 || i === steps.length - 1) {
    checkpoints.push({
      after: fixes.length, distM: tracker.distM, sec: tracker.sec, points: tracker.pts.length,
      currentPace: tracker.currentPace(), avgPace: tracker.avgPace(), status: tracker.status,
    });
  }
});
// current pace once fixes have stopped for a while
nowMs += 25_000;
const stalePace = tracker.currentPace();
const summary = tracker.summary();
Date.now = realNow;

write('gps-track.json', {
  fixes, checkpoints, stalePace,
  final: { distM: tracker.distM, sec: tracker.sec, hasGaps: tracker.hasGaps(), kinds: tracker.pts.map(p => p.kind), pts: tracker.pts.length },
  summary,
  pieces: gps.pieces(summary.track),
});

const hav = [
  [41.88123, -87.62345, 41.88223, -87.62345],
  [0, 0, 0, 1],
  [51.5, -0.12, 40.71, -74.0],
  [-33.86, 151.21, 35.68, 139.69],
  [10, 10, 10, 10],
  [89.9, 0, -89.9, 180],
].map(([a, b, c, d]) => ({ in: [a, b, c, d], out: gps.haversine(a, b, c, d) }));
const paces = [[0, 100], [39, 100], [40, 0], [1609.344, 600], [1000, 400], [50, 100000], [5000, 1800]]
  .map(([m, s]) => ({ m, sec: s, out: gps.paceSec(m, s) }));
// pack() on a hand-made track with a duplicate-ish straight line and pieces of every kind
const handPts = [];
for (let i = 0; i < 40; i++) handPts.push({ lat: LAT0 + i * 0.00002, lng: LNG0 + Math.sin(i / 4) * 0.00004, t: i * 1.4, kind: i === 0 ? 'start' : i === 20 ? 'gap' : i === 30 ? 'break' : 'line' });
handPts.push({ lat: 42.015625, lng: -87.015625, t: 70.5, kind: 'line' }); // toFixed tie case
write('gps-misc.json', {
  haversine: hav, paceSec: paces,
  pack: { in: handPts, out: gps.pack(handPts) },
  pieces: [
    { in: null, out: gps.pieces(null) },
    { in: { v: 1, pts: [[1, 2, 0]], gap: [], brk: [] }, out: gps.pieces({ v: 1, pts: [[1, 2, 0]], gap: [], brk: [] }) },
    { in: { v: 1, pts: [[1, 2, 0], [1, 3, 1], [1, 4, 2], [1, 5, 3], [1, 6, 4]], gap: [2], brk: [4] }, out: gps.pieces({ v: 1, pts: [[1, 2, 0], [1, 3, 1], [1, 4, 2], [1, 5, 3], [1, 6, 4]], gap: [2], brk: [4] }) },
    { in: { v: 1, pts: [[1, 2, 0], [1, 3, 1]], gap: [1, 1] }, out: gps.pieces({ v: 1, pts: [[1, 2, 0], [1, 3, 1]], gap: [1, 1] }) },
  ],
});

// ---------------- store.js ----------------
// Each store "instance" is a fresh import (query string) with its own localStorage stub.
let storeN = 0;
async function freshStore(raw) {
  globalThis.localStorage = { getItem: () => raw, setItem: () => {} };
  const s = await import(mod('js/store.js') + '?n=' + (++storeN));
  return s;
}

const p8 = plan.generatePlan({ weeks: 3, perWeek: 3, level: 'some', paceMi: 12 });
p8.createdAt = '2026-10-01T12:00:00.000Z';
const run = (o) => ({
  id: 'id-' + o.n, date: o.date, sessionId: o.sessionId ?? null, sessionLabel: o.label ?? null, kind: o.kind ?? 'plan',
  workout: o.wk, totalSec: plan.totalSeconds(o.wk), doneSec: o.doneSec ?? plan.totalSeconds(o.wk),
  completed: o.completed ?? true, feel: o.feel ?? null, notes: o.notes ?? '', ...(o.extra || {}),
});
const s1 = p8.weeks[0].sessions;
const currentRaw = JSON.stringify({
  settings: { apiKey: 'sk-ant-test', model: 'claude-opus-5-5', audioMode: 'locked', beeps: false, halfway: true, autoReview: false, gps: true },
  pendingReview: { message: 'Eased week 2 a little.', changes: [{ id: 'w2s1', runSec: 90, walkSec: 120, repeats: 6, note: 'Easier' }], at: '2026-10-05T08:00:00.000Z' },
  profile: { weeks: 3, perWeek: 3, level: 'some', paceMi: 12, startDate: '2026-10-01', notes: 'old knee' },
  plan: p8,
  history: [
    run({ n: 1, date: '2026-10-02T07:00:00.000Z', sessionId: s1[0].id, label: 'Week 1 · Run 1', wk: plan.normWorkout(s1[0]), feel: 'easy' }),
    run({ n: 2, date: '2026-10-03T07:00:00.000Z', sessionId: s1[1].id, label: 'Week 1 · Run 2', wk: plan.normWorkout(s1[1]), completed: false, doneSec: 300, feel: 'hard', notes: 'calves' }),
    run({ n: 3, date: '2026-10-04T07:00:00.000Z', kind: 'custom', wk: { runSec: 600, walkSec: 0, repeats: 1 }, completed: true }),
    run({ n: 4, date: '2026-10-05T07:00:00.000Z', sessionId: s1[1].id, label: 'Week 1 · Run 2', wk: plan.normWorkout(s1[1]), extra: { manual: true, notes: 'Checked off without the timer' } }),
    run({ n: 5, date: '2026-10-06T07:00:00.000Z', sessionId: s1[2].id, label: 'Week 1 · Run 3', wk: plan.normWorkout(s1[2]), feel: 'right', extra: { distM: summary.distM, gpsSec: summary.gpsSec, track: summary.track } }),
    run({ n: 6, date: '2026-10-07T07:00:00.000Z', kind: 'bonus', label: 'Bonus', wk: plan.normWorkout(s1[2]) }),
  ],
  lastWorkout: plan.normWorkout(s1[2]),
});

// An export from an older version: run days + min/km, missing settings and fields, extra workout fields.
const oldRaw = JSON.stringify({
  settings: { apiKey: '', model: 'claude-opus-4-1', beeps: true },
  profile: { weeks: 2, days: [1, 3, 5], pace: 7, level: 'new', startDate: '2025-05-01', notes: '' },
  plan: {
    createdAt: '2025-05-01T10:00:00.000Z', source: 'claude', summary: 'Old plan',
    weeks: [
      { week: 1, focus: 'Start', sessions: [
        { id: 'w1s1', title: 'Run 1', runSec: 60, walkSec: 90, repeats: 6, warmupSec: 300, note: '' },
        { id: 'w1s2', title: 'Run 2', runSec: 60, repeats: 7 },
        { id: 'w1s3', title: 'Run 3', runSec: 90, walkSec: 90, repeats: 6, note: 'x' },
      ] },
      { week: 2, focus: 'More', sessions: [
        { id: 'w2s1', title: 'Run 1', runSec: 120, walkSec: 90, repeats: 5, note: '' },
        { id: 'w2s2', title: 'Run 2', runSec: 1200, walkSec: 0, repeats: 1, note: '' },
      ] },
    ],
  },
  history: [
    { id: '1', date: '2025-05-02T07:00:00.000Z', sessionId: 'w1s1', workout: { runSec: 60, walkSec: 90, repeats: 6, warmupSec: 300 }, totalSec: 1230, doneSec: 1230, completed: true, feel: 'easy' },
    { id: '2', date: '2025-05-04T07:00:00.000Z', sessionId: 'w1s2', workout: { runSec: 60, repeats: 7 }, totalSec: 420, doneSec: 400, completed: true },
    { id: '3', date: '2025-05-06T07:00:00.000Z', sessionId: null, workout: { runSec: 600 }, totalSec: 600, doneSec: 200, completed: false, notes: 'stitch' },
  ],
});

const storeCases = [];
for (const [name, raw] of [['current', currentRaw], ['old', oldRaw], ['empty', null], ['broken', '{not json']]) {
  const s = await freshStore(raw);
  const all = s.allSessions();
  storeCases.push({
    name, raw,
    exported: JSON.parse(s.exportJSON()),
    allSessions: all,
    isDone: Object.fromEntries(all.map(x => [x.id, s.isDone(x.id)])),
    nextSession: s.nextSession(),
    progress: s.progress(),
  });
}
write('store.json', storeCases);
console.log('done');
