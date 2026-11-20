# CoachCore

The 5K Coach logic as a Swift package (Foundation only), ported from the web app:

| Swift file | From | What |
|---|---|---|
| `Plan.swift` | `js/plan.js` | `LEVELS`, `generatePlan`, `segmentsFor`, `totalSeconds`, `fmt`, `dur`, `describe`, `suggestions`, `goalSeconds`, `paceText` |
| `Audio.swift` | `js/audio.js` | `cueEvents`, and `WorkoutAudio` (parse/prepare clips, beep, whole-workout render to 11025 Hz mono PCM / WAV) |
| `GPS.swift` | `js/gps.js` | `haversine`, `GpsTracker` (fix filter, distance, pace), `pack` (Douglas-Peucker), `pieces` |
| `Store.swift` | `js/store.js` | `AppState` model, `isDone`/`nextSession`/`progress`/`allSessions`, `AppState.importPWA` for the web app's export file |
| `JS.swift` | – | `Math.round` / `toFixed` equivalents so numbers match the JS exactly |

Tests compare the port against fixtures made from the JS:

```
node tools/make-fixtures.mjs      # from the repo root; rewrites Tests/CoachCoreTests/Fixtures
cd ios/CoachCore && swift test    # macOS (CI: .github/workflows/coachcore.yml)
```

The audio render test reads the real clips from `audio/*.wav` at the repo root.
