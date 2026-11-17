// Claude integration: build a personalised plan, and review runs to adjust upcoming sessions.
// Calls go straight from the phone to the Claude API with your own key (stored only on this device).

import { generatePlan, LEVELS, DAY_NAMES, describe, workoutFromSession } from './plan.js';
import * as store from './store.js';

const SDK_URL = 'https://cdn.jsdelivr.net/npm/@anthropic-ai/sdk@1.5.0/+esm';

export const MODELS = [
  { id: 'claude-opus-5-5', label: 'Claude Opus 5.5', note: 'Best coaching' },
  { id: 'claude-sonnet-5-5', label: 'Claude Sonnet 5.5', note: 'Cheaper' },
  { id: 'claude-haiku-5-5', label: 'Claude Haiku 5.5', note: 'Cheapest' },
];

let clientPromise = null;
let clientKey = null;

async function client() {
  const key = store.get().settings.apiKey.trim();
  if (!key) throw new Error('Add your Claude API key in Settings first.');
  if (!clientPromise || clientKey !== key) {
    clientKey = key;
    clientPromise = import(SDK_URL).then(m => {
      const Anthropic = m.default || m.Anthropic;
      return new Anthropic({ apiKey: key, dangerouslyAllowBrowser: true, maxRetries: 2 });
    });
  }
  return clientPromise;
}

const SESSION_PROPS = {
  title: { type: 'string' },
  warmupSec: { type: 'integer' },
  runSec: { type: 'integer' },
  walkSec: { type: 'integer' },
  repeats: { type: 'integer' },
  cooldownSec: { type: 'integer' },
  note: { type: 'string' },
};

const PLAN_SCHEMA = {
  type: 'object',
  properties: {
    summary: { type: 'string' },
    weeks: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          focus: { type: 'string' },
          sessions: {
            type: 'array',
            items: { type: 'object', properties: SESSION_PROPS, required: Object.keys(SESSION_PROPS), additionalProperties: false },
          },
        },
        required: ['focus', 'sessions'],
        additionalProperties: false,
      },
    },
  },
  required: ['summary', 'weeks'],
  additionalProperties: false,
};

const ADJUST_SCHEMA = {
  type: 'object',
  properties: {
    message: { type: 'string' },
    changes: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          runSec: { type: 'integer' },
          walkSec: { type: 'integer' },
          repeats: { type: 'integer' },
          note: { type: 'string' },
        },
        required: ['id', 'runSec', 'walkSec', 'repeats', 'note'],
        additionalProperties: false,
      },
    },
  },
  required: ['message', 'changes'],
  additionalProperties: false,
};

const SYSTEM = `You are a friendly, practical running coach inside a personal "Couch to 5K"-style app.
Workouts are run/walk intervals: a warm-up walk, then "run X seconds, walk Y seconds" repeated N times (no walk after the final run), then a cool-down walk.
Coach for injury-free consistency: progress gradually, prefer repeating a step over rushing, and keep runs at an easy conversational pace.
All durations are whole seconds. Use run and walk lengths that are multiples of 15 seconds.`;

async function ask(prompt, schema) {
  const c = await client();
  const { model } = store.get().settings;
  const params = {
    model,
    max_tokens: 16000,
    system: SYSTEM,
    messages: [{ role: 'user', content: prompt }],
    output_config: { effort: 'medium', format: { type: 'json_schema', schema } },
  };
  // Opus 5.5 / Sonnet 5.5: if a safety classifier declines, let the API retry on a fallback model.
  if (model === 'claude-opus-5-5' || model === 'claude-sonnet-5-5') {
    params.betas = ['server-side-fallback-2026-07-01'];
    params.fallbacks = 'default';
  }
  let res;
  try {
    res = await c.beta.messages.create(params);
  } catch (e) {
    // If the account/model doesn't accept the fallback option, retry once without it.
    if (e?.status === 400 && params.fallbacks && /fallback|beta/i.test(e?.message || '')) {
      delete params.fallbacks; delete params.betas;
      try { res = await c.beta.messages.create(params); } catch (e2) { throw new Error(friendlyError(e2)); }
    } else {
      throw new Error(friendlyError(e));
    }
  }
  if (res.stop_reason === 'refusal') throw new Error('Claude declined this request. Try rewording your notes.');
  if (res.stop_reason === 'max_tokens') throw new Error('Claude’s reply was cut off. Try again, or choose fewer weeks.');
  const text = res.content.filter(b => b.type === 'text').map(b => b.text).join('');
  try { return JSON.parse(text); } catch { throw new Error('Claude sent back something unexpected. Please try again.'); }
}

function friendlyError(e) {
  const status = e?.status;
  if (status === 401) return 'Your API key was rejected. Check it in Settings.';
  if (status === 403) return 'This API key doesn’t have access to that model.';
  if (status === 429) return 'Rate limited by the Claude API. Wait a minute and try again.';
  if (status === 400 && /credit|balance/i.test(e?.message || '')) return 'Your Claude API account is out of credit.';
  if (status >= 500) return 'The Claude API is having trouble right now. Try again shortly.';
  if (!status && /fetch|network|load/i.test(e?.message || '')) return 'Couldn’t reach Claude. Are you online?';
  return e?.message || 'Something went wrong talking to Claude.';
}

const int = (v, lo, hi, step = 1) => Math.max(lo, Math.min(hi, Math.round((Number(v) || 0) / step) * step));

function cleanSession(s, id) {
  const repeats = int(s.repeats, 1, 30);
  return {
    id,
    title: String(s.title || 'Run').slice(0, 40),
    warmupSec: int(s.warmupSec ?? 300, 0, 900, 15),
    runSec: int(s.runSec, 15, 3600, 15),
    walkSec: repeats === 1 ? 0 : int(s.walkSec, 0, 600, 15),
    repeats,
    cooldownSec: int(s.cooldownSec ?? 300, 0, 900, 15),
    note: String(s.note || '').slice(0, 240),
  };
}

function profileText(p) {
  return [
    `Experience: ${LEVELS[p.level]?.label} (${LEVELS[p.level]?.detail})`,
    `Plan length: ${p.weeks} weeks, ${p.perWeek} runs per week on ${p.days.map(d => DAY_NAMES[d]).join(', ')}`,
    `Estimated easy pace: ${Math.floor(p.pace)}:${String(Math.round((p.pace % 1) * 60)).padStart(2, '0')} per km`,
    `Start date: ${p.startDate}`,
    p.notes ? `Runner's notes: ${p.notes}` : 'Runner\'s notes: none',
  ].join('\n');
}

export async function buildPlan(profile) {
  const baseline = generatePlan(profile);
  const baselineText = baseline.weeks.map(w =>
    `Week ${w.week}: ` + w.sessions.map(s => describe(workoutFromSession(s))).join(' | ')).join('\n');

  const prompt = `Create my personalised 5K training plan.

${profileText(profile)}

Requirements:
- Exactly ${profile.weeks} weeks with exactly ${profile.perWeek} sessions each.
- The very last session is the goal: one continuous run of about 5 km (repeats = 1, walkSec = 0) titled "5K run".
- Each session has a warm-up and cool-down walk (usually 300 seconds each).
- Short, encouraging "note" for each session (one sentence) and a short "focus" for each week.
- "summary": 1–2 sentences describing the plan.

For reference, here is a simple algorithmic baseline. Improve on it using my experience and notes (smoother steps, sensible repeats), rather than copying it:
${baselineText}`;

  const out = await ask(prompt, PLAN_SCHEMA);
  if (!Array.isArray(out.weeks) || out.weeks.length === 0) throw new Error('Claude returned an empty plan.');
  return {
    createdAt: new Date().toISOString(),
    source: 'claude',
    summary: String(out.summary || '').slice(0, 400),
    weeks: out.weeks.map((w, i) => ({
      week: i + 1,
      focus: String(w.focus || '').slice(0, 40),
      sessions: (w.sessions || []).map((s, j) => cleanSession(s, `w${i + 1}s${j + 1}`)),
    })).filter(w => w.sessions.length),
  };
}

export async function reviewRuns() {
  const st = store.get();
  const all = store.allSessions();
  const upcoming = all.filter(s => !store.isDone(s.id)).slice(0, 9);
  if (!upcoming.length) return { message: 'You’ve finished the plan — no changes needed. Congratulations!', changes: [] };

  const recent = st.history.slice(-8).map(h => {
    const pct = Math.round((h.doneSec / h.totalSec) * 100);
    return `- ${h.date.slice(0, 10)}${h.sessionId ? ` (plan session ${h.sessionId})` : ' (extra run)'}: ${describe(h.workout)}; finished ${pct}% (${h.completed ? 'counted as done' : 'not counted'}); felt ${h.feel || 'not rated'}${h.notes ? `; notes: "${h.notes}"` : ''}`;
  }).join('\n');

  const prog = store.progress();
  const prompt = `Review my recent runs and adjust my upcoming sessions only if it would help.

${profileText(st.profile)}
Progress: ${prog.done} of ${prog.total} sessions done.

Recent runs (oldest first):
${recent || 'none yet'}

Upcoming sessions (id: workout):
${upcoming.map(s => `${s.id} (week ${s.week}): runSec=${s.runSec}, walkSec=${s.walkSec}, repeats=${s.repeats} — ${describe(workoutFromSession(s))}`).join('\n')}

Guidance:
- If the last run felt hard or I had to stop, ease off or repeat the step. If it felt easy, you may progress a little faster.
- If things are on track, return an empty "changes" list.
- Only include sessions you are changing, using ids from the list above. Keep the final 5K run continuous.
- "message": 2–3 short, encouraging sentences to me explaining what you changed and why (or why nothing needs to change).`;

  const out = await ask(prompt, ADJUST_SCHEMA);
  const ids = new Set(upcoming.map(s => s.id));
  const changes = (out.changes || []).filter(c => ids.has(c.id)).map(c => {
    const current = upcoming.find(s => s.id === c.id);
    const repeats = int(c.repeats, 1, 30);
    return {
      id: c.id,
      runSec: int(c.runSec, 15, 3600, 15),
      walkSec: repeats === 1 ? 0 : int(c.walkSec, 0, 600, 15),
      repeats,
      note: String(c.note || current.note || '').slice(0, 240),
    };
  }).filter(c => {
    const s = upcoming.find(x => x.id === c.id);
    return s.runSec !== c.runSec || s.walkSec !== c.walkSec || s.repeats !== c.repeats;
  });
  return { message: String(out.message || '').slice(0, 600), changes, at: new Date().toISOString() };
}

export function applyChanges(changes) {
  store.save(st => {
    for (const w of st.plan.weeks) for (const s of w.sessions) {
      const c = changes.find(x => x.id === s.id);
      if (c) Object.assign(s, { runSec: c.runSec, walkSec: c.walkSec, repeats: c.repeats, note: c.note });
    }
  });
}

export async function testKey() {
  const c = await client();
  try {
    const r = await c.messages.create({ model: store.get().settings.model, max_tokens: 1024, output_config: { effort: 'low' }, messages: [{ role: 'user', content: 'Reply with just: OK' }] });
    return r.content.find(b => b.type === 'text')?.text?.trim() || 'OK';
  } catch (e) { throw new Error(friendlyError(e)); }
}
