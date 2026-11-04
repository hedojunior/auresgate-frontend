import Foundation

struct SessionMetadata: Codable {
    var testType: TestType

    var referenceDistance: Double?

    var environment: Environment

    var motionMode: MotionMode

    var runIndex: Int

    var onCollar: Bool

    var wifiEnabled: Bool

    var obstacle: String

    var note: String

    enum TestType: String, Codable, CaseIterable {
        case calibration = "calibracao"
        case rangeProfile = "alcance"
        case obstacle = "obstaculo"
        case motion = "movimento"

        var displayName: String {
            switch self {
            case .calibration:  return "Calibração (1 m)"
            case .rangeProfile: return "Alcance máximo"
            case .obstacle:     return "Obstáculo"
            case .motion:       return "Movimento"
            }
        }
    }

    enum MotionMode: String, Codable, CaseIterable {
        case stationary = "parado"
        case walking = "caminhando"
        case running = "correndo"
        case cycling = "bicicleta"
        case driving = "carro"

        var displayName: String {
            switch self {
            case .stationary: return "Parado"
            case .walking:    return "Caminhando"
            case .running:    return "Correndo"
            case .cycling:    return "Bicicleta"
            case .driving:    return "Carro"
            }
        }
    }

    enum Environment: String, Codable, CaseIterable {
        case indoorCluttered = "interno-com-eletronicos"
        case indoorClean = "interno-limpo"
        case outdoorOpen = "externo-aberto"
        case outdoorVegetation = "externo-com-vegetacao"
        case outdoorUrban = "externo-urbano"

        var displayName: String {
            switch self {
            case .indoorCluttered:    return "Interno (com eletrônicos)"
            case .indoorClean:        return "Interno (limpo)"
            case .outdoorOpen:        return "Externo (aberto)"
            case .outdoorVegetation:  return "Externo (com vegetação)"
            case .outdoorUrban:       return "Externo (urbano)"
            }
        }
    }

    static let empty = SessionMetadata(
        testType: .calibration,
        referenceDistance: nil,
        environment: .indoorCluttered,
        motionMode: .stationary,
        runIndex: 1,
        onCollar: false,
        wifiEnabled: true,
        obstacle: "nenhum",
        note: ""
    )

    var filenameTag: String {
        let distance = referenceDistance.map { String(format: "%.0fm", $0) } ?? "nd"
        return "\(testType.rawValue)_\(environment.rawValue)_\(motionMode.rawValue)_\(distance)_r\(runIndex)"
    }

    var csvHeaderComment: String {
        let distance = referenceDistance.map { String(format: "%.2f", $0) } ?? "desconhecida"
        return """
        # tipo_teste=\(testType.rawValue)
        # distancia_referencia_m=\(distance)
        # ambiente=\(environment.rawValue)
        # modo_movimento=\(motionMode.rawValue)
        # repeticao=\(runIndex)
        # na_coleira=\(onCollar)
        # wifi_ativo=\(wifiEnabled)
        # obstaculo=\(obstacle)
        # rssi_1m_configurado=\(BeaconConfig.measuredPowerAt1m)
        # expoente_perda=\(BeaconConfig.pathLossExponent)
        # observacao=\(note)
        """
    }
}

struct SessionStatistics {
    let totalRows: Int
    let detectedRows: Int
    let elapsedSeconds: TimeInterval
    let meanRSSI: Double
    let medianRSSI: Double
    let minRSSI: Int
    let maxRSSI: Int
    let standardDeviation: Double
    let meanAccuracyIOS: Double
    let meanAccuracyModel: Double
    let meanSpeed: Double?
    let maxSpeed: Double?

    static let empty = SessionStatistics(
        totalRows: 0, detectedRows: 0, elapsedSeconds: 0,
        meanRSSI: 0, medianRSSI: 0, minRSSI: 0, maxRSSI: 0,
        standardDeviation: 0, meanAccuracyIOS: 0, meanAccuracyModel: 0,
        meanSpeed: nil, maxSpeed: nil
    )

    var detectionRate: Double {
        totalRows > 0 ? Double(detectedRows) / Double(totalRows) : 0
    }

    var amplitude: Int { maxRSSI - minRSSI }

    var longestGapSeconds: Int

    init(
        totalRows: Int, detectedRows: Int, elapsedSeconds: TimeInterval,
        meanRSSI: Double, medianRSSI: Double, minRSSI: Int, maxRSSI: Int,
        standardDeviation: Double, meanAccuracyIOS: Double,
        meanAccuracyModel: Double, meanSpeed: Double?, maxSpeed: Double?,
        longestGapSeconds: Int = 0
    ) {
        self.totalRows = totalRows
        self.detectedRows = detectedRows
        self.elapsedSeconds = elapsedSeconds
        self.meanRSSI = meanRSSI
        self.medianRSSI = medianRSSI
        self.minRSSI = minRSSI
        self.maxRSSI = maxRSSI
        self.standardDeviation = standardDeviation
        self.meanAccuracyIOS = meanAccuracyIOS
        self.meanAccuracyModel = meanAccuracyModel
        self.meanSpeed = meanSpeed
        self.maxSpeed = maxSpeed
        self.longestGapSeconds = longestGapSeconds
    }

    init(samples: [MeasurementSample], startedAt: Date?) {
        guard !samples.isEmpty else {
            self = .empty
            return
        }

        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let detected = samples.filter(\.detected)

        var longestGap = 0
        var currentGap = 0
        for sample in samples {
            if sample.detected {
                currentGap = 0
            } else {
                currentGap += 1
                longestGap = max(longestGap, currentGap)
            }
        }

        let speeds = samples.compactMap(\.speed)
        let meanSpeed = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)
        let maxSpeed = speeds.max()

        guard !detected.isEmpty else {
            self.init(
                totalRows: samples.count, detectedRows: 0, elapsedSeconds: elapsed,
                meanRSSI: 0, medianRSSI: 0, minRSSI: 0, maxRSSI: 0,
                standardDeviation: 0, meanAccuracyIOS: 0, meanAccuracyModel: 0,
                meanSpeed: meanSpeed, maxSpeed: maxSpeed,
                longestGapSeconds: longestGap
            )
            return
        }

        let values = detected.compactMap(\.rssi).map(Double.init)
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)

        let median: Double
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            median = (sorted[mid - 1] + sorted[mid]) / 2
        } else {
            median = sorted[mid]
        }

        let variance = values
            .map { pow($0 - mean, 2) }
            .reduce(0, +) / Double(values.count)

        let validIOS = detected.compactMap(\.accuracyIOS).filter { $0 > 0 }
        let validModel = detected.compactMap(\.accuracyModel).filter { $0 > 0 }

        self.init(
            totalRows: samples.count,
            detectedRows: detected.count,
            elapsedSeconds: elapsed,
            meanRSSI: mean,
            medianRSSI: median,
            minRSSI: Int(sorted.first ?? 0),
            maxRSSI: Int(sorted.last ?? 0),
            standardDeviation: sqrt(variance),
            meanAccuracyIOS: validIOS.isEmpty ? 0 : validIOS.reduce(0, +) / Double(validIOS.count),
            meanAccuracyModel: validModel.isEmpty ? 0 : validModel.reduce(0, +) / Double(validModel.count),
            meanSpeed: meanSpeed,
            maxSpeed: maxSpeed,
            longestGapSeconds: longestGap
        )
    }

    var suggestedMeasuredPower: Double { meanRSSI }
}
