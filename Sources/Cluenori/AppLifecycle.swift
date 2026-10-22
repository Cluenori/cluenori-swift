import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// Tells the engine when the app comes to the foreground and goes to the background, from UIKit's
/// notifications and from the app's state as it starts the SDK, and gives it time to send what
/// waits as the app goes. Elsewhere, such as in tests
/// on a Mac, nothing tells it: tests do.
@MainActor
enum AppLifecycle {
    private static var observers: [any NSObjectProtocol] = []

    static func observe(_ engine: Engine) {
        #if canImport(UIKit)
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            // Becoming active again without leaving the foreground, as after Control Center, changes
            // nothing in the session.
            let active = center.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                engine.foreground()
            }
            let background = center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { _ in
                engine.background()
                MainActor.assumeIsolated { sendInBackground(engine) }
            }
            observers = [active, background]
            // Launched into the foreground, the app is there already as it starts the SDK, before
            // its first activation, and its first screen may appear before that activation too.
            if UIApplication.shared.applicationState != .background { engine.foreground() }
        #endif
    }

    #if canImport(UIKit)
        /// Asks iOS for time to send what waits, and gives it back when done or when iOS says time is
        /// up; what isn't sent then goes at the next launch or resume, with the same IDs.
        private static func sendInBackground(_ engine: Engine) {
            let application = UIApplication.shared
            let ending = BackgroundTaskEnd(application: application)
            let identifier = application.beginBackgroundTask(withName: "Cluenori") {
                ending.end()
            }
            guard identifier != .invalid else { return }
            ending.identifier = identifier
            Task {
                await engine.flush()
                ending.end()
            }
        }

        /// Ends a background task once, from whichever ends first: the sending or iOS's deadline.
        @MainActor
        private final class BackgroundTaskEnd {
            let application: UIApplication
            var identifier: UIBackgroundTaskIdentifier = .invalid

            init(application: UIApplication) {
                self.application = application
            }

            func end() {
                guard identifier != .invalid else { return }
                application.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }
    #endif
}
