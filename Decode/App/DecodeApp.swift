import SwiftUI
import os.log

private let appLog = Logger(subsystem: "com.decode.app", category: "app-diag")

/// The main entry point for the Decode application.
///
/// Uses the SwiftUI App lifecycle. Instantiates the root dependency container
/// and passes it into the view hierarchy via the environment.
///
/// ## Activation-Safe Startup
/// `AppDependencies.init()` is lightweight — only object construction.
/// All activation-sensitive work (Keychain, Accessibility, event monitors)
/// is deferred until `NSApplication.didBecomeActiveNotification` fires,
/// ensuring the run loop, responder chain, and menu bar are fully initialized.
@main
struct DecodeApp: App {

    @State private var dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(dependencies)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.didBecomeActiveNotification
                    )
                ) { _ in
                    appLog.notice("[DIAG] didBecomeActiveNotification received")
                    dependencies.performDeferredStartup()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.willTerminateNotification
                    )
                ) { _ in
                    appLog.notice("[DIAG] willTerminateNotification received")
                    // IAG-003 §4.2: Shutdown understanding pipeline on app termination.
                    // Task.detached avoids @MainActor inheritance — pipeline has no @MainActor (IAG-003 §6.3).
                    let system = dependencies.understandingSystem
                    Task.detached {
                        await system.shutdown()
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("Welcome to Decode...") {
                    OnboardingState.reset()
                    NotificationCenter.default.post(
                        name: .showOnboarding,
                        object: nil
                    )
                }
            }
        }

        Settings {
            SettingsView()
                .environment(dependencies)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the user selects "Welcome to Decode..." from the Help menu.
    static let showOnboarding = Notification.Name("showOnboarding")
}
