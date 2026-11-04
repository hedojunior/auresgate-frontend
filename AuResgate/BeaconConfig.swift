import Foundation
import CoreLocation

enum BeaconConfig {
    static let systemUUID = UUID(uuidString: "D33EE385-1DEA-48FA-AABF-C37A8593C77E")!

    static let regionIdentifier = "com.br.hedo.auresgate"

    static let measuredPowerAt1m: Double = -62.77

    static let pathLossExponent: Double = 1.90

    static let samplingInterval: TimeInterval = 1.0

    static let reliableRangeMeters: Double = 5

    static let opportunisticRangeMeters: Double = 15

    static let detectionCeilingMeters: Double = 22

    static let prototypeIdentity = (major: 1, minor: 1)
}

struct MeasurementSample: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let elapsedSeconds: Double
    let detected: Bool

    let major: Int?
    let minor: Int?
    let rssi: Int?
    let accuracyIOS: Double?
    let accuracyModel: Double?
    let proximity: String?

    let latitude: Double?
    let longitude: Double?
    let speed: Double?
    let course: Double?
    let horizontalAccuracy: Double?

    let appInBackground: Bool

    init(
        beacon: CLBeacon?,
        location: CLLocation?,
        elapsedSeconds: Double,
        appInBackground: Bool
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.elapsedSeconds = elapsedSeconds
        self.detected = beacon != nil && beacon?.rssi != 0
        self.appInBackground = appInBackground

        if let beacon, beacon.rssi != 0 {
            self.major = beacon.major.intValue
            self.minor = beacon.minor.intValue
            self.rssi = beacon.rssi
            self.accuracyIOS = beacon.accuracy > 0 ? beacon.accuracy : nil
            self.accuracyModel = BeaconMath.estimateDistance(rssi: beacon.rssi)
            self.proximity = BeaconMath.describe(beacon.proximity)
        } else {
            self.major = nil
            self.minor = nil
            self.rssi = nil
            self.accuracyIOS = nil
            self.accuracyModel = nil
            self.proximity = nil
        }

        self.latitude = location?.coordinate.latitude
        self.longitude = location?.coordinate.longitude
        self.speed = (location?.speed).flatMap { $0 >= 0 ? $0 : nil }
        self.course = (location?.course).flatMap { $0 >= 0 ? $0 : nil }
        self.horizontalAccuracy = (location?.horizontalAccuracy).flatMap { $0 >= 0 ? $0 : nil }
    }

    var csvRow: String {
        func num(_ value: Double?, _ decimals: Int) -> String {
            value.map { String(format: "%.\(decimals)f", $0) } ?? ""
        }
        func int(_ value: Int?) -> String {
            value.map(String.init) ?? ""
        }

        return [
            MeasurementSample.timestampFormatter.string(from: timestamp),
            String(format: "%.1f", elapsedSeconds),
            detected ? "1" : "0",
            int(major), int(minor), int(rssi),
            num(accuracyIOS, 2), num(accuracyModel, 2),
            proximity ?? "",
            num(latitude, 6), num(longitude, 6),
            num(speed, 2), num(course, 1), num(horizontalAccuracy, 1),
            appInBackground ? "background" : "foreground"
        ].joined(separator: ",")
    }

    static let csvHeader = [
        "timestamp", "elapsed_s", "detected",
        "major", "minor", "rssi",
        "accuracy_ios", "accuracy_model", "proximity",
        "lat", "lon", "speed_mps", "course_deg", "gps_accuracy_m",
        "app_state"
    ].joined(separator: ",")

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum BeaconMath {
    static func estimateDistance(rssi: Int) -> Double {
        guard rssi != 0 else { return -1.0 }
        let ratio = (BeaconConfig.measuredPowerAt1m - Double(rssi))
            / (10.0 * BeaconConfig.pathLossExponent)
        return pow(10.0, ratio)
    }

    static let uncertaintyFactor: Double = pow(
        10.0,
        3.78 / (10.0 * BeaconConfig.pathLossExponent)
    )

    static func uncertaintyRadius(rssi: Int) -> Double {
        let estimate = estimateDistance(rssi: rssi)
        guard estimate > 0 else { return BeaconConfig.opportunisticRangeMeters }

        let upperBound = estimate * uncertaintyFactor
        return min(
            max(upperBound, BeaconConfig.reliableRangeMeters),
            BeaconConfig.detectionCeilingMeters + 3
        )
    }

    static func describe(_ proximity: CLProximity) -> String {
        switch proximity {
        case .immediate: return "immediate"
        case .near:      return "near"
        case .far:       return "far"
        case .unknown:   return "unknown"
        @unknown default: return "unknown"
        }
    }

    static func proximityLabel(rssi: Int) -> String {
        let estimate = estimateDistance(rssi: rssi)
        guard estimate > 0 else { return "sinal instável" }

        if estimate <= BeaconConfig.reliableRangeMeters {
            return "muito perto"
        } else if estimate <= BeaconConfig.opportunisticRangeMeters {
            return "por perto"
        } else {
            return "no limite do alcance"
        }
    }
}

struct BeaconDetection: Identifiable {
    let id = UUID()
    let major: Int
    let minor: Int
    let rssi: Int
    let accuracyIOS: Double
    let proximity: String

    init(beacon: CLBeacon) {
        self.major = beacon.major.intValue
        self.minor = beacon.minor.intValue
        self.rssi = beacon.rssi
        self.accuracyIOS = beacon.accuracy
        self.proximity = BeaconMath.describe(beacon.proximity)
    }
}

struct RSSISmoother {
    private var value: Double?
    let alpha: Double

    init(alpha: Double = 0.1) {
        self.alpha = alpha
    }

    mutating func update(_ raw: Int) -> Double {
        let reading = Double(raw)
        if let current = value {
            value = alpha * reading + (1 - alpha) * current
        } else {
            value = reading
        }
        return value ?? reading
    }

    mutating func reset() {
        value = nil
    }
}
