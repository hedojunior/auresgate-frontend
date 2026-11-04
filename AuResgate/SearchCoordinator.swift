import Foundation
import CoreLocation
import Combine

@MainActor
final class SearchCoordinator: NSObject, ObservableObject {
    enum Role: Equatable {
        case owner
        case participant
    }

    @Published private(set) var canWakeInBackground = true

    @Published private(set) var role: Role = .participant
    @Published private(set) var state: SearchStatePayload?
    @Published private(set) var nearby: [SearchSummaryPayload] = []
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = "Aguardando localização"
    @Published private(set) var errorMessage: String?

    @Published private(set) var currentRSSI: Int?
    @Published private(set) var smoothedRSSI: Double?
    @Published private(set) var proximityLabel: String?
    @Published private(set) var secondsSinceLastDetection: Int?

    @Published private(set) var lastReportedAt: Date?
    @Published private(set) var currentLocation: CLLocation?

    private let api = SearchAPI.shared
    private let locationManager = CLLocationManager()
    private var smoother = RSSISmoother(alpha: 0.1)

    private var pollTask: Task<Void, Never>?
    private var trailTask: Task<Void, Never>?
    private var lastDetectionAt: Date?

    private var targetIdentity: (major: Int, minor: Int)?

    private static let reportCooldown: TimeInterval = 20

    private var constraint: CLBeaconIdentityConstraint {
        CLBeaconIdentityConstraint(uuid: BeaconConfig.systemUUID)
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .otherNavigation
    }

    func requestPermission() {
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
        canWakeInBackground = locationManager.authorizationStatus == .authorizedAlways
    }

    func refreshNearby() async {
        guard let location = currentLocation else {
            statusMessage = "Aguardando localização"
            return
        }
        do {
            nearby = try await api.nearbySearches(at: CoordinatePayload(location))
            statusMessage = nearby.isEmpty
                ? "Nenhuma busca ativa por aqui"
                : "\(nearby.count) busca(s) ativa(s) nas proximidades"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startSearch(pet: PetPayload) async {
        guard let location = currentLocation else {
            errorMessage = "Sem localização para iniciar a busca."
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let body = StartSearchBody(
                pet: pet,
                ownerId: ServerConfig.deviceId,
                ownerLabel: ServerConfig.deviceLabel,
                origin: CoordinatePayload(location)
            )
            let created = try await api.startSearch(body)
            role = .owner
            state = created
            BackgroundSearchResponder.shared.rememberOwnSearch(created.id)
            errorMessage = nil
            beginActiveSession(for: created)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeSearch(found: Bool) async {
        guard let search = state, role == .owner else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let body = CloseSearchBody(ownerId: ServerConfig.deviceId, found: found)
            state = try await api.closeSearch(searchId: search.id, body: body)
        } catch {
            errorMessage = error.localizedDescription
        }
        endActiveSession()
    }

    func join(searchId: UUID) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let body = JoinBody(
                participantId: ServerConfig.deviceId,
                label: ServerConfig.deviceLabel
            )
            let joined = try await api.join(searchId: searchId, body: body)
            role = .participant
            state = joined
            errorMessage = nil
            beginActiveSession(for: joined)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func leave() async {
        guard let search = state else { return }
        let body = JoinBody(
            participantId: ServerConfig.deviceId,
            label: ServerConfig.deviceLabel
        )
        _ = try? await api.leave(searchId: search.id, body: body)
        endActiveSession()
        state = nil
    }

    private func beginActiveSession(for search: SearchStatePayload) {
        targetIdentity = (search.pet.major, search.pet.minor)
        smoother.reset()
        lastDetectionAt = nil
        lastReportedAt = nil

        locationManager.startRangingBeacons(satisfying: constraint)
        startPolling()
        if role == .owner { startTrailReporting() }

        statusMessage = "Busca ativa — procurando \(search.pet.name)"
    }

    private func endActiveSession() {
        locationManager.stopRangingBeacons(satisfying: constraint)
        pollTask?.cancel(); pollTask = nil
        trailTask?.cancel(); trailTask = nil

        targetIdentity = nil
        currentRSSI = nil
        smoothedRSSI = nil
        proximityLabel = nil
        secondsSinceLastDetection = nil
        statusMessage = "Busca encerrada"
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(ServerConfig.pollInterval * 1_000_000_000))
            }
        }
    }

    private func pollOnce() async {
        guard let search = state else { return }
        do {
            if role == .participant {
                let body = JoinBody(
                    participantId: ServerConfig.deviceId,
                    label: ServerConfig.deviceLabel
                )
                state = try await api.join(searchId: search.id, body: body)
            } else {
                state = try await api.searchState(id: search.id)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        if let updated = state, !updated.isOpen {
            endActiveSession()
        }
    }

    private func startTrailReporting() {
        trailTask?.cancel()
        trailTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                await self?.sendTrailPoint()
            }
        }
    }

    private func sendTrailPoint() async {
        guard role == .owner,
              let search = state, search.isOpen,
              let location = currentLocation
        else { return }

        let body = TrailBody(
            ownerId: ServerConfig.deviceId,
            coordinate: CoordinatePayload(location)
        )
        if let updated = try? await api.appendTrail(searchId: search.id, body: body) {
            state = updated
        }
    }

    func reportDetection(automatic: Bool) async {
        guard let search = state, search.isOpen,
              let rssi = currentRSSI,
              let location = currentLocation
        else { return }

        if automatic, let last = lastReportedAt,
           Date().timeIntervalSince(last) < SearchCoordinator.reportCooldown {
            return
        }

        let body = ReportDetectionBody(
            participantId: ServerConfig.deviceId,
            participantLabel: ServerConfig.deviceLabel,
            coordinate: CoordinatePayload(location),
            radiusMeters: BeaconMath.uncertaintyRadius(rssi: rssi),
            rssi: rssi
        )

        do {
            state = try await api.reportDetection(searchId: search.id, body: body)
            lastReportedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension SearchCoordinator: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor in
            currentLocation = locations.last
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

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            canWakeInBackground = manager.authorizationStatus == .authorizedAlways

            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
                statusMessage = "Localização autorizada"
            case .denied, .restricted:
                errorMessage = "Permissão de localização negada — a busca precisa dela."
            case .notDetermined:
                statusMessage = "Aguardando permissão de localização"
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            errorMessage = error.localizedDescription
        }
    }

    private func handle(beacons: [CLBeacon]) {
        guard let target = targetIdentity else { return }

        let matches = beacons.filter {
            $0.rssi != 0
                && $0.major.intValue == target.major
                && $0.minor.intValue == target.minor
        }

        guard let strongest = matches.max(by: { $0.rssi < $1.rssi }) else {
            secondsSinceLastDetection = lastDetectionAt.map {
                Int(Date().timeIntervalSince($0).rounded())
            }
            currentRSSI = nil
            return
        }

        lastDetectionAt = Date()
        secondsSinceLastDetection = 0
        currentRSSI = strongest.rssi

        let smoothed = smoother.update(strongest.rssi)
        smoothedRSSI = smoothed
        proximityLabel = BeaconMath.proximityLabel(rssi: Int(smoothed.rounded()))

        Task { await reportDetection(automatic: true) }
    }
}
