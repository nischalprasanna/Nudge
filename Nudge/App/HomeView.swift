import SwiftUI

/// Where the app can go from the home screen.
enum Route: Hashable {
    case task
    case perceptionTest
}

/// Home: one action. Everything else is a step away in Settings.
struct HomeView: View {
    @State private var showSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        GeometryReader { proxy in
            let disc = min(proxy.size.width * 0.62, 280)
            ZStack {
                Theme.ink.ignoresSafeArea()

                // The dot field ripples out from behind the Start button.
                DotField(mode: .idle, focus: UnitPoint(x: 0.5, y: 0.5), clearRadius: disc / 2 + 14)
                    .ignoresSafeArea()
                    // Fade the dots out toward the top so the name and the clock sit on clean black.
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0.08),
                                               .init(color: .black, location: 0.26)],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea()
                    }
                    .opacity(appeared ? 1 : 0)

                VStack(spacing: 0) {
                    HStack(alignment: .center) {
                        NudgeWordmark()
                        Spacer()
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Theme.paper)
                                .frame(width: 56, height: 56)
                                .background(Theme.surface, in: Circle())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Settings")
                        .accessibilityHint("Choose sounds, voice and watch feedback")
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 8)
                    .background(Theme.ink.opacity(0.001))

                    Spacer(minLength: 0)
                }

                // Start sits at the true centre of the screen, where the ripples begin.
                NavigationLink(value: Route.task) {
                    ZStack {
                        Circle()
                            .fill(Theme.signal)
                            .frame(width: disc, height: disc)
                        Text("Start")
                            .font(.system(size: disc * 0.2, weight: .heavy, design: .rounded))
                            .foregroundStyle(Theme.ink)
                    }
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.92)
                    .opacity(appeared ? 1 : 0)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Start")
                .accessibilityHint("Opens the camera. Point your phone at a touchscreen and say what you want to do.")
                .accessibilitySortPriority(2)

                VStack {
                    Spacer()
                    Text("Point your phone at a touchscreen, then press Start.")
                        .font(Theme.label(.title3))
                        .foregroundStyle(Theme.paper)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.horizontal, Theme.gutter)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 12) + 12)
                        .accessibilityHidden(true) // The Start button's hint already says this.
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            withAnimation(reduceMotion ? Theme.fade : Theme.arrive) { appeared = true }
            #if targetEnvironment(simulator)
            if UserDefaults.standard.string(forKey: "NudgePreview") == "settings" { showSettings = true }
            #endif
        }
    }
}
