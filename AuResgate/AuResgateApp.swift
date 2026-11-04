import SwiftUI
import UIKit

@main
struct AuResgateApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let reason: PassiveEventLog.Event
        if launchOptions?[.location] != nil {
            reason = .launchByLocation
        } else {
            reason = .appLaunch
        }

        Task { @MainActor in
            PassiveMonitor.shared.start(launchReason: reason)
            BackgroundSearchResponder.shared.requestNotificationPermission()
        }

        registerLifecycleObservers()
        return true
    }

    private func registerLifecycleObservers() {
        let center = NotificationCenter.default

        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            PassiveEventLog.shared.record(
                .appStateChange, detail: "entrou em background", appState: "background"
            )
        }

        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            PassiveEventLog.shared.record(
                .appStateChange, detail: "voltou ao foreground", appState: "foreground"
            )
        }

        center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            PassiveEventLog.shared.record(
                .appStateChange, detail: "encerrando", appState: "background"
            )
        }
    }
}
