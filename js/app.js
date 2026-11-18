import * as store from './store.js';
import { generatePlan, LEVELS, workoutFromSession, normWorkout, DEFAULT_WORKOUT, segmentsFor, totalSeconds, fmt, dur, describe, suggestions, goalSeconds, paceText } from './plan.js';
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

// In-app replacement for confirm(). iOS home-screen apps can lose the keyboard
// (textareas won't open it) after a native confirm()/alert(), so we never use those.
function confirmBox(message, { ok = 'OK', cancel = 'Cancel', danger = false } = {}) {
  return new Promise(resolve => {
    const el = document.createElement('div');
    el.className = 'alert-backdrop';
    el.innerHTML = `<div class="alert" role="alertdialog" aria-modal="true" aria-label="${esc(message)}">
      <p>${esc(message)}</p>
      <div class="alert-btns"><button data-r="0">${esc(cancel)}</button><button data-r="1" class="${danger ? 'danger' : 'strong'}">${esc(ok)}</button></div></div>`;
    el.addEventListener('click', e => {
      const b = e.target.closest('button[data-r]');
      if (!b) return;
      e.stopPropagation();
      el.classList.remove('show');
      setTimeout(() => el.remove(), 160);
      resolve(b.dataset.r === '1');
    });
    document.body.appendChild(el);
    requestAnimationFrame(() => el.classList.add('show'));
  });
}

const minutes = sec => Math.round(sec / 60);
const todayISO = () => { const d = new Date(); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 10); };
const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
const LOCALE = 'en-US';
const shortDate = iso => new Date(iso).toLocaleDateString(LOCALE, { weekday: 'short', month: 'short', day: 'numeric' });
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
  return p ? structuredClone(p) : { level: 'new', weeks: 8, perWeek: 3, paceMi: 11.25, startDate: todayISO(), notes: '' };
}

function viewOnboarding() {
  const st = store.get();
  const d = ui.draft || (ui.draft = defaultDraft());
  const editing = !!st.plan;
  const goal = minutes(goalSeconds(d.paceMi));
  const hasKey = !!st.settings.apiKey.trim();
  const rec = REC_WEEKS[d.level];

  return `<div class="page no-tabs">
    <div class="nav-row">${editing ? `<button class="btn plain" style="width:auto" data-act="cancel-edit">Cancel</button>` : '<span></span>'}
      <button class="glass-btn" data-act="coach-setup" aria-label="Coach setup">${I.settings}</button></div>
    <h1 class="large-title" style="margin-top:${editing ? 8 : 40}px">${editing ? 'Plan settings' : 'Your 5K plan'}</h1>
    <p class="subtitle">${editing ? 'Rebuild your plan. Completed runs stay checked off.' : 'Answer a few questions and I’ll build a run/walk plan that ends with a non-stop 5K (3.1 miles).'}</p>

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
      <div class="row"><div class="grow">Runs per week</div><span class="stepper-value">${d.perWeek}</span>${stepper('draft-step', 'perWeek', d.perWeek, { min: 2, max: 6 })}</div>
      <div class="row"><div class="grow">Start date</div><input type="date" data-draft="startDate" value="${esc(d.startDate)}"></div>
    </div>
    <p class="section-footer">${d.weeks < rec
      ? `<span style="color:var(--warm)">Heads up: ${rec}+ weeks is typical from this starting point. A shorter plan has bigger jumps — Claude can tune it, or you can repeat weeks.</span>`
      : 'Run on any days you like — just aim for a rest day between runs.'}</p>

    <div class="section-header">Easy pace</div>
    <div class="group">
      <div class="row"><div class="grow">Per mile</div><span class="stepper-value">${paceText(d.paceMi)}</span>${stepper('draft-step', 'paceMi', d.paceMi, { min: 7, max: 18 })}</div>
    </div>
    <p class="section-footer">Not sure? Leave it. This sets the final 3.1-mile run at about ${goal} minutes.</p>

    ${hasKey ? `<div class="section-header">Anything your coach should know?</div>
    <div class="group">
      <div class="row"><textarea data-draft="notes" placeholder="Optional — e.g. old knee injury, I walk a lot, I’d like to run a 5K race on Feb 14…">${esc(d.notes)}</textarea></div>
    </div>
    <p class="section-footer">Claude uses this to personalize the plan.</p>` : ''}

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
    st.profile = { ...d };
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
  ui.buildError = null;
  return true;
}

async function confirmReplace() {
  return !store.get().plan || confirmBox('Replace your current plan? Completed runs stay in History.', { ok: 'Replace' });
}

// ---------------- Today ----------------
const COMEBACK_DAYS = 7;
const startOfDay = d => new Date(d.getFullYear(), d.getMonth(), d.getDate());

function daysSinceLastRun() {
  const h = store.get().history;
  if (!h.length) return null;
  const last = new Date(Math.max(...h.map(x => +new Date(x.date))));
  return Math.round((startOfDay(new Date()) - startOfDay(last)) / 864e5);
}

// Runs logged since Sunday (US calendar week), of any kind.
function runsThisWeek() {
  const now = new Date();
  const sunday = startOfDay(now); sunday.setDate(sunday.getDate() - now.getDay());
  return store.get().history.filter(h => new Date(h.date) >= sunday).length;
}

function lastDonePlanSession() {
  const done = store.allSessions().filter(s => store.isDone(s.id));
  return done[done.length - 1] || null;
}

// A bonus run repeats the most recent completed plan run (it's already been earned).
function bonusWorkout() {
  const lastDone = lastDonePlanSession();
  const st = store.get();
  return lastDone ? workoutFromSession(lastDone) : st.lastWorkout ? normWorkout(st.lastWorkout) : { ...DEFAULT_WORKOUT };
}

function weekChecklist(next) {
  const st = store.get();
  const weekNo = next ? next.week : st.plan.weeks.length;
  const w = st.plan.weeks.find(x => x.week === weekNo);
  const n = w.sessions.length;
  const doneCount = w.sessions.filter(s => store.isDone(s.id)).length;
  return `<div class="week-card">
    <div class="wc-head">
      <div><div class="eyebrow">Week ${weekNo} of ${st.plan.weeks.length}</div>
        <div class="wc-title">${doneCount === n ? 'Week complete!' : `${doneCount} of ${n} runs done`}</div></div>
      ${ring(doneCount / n, 46, 6)}
    </div>
    <div class="wc-runs" style="grid-template-columns:repeat(${n},1fr)">${w.sessions.map((s, i) => {
      const done = store.isDone(s.id);
      const isNext = next && next.id === s.id;
      return `<button class="wc-run" data-act="setup" data-id="${s.id}" aria-label="${esc(s.title)}${done ? ', done' : ''}">
        <span class="status ${done ? 'done' : isNext ? 'next' : ''}">${done ? I.check : ''}</span>
        <span class="lbl">${s.title === '5K run' ? '5K' : `Run ${i + 1}`}</span>
        <span class="sub">${minutes(totalSeconds(workoutFromSession(s)))} min</span>
      </button>`;
    }).join('')}</div>
  </div>`;
}

function viewToday() {
  const st = store.get();
  const next = store.nextSession();
  const prog = store.progress();
  const now = new Date();

  const gap = daysSinceLastRun();
  const lastDone = lastDonePlanSession();
  const weekCount = runsThisWeek();

  let hero;
  if (next && lastDone && gap !== null && gap > COMEBACK_DAYS) {
    // Comeback: after a long break, suggest repeating the last plan run before moving on.
    const wk = workoutFromSession(lastDone);
    hero = `<div class="hero">
      <div class="eyebrow" style="color:var(--walk)">Welcome back</div>
      <h2>Ease back in</h2>
      <div class="meta">It’s been ${gap} days since your last run. Repeat your last plan run before moving on — it’ll feel easier than you think.</div>
      <div class="note"><b>${esc(sessionLabel(lastDone))}</b><br>${esc(describe(wk))} · ${minutes(totalSeconds(wk))} min</div>
      <button class="btn" data-act="repeat-run" data-id="${lastDone.id}">${I.play.replace(/34/g, '22')} Repeat last run</button>
      <button class="btn plain mt" style="margin-top:6px" data-act="setup" data-id="${next.id}">Continue with ${esc(sessionLabel(next))}</button>
    </div>`;
  } else if (next && weekCount >= st.profile.perWeek) {
    // Weekly target reached: steer extra runs to an easy bonus run that doesn't advance the plan.
    const wk = bonusWorkout();
    hero = `<div class="hero">
      <div class="eyebrow">This week · ${weekCount} run${weekCount === 1 ? '' : 's'}</div>
      <h2>Weekly goal done!</h2>
      <div class="meta">Rest days are when your legs get stronger. Want to run anyway? Do an easy bonus run — it won’t move your plan ahead.</div>
      <div class="note"><b>Bonus run</b><br>${esc(describe(wk))} · ${minutes(totalSeconds(wk))} min</div>
      <button class="btn" data-act="bonus-run">${I.play.replace(/34/g, '22')} Bonus easy run</button>
      <button class="btn plain mt" style="margin-top:6px" data-act="setup" data-id="${next.id}">Do ${esc(sessionLabel(next))} instead</button>
    </div>`;
  } else if (next) {
    const wk = workoutFromSession(next);
    const total = totalSeconds(wk);
    const runTotal = wk.runSec * wk.repeats;
    hero = `<div class="hero">
      <div class="eyebrow">Up next · ${esc(sessionLabel(next))}</div>
      <h2>${wk.repeats > 1 && wk.walkSec ? `Run ${dur(wk.runSec)}<span style="color:var(--label3)"> / </span>Walk ${dur(wk.walkSec)}` : `Run ${dur(runTotal)}`}</h2>
      <div class="meta">${wk.repeats > 1 && wk.walkSec ? `${wk.repeats} rounds · ` : 'Non-stop · '}${minutes(total)} min total · ${minutes(runTotal)} min running</div>
      ${blocks(wk)}
      <div class="legend"><span style="--c:var(--run)">Run</span><span style="--c:var(--walk)">Walk</span></div>
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

  const longest = st.history.filter(h => h.completed).reduce((m, h) => Math.max(m, h.workout.runSec), 0);

  return `<div class="page">
    <h1 class="large-title">Today</h1>
    <p class="subtitle">${now.toLocaleDateString(LOCALE, { weekday: 'long', month: 'long', day: 'numeric' })}</p>
    ${!isStandalone() ? `<div class="coach" style="margin:0 0 14px"><div class="coach-head">${I.share} Install on your iPhone</div><p style="margin:0">Tap Share in Safari, then <b>Add to Home Screen</b>. It runs full-screen and works offline.</p></div>` : ''}
    ${weekChecklist(next)}
    ${hero}
    ${viewCoach()}
    <div class="stats">
      <div class="stat ring-wrap">${ring(prog.total ? prog.done / prog.total : 0, 56, 7)}
        <div><div class="k">Plan</div><div class="v">${prog.done}<small>/${prog.total}</small></div></div></div>
      <div class="stat"><div class="k">Longest run</div><div class="v">${longest ? fmt(longest) : '—'}<small>${longest ? ' non-stop' : ''}</small></div></div>
      <div class="stat"><div class="k">Runs logged</div><div class="v">${st.history.length}</div></div>
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
    onClose: () => render(), // reflect edited notes in the list
    body: () => `
      <div class="summary-card"><div class="muted">${esc(h.sessionLabel || 'Custom run')}</div>
        <div class="big">${fmt(h.doneSec)}<span class="muted" style="font-size:17px"> / ${fmt(h.totalSec)}</span></div>
        <div class="muted">${esc(describe(h.workout))}</div></div>
      <div class="group mt">
        <div class="row"><div class="grow">Counted as done</div><span class="value">${h.completed ? 'Yes' : 'No'}</span></div>
        <div class="row"><div class="grow">How it felt</div><span class="value">${FEELS.find(f => f.id === h.feel)?.label || '—'}</span></div>
      </div>
      <div class="section-header">Notes</div>
      <div class="group"><label class="row note-row"><textarea data-note="${h.id}" rows="3" enterkeyhint="done" placeholder="Add a note about this run">${esc(h.notes || '')}</textarea></label></div>
      <p class="section-footer">Saved automatically.</p>
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

    <div class="section-header">Coach</div>
    <div class="group">
      <button class="row tap" data-act="coach-setup">
        <span class="icon-badge" style="background:linear-gradient(135deg,#d97757,#c15f3c)">${I.spark}</span>
        <div class="grow"><div class="title">Claude coach</div><div class="sub">${s.apiKey.trim() ? 'Connected' : 'Not set up'}</div></div>
        <span class="chev">${I.chev}</span>
      </button>
      ${s.apiKey.trim() ? `<div class="row"><div class="grow">Review after each run</div>${toggle('autoReview', s.autoReview !== false)}</div>` : ''}
    </div>

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

// ---------------- Coach setup (admin) ----------------
function openCoachSetup() {
  const state = { status: '', ok: false, busy: false };
  openSheet({
    title: 'Coach setup',
    admin: state,
    body: () => {
      const set = store.get().settings;
      const key = set.apiKey.trim();
      return `
        <p class="section-footer" style="margin:2px 4px 0">One-time setup. Paste a Claude API key and the coach builds the plan and reviews each run. The key stays on this iPhone and is only ever sent to Anthropic.</p>
        ${!isStandalone() ? `<p class="section-footer" style="margin:10px 4px 0;color:var(--warm)">You’re in Safari. Add the app to the Home Screen first and enter the key there — the Home Screen app doesn’t share Safari’s storage.</p>` : ''}
        <div class="section-header">Claude API key</div>
        <div class="group">
          ${key ? `<div class="row"><div class="grow">Current key</div><span class="value">••••${esc(key.slice(-4))}</span></div>` : ''}
          <div class="row"><input type="password" id="admin-key" placeholder="${key ? 'Paste a new key to replace it' : 'sk-ant-…'}" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" style="text-align:left;color:var(--label)"></div>
          <div class="row"><div class="grow">Model</div>
            <select data-set="model">${ai.MODELS.map(m => `<option value="${m.id}" ${set.model === m.id ? 'selected' : ''}>${m.label}</option>`).join('')}</select></div>
        </div>
        ${state.status ? `<p class="section-footer" style="color:${state.ok ? 'var(--accent)' : 'var(--red)'};font-weight:600">${esc(state.status)}</p>` : ''}
        <p class="section-footer">Tip: create a separate key for this app at console.anthropic.com and put a monthly spend limit on its workspace. A plan or a run review costs a few cents.</p>
        ${key ? `<div class="group mt"><button class="row tap danger" data-act="admin-remove">Remove API key</button></div>` : ''}`;
    },
    foot: () => `<button class="btn" data-act="admin-save" ${state.busy ? 'disabled' : ''}>${state.busy ? '<span class="spinner" style="border-top-color:#fff"></span> Checking…' : 'Save & test'}</button>`,
  });
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
const LIMITS = { runSec: [15, 3600], walkSec: [0, 900], repeats: [1, 30] };

function stepFor(k, v, d) {
  if (k === 'repeats') return 1;
  if (k === 'walkSec') return 15;
  const base = d < 0 ? v - 1 : v;
  return base < 300 ? 15 : base < 600 ? 30 : 60;
}

// extra = { kind: 'repeat' | 'bonus', wk, label } for runs that don't advance the plan.
function openSetup(sessionId, extra = null) {
  const st = store.get();
  const session = !extra && sessionId ? store.allSessions().find(s => s.id === sessionId) : null;
  const planned = session || store.nextSession();
  let wk = extra ? normWorkout(extra.wk)
    : session ? workoutFromSession(session)
      : st.lastWorkout ? normWorkout(st.lastWorkout)
        : planned ? workoutFromSession(planned)
          : { ...DEFAULT_WORKOUT };
  const sugg = extra ? [{ label: extra.kind === 'repeat' ? 'Repeat' : 'Bonus', wk: normWorkout(extra.wk) }, ...suggestions(null, st.lastWorkout)] : suggestions(planned, st.lastWorkout);
  loadClips().catch(() => {});
  const canMark = session && !store.isDone(session.id);

  const title = extra ? extra.label : session ? sessionLabel(session) : 'Custom run';
  openSheet({
    title,
    session,
    kind: extra ? extra.kind : session ? 'plan' : 'custom',
    label: title,
    sugg,
    get wk() { return wk; },
    set wk(v) { wk = v; },
    body: () => {
      const s = store.get().settings;
      const total = totalSeconds(wk);
      const ends = new Date(Date.now() + total * 1000).toLocaleTimeString(LOCALE, { hour: 'numeric', minute: '2-digit' });
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
        <p class="section-footer">Starts and ends with a walk — those are the warm-up and cool-down.${sheet?.kind === 'repeat' || sheet?.kind === 'bonus' ? ' This run won’t move your plan ahead.' : ''}</p>
        <div class="summary-card">
          <div class="muted">Total</div>
          <div class="big">${fmt(total)}</div>
          <div class="muted">${dur(wk.runSec * wk.repeats)} running · finishes around ${ends}</div>
          ${blocks(wk)}
        </div>
        <div class="section-header">Audio</div>
        <div class="group"><div class="row">
          <div class="segmented">
            <button data-act="audio-mode" data-v="mix" class="${s.audioMode === 'mix' ? 'on' : ''}">Music mix</button>
            <button data-act="audio-mode" data-v="locked" class="${s.audioMode === 'locked' ? 'on' : ''}">Screen off</button>
          </div></div></div>
        <p class="section-footer">${audioModeHelp(s.audioMode)}</p>`;
    },
    foot: () => `<button class="btn" data-act="start-run">${I.play.replace(/34/g, '22')} Start</button>
      ${canMark ? `<button class="btn plain" data-act="mark-done">Check off without the timer</button>` : ''}`,
  });
}

// Lets a run done without the app (treadmill, forgot phone…) still count toward the week.
async function markDone() {
  const { session, wk } = sheet;
  if (!(await confirmBox(`Check off ${sessionLabel(session)} as done?`, { ok: 'Check off' }))) return;
  closeSheet();
  const total = totalSeconds(wk);
  store.save(st => {
    st.history.push({
      id: (crypto.randomUUID?.() || String(Date.now())),
      date: new Date().toISOString(),
      sessionId: session.id,
      sessionLabel: sessionLabel(session),
      kind: 'plan',
      workout: wk, totalSec: total, doneSec: total,
      completed: true, feel: null, notes: 'Checked off without the timer', manual: true,
    });
  });
  render();
  toast('Checked off ✓');
}

// ---------------- Run screen ----------------
let run = null;

async function startRun() {
  const { wk, session, kind, label } = sheet;
  const st = store.get();
  if (!clipsReady()) {
    try { await loadClips(); } catch { toast('Couldn’t load voice cues'); return; }
  }
  closeSheet(true);

  const meta = { title: describe(wk), subtitle: label };
  let rendered;
  try {
    rendered = player.load(wk, { mode: st.settings.audioMode, beeps: st.settings.beeps, halfway: st.settings.halfway }, meta);
  } catch (e) {
    toast('Couldn’t prepare audio: ' + e.message);
    return;
  }
  run = { wk, session, kind, label, segs: rendered.segs, end: rendered.end, pocket: false, finished: false, startedAt: new Date().toISOString() };
  mountRunScreen(meta);
  try {
    await player.play();
  } catch (e) {
    console.warn(e);
    $('.start-overlay').hidden = false; // needs a fresh tap (autoplay rules)
  }
  scheduleTick();
}

function mountRunScreen(meta) {
  const r = 140, C = 2 * Math.PI * r;
  run.C = C;
  $('#run-root').innerHTML = `<div class="run-screen walk" id="run">
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
  $('#r-rep').textContent = !seg ? ''
    : seg.edge === 'start' ? 'Warm-up'
      : seg.edge === 'end' ? 'Cool-down'
        : seg.of > 1 ? `${seg.rep} of ${seg.of}` : '';
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
  // iOS paused the audio while we're on screen (Siri, a call, another app's sound…): catch up.
  if (!player.paused && player.audio.paused && document.visibilityState === 'visible' && Date.now() - (run.lastCatchUp || 0) > 2000) {
    run.lastCatchUp = Date.now();
    resumeAfterInterruption();
  }

  if (player.ended && !run.finished) { finishRun(true); return; }
  scheduleTick();
}

function scheduleTick() {
  if (!run) return;
  cancelAnimationFrame(run.raf);
  run.raf = requestAnimationFrame(tick);
}

// Jump the audio to where the workout really is (the clock never stops) and keep going.
async function resumeAfterInterruption() {
  if (!run || run.finished) return;
  try {
    await player.catchUp();
    $('.start-overlay') && ($('.start-overlay').hidden = true);
  } catch (e) {
    // iOS wants a tap before audio can restart.
    const ov = $('.start-overlay');
    if (ov) { ov.hidden = false; $('button', ov).innerHTML = `${I.play.replace(/34/g, '22')} Tap to resume cues`; }
  }
  if (player.ended && !run.finished) finishRun(true); else scheduleTick();
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
  cancelAnimationFrame(run.raf);
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
        <div class="muted">${esc(describe(r.wk))}${r.kind !== 'custom' ? ` · ${esc(r.label)}` : ''}</div>
      </div>
      <div class="section-header">How did it feel?</div>
      <div class="segmented" style="background:var(--card)">${FEELS.map(f => `<button data-act="feel" data-v="${f.id}" class="${result.feel === f.id ? 'on' : ''}">${f.label}</button>`).join('')}</div>
      ${r.session ? `<div class="group mt"><div class="row"><div class="grow">Count session as done</div>${toggle('completed', result.completed, 'data-result')}</div></div>` : ''}
      <div class="section-header">Notes</div>
      <div class="group"><label class="row note-row"><textarea data-result="notes" rows="3" enterkeyhint="done" placeholder="Optional — e.g. calves tight, felt strong on the last run">${esc(result.notes)}</textarea></label></div>`,
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
      sessionLabel: r.kind === 'custom' ? null : r.label,
      kind: r.kind,
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
  'draft-step': el => {
    const d = ui.draft, k = el.dataset.k, dir = +el.dataset.d;
    if (k === 'weeks') d.weeks = Math.max(2, Math.min(20, d.weeks + dir));
    if (k === 'perWeek') d.perWeek = Math.max(2, Math.min(6, d.perWeek + dir));
    if (k === 'paceMi') d.paceMi = Math.max(7, Math.min(18, Math.round((d.paceMi + dir * 0.25) * 4) / 4));
    render();
  },
  'build-local': async () => {
    if (!checkDraft() || !(await confirmReplace())) return;
    const d = ui.draft;
    savePlan(generatePlan({ ...d }));
  },
  'build-claude': async () => {
    if (!checkDraft() || !(await confirmReplace())) return;
    const d = ui.draft;
    ui.building = true; ui.buildError = null; render();
    try {
      const plan = await ai.buildPlan({ ...d });
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
    sheet.wk = { ...sheet.sugg[+el.dataset.i].wk };
    sheet.update();
  },
  'audio-mode': el => {
    store.save(st => { st.settings.audioMode = el.dataset.v; });
    if (sheet) sheet.update(); else render();
  },
  'start-run': () => startRun(),
  'mark-done': () => markDone(),
  'repeat-run': el => {
    const s = store.allSessions().find(x => x.id === el.dataset.id);
    if (s) openSetup(null, { kind: 'repeat', wk: workoutFromSession(s), label: `${sessionLabel(s)} (repeat)` });
  },
  'bonus-run': () => openSetup(null, { kind: 'bonus', wk: bonusWorkout(), label: 'Bonus run' }),

  'run-toggle': () => { if (player.paused) player.play().catch(() => {}); else player.pause(); },
  'run-resume': () => {
    $('.start-overlay').hidden = true;
    // First start, or resuming after iOS stopped the audio: either way, line up with the clock.
    (player.anchor == null ? player.play() : player.catchUp()).catch(e => toast(e.message));
  },
  'run-end': async () => {
    if (!run) return;
    const wasPlaying = !player.paused;
    player.pause();
    if (await confirmBox('End this run?', { ok: 'End run', cancel: 'Keep going', danger: true })) finishRun(false);
    else if (wasPlaying && run) player.play().catch(() => {});
  },
  pocket: () => openPocket(),

  feel: el => { sheet.result.feel = sheet.result.feel === el.dataset.v ? null : el.dataset.v; sheet.update(); },
  'save-run': () => saveRun(false),
  'discard-run': async () => { if (await confirmBox('Discard this run?', { ok: 'Discard', danger: true })) saveRun(true); },

  review: () => runReview(),
  'review-from-plan': () => { ui.tab = 'today'; window.scrollTo(0, 0); runReview(); },
  'apply-review': () => {
    ai.applyChanges(store.get().pendingReview.changes);
    store.save(st => { st.pendingReview = null; });
    render(); toast('Plan updated');
  },
  'dismiss-review': () => { store.save(st => { st.pendingReview = null; }); render(); },

  'history-detail': el => openHistoryDetail(el.dataset.id),
  'delete-run': async el => {
    if (!(await confirmBox('Delete this run?', { ok: 'Delete', danger: true }))) return;
    store.save(st => { st.history = st.history.filter(h => h.id !== el.dataset.id); });
    closeSheet(); render();
  },

  'test-voice': async () => {
    try { await testCue(store.get().settings.audioMode); } catch (e) { toast('Couldn’t play: ' + e.message); }
  },
  'coach-setup': () => openCoachSetup(),
  'admin-save': async () => {
    const s = sheet.admin;
    const typed = $('#admin-key')?.value.trim();
    if (typed) store.save(st => { st.settings.apiKey = typed; });
    if (!store.get().settings.apiKey.trim()) { s.status = 'Paste a key first.'; s.ok = false; sheet.update(); return; }
    s.busy = true; s.status = ''; sheet.update();
    try {
      await ai.testKey();
      s.ok = true; s.status = 'Connected — the coach is ready.';
    } catch (e) {
      s.ok = false; s.status = e.message;
    }
    s.busy = false;
    if (sheet?.admin === s) sheet.update();
    render();
  },
  'admin-remove': async () => {
    if (!(await confirmBox('Remove the API key from this iPhone? The coach will stop working until a key is added again.', { ok: 'Remove', danger: true }))) return;
    store.save(st => { st.settings.apiKey = ''; st.pendingReview = null; });
    sheet.admin.status = ''; sheet.update(); render();
  },
  export: async () => {
    const json = store.exportJSON();
    const file = new File([json], `5k-coach-${todayISO()}.json`, { type: 'application/json' });
    try {
      if (navigator.canShare?.({ files: [file] })) await navigator.share({ files: [file], title: '5K Coach data' });
      else { await navigator.clipboard.writeText(json); toast('Copied to clipboard'); }
    } catch (e) { if (e.name !== 'AbortError') toast('Export failed'); }
  },
  reset: async () => {
    if (!(await confirmBox('Delete your plan, history and settings from this iPhone? (The coach setup is kept.)', { ok: 'Delete all', danger: true }))) return;
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
  if (t.dataset.note) store.save(st => { const h = st.history.find(x => x.id === t.dataset.note); if (h) h.notes = t.value; });
});

document.addEventListener('change', e => {
  const t = e.target;
  if (t.dataset.set && t.type === 'checkbox') store.save(st => { st.settings[t.dataset.set] = t.checked; });
  if (t.dataset.result && t.type === 'checkbox' && sheet?.result) sheet.result[t.dataset.result] = t.checked;
});

// Back from another app: the timer kept counting while she was away, so jump the cues forward.
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && run && !run.finished) {
    if (player.ended) finishRun(true); else resumeAfterInterruption();
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
