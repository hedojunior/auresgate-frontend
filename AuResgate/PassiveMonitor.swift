import Foundation
import CoreLocation
import UIKit

@MainActor
final class PassiveMonitor: NSObject {
    static let shared = PassiveMonitor()

    private let locationManager = CLLocationManager()

    private static let wakeWindow: TimeInterval = 10.0

    private(set) var lastKnownLocation: CLLocation?

    private var wakeTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isRangingInWakeWindow = false

    private var systemRegion: CLBeaconRegion {
        let region = CLBeaconRegion(
            uuid: BeaconConfig.systemUUID,
            identifier: BeaconConfig.regionIdentifier
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        region.notifyEntryStateOnDisplay = true
        return region
    }

    private var constraint: CLBeaconIdentityConstraint {
        CLBeaconIdentityConstraint(uuid: BeaconConfig.systemUUID)
    }

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50
    }

    var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: return "foreground"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    func start(launchReason: PassiveEventLog.Event) {
        PassiveEventLog.shared.record(
            launchReason,
            detail: "auth=\(locationManager.authorizationStatus.rawValue)",
            appState: appState
        )

        guard locationManager.authorizationStatus == .authorizedAlways else {
            PassiveEventLog.shared.record(
                .error,
                detail: "precisa de autorizacao Always para monitoramento passivo",
                appState: appState
            )
            locationManager.requestAlwaysAuthorization()
            return
        }

        beginMonitoring()
    }

    private func beginMonitoring() {
        var enabled: [String] = []

        if CLLocationManager.isMonitoringAvailable(for: CLBeaconRegion.self) {
            locationManager.startMonitoring(for: systemRegion)
            locationManager.requestState(for: systemRegion)
            enabled.append("regiao")
        }

        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            locationManager.startMonitoringSignificantLocationChanges()
            enabled.append("mudanca-significativa")
        }

        locationManager.startMonitoringVisits()
        enabled.append("visitas")

        PassiveEventLog.shared.record(
            .monitoringStarted,
            detail: enabled.joined(separator: "+"),
            appState: appState
        )
    }

    func stop() {
        locationManager.stopMonitoring(for: systemRegion)
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.stopMonitoringVisits()
        endWakeWindow()
    }

    private func beginWakeWindow(trigger: String) {
        guard !isRangingInWakeWindow else { return }
        isRangingInWakeWindow = true

        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "wake-ranging") { [weak self] in
            Task { @MainActor in self?.endWakeWindow() }
        }

        locationManager.startRangingBeacons(satisfying: constraint)
        PassiveEventLog.shared.record(
            .wakeWindowStart,
            detail: trigger,
            appState: appState
        )

        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(PassiveMonitor.wakeWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.endWakeWindow() }
        }
    }

    private func endWakeWindow() {
        guard isRangingInWakeWindow else { return }
        isRangingInWakeWindow = false

        locationManager.stopRangingBeacons(satisfying: constraint)
        wakeTask?.cancel()
        wakeTask = nil

        PassiveEventLog.shared.record(.wakeWindowEnd, appState: appState)

        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

extension PassiveMonitor: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            PassiveEventLog.shared.record(
                .authChange,
                detail: "status=\(manager.authorizationStatus.rawValue)",
                appState: appState
            )
            if manager.authorizationStatus == .authorizedAlways {
                beginMonitoring()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in
            PassiveEventLog.shared.record(
                .regionEnter,
                detail: region.identifier,
                appState: appState
            )
            beginWakeWindow(trigger: "enter")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in
            PassiveEventLog.shared.record(
                .regionExit,
                detail: region.identifier,
                appState: appState
            )
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didDetermineState state: CLRegionState,
        for region: CLRegion
    ) {
        Task { @MainActor in
            let label: String
            switch state {
            case .inside:  label = "inside"
            case .outside: label = "outside"
            case .unknown: label = "unknown"
            @unknown default: label = "unknown"
            }
            PassiveEventLog.shared.record(
                .regionState,
                detail: "\(region.identifier)=\(label)",
                appState: appState
            )
            if state == .inside {
                beginWakeWindow(trigger: "state-inside")
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didRange beacons: [CLBeacon],
        satisfying constraint: CLBeaconIdentityConstraint
    ) {
        Task { @MainActor in
            guard let strongest = beacons.filter({ $0.rssi != 0 }).max(by: { $0.rssi < $1.rssi })
            else { return }
            PassiveEventLog.shared.record(
                .wakeSample,
                detail: "rssi=\(strongest.rssi) major=\(strongest.major) minor=\(strongest.minor)",
                appState: appState
            )

            BackgroundSearchResponder.shared.handleDetection(
                beacon: strongest,
                location: lastKnownLocation ?? locationManager.location
            )
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor in
            guard let location = locations.last else { return }
            lastKnownLocation = location
            PassiveEventLog.shared.record(
                .significantChange,
                detail: String(format: "idade=%.0fs", -location.timestamp.timeIntervalSinceNow),
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                speed: location.speed >= 0 ? location.speed : nil,
                appState: appState
            )

            BackgroundSearchResponder.shared.handleDisplacement(location: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor in
            let arrival = visit.arrivalDate == Date.distantPast ? "?" : "\(visit.arrivalDate)"
            let departure = visit.departureDate == Date.distantFuture ? "?" : "\(visit.departureDate)"
            PassiveEventLog.shared.record(
                .visit,
                detail: "chegada=\(arrival) saida=\(departure)",
                latitude: visit.coordinate.latitude,
                longitude: visit.coordinate.longitude,
                accuracy: visit.horizontalAccuracy,
                appState: appState
            )

            BackgroundSearchResponder.shared.handleDisplacement(
                location: CLLocation(latitude: visit.coordinate.latitude,
                                     longitude: visit.coordinate.longitude)
            )
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            PassiveEventLog.shared.record(
                .error,
                detail: error.localizedDescription,
                appState: appState
            )
        }
    }
}
