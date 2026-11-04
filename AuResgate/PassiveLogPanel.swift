import Combine
import SwiftUI

struct PassiveLogPanel: View {
    @State private var rowCount: Int = 0
    @State private var recent: [String] = []
    @State private var isShowingShareSheet = false
    @State private var isShowingClearConfirmation = false

    private let clock = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Log passivo").font(.headline)
                Spacer()
                Text("\(rowCount) eventos")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text("Monitoramento de região e localização em background. Continua "
                 + "registrando com o app fechado. Horários exibidos no fuso local; "
                 + "o arquivo guarda UTC.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if recent.isEmpty {
                Text("Nenhum evento ainda.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(recent, id: \.self) { line in
                        Text(summarize(line))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .lineLimit(1)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Exportar log") { isShowingShareSheet = true }
                    .buttonStyle(.bordered)
                    .disabled(rowCount == 0)

                Button("Limpar log", role: .destructive) {
                    isShowingClearConfirmation = true
                }
                .buttonStyle(.bordered)
                .disabled(rowCount == 0)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .onAppear(perform: refresh)
        .onReceive(clock) { _ in refresh() }
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityView(items: [PassiveEventLog.shared.fileURL])
        }
        .confirmationDialog(
            "Apagar o log passivo?",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Apagar", role: .destructive) {
                PassiveEventLog.shared.clear()
                refresh()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Exporte antes se ainda não exportou — não dá para desfazer.")
        }
    }

    private func refresh() {
        rowCount = PassiveEventLog.shared.rowCount()
        recent = PassiveEventLog.shared.tail(10)
    }

    private func summarize(_ line: String) -> String {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return line }

        let time = PassiveLogPanel.localTime(fromISO: parts[0])
        let event = parts[1]
        let detail = parts[2]
        return detail.isEmpty ? "\(time)  \(event)" : "\(time)  \(event)  \(detail)"
    }

    private static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let localDisplay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()

    static func localTime(fromISO timestamp: String) -> String {
        if let date = isoParser.date(from: timestamp) {
            return localDisplay.string(from: date)
        }
        return String(timestamp.split(separator: "T").last?.prefix(8) ?? "")
    }

    private func color(for line: String) -> Color {
        if line.contains("launch_by_location") { return .green }
        if line.contains("region_enter") || line.contains("wake_sample") { return .blue }
        if line.contains("error") { return .red }
        return .secondary
    }
}
