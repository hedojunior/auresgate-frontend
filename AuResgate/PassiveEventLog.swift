import Foundation

final class PassiveEventLog {
    static let shared = PassiveEventLog()

    enum Event: String {
        case appLaunch = "app_launch"
        case launchByLocation = "launch_by_location"
        case launchByRegion = "launch_by_region"
        case authChange = "auth_change"
        case monitoringStarted = "monitoring_started"
        case regionEnter = "region_enter"
        case regionExit = "region_exit"
        case regionState = "region_state"
        case wakeSample = "wake_sample"
        case wakeWindowStart = "wake_window_start"
        case wakeWindowEnd = "wake_window_end"
        case significantChange = "significant_change"
        case visit = "visit"
        case locationUpdate = "location_update"
        case appStateChange = "app_state_change"
        case backgroundQuery = "background_query"
        case backgroundNotification = "background_notification"
        case error = "error"
    }

    private let queue = DispatchQueue(label: "com.br.hedo.auresgate.passivelog")
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {}

    var fileURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("passive-log.csv")
    }

    static let header = [
        "timestamp", "event", "detail",
        "lat", "lon", "gps_accuracy_m", "speed_mps",
        "app_state"
    ].joined(separator: ",")

    func record(
        _ event: Event,
        detail: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil,
        accuracy: Double? = nil,
        speed: Double? = nil,
        appState: String
    ) {
        let timestamp = formatter.string(from: Date())

        func num(_ value: Double?, _ decimals: Int) -> String {
            value.map { String(format: "%.\(decimals)f", $0) } ?? ""
        }

        let row = [
            timestamp,
            event.rawValue,
            detail.replacingOccurrences(of: ",", with: ";"),
            num(latitude, 6), num(longitude, 6),
            num(accuracy, 1), num(speed, 2),
            appState
        ].joined(separator: ",") + "\n"

        queue.async { [weak self] in
            self?.append(row)
        }
    }

    private func append(_ row: String) {
        let url = fileURL
        let manager = FileManager.default

        guard let data = row.data(using: .utf8) else { return }

        if !manager.fileExists(atPath: url.path) {
            let start = PassiveEventLog.header + "\n" + row
            try? start.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    func rowCount() -> Int {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        return max(0, text.split(separator: "\n").count - 1)
    }

    func tail(_ limit: Int = 12) -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").dropFirst()
        return lines.suffix(limit).reversed().map(String.init)
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }
}
