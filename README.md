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

How it works: the whole workout is rendered into one audio track (silence + spoken cues + beeps at exact times) and played as a normal audio file, so cues stay on time even if iOS pauses the page's JavaScript.

## Development

```bash
node tools/serve.mjs 5173
```

- `python tools/make-cues.py` regenerates the voice clips in `audio/` (NZ neural voice "Molly" via edge-tts + ffmpeg; `--voice` to change).
- `tools/make-icons.ps1` regenerates the icons.
- Data lives in `localStorage` on the phone. Your API key never leaves the device except to call `api.anthropic.com`.
- After changing files, bump `CACHE` in `sw.js` so phones pick up the update.
