import SwiftUI

@main
struct NudgeApp: App {
    @StateObject private var watchLink = PhoneWatchLink.shared
    @State private var path: [Route] = NudgeApp.initialPath
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    /// Normally the app opens on the home screen. In the simulator, a `-NudgePreview <state>`
    /// launch argument opens the task screen in a fixed state for checking layouts.
    private static var initialPath: [Route] {
        #if targetEnvironment(simulator)
        if let state = UserDefaults.standard.string(forKey: "NudgePreview"), state != "home", state != "settings" {
            return [.task]
        }
        #endif
        // Worn on the chest, nothing can be pressed: open straight into the task screen, which
        // starts by asking aloud what to do. The home screen is still one step back.
        if UserDefaults.standard.bool(forKey: "wornOnChest") { return [.task] }
        return []
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                HomeView()
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .task: TaskView()
                        case .perceptionTest: PerceptionTestView()
                        }
                    }
            }
            .environmentObject(watchLink)
            .preferredColorScheme(.dark)
            .tint(Theme.signal)
            .onAppear { watchLink.start() }
            .onChange(of: scenePhase) { _, phase in
                // Reopened (by voice, say) while sitting on the home screen: go hands-free again.
                if phase == .background { wasInBackground = true }
                if phase == .active, wasInBackground {
                    wasInBackground = false
                    if UserDefaults.standard.bool(forKey: "wornOnChest"), path.isEmpty { path = [.task] }
                }
            }
        }
    }
}
