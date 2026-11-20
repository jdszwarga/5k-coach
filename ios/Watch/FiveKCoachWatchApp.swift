import SwiftUI

@main
struct FiveKCoachWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchHomeView()
        }
    }
}

// Phase 1 placeholder: confirms the Watch app installs alongside the iPhone app.
struct WatchHomeView: View {
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.run")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.green)
            Text("5K Coach")
                .font(.headline)
            Text("Build \(build)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
