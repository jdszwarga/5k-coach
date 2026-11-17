import * as store from './store.js';
import { generatePlan, LEVELS, DAY_NAMES, workoutFromSession, segmentsFor, totalSeconds, fmt, dur, describe, suggestions, goalSeconds } from './plan.js';
import { loadClips, clipsReady, WorkoutPlayer, testCue } from './audio.js';
import * as ai from './ai.js';

const VERSION = '1.0.0';
const $ = (s, r = document) => r.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const sv = (p, size = 24, sw = 2) => `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${p}</svg>`;

const I = {
  today: sv('<circle cx="12" cy="12" r="9" opacity=".35"/><path d="M12 3a9 9 0 0 1 9 9"/><path d="M12 8v4l2.5 2.5"/>'),
  plan: sv('<rect x="3.5" y="5" width="17" height="15.5" rx="3"/><path d="M3.5 10h17M8 3v4M16 3v4"/><path d="M8 14h2M14 14h2M8 17h2"/>'),
  history: sv('<path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1"/><path d="M3 4v4h4"/><path d="M12 8v4.5l3 1.8"/>'),
  settings: sv('<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2.2"/><circle cx="10" cy="17" r="2.2"/>'),
  x: sv('<path d="M7 7l10 10M17 7L7 17"/>', 18, 2.4),
  chev: sv('<path d="M9.5 6l6 6-6 6"/>', 16, 2.4),
  check: sv('<path d="M5.5 12.5l4 4 9-9"/>', 16, 3),
  plus: sv('<path d="M12 6v12M6 12h12"/>', 18, 2.4),
  minus: sv('<path d="M6 12h12"/>', 18, 2.4),
  play: '<svg width="34" height="34" viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M8 5.5v13a1 1 0 0 0 1.5.86l10.4-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z"/></svg>',
  pause: '<svg width="34" height="34" viewBox="0 0 24 24" aria-hidden="true"><rect fill="currentColor" x="6" y="5" width="4.2" height="14" rx="1.2"/><rect fill="currentColor" x="13.8" y="5" width="4.2" height="14" rx="1.2"/></svg>',
  stop: '<svg width="22" height="22" viewBox="0 0 24 24" aria-hidden="true"><rect fill="currentColor" x="6" y="6" width="12" height="12" rx="2.5"/></svg>',
  lock: sv('<rect x="5" y="10.5" width="14" height="10" rx="2.5"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/>', 22),
  spark: sv('<path d="M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5L18 18M18 6l-2.5 2.5M8.5 15.5L6 18"/>', 16, 2.2),
  share: sv('<path d="M12 3v12M7.5 7.5L12 3l4.5 4.5"/><path d="M5 12v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7"/>', 18),
  shoe: sv('<path d="M3 16.5c0-2 .5-6 1.5-8.5l3 1 2.5 3.5 6 2.5c2.5 1 4 1.5 4 3v1H3z"/><path d="M3 19h18"/>', 48, 1.5),
};

const FEELS = [
  { id: 'easy', label: 'Easy' },
  { id: 'right', label: 'Just right' },
  { id: 'hard', label: 'Hard' },
  { id: 'stopped', label: 'Had to stop' },
];

const ui = { tab: 'today', reviewing: false, reviewError: null, draft: null, building: false, buildError: null };
const player = new WorkoutPlayer();

// ---------------- helpers ----------------
function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toast.t);
  toast.t = setTimeout(() => t.classList.remove('show'), 2200);
}

const minutes = sec => Math.round(sec / 60);
const todayISO = () => { const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 10); };
const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
const shortDate = iso => new Date(iso).toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
const paceText = p => `${Math.floor(p)}:${String(Math.round((p % 1) * 60)).padStart(2, '0')}`;
const isStandalone = () => navigator.standalone || matchMedia('(display-mode: standalone)').matches;

function ring(pct, size = 64, stroke = 8, color = 'var(--accent)', track = 'var(--fill)') {
  const r = (size - stroke) / 2, c = 2 * Math.PI * r;
  return `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" style="transform:rotate(-90deg)">
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${track}" stroke-width="${stroke}"/>
    <circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${color}" stroke-width="${stroke}" stroke-linecap="round"
      stroke-dasharray="${c}" stroke-dashoffset="${c * (1 - Math.max(0, Math.min(1, pct)))}"/></svg>`;
}

function blocks(wk) {
  return `<div class="blocks" aria-hidden="true">${segmentsFor(wk).map(s => `<div class="${s.type}" style="flex:${s.dur}"></div>`).join('')}</div>`;
}

function stepper(act, key, value, { min = -Infinity, max = Infinity } = {}) {
  return `<div class="stepper">
    <button data-act="${act}" data-k="${key}" data-d="-1" aria-label="Decrease" ${value <= min ? 'disabled' : ''}>${I.minus}</button><i></i>
    <button data-act="${act}" data-k="${key}" data-d="1" aria-label="Increase" ${value >= max ? 'disabled' : ''}>${I.plus}</button>
  </div>`;
}

const toggle = (key, on, attr = 'data-set') => `<label class="switch"><input type="checkbox" ${attr}="${key}" ${on ? 'checked' : ''}><span></span></label>`;

function sessionLabel(s) {
  const st = store.get();
  const per = st.plan?.weeks.find(w => w.week === s.week)?.sessions.length || 0;
  return `Week ${s.week} · ${s.title === '5K run' ? '5K run' : `Run ${s.id.split('s').pop()} of ${per}`}`;
}

// ---------------- main render ----------------
function render() {
  const st = store.get();
  const app = $('#app');
  const tabbar = $('#tabbar');
  if (!st.plan || ui.draft) {
    tabbar.hidden = true;
    app.innerHTML = viewOnboarding();
    return;
  }
  tabbar.hidden = false;
  tabbar.innerHTML = [['today', 'Today'], ['plan', 'Plan'], ['history', 'History'], ['settings', 'Settings']]
    .map(([id, label]) => `<button data-act="tab" data-tab="${id}" class="${ui.tab === id ? 'on' : ''}" aria-label="${label}">${I[id]}<span>${label}</span></button>`).join('');
  app.innerHTML = { today: viewToday, plan: viewPlan, history: viewHistory, settings: viewSettings }[ui.tab]();
}

// ---------------- Onboarding / plan settings ----------------
const REC_WEEKS = { new: 8, some: 6, regular: 4, strong: 3 };

function defaultDraft() {
  const p = store.get().profile;
  return p ? structuredClone(p) : { level: 'new', weeks: 8, days: [1, 3, 6], pace: 7, startDate: todayISO(), notes: '' };
}

function viewOnboarding() {
  const st = store.get();
  const d = ui.draft || (ui.draft = defaultDraft());
  const editing = !!st.plan;
  const goal = minutes(goalSeconds(d.pace));
  const hasKey = !!st.settings.apiKey.trim();
  const rec = REC_WEEKS[d.level];
  const daysSorted = [1, 2, 3, 4, 5, 6, 0];

  return `<div class="page no-tabs">
    <div class="nav-row">${editing ? `<button class="btn plain" style="width:auto" data-act="cancel-edit">Cancel</button>` : '<span></span>'}<span></span></div>
    <h1 class="large-title" style="margin-top:${editing ? 8 : 40}px">${editing ? 'Plan settings' : 'Your 5K plan'}</h1>
    <p class="subtitle">${editing ? 'Rebuild your plan. Completed runs stay ticked.' : 'Answer a few questions and I’ll build a run/walk plan that ends with a continuous 5K.'}</p>

    <div class="section-header">Where are you starting?</div>
    <div class="group">${Object.entries(LEVELS).map(([id, L]) => `
      <button class="row tap" data-act="draft-level" data-v="${id}">
        <div class="grow"><div class="title">${L.label}</div><div class="sub">${L.detail}</div></div>
        ${d.level === id ? `<span class="check">${I.check}</span>` : ''}
      </button>`).join('')}
    </div>

    <div class="section-header">Schedule</div>
    <div class="group">
      <div class="row"><div class="grow">Weeks to 5K</div><span class="stepper-value">${d.weeks} weeks</span>${stepper('draft-step', 'weeks', d.weeks, { min: 2, max: 20 })}</div>
      <div class="row" style="padding-bottom:0"><div class="grow">Run days</div><span class="value">${d.days.length} a week</span></div>
      <div class="days">${daysSorted.map(i => `<button data-act="draft-day" data-v="${i}" class="${d.days.includes(i) ? 'on' : ''}" aria-pressed="${d.days.includes(i)}" aria-label="${DAY_NAMES[i]}">${DAY_NAMES[i][0]}</button>`).join('')}</div>
      <div class="row"><div class="grow">Start date</div><input type="date" data-draft="startDate" value="${esc(d.startDate)}"></div>
    </div>
    ${d.weeks < rec ? `<p class="section-footer" style="color:var(--warm)">Heads up: ${rec}+ weeks is typical from this starting point. A shorter plan has bigger jumps — Claude can tune it, or you can repeat weeks.</p>` : ''}

    <div class="section-header">Easy pace</div>
    <div class="group">
      <div class="row"><div class="grow">Per kilometre</div><span class="stepper-value">${paceText(d.pace)}</span>${stepper('draft-step', 'pace', d.pace, { min: 4.5, max: 11 })}</div>
    </div>
    <p class="section-footer">Not sure? Leave it. This sets the final run at about ${goal} minutes.</p>

    <div class="section-header">Claude coach (optional)</div>
    <div class="group">
      <div class="row"><div>API key</div><input type="password" data-set="apiKey" placeholder="sk-ant-…" value="${esc(st.settings.apiKey)}" autocomplete="off" autocapitalize="off" spellcheck="false"></div>
      <div class="row"><textarea data-draft="notes" placeholder="Anything Claude should know? e.g. old knee injury, I walk a lot, I want to run a parkrun on 14 Feb…">${esc(d.notes)}</textarea></div>
    </div>
    <p class="section-footer">With a key, Claude personalises the plan and reviews each run. Without one, you get the built-in plan.</p>

    <div class="mt-l">
      ${ui.buildError ? `<p class="err center">${esc(ui.buildError)}</p>` : ''}
      ${hasKey ? `<button class="btn" data-act="build-claude" ${ui.building ? 'disabled' : ''}>${ui.building ? '<span class="spinner" style="border-top-color:#fff"></span> Claude is building your plan…' : `${I.spark} Build with Claude`}</button>
        <button class="btn plain mt" data-act="build-local" ${ui.building ? 'disabled' : ''}>Use the built-in plan instead</button>`
      : `<button class="btn" data-act="build-local">Create my plan</button>`}
    </div>
  </div>`;
}

function savePlan(plan) {
  const d = ui.draft;
  store.save(st => {
    st.profile = { ...d, perWeek: d.days.length };
    st.plan = plan;
    st.pendingReview = null;
  });
  ui.draft = null;
  ui.tab = 'today';
  render();
  window.scrollTo(0, 0);
  toast(plan.source === 'claude' ? 'Claude built your plan' : 'Plan ready');
}

function checkDraft() {
  const d = ui.draft;
  if (d.days.length < 2) { ui.buildError = 'Pick at least 2 run days.'; render(); return false; }
  ui.buildError = null;
  return true;
}

function confirmReplace() {
  return !store.get().plan || confirm('Replace your current plan? Completed runs stay in History.');
}

// ---------------- Today ----------------
function viewToday() {
  const st = store.get();
  const next = store.nextSession();
  const prog = store.progress();
  const now = new Date();
  const monday = new Date(now); monday.setDate(now.getDate() - ((now.getDay() + 6) % 7));

  const strip = Array.from({ length: 7 }, (_, i) => {
    const d = new Date(monday); d.setDate(monday.getDate() + i);
    const planned = st.profile.days.includes(d.getDay());
    const done = st.history.some(h => sameDay(new Date(h.date), d));
    const cls = [sameDay(d, now) && 'today', planned && 'planned', done && 'done'].filter(Boolean).join(' ');
    return `<div class="${cls}"><div class="d">${DAY_NAMES[d.getDay()][0]}</div><div class="n">${d.getDate()}</div><div class="dot"></div></div>`;
  }).join('');

  let hero;
  if (next) {
    const wk = workoutFromSession(next);
    const total = totalSeconds(wk);
    const runTotal = wk.runSec * wk.repeats;
    const todayPlanned = st.profile.days.includes(now.getDay());
    let restLine = '';
    if (!todayPlanned) {
      const nd = [1, 2, 3, 4, 5, 6, 7].map(k => (now.getDay() + k) % 7).find(x => st.profile.days.includes(x));
      restLine = `<p class="meta" style="margin:-8px 0 14px">Rest day — next planned run is ${new Date(2024, 0, 7 + nd).toLocaleDateString(undefined, { weekday: 'long' })}. Go anyway if you feel good.</p>`;
    }
    hero = `<div class="hero">
      <div class="eyebrow">${esc(sessionLabel(next))}</div>
      <h2>${wk.repeats > 1 && wk.walkSec ? `Run ${dur(wk.runSec)}<span style="color:var(--label3)"> / </span>Walk ${dur(wk.walkSec)}` : `Run ${dur(runTotal)}`}</h2>
      <div class="meta">${wk.repeats > 1 && wk.walkSec ? `${wk.repeats} rounds · ` : 'Non-stop · '}${minutes(total)} min total · ${minutes(runTotal)} min running</div>
      ${blocks(wk)}
      <div class="legend"><span style="--c:var(--run)">Run</span><span style="--c:var(--walk)">Walk</span><span style="--c:var(--fill2)">Warm-up / cool-down</span></div>
      ${restLine}
      ${next.note ? `<div class="note">${esc(next.note)}</div>` : ''}
      <button class="btn" data-act="setup" data-id="${next.id}">${I.play.replace(/34/g, '22')} Start run</button>
      <button class="btn plain mt" style="margin-top:6px" data-act="setup">Custom intervals</button>
    </div>`;
  } else {
    hero = `<div class="hero center">
      <div class="eyebrow">Plan complete</div>
      <h2>You did it — 5K!</h2>
      <p class="meta">Every session is done. Keep running with custom intervals, or build a new plan.</p>
      <button class="btn" data-act="setup">Start a run</button>
      <button class="btn plain mt" data-act="edit-plan">Build a new plan</button>
    </div>`;
  }

  const curWeek = next ? next.week : st.plan.weeks.length;
  const weekRuns = st.history.filter(h => new Date(h.date) >= new Date(monday.getFullYear(), monday.getMonth(), monday.getDate())).length;

  return `<div class="page">
    <h1 class="large-title">Today</h1>
    <p class="subtitle">${now.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' })}</p>
    ${!isStandalone() ? `<div class="coach" style="margin:0 0 14px"><div class="coach-head">${I.share} Install on your iPhone</div><p style="margin:0">Tap Share in Safari, then <b>Add to Home Screen</b>. It runs full-screen and works offline.</p></div>` : ''}
    <div class="week-strip">${strip}</div>
    ${hero}
    ${viewCoach()}
    <div class="stats">
      <div class="stat ring-wrap">${ring(prog.total ? prog.done / prog.total : 0, 56, 7)}
        <div><div class="k">Plan</div><div class="v">${prog.done}<small>/${prog.total}</small></div></div></div>
      <div class="stat"><div class="k">Week</div><div class="v">${curWeek}<small> of ${st.plan.weeks.length}</small></div></div>
      <div class="stat"><div class="k">This week</div><div class="v">${weekRuns}<small>/${st.profile.days.length} runs</small></div></div>
      <div class="stat"><div class="k">Total time</div><div class="v">${minutes(st.history.reduce((a, h) => a + h.doneSec, 0))}<small> min</small></div></div>
    </div>
  </div>`;
}

function viewCoach() {
  const st = store.get();
  const hasKey = !!st.settings.apiKey.trim();
  if (ui.reviewing) {
    return `<div class="coach"><div class="coach-head"><span class="spinner"></span> Claude is reviewing your runs…</div></div>`;
  }
  if (ui.reviewError) {
    return `<div class="coach"><div class="coach-head"><span class="spark">${I.spark}</span> Coach</div><p class="err" style="margin-top:0">${esc(ui.reviewError)}</p>
      <button class="pill-btn" data-act="review">Try again</button></div>`;
  }
  const r = st.pendingReview;
  if (r) {
    const all = store.allSessions();
    const changes = r.changes.map(c => {
      const s = all.find(x => x.id === c.id);
      if (!s) return '';
      return `<div class="change"><div><div style="font-weight:600">${esc(sessionLabel(s))}</div><div class="from">${esc(describe(workoutFromSession(s)))}</div></div>
        <div class="to">${esc(describe({ ...workoutFromSession(s), ...c }))}</div></div>`;
    }).join('');
    return `<div class="coach"><div class="coach-head"><span class="spark">${I.spark}</span> Coach</div>
      <p>${esc(r.message)}</p>${changes}
      <div class="btn-row mt">${r.changes.length
        ? `<button class="btn" style="min-height:44px" data-act="apply-review">Update plan</button><button class="btn secondary" style="min-height:44px" data-act="dismiss-review">Keep plan</button>`
        : `<button class="btn secondary" style="min-height:44px" data-act="dismiss-review">Got it</button>`}</div></div>`;
  }
  if (hasKey && st.history.length) {
    return `<div class="coach"><div class="coach-head"><span class="spark">${I.spark}</span> Coach</div>
      <p style="color:var(--label2)">Ask Claude to look at how your runs went and tune the next few sessions.</p>
      <button class="pill-btn" data-act="review">Review my runs</button></div>`;
  }
  return '';
}

async function runReview() {
  ui.reviewing = true; ui.reviewError = null; render();
  try {
    const r = await ai.reviewRuns();
    store.save(st => { st.pendingReview = r; });
  } catch (e) {
    ui.reviewError = e.message;
  } finally {
    ui.reviewing = false;
    render();
  }
}

// ---------------- Plan ----------------
function viewPlan() {
  const st = store.get();
  const next = store.nextSession();
  const hasKey = !!st.settings.apiKey.trim();
  return `<div class="page">
    <h1 class="large-title">Plan</h1>
    <p class="subtitle">${esc(st.plan.summary)}${st.plan.source === 'claude' ? ' · Made with Claude' : ''}</p>
    ${st.plan.weeks.map(w => `
      <div class="week-head"><div class="section-header">Week ${w.week}</div><div class="focus">${esc(w.focus)}</div></div>
      <div class="group">${w.sessions.map(s0 => {
        const s = { ...s0, week: w.week };
        const wk = workoutFromSession(s);
        const done = store.isDone(s.id);
        const isNext = next && next.id === s.id;
        return `<button class="row tap ${isNext ? 'current' : ''}" data-act="setup" data-id="${s.id}">
          <span class="status ${done ? 'done' : isNext ? 'next' : ''}">${done ? I.check : ''}</span>
          <div class="grow"><div class="title">${esc(s.title)}</div><div class="sub">${esc(describe(wk))}</div></div>
          <span class="mins">${minutes(totalSeconds(wk))} min</span><span class="chev">${I.chev}</span>
        </button>`;
      }).join('')}</div>`).join('')}
    <div class="mt-l">
      ${hasKey ? `<button class="btn secondary" data-act="review-from-plan">${I.spark} Review with Claude</button>` : ''}
      <button class="btn plain mt" data-act="edit-plan">Plan settings</button>
    </div>
  </div>`;
}

// ---------------- History ----------------
function viewHistory() {
  const st = store.get();
  const list = [...st.history].reverse();
  if (!list.length) {
    return `<div class="page"><h1 class="large-title">History</h1>
      <div class="empty">${I.shoe}<div style="font-weight:600;color:var(--label)">No runs yet</div><div>Your completed runs will show up here.</div></div></div>`;
  }
  return `<div class="page"><h1 class="large-title">History</h1>
    <p class="subtitle">${list.length} run${list.length === 1 ? '' : 's'} · ${minutes(list.reduce((a, h) => a + h.doneSec, 0))} minutes</p>
    <div class="group">${list.map(h => `
      <button class="row tap" data-act="history-detail" data-id="${h.id}">
        <div class="grow"><div class="title">${esc(shortDate(h.date))}${h.sessionLabel ? ` · <span style="color:var(--label2)">${esc(h.sessionLabel)}</span>` : ''}</div>
          <div class="sub">${esc(describe(h.workout))} · ${fmt(h.doneSec)}${h.completed ? '' : ' (partial)'}</div></div>
        ${h.feel ? `<span class="feel ${h.feel}">${FEELS.find(f => f.id === h.feel)?.label}</span>` : ''}
        <span class="chev">${I.chev}</span>
      </button>`).join('')}</div></div>`;
}

function openHistoryDetail(id) {
  const h = store.get().history.find(x => x.id === id);
  if (!h) return;
  openSheet({
    title: shortDate(h.date),
    body: () => `
      <div class="summary-card"><div class="muted">${esc(h.sessionLabel || 'Custom run')}</div>
        <div class="big">${fmt(h.doneSec)}<span class="muted" style="font-size:17px"> / ${fmt(h.totalSec)}</span></div>
        <div class="muted">${esc(describe(h.workout))}</div></div>
      <div class="group mt">
        <div class="row"><div class="grow">Counted as done</div><span class="value">${h.completed ? 'Yes' : 'No'}</span></div>
        <div class="row"><div class="grow">How it felt</div><span class="value">${FEELS.find(f => f.id === h.feel)?.label || '—'}</span></div>
        ${h.notes ? `<div class="row"><div class="grow" style="-webkit-user-select:text;user-select:text">${esc(h.notes)}</div></div>` : ''}
      </div>
      <div class="group mt"><button class="row tap danger" data-act="delete-run" data-id="${h.id}">Delete run</button></div>`,
  });
}

// ---------------- Settings ----------------
function viewSettings() {
  const s = store.get().settings;
  return `<div class="page">
    <h1 class="large-title">Settings</h1>

    <div class="section-header">Voice cues</div>
    <div class="group">
      <div class="row" style="flex-direction:column;align-items:stretch;gap:10px">
        <div>Audio mode</div>
        <div class="segmented">
          <button data-act="audio-mode" data-v="mix" class="${s.audioMode === 'mix' ? 'on' : ''}">Music mix</button>
          <button data-act="audio-mode" data-v="locked" class="${s.audioMode === 'locked' ? 'on' : ''}">Screen off</button>
        </div>
      </div>
      <div class="row"><div class="grow">Countdown beeps</div>${toggle('beeps', s.beeps)}</div>
      <div class="row"><div class="grow">“Halfway there” cue</div>${toggle('halfway', s.halfway)}</div>
      <button class="row tap link" data-act="test-voice">Test voice cue</button>
    </div>
    <p class="section-footer">${audioModeHelp(s.audioMode)}</p>

    <div class="section-header">Claude coach</div>
    <div class="group">
      <div class="row"><div>API key</div><input type="password" data-set="apiKey" placeholder="sk-ant-…" value="${esc(s.apiKey)}" autocomplete="off" autocapitalize="off" spellcheck="false"></div>
      <div class="row"><div class="grow">Model</div>
        <select data-set="model">${ai.MODELS.map(m => `<option value="${m.id}" ${s.model === m.id ? 'selected' : ''}>${m.label}</option>`).join('')}</select></div>
      <div class="row"><div class="grow">Review after each run</div>${toggle('autoReview', s.autoReview !== false)}</div>
      <button class="row tap link" data-act="test-key">Test connection</button>
    </div>
    <p class="section-footer">Your key is stored only on this iPhone and sent only to Anthropic’s API. Create one at console.anthropic.com. Each plan or review costs a few cents at most.</p>

    <div class="section-header">Plan</div>
    <div class="group">
      <button class="row tap" data-act="edit-plan"><div class="grow">Plan settings</div><span class="chev">${I.chev}</span></button>
    </div>

    <div class="section-header">Data</div>
    <div class="group">
      <button class="row tap link" data-act="export">Export data</button>
      <button class="row tap danger" data-act="reset">Reset everything</button>
    </div>
    <p class="section-footer center" style="margin-top:24px">5K Coach ${VERSION}</p>
  </div>`;
}

function audioModeHelp(mode) {
  return mode === 'locked'
    ? 'Screen off: cues keep playing with your iPhone locked in your pocket, but iOS pauses Spotify/podcasts while a workout plays.'
    : 'Music mix: cues play over Spotify/podcasts. iOS mutes web audio when the screen locks, so the app keeps the screen awake — use the pocket lock button. Make sure Silent mode is off.';
}

// ---------------- Sheets ----------------
let sheet = null;

function openSheet(opts) {
  closeSheet(true);
  sheet = opts;
  const root = $('#sheet-root');
  root.innerHTML = `<div class="sheet-backdrop" ${opts.locked ? '' : 'data-act="sheet-close"'}></div>
    <div class="sheet" role="dialog" aria-modal="true" aria-label="${esc(opts.title)}">
      <div class="grabber"></div>
      <div class="sheet-head"><h3>${esc(opts.title)}</h3>${opts.locked ? '' : `<button class="glass-btn" data-act="sheet-close" aria-label="Close">${I.x}</button>`}</div>
      <div class="sheet-body"></div><div class="sheet-foot"></div>
    </div>`;
  opts.update = () => {
    $('.sheet-body', root).innerHTML = opts.body();
    const foot = $('.sheet-foot', root);
    foot.innerHTML = opts.foot ? opts.foot() : '';
    foot.hidden = !opts.foot;
  };
  opts.update();
  opts.onMount?.();
  requestAnimationFrame(() => requestAnimationFrame(() => {
    $('.sheet-backdrop', root)?.classList.add('show');
    $('.sheet', root)?.classList.add('show');
  }));
  if (!opts.locked) enableSwipeDown($('.sheet', root));
}

function closeSheet(instant) {
  const root = $('#sheet-root');
  if (!root.firstChild) return;
  const s = sheet; sheet = null;
  s?.onClose?.();
  if (instant) { root.innerHTML = ''; return; }
  $('.sheet-backdrop', root)?.classList.remove('show');
  $('.sheet', root)?.classList.remove('show');
  setTimeout(() => { if (!sheet) root.innerHTML = ''; }, 380);
}

function enableSwipeDown(el) {
  let y0 = null, dy = 0;
  const head = [$('.grabber', el), $('.sheet-head', el)];
  head.forEach(h => {
    h.addEventListener('pointerdown', e => { if (e.target.closest('button')) return; y0 = e.clientY; dy = 0; el.style.transition = 'none'; h.setPointerCapture(e.pointerId); });
    h.addEventListener('pointermove', e => { if (y0 === null) return; dy = Math.max(0, e.clientY - y0); el.style.transform = `translateY(${dy}px)`; });
    h.addEventListener('pointerup', () => {
      if (y0 === null) return;
      y0 = null; el.style.transition = ''; el.style.transform = '';
      if (dy > 110) closeSheet();
    });
  });
}

// ---------------- Run setup ----------------
const LIMITS = { runSec: [15, 3600], walkSec: [0, 900], repeats: [1, 30], warmupSec: [0, 900], cooldownSec: [0, 900] };

function stepFor(k, v, d) {
  if (k === 'repeats') return 1;
  if (k === 'warmupSec' || k === 'cooldownSec') return 60;
  if (k === 'walkSec') return 15;
  const base = d < 0 ? v - 1 : v;
  return base < 300 ? 15 : base < 600 ? 30 : 60;
}

function openSetup(sessionId) {
  const st = store.get();
  const session = sessionId ? store.allSessions().find(s => s.id === sessionId) : null;
  const planned = session || store.nextSession();
  let wk = session ? workoutFromSession(session)
    : st.lastWorkout ? { ...st.lastWorkout }
      : planned ? workoutFromSession(planned)
        : { warmupSec: 300, runSec: 90, walkSec: 90, repeats: 8, cooldownSec: 300 };
  const sugg = suggestions(planned, st.lastWorkout);
  loadClips().catch(() => {});

  const title = session ? sessionLabel(session) : 'Custom run';
  openSheet({
    title,
    session,
    get wk() { return wk; },
    set wk(v) { wk = v; },
    body: () => {
      const s = store.get().settings;
      const total = totalSeconds(wk);
      const ends = new Date(Date.now() + total * 1000).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
      const row = (k, label, val) => `<div class="row"><div class="grow">${label}</div><span class="stepper-value">${val}</span>${stepper('wk-step', k, wk[k], { min: LIMITS[k][0], max: LIMITS[k][1] })}</div>`;
      return `
        <div class="section-header" style="margin-top:6px">Suggestions</div>
        <div class="chips">${sugg.map((x, i) => `<button class="chip ${JSON.stringify(x.wk) === JSON.stringify(wk) ? 'on' : ''}" data-act="wk-sugg" data-i="${i}">${esc(x.label)}<small>${esc(describe(x.wk))}</small></button>`).join('')}</div>
        <div class="section-header">Intervals</div>
        <div class="group">
          ${row('runSec', '<span style="color:var(--run);font-weight:600">Run</span>', fmt(wk.runSec))}
          ${row('walkSec', '<span style="color:var(--walk);font-weight:600">Walk</span>', wk.walkSec ? fmt(wk.walkSec) : 'None')}
          ${row('repeats', 'Repeats', `× ${wk.repeats}`)}
        </div>
        <div class="group mt">
          ${row('warmupSec', 'Warm-up walk', wk.warmupSec ? dur(wk.warmupSec) : 'None')}
          ${row('cooldownSec', 'Cool-down walk', wk.cooldownSec ? dur(wk.cooldownSec) : 'None')}
        </div>
        <div class="summary-card">
          <div class="muted">Total</div>
          <div class="big">${fmt(total)}</div>
          <div class="muted">${dur(wk.runSec * wk.repeats)} running · finishes about ${ends}</div>
          ${blocks(wk).replace('margin: 4px 0 16px', '')}
        </div>
        <div class="section-header">Audio</div>
        <div class="group"><div class="row">
          <div class="segmented">
            <button data-act="audio-mode" data-v="mix" class="${s.audioMode === 'mix' ? 'on' : ''}">Music mix</button>
            <button data-act="audio-mode" data-v="locked" class="${s.audioMode === 'locked' ? 'on' : ''}">Screen off</button>
          </div></div></div>
        <p class="section-footer">${audioModeHelp(s.audioMode)}</p>`;
    },
    foot: () => `<button class="btn" data-act="start-run">${I.play.replace(/34/g, '22')} Start</button>`,
  });
}

// ---------------- Run screen ----------------
let run = null;

async function startRun() {
  const { wk, session } = sheet;
  const st = store.get();
  if (!clipsReady()) {
    try { await loadClips(); } catch { toast('Couldn’t load voice cues'); return; }
  }
  closeSheet(true);

  const meta = {
    title: describe(wk),
    subtitle: session ? sessionLabel(session) : 'Custom run',
  };
  let rendered;
  try {
    rendered = player.load(wk, { mode: st.settings.audioMode, beeps: st.settings.beeps, halfway: st.settings.halfway }, meta);
  } catch (e) {
    toast('Couldn’t prepare audio: ' + e.message);
    return;
  }
  run = { wk, session, segs: rendered.segs, end: rendered.end, pocket: false, finished: false, startedAt: new Date().toISOString() };
  mountRunScreen(meta);
  try {
    await player.play();
  } catch (e) {
    console.warn(e);
    $('.start-overlay').hidden = false; // needs a fresh tap (autoplay rules)
  }
  tick();
}

function mountRunScreen(meta) {
  const r = 140, C = 2 * Math.PI * r;
  run.C = C;
  $('#run-root').innerHTML = `<div class="run-screen warmup" id="run">
    <div class="run-top">
      <span style="width:40px"></span>
      <div class="t">${esc(meta.subtitle)}</div>
      <button class="icon-btn" data-act="run-end" aria-label="End run">${I.x}</button>
    </div>
    <div class="phase"><div class="name" id="r-name">WARM UP</div><div class="rep" id="r-rep"></div></div>
    <div class="dial">
      <svg viewBox="0 0 300 300"><circle class="track" cx="150" cy="150" r="${r}" fill="none" stroke-width="14"/>
        <circle class="prog" id="r-prog" cx="150" cy="150" r="${r}" fill="none" stroke-width="14" stroke-linecap="round" stroke-dasharray="${C}" stroke-dashoffset="${C}"/></svg>
      <div class="inner"><div class="count" id="r-count">0:00</div><div class="next" id="r-next"></div></div>
    </div>
    <div class="timeline-wrap"><div class="timeline">${run.segs.map(s => `<div class="${s.type}" style="flex:${s.dur}"></div>`).join('')}</div><div class="shade" id="r-shade"></div></div>
    <div class="run-stats">
      <div><div class="k">Elapsed</div><div class="v" id="r-el">0:00</div></div>
      <div><div class="k">Remaining</div><div class="v" id="r-rem">0:00</div></div>
    </div>
    <div class="run-controls">
      <button class="side" data-act="run-end" aria-label="End run">${I.stop}</button>
      <button class="main" data-act="run-toggle" id="r-toggle" aria-label="Pause">${I.pause}</button>
      <button class="side" data-act="pocket" aria-label="Pocket lock">${I.lock}</button>
    </div>
    <div class="run-hint">${store.get().settings.audioMode === 'locked' ? 'You can lock your iPhone — cues keep playing.' : 'Keep the screen on. Tap the lock for pocket mode.'}</div>
    <div class="start-overlay" hidden><button class="btn" style="width:auto;padding:0 28px" data-act="run-resume">${I.play.replace(/34/g, '22')} Tap to start</button></div>
  </div>`;
  document.body.style.overflow = 'hidden';
}

const PHASE_NAMES = { warmup: 'WARM UP', run: 'RUN', walk: 'WALK', cooldown: 'COOL DOWN' };

function tick() {
  if (!run) return;
  const t = Math.min(player.time, run.end);
  const segs = run.segs;
  const i = Math.max(0, segs.findIndex(s => t < s.end));
  const seg = t >= run.end ? null : segs[i];
  const screen = $('#run');
  if (!screen) return;

  const phase = seg ? seg.type : 'done';
  if (run.phase !== phase) { screen.className = `run-screen ${phase}`; run.phase = phase; }
  $('#r-name').textContent = seg ? PHASE_NAMES[seg.type] : 'DONE';
  $('#r-rep').textContent = seg && (seg.type === 'run' || seg.type === 'walk') && seg.of > 1 ? `${seg.rep} of ${seg.of}` : '';
  const remSeg = seg ? seg.end - t : 0;
  $('#r-count').textContent = fmt(Math.ceil(remSeg - 0.05));
  const frac = seg ? (t - seg.start) / seg.dur : 1;
  $('#r-prog').style.strokeDashoffset = run.C * (1 - frac);
  const nx = seg ? segs[i + 1] : null;
  $('#r-next').textContent = nx ? `Next: ${PHASE_NAMES[nx.type].toLowerCase().replace(/^./, c => c.toUpperCase())} ${fmt(nx.dur)}` : seg ? 'Last stretch' : 'Great job!';
  $('#r-el').textContent = fmt(t);
  $('#r-rem').textContent = fmt(run.end - t);
  $('#r-shade').style.width = `${(t / run.end) * 100}%`;
  const paused = player.paused && !run.finished;
  const tg = $('#r-toggle');
  if (tg.dataset.p !== String(paused)) { tg.innerHTML = paused ? I.play : I.pause; tg.dataset.p = String(paused); tg.setAttribute('aria-label', paused ? 'Resume' : 'Pause'); }

  const pk = $('#pocket');
  if (pk) {
    $('#p-t', pk).textContent = fmt(Math.ceil(remSeg - 0.05));
    $('#p-p', pk).textContent = seg ? PHASE_NAMES[seg.type] : 'DONE';
    pk.style.setProperty('--c', getComputedStyle(screen).getPropertyValue('--c'));
  }
  if ('mediaSession' in navigator && navigator.mediaSession.setPositionState && !player.paused) {
    try { navigator.mediaSession.setPositionState({ duration: player.rendered.duration, position: Math.min(player.time, player.rendered.duration), playbackRate: 1 }); } catch {}
  }

  if (player.ended && !run.finished) { finishRun(true); return; }
  requestAnimationFrame(tick);
}

function openPocket() {
  const el = document.createElement('div');
  el.className = 'pocket'; el.id = 'pocket';
  el.innerHTML = `<div class="pp" id="p-p"></div><div class="pt" id="p-t"></div>
    <div class="hold" id="p-hold">${I.lock}<svg class="ring" width="88" height="88" viewBox="0 0 88 88"><circle cx="44" cy="44" r="42" fill="none" stroke="rgba(255,255,255,.7)" stroke-width="3" stroke-dasharray="264" stroke-dashoffset="264" id="p-ring"/></svg></div>
    <small>Hold to unlock</small>`;
  document.body.appendChild(el);
  const hold = $('#p-hold', el), ringEl = $('#p-ring', el);
  let timer;
  const start = e => { e.preventDefault(); ringEl.style.transition = 'stroke-dashoffset .9s linear'; ringEl.style.strokeDashoffset = '0'; timer = setTimeout(() => el.remove(), 900); };
  const cancel = () => { clearTimeout(timer); ringEl.style.transition = 'stroke-dashoffset .2s'; ringEl.style.strokeDashoffset = '264'; };
  hold.addEventListener('pointerdown', start);
  hold.addEventListener('pointerup', cancel);
  hold.addEventListener('pointerleave', cancel);
  hold.addEventListener('pointercancel', cancel);
  el.addEventListener('contextmenu', e => e.preventDefault());
}

function finishRun(reachedEnd) {
  if (!run || run.finished) return;
  run.finished = true;
  const doneSec = reachedEnd ? run.end : Math.min(player.time, run.end);
  player.pause();
  const r = run;
  const runs = r.segs.filter(s => s.type === 'run');
  const mainDone = runs.length ? doneSec >= runs[runs.length - 1].end - 3 : doneSec >= r.end - 3;
  const result = { feel: null, notes: '', completed: mainDone };

  $('#pocket')?.remove();
  $('#run-root').innerHTML = '';
  document.body.style.overflow = '';
  player.unload();
  run = null;

  openSheet({
    title: mainDone ? 'Nice work!' : 'Run ended',
    locked: true,
    body: () => `
      <div class="summary-card center">
        ${ring(doneSec / r.end, 96, 10)}
        <div class="big mt">${fmt(doneSec)}</div>
        <div class="muted">${esc(describe(r.wk))}${r.session ? ` · ${esc(sessionLabel(r.session))}` : ''}</div>
      </div>
      <div class="section-header">How did it feel?</div>
      <div class="segmented" style="background:var(--card)">${FEELS.map(f => `<button data-act="feel" data-v="${f.id}" class="${result.feel === f.id ? 'on' : ''}">${f.label}</button>`).join('')}</div>
      ${r.session ? `<div class="group mt"><div class="row"><div class="grow">Count session as done</div>${toggle('completed', result.completed, 'data-result')}</div></div>` : ''}
      <div class="group mt"><div class="row"><textarea data-result="notes" placeholder="Notes (optional) — e.g. calves tight, felt strong on the last run">${esc(result.notes)}</textarea></div></div>`,
    foot: () => `<button class="btn" data-act="save-run">Save</button><button class="btn plain" data-act="discard-run">Don’t save</button>`,
    result, r, doneSec,
  });
}

function saveRun(discard) {
  const { result, r, doneSec } = sheet;
  closeSheet();
  if (discard) { render(); return; }
  store.save(st => {
    st.history.push({
      id: (crypto.randomUUID?.() || String(Date.now())),
      date: r.startedAt,
      sessionId: r.session ? r.session.id : null,
      sessionLabel: r.session ? sessionLabel(r.session) : null,
      workout: r.wk,
      totalSec: Math.round(r.end),
      doneSec: Math.round(doneSec),
      completed: r.session ? result.completed : doneSec >= r.end - 3,
      feel: result.feel,
      notes: result.notes.trim(),
    });
    st.lastWorkout = r.wk;
  });
  ui.tab = 'today';
  render();
  toast('Run saved');
  const s = store.get().settings;
  if (s.apiKey.trim() && s.autoReview !== false && store.nextSession()) runReview();
}

// ---------------- Events ----------------
const actions = {
  tab: el => { ui.tab = el.dataset.tab; render(); window.scrollTo(0, 0); },
  'sheet-close': () => closeSheet(),

  'draft-level': el => { ui.draft.level = el.dataset.v; render(); },
  'draft-day': el => {
    const v = +el.dataset.v, d = ui.draft;
    d.days = d.days.includes(v) ? d.days.filter(x => x !== v) : [...d.days, v].sort();
    render();
  },
  'draft-step': el => {
    const d = ui.draft, k = el.dataset.k, dir = +el.dataset.d;
    if (k === 'weeks') d.weeks = Math.max(2, Math.min(20, d.weeks + dir));
    if (k === 'pace') d.pace = Math.max(4.5, Math.min(11, Math.round((d.pace + dir * 0.25) * 4) / 4));
    render();
  },
  'build-local': () => {
    if (!checkDraft() || !confirmReplace()) return;
    const d = ui.draft;
    savePlan(generatePlan({ ...d, perWeek: d.days.length }));
  },
  'build-claude': async () => {
    if (!checkDraft() || !confirmReplace()) return;
    const d = ui.draft;
    ui.building = true; ui.buildError = null; render();
    try {
      const plan = await ai.buildPlan({ ...d, perWeek: d.days.length });
      ui.building = false;
      savePlan(plan);
    } catch (e) {
      ui.building = false; ui.buildError = e.message; render();
    }
  },
  'cancel-edit': () => { ui.draft = null; ui.buildError = null; render(); },
  'edit-plan': () => { ui.draft = defaultDraft(); ui.buildError = null; render(); window.scrollTo(0, 0); },

  setup: el => openSetup(el.dataset.id || null),
  'wk-step': el => {
    const k = el.dataset.k, d = +el.dataset.d;
    const wk = { ...sheet.wk };
    const [lo, hi] = LIMITS[k];
    wk[k] = Math.max(lo, Math.min(hi, wk[k] + d * stepFor(k, wk[k], d)));
    sheet.wk = wk;
    sheet.update();
  },
  'wk-sugg': el => {
    const st = store.get();
    const sugg = suggestions(sheet.session || store.nextSession(), st.lastWorkout);
    sheet.wk = { ...sugg[+el.dataset.i].wk };
    sheet.update();
  },
  'audio-mode': el => {
    store.save(st => { st.settings.audioMode = el.dataset.v; });
    if (sheet) sheet.update(); else render();
  },
  'start-run': () => startRun(),

  'run-toggle': () => { if (player.paused) player.play().catch(() => {}); else player.pause(); },
  'run-resume': () => { $('.start-overlay').hidden = true; player.play().catch(e => toast(e.message)); },
  'run-end': () => {
    if (!run) return;
    const wasPlaying = !player.paused;
    player.pause();
    if (confirm('End this run?')) finishRun(false);
    else if (wasPlaying) player.play().catch(() => {});
  },
  pocket: () => openPocket(),

  feel: el => { sheet.result.feel = sheet.result.feel === el.dataset.v ? null : el.dataset.v; sheet.update(); },
  'save-run': () => saveRun(false),
  'discard-run': () => { if (confirm('Discard this run?')) saveRun(true); },

  review: () => runReview(),
  'review-from-plan': () => { ui.tab = 'today'; window.scrollTo(0, 0); runReview(); },
  'apply-review': () => {
    ai.applyChanges(store.get().pendingReview.changes);
    store.save(st => { st.pendingReview = null; });
    render(); toast('Plan updated');
  },
  'dismiss-review': () => { store.save(st => { st.pendingReview = null; }); render(); },

  'history-detail': el => openHistoryDetail(el.dataset.id),
  'delete-run': el => {
    if (!confirm('Delete this run?')) return;
    store.save(st => { st.history = st.history.filter(h => h.id !== el.dataset.id); });
    closeSheet(); render();
  },

  'test-voice': async () => {
    try { await testCue(store.get().settings.audioMode); } catch (e) { toast('Couldn’t play: ' + e.message); }
  },
  'test-key': async () => {
    toast('Contacting Claude…');
    try { await ai.testKey(); toast('Connected to Claude ✓'); } catch (e) { toast(e.message); }
  },
  export: async () => {
    const json = store.exportJSON();
    const file = new File([json], `5k-coach-${todayISO()}.json`, { type: 'application/json' });
    try {
      if (navigator.canShare?.({ files: [file] })) await navigator.share({ files: [file], title: '5K Coach data' });
      else { await navigator.clipboard.writeText(json); toast('Copied to clipboard'); }
    } catch (e) { if (e.name !== 'AbortError') toast('Export failed'); }
  },
  reset: () => {
    if (!confirm('Delete your plan, history and settings from this iPhone?')) return;
    store.reset(); ui.draft = null; ui.tab = 'today'; render();
  },
};

document.addEventListener('click', e => {
  const el = e.target.closest('[data-act]');
  if (!el || el.disabled) return;
  const fn = actions[el.dataset.act];
  if (fn) { e.preventDefault(); fn(el, e); }
});

document.addEventListener('input', e => {
  const t = e.target;
  if (t.dataset.set && t.type !== 'checkbox') store.save(st => { st.settings[t.dataset.set] = t.value; });
  if (t.dataset.draft && ui.draft) ui.draft[t.dataset.draft] = t.value;
  if (t.dataset.result && sheet?.result && t.type !== 'checkbox') sheet.result[t.dataset.result] = t.value;
});

document.addEventListener('change', e => {
  const t = e.target;
  if (t.dataset.set && t.type === 'checkbox') store.save(st => { st.settings[t.dataset.set] = t.checked; });
  if (t.dataset.set === 'apiKey' && ui.draft) render(); // reveal "Build with Claude"
  if (t.dataset.result && t.type === 'checkbox' && sheet?.result) sheet.result[t.dataset.result] = t.checked;
});

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && run && !run.finished) {
    if (player.ended) finishRun(true); else tick();
  }
});

// Never lose a run by accidentally closing the tab mid-workout.
window.addEventListener('beforeunload', e => { if (run && !run.finished) { e.preventDefault(); e.returnValue = ''; } });

// ---------------- Boot ----------------
if ('serviceWorker' in navigator && location.protocol !== 'file:') {
  navigator.serviceWorker.register('sw.js').catch(e => console.warn('SW', e));
}
loadClips().catch(e => console.warn('cues', e));
render();

// Expose for debugging in the browser console.
window.__app = { store, player, ui };
