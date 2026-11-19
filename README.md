# 5K Coach

A personal iPhone web app (PWA) for getting to 5K with run/walk intervals.

- **Plan**: pick your starting level, number of weeks and runs per week; get a week-by-week plan ending in a non-stop 5K (3.1 miles). Runs aren't tied to days — the Today screen checks them off as each week's runs are done.
- **Interval timer**: before each run, use the planned intervals or set your own (run / walk / repeats; default 1:30 / 1:30). Every workout starts and ends with a walk, which serves as the warm-up and cool-down. A voice says "Run" and "Walk" at each change, with countdown beeps.
- **Claude coach** (optional): an admin adds a Claude API key once under **Coach setup** (gear icon on the first screen, or Settings → Claude coach). Claude then builds a personalized plan and reviews each run, suggesting changes to upcoming sessions that can be accepted or ignored. "Reset everything" keeps the coach setup.

## Install on iPhone

Open the site in **Safari** → Share → **Add to Home Screen**.

## Audio modes

iOS limits what web apps can do with audio, so there are two modes (Settings, or the run setup sheet):

| Mode | Music keeps playing? | Works with screen locked? |
|---|---|---|
| **Music mix** (default) | Yes — cues play over Spotify/podcasts | No — the app keeps the screen awake; use the pocket-lock button. Silent mode must be off. |
| **Screen off** | No — iOS pauses other audio | Yes |

The timer runs on the wall clock: if iOS stops the audio (switching to Spotify in Music mix mode, Siri, a call), the timer keeps counting, and when the app is back on screen the cues jump to the right spot and carry on. Cues missed while the app was in the background aren't replayed.

## Distance (GPS)

On by default (Settings → Distance). During a run the app records GPS fixes, drops poor ones (accuracy worse than 35 m, or jumps faster than 8 m/s) and adds up the distance. The run screen shows miles plus current and average pace; History shows distance, average pace and a map of the route.

- **Music mix** keeps the screen awake, so GPS covers the whole run.
- **Screen off**: iOS pauses the page — and location — while the phone is locked. When a fix arrives after a gap, it's joined to the last one with a straight line: that counts toward distance (usually a bit short) and is drawn dashed on the map.
- Maps use [Leaflet](https://leafletjs.com) 1.9.4 from unpkg with OpenStreetMap tiles, loaded only when a map is shown. Offline, or if tiles fail, a plain route trace is shown instead.
- Stored per run: `distM`, `gpsSec` and a thinned `track` (`pts` of `[lat, lng, sec]` rounded to 5 decimals, plus `gap`/`brk` point indices). Runs from before GPS have none of these.

**Apple Watch:** start the Watch workout as usual and leave this app on the phone. If the Watch workout keeps pausing during walk breaks, turn off Auto-Pause for running (Watch app on iPhone → Workout).

How it works: the whole workout is rendered into one audio track (silence + spoken cues + beeps at exact times) and played as a normal audio file, so cues stay on time even if iOS pauses the page's JavaScript.

## Development

```bash
node tools/serve.mjs 5173
```

- `python tools/make-cues.py` regenerates the voice clips in `audio/` (NZ neural voice "Molly" via edge-tts + ffmpeg; `--voice` to change).
- `tools/make-icons.ps1` regenerates the icons.
- Data lives in `localStorage` on the phone. Your API key never leaves the device except to call `api.anthropic.com`.
- After changing files, bump `CACHE` in `sw.js` and `VERSION` in `js/app.js` (Settings shows it). The app reloads into a new version by itself next time it comes to the front, unless a run or sheet is open.
