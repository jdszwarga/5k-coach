// Built-in 5K plan generator (works offline, no AI needed).
// Each session is a run/walk interval workout that ends with one continuous 5K run.

export const LEVELS = {
  new:     { label: 'New to running',         detail: 'Running for a minute is hard',  s0: 60,  R0: 8 * 60,  ratio0: 1.5 },
  some:    { label: 'A little running',       detail: 'I can run 1–5 minutes',         s0: 120, R0: 12 * 60, ratio0: 1.0 },
  regular: { label: 'Some base',              detail: 'I can run 5–15 minutes',        s0: 300, R0: 16 * 60, ratio0: 0.6 },
  strong:  { label: 'Comfortable runner',     detail: 'I can run 15+ minutes',         s0: 600, R0: 20 * 60, ratio0: 0.3 },
};

export const DAY_NAMES = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

const round = (v, step) => Math.round(v / step) * step;
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

function roundRun(s) {
  if (s < 120) return round(s, 15);
  if (s < 600) return round(s, 30);
  return round(s, 60);
}

// Minutes to run 5K at an easy pace (pace = min per km).
export function goalSeconds(pace = 7) {
  return clamp(Math.round(5 * pace * 60 / 60) * 60, 20 * 60, 50 * 60);
}

export function generatePlan(profile) {
  const { weeks, perWeek, level = 'new', pace = 7 } = profile;
  const L = LEVELS[level] || LEVELS.new;
  const T = goalSeconds(pace);
  const S = weeks * perWeek;
  const warmupSec = 300, cooldownSec = 300;

  const out = [];
  let longestBlock = L.s0;
  for (let w = 0; w < weeks; w++) {
    const sessions = [];
    for (let j = 0; j < perWeek; j++) {
      const k = w * perWeek + j;
      const p = S <= 1 ? 1 : k / (S - 1);
      let runSec, walkSec, repeats;

      if (p >= 1) {
        runSec = T; walkSec = 0; repeats = 1;
      } else {
        const R = L.R0 + (T * 0.9 - L.R0) * Math.pow(p, 1.3);          // total running this session
        const s = L.s0 * Math.pow(T / L.s0, Math.pow(p, 1.8));          // length of one run block
        runSec = roundRun(Math.min(s, T));
        repeats = Math.max(1, Math.round(R / runSec));
        if (repeats === 1) {
          // Don't let a continuous run jump too far past the longest block so far.
          runSec = roundRun(Math.min(Math.max(runSec, R), longestBlock * 1.4));
          walkSec = 0;
        } else {
          const ratio = L.ratio0 * (1 - p) + 0.15 * p;
          walkSec = round(clamp(runSec * ratio, 60, 180), 15);
        }
      }

      longestBlock = Math.max(longestBlock, runSec);
      const last = w === weeks - 1 && j === perWeek - 1;
      sessions.push({
        id: `w${w + 1}s${j + 1}`,
        title: last ? '5K run' : `Run ${j + 1}`,
        warmupSec, runSec, walkSec, repeats, cooldownSec,
        note: last
          ? 'Goal day: run the whole 5K at an easy, steady pace.'
          : repeats === 1
            ? 'Continuous run. Keep it slow enough to talk.'
            : 'Easy pace — you should be able to talk in short sentences.',
      });
    }
    out.push({ week: w + 1, focus: weekFocus(w, weeks), sessions });
  }

  return {
    createdAt: new Date().toISOString(),
    source: 'builtin',
    summary: `${weeks} weeks · ${perWeek} runs a week · finishing with a ${Math.round(T / 60)}-minute 5K.`,
    weeks: out,
  };
}

function weekFocus(w, weeks) {
  const p = weeks <= 1 ? 1 : w / (weeks - 1);
  if (p === 1) return 'Race week';
  if (p < 0.34) return 'Build the habit';
  if (p < 0.67) return 'Longer runs';
  return 'Run continuously';
}

// ---- Workout helpers ----

export function workoutFromSession(s) {
  return {
    warmupSec: s.warmupSec ?? 300,
    runSec: s.runSec,
    walkSec: s.walkSec ?? 0,
    repeats: s.repeats ?? 1,
    cooldownSec: s.cooldownSec ?? 300,
  };
}

// Converts a workout into an ordered list of timed segments.
export function segmentsFor(wk) {
  const segs = [];
  if (wk.warmupSec > 0) segs.push({ type: 'warmup', dur: wk.warmupSec });
  for (let i = 0; i < wk.repeats; i++) {
    segs.push({ type: 'run', dur: wk.runSec, rep: i + 1, of: wk.repeats });
    const lastRep = i === wk.repeats - 1;
    if (!lastRep && wk.walkSec > 0) segs.push({ type: 'walk', dur: wk.walkSec, rep: i + 1, of: wk.repeats });
  }
  if (wk.cooldownSec > 0) segs.push({ type: 'cooldown', dur: wk.cooldownSec });
  let t = 0;
  for (const s of segs) { s.start = t; t += s.dur; s.end = t; }
  return segs;
}

export function totalSeconds(wk) {
  return wk.warmupSec + wk.cooldownSec + wk.repeats * wk.runSec + Math.max(0, wk.repeats - 1) * wk.walkSec;
}

export function fmt(sec) {
  sec = Math.max(0, Math.round(sec));
  const m = Math.floor(sec / 60), s = sec % 60;
  return `${m}:${String(s).padStart(2, '0')}`;
}

// Friendly short duration: 90 -> "1:30", 120 -> "2 min", 45 -> "45 s"
export function dur(sec) {
  if (sec < 60) return `${sec} s`;
  if (sec % 60 === 0) return `${sec / 60} min`;
  return fmt(sec);
}

export function describe(wk) {
  if (wk.repeats === 1 || wk.walkSec === 0) return `Run ${dur(wk.runSec * wk.repeats)} continuously`;
  return `Run ${dur(wk.runSec)} · Walk ${dur(wk.walkSec)} × ${wk.repeats}`;
}

// Suggestions shown before a run.
export function suggestions(planned, last) {
  const list = [];
  if (planned) list.push({ label: 'Planned', wk: workoutFromSession(planned) });
  if (last) list.push({ label: 'Last run', wk: { ...last } });
  const base = planned ? workoutFromSession(planned) : last;
  if (base && base.repeats > 1) {
    list.push({ label: 'Easier', wk: { ...base, runSec: Math.max(15, base.runSec - 15), walkSec: base.walkSec + 15 } });
    list.push({ label: 'Harder', wk: { ...base, runSec: base.runSec + 15, walkSec: Math.max(15, base.walkSec - 15) } });
  } else if (base) {
    list.push({ label: 'Easier', wk: { ...base, runSec: Math.max(60, base.runSec - 120) } });
    list.push({ label: 'Harder', wk: { ...base, runSec: base.runSec + 120 } });
  }
  list.push({ label: '1:30 / 1:30', wk: { warmupSec: 300, runSec: 90, walkSec: 90, repeats: 8, cooldownSec: 300 } });
  // De-duplicate identical workouts
  const seen = new Set();
  return list.filter(x => { const k = JSON.stringify(x.wk); if (seen.has(k)) return false; seen.add(k); return true; });
}
