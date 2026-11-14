import SwiftUI

@main
struct NudgeApp: App {
    @StateObject private var watchLink = PhoneWatchLink.shared

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                BootstrapView()
            }
            .environmentObject(watchLink)
            .onAppear { watchLink.start() }
        }
    }
}
