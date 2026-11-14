import SwiftUI

@main
struct NudgeApp: App {
    @StateObject private var watchLink = PhoneWatchLink.shared

    var body: some Scene {
        WindowGroup {
            BootstrapView()
                .environmentObject(watchLink)
                .onAppear { watchLink.start() }
        }
    }
}
