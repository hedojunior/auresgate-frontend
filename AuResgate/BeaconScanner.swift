import Foundation
import CoreLocation
import Combine
import UIKit
import AudioToolbox

@MainActor
final class BeaconScanner: NSObject, ObservableObject {
    @Published private(set) var detections: [BeaconDetection] = []
    @Published private(set) var currentRSSI: Int?
    @Published private(set) var smoothedRSSI: Double?
    @Published private(set) var estimatedDistance: Double?
    @Published private(set) var proximityLabel: String = "—"
    @Published private(set) var isRanging = false
    @Published private(set) var statusMessage = "Aguardando permissão de localização"
    @Published private(set) var authorizationDenied = false

    @Published private(set) var currentSpeed: Double?

    @Published private(set) var secondsSinceLastDetection: Int?

    @Published private(set) var statistics: SessionStatistics = .empty

    @Published var metadata: SessionMetadata = .empty

    @Published var audioFeedbackEnabled: Bool = false

    @Published var smoothingAlpha: Double = 0.1 {
        didSet { smoother = RSSISmoother(alpha: smoothingAlpha) }
    }

    private(set) var sessionLog: [MeasurementSample] = []
    private(set) var sessionStartedAt: Date?

    private let locationManager = CLLocationManager()
    private var smoother = RSSISmoother(alpha: 0.1)
    private var lastKnownLocation: CLLocation?
    private var samplingTimer: Timer?

    private var pendingBeacon: CLBeacon?
    private var lastDetectionAt: Date?

    private var constraint: CLBeaconIdentityConstraint {
        CLBeaconIdentityConstraint(uuid: BeaconConfig.systemUUID)
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .otherNavigation
    }

    func requestPermission() {
        locationManager.requestAlwaysAuthorization()
    }

    func start() {
        guard CLLocationManager.isRangingAvailable() else {
            statusMessage = "Ranging de beacons indisponível neste dispositivo"
            return
        }
        locationManager.startRangingBeacons(satisfying: constraint)
        locationManager.startUpdatingLocation()

        if sessionStartedAt == nil {
            sessionStartedAt = Date()
        }
        startSamplingTimer()

        isRanging = true
        statusMessage = "Procurando beacons…"
    }

    func stop() {
        locationManager.stopRangingBeacons(satisfying: constraint)
        locationManager.stopUpdatingLocation()
        stopSamplingTimer()

        isRanging = false
        statusMessage = "Busca interrompida"
        smoother.reset()
        currentRSSI = nil
        smoothedRSSI = nil
        estimatedDistance = nil
        proximityLabel = "—"
        pendingBeacon = nil
    }

    func clearSession() {
        sessionLog.removeAll()
        detections.removeAll()
        sessionStartedAt = isRanging ? Date() : nil
        statistics = .empty
        lastDetectionAt = nil
        secondsSinceLastDetection = nil
        pendingBeacon = nil
        smoother.reset()
    }

    var elapsedSeconds: TimeInterval {
        guard let start = sessionStartedAt else { return 0 }
        return Date().timeIntervalSince(start)
    }

    private func startSamplingTimer() {
        stopSamplingTimer()
        let timer = Timer(
            timeInterval: BeaconConfig.samplingInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.writeSample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        samplingTimer = timer
    }

    private func stopSamplingTimer() {
        samplingTimer?.invalidate()
        samplingTimer = nil
    }

    private func writeSample() {
        guard isRanging, let start = sessionStartedAt else { return }

        let beacon = pendingBeacon
        pendingBeacon = nil

        let sample = MeasurementSample(
            beacon: beacon,
            location: lastKnownLocation,
            elapsedSeconds: Date().timeIntervalSince(start),
            appInBackground: UIApplication.shared.applicationState != .active
        )
        sessionLog.append(sample)

        if sample.detected {
            lastDetectionAt = sample.timestamp
            if audioFeedbackEnabled {
                AudioFeedback.tick()
            }
        } else {
            currentRSSI = nil
            detections = []
            statusMessage = isRanging ? "Nenhum beacon no alcance" : statusMessage
        }

        secondsSinceLastDetection = lastDetectionAt.map {
            Int(Date().timeIntervalSince($0).rounded())
        }
        currentSpeed = sample.speed
        statistics = SessionStatistics(samples: sessionLog, startedAt: sessionStartedAt)
    }

    func exportCSV() throws -> URL {
        var text = metadata.csvHeaderComment + "\n"
        text += "# amostras=\(statistics.totalRows) detectadas=\(statistics.detectedRows)\n"
        text += String(format: "# taxa_deteccao=%.3f\n", statistics.detectionRate)
        text += MeasurementSample.csvHeader + "\n"
        text += sessionLog.map(\.csvRow).joined(separator: "\n")
        text += "\n"

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: sessionStartedAt ?? Date())
        let filename = "beacon_\(metadata.filenameTag)_\(stamp).csv"

        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)

        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

extension BeaconScanner: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways:
                authorizationDenied = false
                statusMessage = "Permissão concedida (Always)"
                start()
            case .authorizedWhenInUse:
                authorizationDenied = false
                statusMessage = "Permissão apenas em uso — background limitado"
                start()
            case .denied, .restricted:
                authorizationDenied = true
                statusMessage = "Permissão de localização negada"
            case .notDetermined:
                statusMessage = "Aguardando permissão de localização"
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didRange beacons: [CLBeacon],
        satisfying constraint: CLBeaconIdentityConstraint
    ) {
        Task { @MainActor in
            handle(beacons: beacons)
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor in
            lastKnownLocation = locations.last
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            statusMessage = "Erro: \(error.localizedDescription)"
        }
    }

    private func handle(beacons: [CLBeacon]) {
        let usable = beacons.filter { $0.rssi != 0 }

        guard !usable.isEmpty else { return }

        detections = usable
            .map(BeaconDetection.init)
            .sorted { $0.rssi > $1.rssi }

        if let target = usable.max(by: { $0.rssi < $1.rssi }) {
            if let pending = pendingBeacon, pending.rssi >= target.rssi {
            } else {
                pendingBeacon = target
            }

            currentRSSI = target.rssi
            let smoothed = smoother.update(target.rssi)
            smoothedRSSI = smoothed
            estimatedDistance = BeaconMath.estimateDistance(rssi: Int(smoothed.rounded()))
            proximityLabel = BeaconMath.describe(target.proximity)
            statusMessage = "Beacon detectado"
        }
    }
}

enum AudioFeedback {
    static func tick() {
        AudioServicesPlaySystemSound(1103)
    }
}
