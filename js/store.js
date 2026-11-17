// Local persistence. Everything lives in localStorage on the phone.
const KEY = 'run5k.v1';

const DEFAULTS = {
  settings: {
    apiKey: '',
    model: 'claude-opus-5-5',
    audioMode: 'mix',      // 'mix' = keep music playing, screen stays on | 'locked' = works with screen off, pauses music
    beeps: true,
    halfway: true,
    autoReview: true,
  },
  pendingReview: null,     // last Claude review waiting for Apply / Keep
  profile: null,           // { weeks, perWeek, level, paceMi (min/mile), startDate, notes }
  plan: null,              // { createdAt, source, summary, weeks:[{ week, focus, sessions:[...] }] }
  history: [],             // [{ id, date, sessionId, workout, totalSec, doneSec, completed, feel, notes }]
  lastWorkout: null,
};

let state = load();

function load() {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return structuredClone(DEFAULTS);
    const parsed = JSON.parse(raw);
    const p = parsed.profile;
    if (p) { // migrate older profiles: run days -> runs per week, min/km -> min/mile
      if (!p.perWeek && Array.isArray(p.days)) p.perWeek = p.days.length;
      if (p.paceMi == null && p.pace != null) p.paceMi = Math.round(p.pace * 1.609 * 4) / 4;
      delete p.days; delete p.pace;
    }
    return { ...structuredClone(DEFAULTS), ...parsed, settings: { ...DEFAULTS.settings, ...parsed.settings } };
  } catch {
    return structuredClone(DEFAULTS);
  }
}

export function get() { return state; }

export function save(mutator) {
  if (mutator) mutator(state);
  try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) { console.warn('save failed', e); }
  return state;
}

// Wipes plan, history and preferences, but keeps the admin's coach setup (API key + model).
export function reset() {
  const { apiKey, model } = state.settings;
  state = structuredClone(DEFAULTS);
  Object.assign(state.settings, { apiKey, model });
  save();
}

export function exportJSON() {
  const copy = structuredClone(state);
  copy.settings.apiKey = copy.settings.apiKey ? '(removed)' : '';
  return JSON.stringify(copy, null, 2);
}

// ---- Plan helpers ----
export function allSessions(plan = state.plan) {
  if (!plan) return [];
  return plan.weeks.flatMap(w => w.sessions.map(s => ({ ...s, week: w.week })));
}

export function isDone(sessionId) {
  return state.history.some(h => h.sessionId === sessionId && h.completed);
}

export function nextSession() {
  return allSessions().find(s => !isDone(s.id)) || null;
}

export function progress() {
  const all = allSessions();
  const done = all.filter(s => isDone(s.id)).length;
  return { done, total: all.length };
}
