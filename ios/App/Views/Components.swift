import SwiftUI
import MapKit
import CoachCore

extension Color {
    static let run = Color.green
    static let walk = Color.blue
    static let warm = Color.orange
    static let card = Color(.secondarySystemGroupedBackground)
    static let page = Color(.systemGroupedBackground)
}

func feelColor(_ id: String) -> Color {
    switch id {
    case "easy": return .green
    case "right": return .blue
    case "hard": return .orange
    default: return .red
    }
}

/// Progress ring.
struct Ring: View {
    var pct: Double
    var size: CGFloat = 64
    var stroke: CGFloat = 8
    var color: Color = .run

    var body: some View {
        ZStack {
            Circle().stroke(Color(.systemFill), lineWidth: stroke)
            Circle()
                .trim(from: 0, to: max(0, min(1, pct)))
                .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(stroke / 2)
        .frame(width: size, height: size)
    }
}

/// The workout as coloured blocks: green runs, blue walks, widths by duration.
struct Blocks: View {
    let segs: [Segment]
    var height: CGFloat = 10
    /// Fraction done, shaded (the run screen's timeline).
    var done: Double? = nil

    init(_ wk: Workout, height: CGFloat = 10) { segs = segmentsFor(wk); self.height = height }
    init(segs: [Segment], height: CGFloat, done: Double?) { self.segs = segs; self.height = height; self.done = done }

    var body: some View {
        GeometryReader { geo in
            let total = CGFloat(max(1, segs.reduce(0) { $0 + $1.dur }))
            let gap: CGFloat = segs.count > 40 ? 1 : 2
            let avail = max(0, geo.size.width - gap * CGFloat(max(0, segs.count - 1)))
            ZStack(alignment: .leading) {
                HStack(spacing: gap) {
                    ForEach(Array(segs.enumerated()), id: \.offset) { _, s in
                        RoundedRectangle(cornerRadius: min(3, height / 3))
                            .fill(s.type == .run ? Color.run : Color.walk)
                            .frame(width: avail * CGFloat(s.dur) / total)
                    }
                }
                if let done {
                    Rectangle().fill(Color.black.opacity(0.45))
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, done))))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: min(3, height / 3)))
    }
}

/// A rounded card like the web app's.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct Eyebrow: View {
    let text: String
    var color: Color = .run
    init(_ text: String, color: Color = .run) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.bold)).foregroundStyle(color).tracking(0.5)
    }
}

struct FeelPill: View {
    let feel: String?
    var body: some View {
        if let f = feel, let label = feelLabel(f) {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(feelColor(f))
                .background(feelColor(f).opacity(0.15), in: Capsule())
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = .run
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Route map: solid lines for the track, dashed straight lines across GPS gaps.
struct RouteMap: View {
    let track: Track
    var height: CGFloat = 220

    var body: some View {
        let ps = pieces(track)
        let all = ps.flatMap(\.line)
        Map(initialPosition: .automatic) {
            ForEach(Array(ps.enumerated()), id: \.offset) { _, p in
                MapPolyline(coordinates: p.line.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) })
                    .stroke(Color.run, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: p.dashed ? [6, 8] : []))
            }
            if let first = all.first {
                Annotation("Start", coordinate: CLLocationCoordinate2D(latitude: first.lat, longitude: first.lng)) {
                    Circle().fill(Color.run).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2))
                }
                .annotationTitles(.hidden)
            }
            if let last = all.last, all.count > 1 {
                Annotation("Finish", coordinate: CLLocationCoordinate2D(latitude: last.lat, longitude: last.lng)) {
                    Circle().fill(Color.red).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Distance, pace and route for a run (history detail and the post-run summary).
struct GpsBlock: View {
    let distM: Int
    let pace: Double?
    let track: Track?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                stat("Distance", miText(Double(distM)), " mi")
                stat("Avg pace", pace.map { fmt($0) } ?? "—", " /mi")
                Spacer()
            }
            if let track, !track.pts.isEmpty { RouteMap(track: track) }
            if let gaps = track?.gap, !gaps.isEmpty {
                Text("Dashed lines are GPS gaps, joined with a straight line.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ k: String, _ v: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            (Text(v).font(.title2.weight(.bold)).monospacedDigit() + Text(unit).font(.subheadline).foregroundStyle(.secondary))
        }
    }
}
