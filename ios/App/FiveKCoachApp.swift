import SwiftUI

@main
struct FiveKCoachApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// Phase 1 placeholder: proves the build → TestFlight → iPhone + Watch pipeline works.
struct ContentView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(v) (build \(b))"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.run")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.green)
            Text("5K Coach")
                .font(.largeTitle.bold())
            Text("The native app is on its way.")
                .foregroundStyle(.secondary)
            Text(version)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}
