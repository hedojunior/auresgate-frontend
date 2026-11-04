import Foundation
import CoreLocation
import UIKit
import UserNotifications

@MainActor
final class BackgroundSearchResponder: NSObject {
    static let shared = BackgroundSearchResponder()

    private static let reportCooldown: TimeInterval = 20

    private static let announceCooldown: TimeInterval = 600

    private static let detectionNotifyCooldown: TimeInterval = 120

    private let defaults = UserDefaults.standard

    private var isResponding = false

    private var lastQueryAt: Date?

    private static let queryInterval: TimeInterval = 10

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                Task { @MainActor in
                    if let error {
                        PassiveEventLog.shared.record(
                            .error,
                            detail: "permissao de notificacao: \(error.localizedDescription)",
                            appState: PassiveMonitor.shared.appState
                        )
                    } else if !granted {
                        PassiveEventLog.shared.record(
                            .error,
                            detail: "notificacoes negadas pelo usuario",
                            appState: PassiveMonitor.shared.appState
                        )
                    }
                }
            }
    }

    func handleDetection(beacon: CLBeacon, location: CLLocation?) {
        guard !isResponding, isQueryDue else { return }

        guard let location else {
            PassiveEventLog.shared.record(
                .backgroundQuery,
                detail: "sem localizacao conhecida, consulta abortada",
                appState: PassiveMonitor.shared.appState
            )
            return
        }

        isResponding = true
        lastQueryAt = Date()

        let task = UIApplication.shared.beginBackgroundTask(withName: "background-search-response")

        Task {
            await respond(beacon: beacon, location: location)
            isResponding = false
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
            }
        }
    }

    func handleDisplacement(location: CLLocation) {
        guard !isResponding, isQueryDue else { return }
        isResponding = true
        lastQueryAt = Date()

        let task = UIApplication.shared.beginBackgroundTask(withName: "background-nearby-query")

        Task {
            await announceNearbySearches(location: location)
            isResponding = false
            if task != .invalid {
                UIApplication.shared.endBackgroundTask(task)
            }
        }
    }

    private func announceNearbySearches(location: CLLocation) async {
        let appState = PassiveMonitor.shared.appState
        let coordinate = CoordinatePayload(location)

        do {
            let nearby = try await SearchAPI.shared.nearbySearches(at: coordinate)

            PassiveEventLog.shared.record(
                .backgroundQuery,
                detail: "deslocamento — \(nearby.count) busca(s) por perto",
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                appState: appState
            )

            for summary in nearby where !isOwnSearch(summary.id) {
                guard isDue(key: Self.announceKey(summary.id),
                            cooldown: Self.announceCooldown)
                else { continue }

                notifyNearbySearch(summary, appState: appState)
                return
            }
        } catch {
            PassiveEventLog.shared.record(
                .error,
                detail: "consulta por deslocamento: \(error.localizedDescription)",
                appState: appState
            )
        }
    }

    private func notifyNearbySearch(_ summary: SearchSummaryPayload, appState: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(summary.petName) está desaparecido por aqui"
        content.body = summary.petBreed.isEmpty
            ? "A busca começou a cerca de \(Int(summary.distanceMeters)) m daqui. Abra o AuResgate para ajudar."
            : "\(summary.petBreed), a cerca de \(Int(summary.distanceMeters)) m daqui. Abra o AuResgate para ajudar."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "nearby-\(summary.id.uuidString)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in
                if let error {
                    PassiveEventLog.shared.record(
                        .error,
                        detail: "notificacao de busca proxima: \(error.localizedDescription)",
                        appState: appState
                    )
                } else {
                    PassiveEventLog.shared.record(
                        .backgroundNotification,
                        detail: "busca proxima anunciada — \(summary.petName)",
                        appState: appState
                    )
                }
            }
        }

        stamp(key: Self.announceKey(summary.id))
    }

    func rememberOwnSearch(_ id: UUID) {
        var ids = defaults.stringArray(forKey: Self.ownSearchesKey) ?? []
        guard !ids.contains(id.uuidString) else { return }
        ids.append(id.uuidString)
        defaults.set(Array(ids.suffix(20)), forKey: Self.ownSearchesKey)
    }

    private func isOwnSearch(_ id: UUID) -> Bool {
        (defaults.stringArray(forKey: Self.ownSearchesKey) ?? []).contains(id.uuidString)
    }

    private static let ownSearchesKey = "bg.ownSearches"

    private func respond(beacon: CLBeacon, location: CLLocation) async {
        let appState = PassiveMonitor.shared.appState
        let coordinate = CoordinatePayload(location)
        let major = beacon.major.intValue
        let minor = beacon.minor.intValue

        do {
            let nearby = try await SearchAPI.shared.nearbySearches(at: coordinate)

            PassiveEventLog.shared.record(
                .backgroundQuery,
                detail: "beacon \(major)/\(minor) — \(nearby.count) busca(s) por perto",
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                appState: appState
            )

            for summary in nearby {
                let state = try await SearchAPI.shared.searchState(id: summary.id)
                guard state.pet.major == major, state.pet.minor == minor else { continue }

                try await report(state: state, beacon: beacon, coordinate: coordinate, appState: appState)
                notifyIfDue(state: state, appState: appState)
                return
            }
        } catch {
            PassiveEventLog.shared.record(
                .error,
                detail: "resposta em background: \(error.localizedDescription)",
                appState: appState
            )
        }
    }

    private func report(
        state: SearchStatePayload,
        beacon: CLBeacon,
        coordinate: CoordinatePayload,
        appState: String
    ) async throws {
        guard isDue(key: Self.reportKey(state.id), cooldown: Self.reportCooldown) else { return }

        if !isOwnSearch(state.id) {
            _ = try await SearchAPI.shared.join(
                searchId: state.id,
                body: JoinBody(participantId: ServerConfig.deviceId, label: ServerConfig.deviceLabel)
            )
        }

        _ = try await SearchAPI.shared.reportDetection(
            searchId: state.id,
            body: ReportDetectionBody(
                participantId: ServerConfig.deviceId,
                participantLabel: ServerConfig.deviceLabel,
                coordinate: coordinate,
                radiusMeters: BeaconMath.uncertaintyRadius(rssi: beacon.rssi),
                rssi: beacon.rssi
            )
        )

        stamp(key: Self.reportKey(state.id))

        PassiveEventLog.shared.record(
            .backgroundQuery,
            detail: "deteccao reportada para \(state.pet.name) — rssi=\(beacon.rssi)",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            appState: appState
        )
    }

    private func notifyIfDue(state: SearchStatePayload, appState: String) {
        guard isDue(key: Self.detectionKey(state.id),
                    cooldown: Self.detectionNotifyCooldown) else { return }

        let isOwn = isOwnSearch(state.id)
        let callThem = state.pet.nicknames.isEmpty
            ? state.pet.name
            : state.pet.nicknames.joined(separator: " ou ")

        let content = UNMutableNotificationContent()
        content.title = "Sinal de \(state.pet.name) por perto"
        content.body = isOwn
            ? "O sinal está ao alcance daqui. Chame por \(callThem)."
            : "Chame por \(callThem). Abra o AuResgate para ajudar."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "detection-\(state.id.uuidString)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in
                if let error {
                    PassiveEventLog.shared.record(
                        .error,
                        detail: "notificacao local: \(error.localizedDescription)",
                        appState: appState
                    )
                } else {
                    PassiveEventLog.shared.record(
                        .backgroundNotification,
                        detail: "notificacao entregue — \(state.pet.name)",
                        appState: appState
                    )
                }
            }
        }

        stamp(key: Self.detectionKey(state.id))
    }

    private static func reportKey(_ id: UUID) -> String { "bg.report.\(id.uuidString)" }
    private static func announceKey(_ id: UUID) -> String { "bg.notify.nearby.\(id.uuidString)" }
    private static func detectionKey(_ id: UUID) -> String { "bg.notify.signal.\(id.uuidString)" }

    private var isQueryDue: Bool {
        guard let lastQueryAt else { return true }
        return Date().timeIntervalSince(lastQueryAt) >= Self.queryInterval
    }

    private func isDue(key: String, cooldown: TimeInterval) -> Bool {
        let last = defaults.double(forKey: key)
        guard last > 0 else { return true }
        return Date().timeIntervalSince1970 - last >= cooldown
    }

    private func stamp(key: String) {
        defaults.set(Date().timeIntervalSince1970, forKey: key)
    }
}

extension BackgroundSearchResponder: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
