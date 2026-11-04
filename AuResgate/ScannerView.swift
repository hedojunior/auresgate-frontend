import Combine
import SwiftUI
import UIKit

struct ScannerView: View {
    @StateObject private var scanner = BeaconScanner()
    @State private var csvURL: URL?
    @State private var isShowingShareSheet = false
    @State private var isShowingSetup = false
    @State private var exportError: String?
    @State private var timerTick = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusHeader

                    if scanner.currentRSSI != nil {
                        primaryReading
                        signalBar
                    } else {
                        noSignalPanel
                    }

                    detectionPanel
                    PassiveLogPanel()
                    statisticsPanel
                    conditionsSummary
                    smoothingControl
                    beaconList
                }
                .padding()
            }
            .navigationTitle("Scanner BLE")
            .safeAreaInset(edge: .bottom) { controls }
            .toolbar {
                Button("Condições") { isShowingSetup = true }
            }
        }
        .onAppear { scanner.requestPermission() }
        .onReceive(clock) { timerTick = $0 }
        .sheet(isPresented: $isShowingSetup) {
            SessionSetupView(metadata: $scanner.metadata)
        }
        .sheet(isPresented: $isShowingShareSheet) {
            if let csvURL {
                ActivityView(items: [csvURL])
            }
        }
        .alert("Falha ao exportar", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 4) {
            Text(scanner.statusMessage)
                .font(.subheadline)
                .foregroundStyle(scanner.authorizationDenied ? .red : .secondary)
            Text(formattedElapsed)
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(scanner.isRanging ? .primary : .secondary)
            Text("\(scanner.statistics.detectedRows)/\(scanner.statistics.totalRows) segundos com sinal")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var formattedElapsed: String {
        _ = timerTick
        let total = Int(scanner.elapsedSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var noSignalPanel: some View {
        VStack(spacing: 6) {
            Text("Sem sinal")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let gap = scanner.secondsSinceLastDetection {
                Text("última detecção há \(gap) s")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if scanner.isRanging {
                Text("nenhuma detecção nesta sessão")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 30)
    }

    private var primaryReading: some View {
        VStack(spacing: 12) {
            if let distance = scanner.estimatedDistance, distance > 0 {
                Text(String(format: "%.1f m", distance))
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Text("distância estimada (modelo próprio)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                metric("RSSI", scanner.currentRSSI.map { "\($0) dBm" } ?? "—")
                metric("Suavizado", scanner.smoothedRSSI.map { String(format: "%.1f", $0) } ?? "—")
                metric("Faixa", scanner.proximityLabel)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var signalBar: some View {
        let rssi = scanner.smoothedRSSI ?? -100
        let fraction = max(0, min(1, (rssi + 100) / 60))

        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(
                        colors: [.blue, .green],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: geometry.size.width * fraction)
                    .animation(.easeOut(duration: 0.3), value: fraction)
            }
        }
        .frame(height: 14)
    }

    private var detectionPanel: some View {
        let stats = scanner.statistics
        let rate = stats.detectionRate

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Taxa de detecção").font(.headline)
                Spacer()
                Text(String(format: "%.0f%%", rate * 100))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(rateColor(rate))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(rateColor(rate))
                        .frame(width: geometry.size.width * rate)
                }
            }
            .frame(height: 10)

            HStack {
                Text("Maior lacuna: \(stats.longestGapSeconds) s")
                Spacer()
                if let speed = scanner.currentSpeed {
                    Text(String(format: "%.1f m/s · %.0f km/h", speed, speed * 3.6))
                        .monospacedDigit()
                } else {
                    Text("velocidade —")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let maxSpeed = stats.maxSpeed {
                Text(String(format: "Velocidade máx. da sessão: %.1f km/h", maxSpeed * 3.6))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private func rateColor(_ rate: Double) -> Color {
        if rate >= 0.9 { return .green }
        if rate >= 0.5 { return .orange }
        return .red
    }

    private var statisticsPanel: some View {
        let stats = scanner.statistics

        return VStack(alignment: .leading, spacing: 10) {
            Text("Estatísticas da sessão")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                statRow("Média", String(format: "%.1f dBm", stats.meanRSSI))
                statRow("Mediana", String(format: "%.1f dBm", stats.medianRSSI))
                statRow("Desvio-padrão", String(format: "%.2f dB", stats.standardDeviation))
                statRow("Amplitude", "\(stats.amplitude) dB")
                statRow("Mín / Máx", "\(stats.minRSSI) / \(stats.maxRSSI)")
                statRow("Detectadas", "\(stats.detectedRows)")
                statRow("Dist. iOS", String(format: "%.2f m", stats.meanAccuracyIOS))
                statRow("Dist. modelo", String(format: "%.2f m", stats.meanAccuracyModel))
            }

            if let reference = scanner.metadata.referenceDistance,
               reference == 1.0,
               stats.detectedRows > 30 {
                Divider()
                Text(String(format: "Sugestão de RSSI@1m: %.1f dBm", stats.suggestedMeasuredPower))
                    .font(.footnote)
                    .foregroundStyle(.blue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).monospacedDigit()
        }
    }

    private var conditionsSummary: some View {
        let meta = scanner.metadata
        let distance = meta.referenceDistance.map { String(format: "%.1f m", $0) } ?? "não definida"

        return VStack(alignment: .leading, spacing: 4) {
            Text("Condições").font(.headline)
            Text("Teste: \(meta.testType.displayName) · repetição \(meta.runIndex)")
            Text("Distância de referência: \(distance)")
            Text("Ambiente: \(meta.environment.displayName)")
            Text("Movimento: \(meta.motionMode.displayName)")
            Text("Na coleira: \(meta.onCollar ? "sim" : "não") · Wi-Fi: \(meta.wifiEnabled ? "ligado" : "desligado")")
            Text("Obstáculo: \(meta.obstacle)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private var smoothingControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Suavização (alpha)").font(.caption)
                Spacer()
                Text(String(format: "%.2f", scanner.smoothingAlpha))
                    .font(.caption).monospacedDigit()
            }
            Slider(value: $scanner.smoothingAlpha, in: 0.02...0.5)
            Text("Valores menores suavizam mais, porém reagem mais devagar.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Toggle("Bipe a cada detecção", isOn: $scanner.audioFeedbackEnabled)
                .font(.caption)
        }
    }

    private var beaconList: some View {
        VStack(spacing: 0) {
            ForEach(scanner.detections) { detection in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("major \(detection.major) · minor \(detection.minor)")
                            .font(.subheadline).monospacedDigit()
                        Text(detection.proximity)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(detection.rssi) dBm").monospacedDigit()
                        Text(detection.accuracyIOS > 0
                             ? String(format: "iOS: %.1f m", detection.accuracyIOS)
                             : "iOS: —")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(scanner.isRanging ? "Parar" : "Iniciar") {
                scanner.isRanging ? scanner.stop() : scanner.start()
            }
            .buttonStyle(.borderedProminent)

            Button("Limpar") { scanner.clearSession() }
                .buttonStyle(.bordered)

            Button("Exportar") {
                do {
                    csvURL = try scanner.exportCSV()
                    isShowingShareSheet = true
                } catch {
                    exportError = error.localizedDescription
                }
            }
            .buttonStyle(.bordered)
            .disabled(scanner.sessionLog.isEmpty)
        }
        .padding()
        .background(.bar)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SessionSetupView: View {
    @Binding var metadata: SessionMetadata
    @Environment(\.dismiss) private var dismiss
    @State private var distanceText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Tipo de teste") {
                    Picker("Tipo", selection: $metadata.testType) {
                        ForEach(SessionMetadata.TestType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    Stepper("Repetição: \(metadata.runIndex)", value: $metadata.runIndex, in: 1...10)
                }

                Section("Distância de referência") {
                    TextField("metros (medidos com trena)", text: $distanceText)
                        .keyboardType(.decimalPad)
                    Text("Deixe em branco nos testes de movimento.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Ambiente") {
                    Picker("Ambiente", selection: $metadata.environment) {
                        ForEach(SessionMetadata.Environment.allCases, id: \.self) { environment in
                            Text(environment.displayName).tag(environment)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Movimento") {
                    Picker("Movimento", selection: $metadata.motionMode) {
                        ForEach(SessionMetadata.MotionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Configuração") {
                    Toggle("Beacon na coleira do animal", isOn: $metadata.onCollar)
                    Toggle("Wi-Fi do iPhone ligado", isOn: $metadata.wifiEnabled)
                    TextField("Obstáculo (ex.: parede, carro)", text: $metadata.obstacle)
                }

                Section("Observações") {
                    TextField("anotação livre", text: $metadata.note, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Condições do teste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        let cleaned = distanceText
                            .trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: ",", with: ".")
                        metadata.referenceDistance = cleaned.isEmpty ? nil : Double(cleaned)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .onAppear {
                if let distance = metadata.referenceDistance {
                    distanceText = String(format: "%.1f", distance)
                }
            }
        }
    }
}
