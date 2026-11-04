import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum ServerConfig {
    static let baseURL = URL(string: "https://auresgate-backend-production.up.railway.app")!

    static let apiKey = ProcessInfo.processInfo.environment["AURESGATE_API_KEY"] ?? ""

    static let nearbyRadiusMeters: Double = 2_000

    static let pollInterval: TimeInterval = 4

    static var deviceId: UUID {
        let key = "auresgate.deviceId"
        if let stored = UserDefaults.standard.string(forKey: key),
           let id = UUID(uuidString: stored) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    static var deviceLabel: String {
        let key = "auresgate.deviceLabel"
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
            return stored
        }
        let suffix = deviceId.uuidString.prefix(4)
        return "\(UIDevice.current.model) \(suffix)"
    }
}

enum APIError: LocalizedError {
    case badStatus(Int, String?)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let reason):
            return reason ?? "O servidor respondeu \(code)."
        case .transport(let error):
            return "Falha de rede: \(error.localizedDescription)"
        case .decoding(let error):
            return "Resposta inesperada do servidor: \(error.localizedDescription)"
        }
    }
}

actor SearchAPI {
    static let shared = SearchAPI()

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseURL: URL = ServerConfig.baseURL) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        self.decoder = decoder
    }

    private let baseURL: URL

    func health() async throws -> SimpleResponsePayload {
        try await get("api/health")
    }

    func startSearch(_ body: StartSearchBody) async throws -> SearchStatePayload {
        try await post("api/searches", body: body)
    }

    func nearbySearches(
        at coordinate: CoordinatePayload,
        radiusMeters: Double = ServerConfig.nearbyRadiusMeters
    ) async throws -> [SearchSummaryPayload] {
        try await get(
            "api/searches/nearby",
            query: [
                URLQueryItem(name: "lat", value: String(coordinate.latitude)),
                URLQueryItem(name: "lon", value: String(coordinate.longitude)),
                URLQueryItem(name: "radius", value: String(Int(radiusMeters)))
            ]
        )
    }

    func searchState(id: UUID) async throws -> SearchStatePayload {
        try await get("api/searches/\(id.uuidString)")
    }

    func join(searchId: UUID, body: JoinBody) async throws -> SearchStatePayload {
        try await post("api/searches/\(searchId.uuidString)/join", body: body)
    }

    func leave(searchId: UUID, body: JoinBody) async throws -> SimpleResponsePayload {
        try await post("api/searches/\(searchId.uuidString)/leave", body: body)
    }

    func reportDetection(
        searchId: UUID,
        body: ReportDetectionBody
    ) async throws -> SearchStatePayload {
        try await post("api/searches/\(searchId.uuidString)/detections", body: body)
    }

    func appendTrail(searchId: UUID, body: TrailBody) async throws -> SearchStatePayload {
        try await post("api/searches/\(searchId.uuidString)/trail", body: body)
    }

    func closeSearch(searchId: UUID, body: CloseSearchBody) async throws -> SearchStatePayload {
        try await post("api/searches/\(searchId.uuidString)/close", body: body)
    }

    private func get<Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await send(request)
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        var request = request
        request.setValue(ServerConfig.apiKey, forHTTPHeaderField: "X-AuResgate-Key")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 {
                throw APIError.badStatus(
                    401,
                    "Chave de API recusada. Confira se ServerConfig.apiKey "
                    + "é igual à AURESGATE_API_KEY do servidor."
                )
            }
            let reason = (try? JSONDecoder().decode(VaporError.self, from: data))?.reason
            throw APIError.badStatus(http.statusCode, reason)
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    private struct VaporError: Decodable {
        let reason: String?
    }
}

extension JSONEncoder.DateEncodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.fractional.string(from: date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: Self {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: text) {
                return date
            }
            if let date = ISO8601DateFormatter.plain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Data em formato não reconhecido: \(text)"
            )
        }
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
