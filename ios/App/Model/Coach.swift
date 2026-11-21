import Foundation
import CoachCore

// Port of js/ai.js: build a personalized plan, and review runs to adjust upcoming sessions.
// Calls go straight from the phone to the Claude Messages API with your own key (Swift has no
// official Anthropic SDK, so this is plain HTTPS).

struct CoachError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A non-200 reply from the API.
private struct APIFailure: Error {
    let status: Int
    let message: String
}

struct Coach: Sendable {
    let apiKey: String
    let model: String

    static let MODELS: [(id: String, label: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-haiku-5-5", "Claude Haiku 5.5"),
    ]

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2026-10-21"
    private static let fallbackBeta = "server-side-fallback-2026-07-01"

    static let SYSTEM = """
    You are a friendly, practical running coach inside a personal "Couch to 5K"-style app.
    Workouts are run/walk intervals: walk Y seconds, then "run X seconds, walk Y seconds" repeated N times. So every workout starts and ends with a walk of the same length — those walks are the warm-up and cool-down (there are no separate ones). For a non-stop run, repeats = 1 and walkSec is just the walk before and after.
    Coach for injury-free consistency: progress gradually, prefer repeating a step over rushing, and keep runs at an easy conversational pace.
    All durations are whole seconds. Use run and walk lengths that are multiples of 15 seconds.
    The runner is in the US: in any text, use miles and US spelling (never kilometers). A 5K is 3.1 miles.
    """

    private static let SESSION_PROPS: [String: Any] = [
        "title": ["type": "string"],
        "runSec": ["type": "integer"],
        "walkSec": ["type": "integer"],
        "repeats": ["type": "integer"],
        "note": ["type": "string"],
    ]

    private static let PLAN_SCHEMA: [String: Any] = [
        "type": "object",
        "properties": [
            "summary": ["type": "string"],
            "weeks": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "focus": ["type": "string"],
                        "sessions": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": SESSION_PROPS,
                                "required": ["title", "runSec", "walkSec", "repeats", "note"],
                                "additionalProperties": false,
                            ] as [String: Any],
                        ] as [String: Any],
                    ] as [String: Any],
                    "required": ["focus", "sessions"],
                    "additionalProperties": false,
                ] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
        "required": ["summary", "weeks"],
        "additionalProperties": false,
    ]

    private static let ADJUST_SCHEMA: [String: Any] = [
        "type": "object",
        "properties": [
            "message": ["type": "string"],
            "changes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "runSec": ["type": "integer"],
                        "walkSec": ["type": "integer"],
                        "repeats": ["type": "integer"],
                        "note": ["type": "string"],
                    ] as [String: Any],
                    "required": ["id", "runSec", "walkSec", "repeats", "note"],
                    "additionalProperties": false,
                ] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
        "required": ["message", "changes"],
        "additionalProperties": false,
    ]

    // MARK: Requests

    private func send(_ body: [String: Any], beta: Bool) async throws -> (stopReason: String?, text: String) {
        var req = URLRequest(url: Coach.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Coach.apiVersion, forHTTPHeaderField: "anthropic-version")
        if beta { req.setValue(Coach.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if status == 200, let json {
                let blocks = json["content"] as? [[String: Any]] ?? []
                let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                return (json["stop_reason"] as? String, text)
            }
            // Retry rate limits and server trouble a couple of times, like the SDK does.
            if (status == 429 || status >= 500) && attempt < 2 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                continue
            }
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw APIFailure(status: status, message: msg)
        }
    }

    private func friendly(_ e: Error) -> CoachError {
        if let e = e as? CoachError { return e }
        if let e = e as? APIFailure {
            let s = e.status
            if s == 401 { return CoachError(message: "The API key was rejected. Check it in Settings → Claude coach.") }
            if s == 403 { return CoachError(message: "This API key doesn’t have access to that model.") }
            if s == 429 { return CoachError(message: "Rate limited by the Claude API. Wait a minute and try again.") }
            if s == 400 && e.message.range(of: "credit|balance", options: [.regularExpression, .caseInsensitive]) != nil {
                return CoachError(message: "Your Claude API account is out of credit.")
            }
            if s >= 500 { return CoachError(message: "The Claude API is having trouble right now. Try again shortly.") }
            return CoachError(message: e.message)
        }
        if e is URLError { return CoachError(message: "Couldn’t reach Claude. Are you online?") }
        return CoachError(message: e.localizedDescription)
    }

    private func ask(_ prompt: String, schema: [String: Any]) async throws -> [String: Any] {
        guard !apiKey.isEmpty else { throw CoachError(message: "The Claude coach isn’t set up yet (Settings → Claude coach).") }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": Coach.SYSTEM,
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema] as [String: Any]] as [String: Any],
        ]
        // Opus 5.5 / Sonnet 5.5: if a safety classifier declines, let the API retry on a fallback model.
        let fallback = model == "claude-opus-5-5" || model == "claude-sonnet-5-5"
        if fallback { body["fallbacks"] = "default" }

        let res: (stopReason: String?, text: String)
        do {
            res = try await send(body, beta: fallback)
        } catch let e as APIFailure where fallback && e.status == 400
                    && e.message.range(of: "fallback|beta", options: [.regularExpression, .caseInsensitive]) != nil {
            // The account/model doesn't accept the fallback option: retry once without it.
            body["fallbacks"] = nil
            do { res = try await send(body, beta: false) } catch { throw friendly(error) }
        } catch {
            throw friendly(error)
        }
        if res.stopReason == "refusal" { throw CoachError(message: "Claude declined this request. Try rewording your notes.") }
        if res.stopReason == "max_tokens" { throw CoachError(message: "Claude’s reply was cut off. Try again, or choose fewer weeks.") }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(res.text.utf8)) as? [String: Any] else {
            throw CoachError(message: "Claude sent back something unexpected. Please try again.")
        }
        return obj
    }

    func testKey() async throws {
        guard !apiKey.isEmpty else { throw CoachError(message: "Paste a key first.") }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "output_config": ["effort": "low"],
            "messages": [["role": "user", "content": "Reply with just: OK"]],
        ]
        do { _ = try await send(body, beta: false) } catch { throw friendly(error) }
    }

    // MARK: Helpers

    /// `Math.max(lo, Math.min(hi, Math.round((Number(v) || 0) / step) * step))`
    private static func int(_ v: Any?, _ lo: Int, _ hi: Int, _ step: Int = 1) -> Int {
        var n = 0.0
        if let x = v as? NSNumber { n = x.doubleValue } else if let s = v as? String { n = Double(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
        if !n.isFinite { n = 0 }
        let r = Int(jsRound(n / Double(step))) * step
        return max(lo, min(hi, r))
    }

    private static func str(_ v: Any?, _ max: Int) -> String {
        let s: String
        if let x = v as? String { s = x } else if let x = v as? NSNumber { s = x.stringValue } else { s = "" }
        return String(s.prefix(max))
    }

    private static func cleanSession(_ s: [String: Any], id: String) -> PlanSession {
        let title = str(s["title"], 40)
        return PlanSession(
            id: id,
            title: title.isEmpty ? "Run" : title,
            runSec: int(s["runSec"], 15, 3600, 15),
            walkSec: int(s["walkSec"], 0, 600, 15),
            repeats: int(s["repeats"], 1, 30),
            note: str(s["note"], 240))
    }

    private static func profileText(_ p: Profile) -> String {
        let L = levelFor(p.level)
        let notes = (p.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "Experience: \(L.label) (\(L.detail))",
            "Plan length: \(p.weeks) weeks, \(p.perWeek) runs per week (no fixed days — runs whenever it suits)",
            "Estimated easy pace: \(paceText(p.paceMi)) per mile",
            "Start date: \(p.startDate ?? todayISO())",
            notes.isEmpty ? "Runner's notes: none" : "Runner's notes: \(notes)",
        ].joined(separator: "\n")
    }

    // MARK: Plan

    func buildPlan(_ profile: Profile) async throws -> Plan {
        let baseline = generatePlan(profile)
        let baselineText = baseline.weeks.map { w in
            "Week \(w.week): " + w.sessions.map { describe($0.workout) }.joined(separator: " | ")
        }.joined(separator: "\n")

        let prompt = """
        Create my personalized 5K training plan.

        \(Coach.profileText(profile))

        Requirements:
        - Exactly \(profile.weeks) weeks with exactly \(profile.perWeek) sessions each.
        - Start where I am: for a new runner the first week should be about run 90 seconds / walk 90 seconds × 8.
        - The very last session is the goal: one non-stop run of about 5K / 3.1 miles (repeats = 1) titled "5K run", with walkSec as the walk before and after.
        - Short, encouraging "note" for each session (one sentence) and a short "focus" for each week.
        - "summary": 1–2 sentences describing the plan.

        For reference, here is a simple algorithmic baseline. Improve on it using my experience and notes (smoother steps, sensible repeats), rather than copying it:
        \(baselineText)
        """

        let out = try await ask(prompt, schema: Coach.PLAN_SCHEMA)
        guard let weeks = out["weeks"] as? [[String: Any]], !weeks.isEmpty else {
            throw CoachError(message: "Claude returned an empty plan.")
        }
        let planWeeks = weeks.enumerated().map { i, w in
            PlanWeek(
                week: i + 1,
                focus: Coach.str(w["focus"], 40),
                sessions: (w["sessions"] as? [[String: Any]] ?? []).enumerated().map { j, s in
                    Coach.cleanSession(s, id: "w\(i + 1)s\(j + 1)")
                })
        }.filter { !$0.sessions.isEmpty }
        guard !planWeeks.isEmpty else { throw CoachError(message: "Claude returned an empty plan.") }
        return Plan(createdAt: isoString(Date()), source: "claude", summary: Coach.str(out["summary"], 400), weeks: planWeeks)
    }

    // MARK: Review

    func reviewRuns(_ st: AppState) async throws -> PendingReview {
        let upcoming = Array(st.allSessions().filter { !st.isDone($0.id) }.prefix(9))
        if upcoming.isEmpty {
            return PendingReview(message: "You’ve finished the plan — no changes needed. Congratulations!", changes: [])
        }
        guard let profile = st.profile else { throw CoachError(message: "There’s no plan to review yet.") }

        func kindText(_ h: HistoryEntry) -> String {
            if let id = h.sessionId, !id.isEmpty { return "plan session \(id)" }
            if h.kind == "repeat" { return "repeat of earlier session \"\(h.sessionLabel ?? "")\" — does not advance the plan" }
            if h.kind == "bonus" { return "bonus easy run — does not advance the plan" }
            return "extra custom run — does not advance the plan"
        }
        let recent = st.history.suffix(10).map { h -> String in
            let pct = h.totalSec > 0 ? jsRoundInt(Double(h.doneSec) / Double(h.totalSec) * 100) : 0
            let day = h.dateValue.map(localDay) ?? h.date
            var line = "- \(day) (\(kindText(h))): \(describe(h.workout)); finished \(pct)% (\(h.completed ? "counted as done" : "not counted"));"
            if let x = h.extraSec, x > 0 { line += " kept going \(fmt(x)) after the workout ended;" }
            if let d = h.distM, d > 0 { line += " GPS \(miText(Double(d))) mi;" }
            line += " felt \(h.feel ?? "not rated")"
            if !h.notes.isEmpty { line += "; notes: \"\(h.notes)\"" }
            return line
        }.joined(separator: "\n")

        let prog = st.progress()
        let upcomingText = upcoming.map {
            "\($0.id) (week \($0.week)): runSec=\($0.runSec), walkSec=\($0.walkSec), repeats=\($0.repeats) — \(describe($0.workout))"
        }.joined(separator: "\n")

        let prompt = """
        Review my recent runs and adjust my upcoming sessions only if it would help.

        Today's date: \(todayISO())
        \(Coach.profileText(profile))
        Progress: \(prog.done) of \(prog.total) sessions done. The plan moves forward one session per completed plan run (not by calendar), so falling behind just means it finishes later.

        Recent runs (oldest first):
        \(recent.isEmpty ? "none yet" : recent)

        Upcoming sessions (id: workout):
        \(upcomingText)

        Guidance:
        - If the last run felt hard or I had to stop, ease off or repeat the step. If it felt easy, you may progress a little faster.
        - Look at the dates: after a long gap (7+ days), ease the next session or two; if plan runs were crammed into back-to-back days, slow the progression rather than speeding it up.
        - If things are on track, return an empty "changes" list.
        - Only include sessions you are changing, using ids from the list above. Keep the final 5K run continuous.
        - "message": 2–3 short, encouraging sentences to me explaining what you changed and why (or why nothing needs to change).
        """

        let out = try await ask(prompt, schema: Coach.ADJUST_SCHEMA)
        let byId = Dictionary(upcoming.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let changes: [PlanChange] = (out["changes"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String, let cur = byId[id] else { return nil }
            var note = Coach.str(c["note"], 240)
            if note.isEmpty { note = String(cur.note.prefix(240)) }
            let ch = PlanChange(id: id, runSec: Coach.int(c["runSec"], 15, 3600, 15), walkSec: Coach.int(c["walkSec"], 0, 600, 15),
                                repeats: Coach.int(c["repeats"], 1, 30), note: note)
            let same = cur.runSec == ch.runSec && cur.walkSec == ch.walkSec && cur.repeats == ch.repeats
            return same ? nil : ch
        }
        return PendingReview(message: Coach.str(out["message"], 600), changes: changes, at: isoString(Date()))
    }
}
