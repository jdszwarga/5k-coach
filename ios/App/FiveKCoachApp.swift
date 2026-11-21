import SwiftUI
import CoachCore

@main
struct FiveKCoachApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(.run)
        }
    }
}

/// Plan setup until there's a plan (or while editing it), otherwise the four tabs.
/// The run setup sheet, the run screen and the toast hang off the root so any tab can open them.
struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.state.plan == nil || model.editingPlan {
                PlanSetupView()
            } else {
                MainTabs()
            }
        }
        .sheet(item: $model.setup, onDismiss: { model.launchPendingRun() }) { req in
            RunSetupView(info: model.setupInfo(req))
        }
        .fullScreenCover(item: $model.run) { engine in
            RunFlowView(engine: engine)
        }
        .overlay(alignment: .top) { ToastView() }
    }
}

struct MainTabs: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.tab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(AppModel.Tab.today)
            PlanView()
                .tabItem { Label("Plan", systemImage: "calendar") }
                .tag(AppModel.Tab.plan)
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppModel.Tab.history)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(AppModel.Tab.settings)
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let msg = model.toast {
            Text(msg)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(msg)
        }
    }
}
