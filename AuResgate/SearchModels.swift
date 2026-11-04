import Foundation
import CoreLocation

struct PetPayload: Codable, Equatable {
    var name: String
    var breed: String
    var nicknames: [String]
    var note: String
    var major: Int
    var minor: Int
    var photoBase64: String?

    static let empty = PetPayload(
        name: "", breed: "", nicknames: [], note: "",
        major: BeaconConfig.prototypeIdentity.major,
        minor: BeaconConfig.prototypeIdentity.minor,
        photoBase64: nil
    )
}

struct CoordinatePayload: Codable, Equatable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ location: CLLocation) {
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct TrailPointPayload: Codable, Equatable, Identifiable {
    var coordinate: CoordinatePayload
    var timestamp: Date

    var id: Date { timestamp }
}

struct DetectionPayload: Codable, Equatable, Identifiable {
    var id: UUID
    var participantId: UUID
    var participantLabel: String
    var coordinate: CoordinatePayload
    var radiusMeters: Double
    var rssi: Int
    var timestamp: Date
}

struct SearchSummaryPayload: Codable, Equatable, Identifiable {
    var id: UUID
    var petName: String
    var petBreed: String
    var ownerLabel: String
    var startedAt: Date
    var distanceMeters: Double
    var participantCount: Int
    var detectionCount: Int
}

struct SearchStatePayload: Codable, Equatable, Identifiable {
    var id: UUID
    var pet: PetPayload
    var ownerLabel: String
    var origin: CoordinatePayload
    var startedAt: Date
    var closedAt: Date?
    var isOpen: Bool
    var participantCount: Int
    var ownerTrail: [TrailPointPayload]
    var detections: [DetectionPayload]

    var latestDetection: DetectionPayload? { detections.first }

    var previousDetections: [DetectionPayload] {
        detections.dropFirst().reversed()
    }
}

struct StartSearchBody: Encodable {
    var pet: PetPayload
    var ownerId: UUID
    var ownerLabel: String
    var origin: CoordinatePayload
}

struct JoinBody: Encodable {
    var participantId: UUID
    var label: String
}

struct TrailBody: Encodable {
    var ownerId: UUID
    var coordinate: CoordinatePayload
}

struct ReportDetectionBody: Encodable {
    var participantId: UUID
    var participantLabel: String
    var coordinate: CoordinatePayload
    var radiusMeters: Double
    var rssi: Int
}

struct CloseSearchBody: Encodable {
    var ownerId: UUID
    var found: Bool
}

struct SimpleResponsePayload: Decodable {
    var ok: Bool
    var message: String?
}
