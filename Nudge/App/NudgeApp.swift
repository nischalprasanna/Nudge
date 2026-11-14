import SwiftUI

@main
struct NudgeApp: App {
    @StateObject private var watchLink = PhoneWatchLink.shared
    @State private var path: [Route] = NudgeApp.initialPath

    /// Normally the app opens on the home screen. In the simulator, a `-NudgePreview <state>`
    /// launch argument opens the task screen in a fixed state for checking layouts.
    private static var initialPath: [Route] {
        #if targetEnvironment(simulator)
        if let state = UserDefaults.standard.string(forKey: "NudgePreview"), state != "home", state != "settings" {
            return [.task]
        }
        #endif
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
        }
    }
}
