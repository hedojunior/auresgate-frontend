import Combine
import SwiftUI
import UIKit
import MapKit
import CoreLocation

struct SearchHomeView: View {
    @StateObject private var coordinator = SearchCoordinator()
    @State private var isShowingStartForm = false
    @State private var isShowingTools = false
    private let refreshClock = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            discoveryList
            .navigationTitle("AuResgate")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isShowingTools = true
                        } label: {
                            Label("Ferramentas de medição", systemImage: "waveform.path.ecg")
                        }

                        Section("Este aparelho") {
                            Button {} label: {
                                Label(ServerConfig.deviceLabel, systemImage: "iphone")
                            }
                            .disabled(true)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $isShowingTools) {
                ScannerView()
            }
        }
        .tint(Theme.brand)
        .onAppear { coordinator.requestPermission() }
        .onReceive(refreshClock) { _ in
            guard coordinator.state == nil else { return }
            Task { await coordinator.refreshNearby() }
        }
        .sheet(isPresented: $isShowingStartForm) {
            StartSearchForm { pet in
                Task { await coordinator.startSearch(pet: pet) }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { coordinator.state?.isOpen == true },
            set: { _ in }
        )) {
            ActiveSearchView(coordinator: coordinator)
        }
    }

    private var discoveryList: some View {
        List {
            Section {
                Button {
                    isShowingStartForm = true
                } label: {
                    Label("Perdi meu pet", systemImage: "exclamationmark.triangle.fill")
                        .font(.display(17))
                }
                .disabled(coordinator.currentLocation == nil)
            } footer: {
                if coordinator.currentLocation == nil {
                    Text("Aguardando sinal de localização para poder iniciar uma busca.")
                }
            }

            if !coordinator.canWakeInBackground {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Detecção em segundo plano desativada")
                                .font(.subheadline.weight(.semibold))
                            Text("A localização está como “Ao usar o app”. Para avisar você com "
                                 + "o app fechado, o AuResgate precisa de “Sempre”, em "
                                 + "Ajustes › AuResgate › Localização.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.signal)
                    }
                }
            }

            Section("Buscas próximas") {
                if coordinator.nearby.isEmpty {
                    EmptyStateView(
                        symbol: "dot.radiowaves.left.and.right",
                        title: "Nenhuma busca por perto",
                        message: coordinator.statusMessage
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(coordinator.nearby) { summary in
                        Button {
                            Task { await coordinator.join(searchId: summary.id) }
                        } label: {
                            nearbyRow(summary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let error = coordinator.errorMessage {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .refreshable { await coordinator.refreshNearby() }
    }

    private func nearbyRow(_ summary: SearchSummaryPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.petName)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(summary.petBreed)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label(formatDistance(summary.distanceMeters), systemImage: "location")
                Label("\(summary.participantCount)", systemImage: "person.2")
                if summary.detectionCount > 0 {
                    Label("\(summary.detectionCount)", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        meters < 1_000
            ? String(format: "%.0f m", meters)
            : String(format: "%.1f km", meters / 1_000)
    }
}

struct ActiveSearchView: View {
    @ObservedObject var coordinator: SearchCoordinator

    @State private var isShowingCloseConfirmation = false
    @State private var recenterRequests = 0

    private static let collapsedHeight: CGFloat = 250

    @State private var sheetHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0

    private var isExpanded: Bool {
        containerHeight > 0 && sheetHeight > containerHeight * 0.68
    }

    var body: some View {
        GeometryReader { screen in
            ZStack(alignment: .topTrailing) {
                if let state = coordinator.state {
                    SearchMapView(state: state, recenterRequests: recenterRequests)
                        .ignoresSafeArea()
                }

                closeButton
                    .padding(.trailing, 16)
                    .padding(.top, 8)

                recenterButton
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.leading, 16)
                    .padding(.top, 8)
            }
            .onAppear { containerHeight = screen.size.height }
            .onChange(of: screen.size.height) { _, height in containerHeight = height }
        }
        .sheet(isPresented: .constant(true)) {
            detailSheet
                .presentationDetents([
                    .height(ActiveSearchView.collapsedHeight),
                    .large
                ])
                .presentationBackground(.thinMaterial)
                .presentationBackgroundInteraction(
                    .enabled(upThrough: .height(ActiveSearchView.collapsedHeight))
                )
                .presentationCornerRadius(24)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
                .confirmationDialog(
                    coordinator.role == .owner ? "Encerrar a busca?" : "Sair da busca?",
                    isPresented: $isShowingCloseConfirmation,
                    titleVisibility: .visible
                ) {
                    if coordinator.role == .owner {
                        Button("Encontrei o animal") {
                            Task { await coordinator.closeSearch(found: true) }
                        }
                        Button("Encerrar sem encontrar", role: .destructive) {
                            Task { await coordinator.closeSearch(found: false) }
                        }
                        Button("Continuar procurando", role: .cancel) {}
                    } else {
                        Button("Sair da busca", role: .destructive) {
                            Task { await coordinator.leave() }
                        }
                        Button("Continuar ajudando", role: .cancel) {}
                    }
                } message: {
                    Text(coordinator.role == .owner
                         ? "A busca sai do ar para todo mundo que está ajudando."
                         : "Você deixa de receber as atualizações desta busca.")
                }
        }
    }

    private var closeButton: some View {
        Button {
            isShowingCloseConfirmation = true
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .glassCircle()
        }
        .accessibilityLabel(coordinator.role == .owner ? "Encerrar busca" : "Sair da busca")
    }

    private var recenterButton: some View {
        Button {
            recenterRequests += 1
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 48, height: 48)
                .glassCircle()
        }
        .accessibilityLabel("Centralizar na minha posição")
    }

    private var detailSheet: some View {
        GeometryReader { proxy in
            sheetContent
                .onAppear { sheetHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, height in sheetHeight = height }
        }
    }

    private var sheetContent: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let state = coordinator.state {
                    petHeader(state)
                    signalPanel
                    participantLine(state)

                    if !state.pet.note.isEmpty {
                        Text(state.pet.note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if isExpanded {
                        detectionHistory(state)
                            .transition(.opacity)
                    }
                }

                if let error = coordinator.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
            .padding(.top, 10)
            .animation(.easeInOut(duration: 0.25), value: isExpanded)
        }
        .safeAreaInset(edge: .bottom) {
            if isExpanded {
                endSearchButton
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    private var endSearchButton: some View {
        Button {
            isShowingCloseConfirmation = true
        } label: {
            Text(coordinator.role == .owner ? "Encerrar busca" : "Sair da busca")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.brand)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func petHeader(_ state: SearchStatePayload) -> some View {
        HStack(alignment: .center, spacing: 16) {
            PetAvatar(image: PetPhoto.decode(state.pet.photoBase64), size: 118)
                .overlay(
                    Circle().strokeBorder(Theme.brandSoft.opacity(0.35), lineWidth: 3)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(state.pet.name)
                    .font(.display(26, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if !state.pet.breed.isEmpty {
                    Text(state.pet.breed)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !state.pet.nicknames.isEmpty {
                    Text("atende por \(state.pet.nicknames.joined(separator: ", "))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var signalPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label = coordinator.proximityLabel, coordinator.currentRSSI != nil {
                Text(label)
                    .font(.display(32, .bold))
                    .foregroundStyle(Theme.signal)
                signalBar
            } else {
                Text("Procurando sinal…")
                    .font(.display(21))
                    .foregroundStyle(.secondary)

                if let gap = coordinator.secondsSinceLastDetection, gap > 0 {
                    Text("última detecção há \(gap) s")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Caminhe pela área — o alcance medido é de poucas dezenas de metros.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var signalBar: some View {
        let rssi = coordinator.smoothedRSSI ?? -100
        let fraction = max(0, min(1, (rssi + 100) / 60))

        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(
                        colors: [Theme.brandSoft, Theme.signal],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: geometry.size.width * fraction)
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: 10)
    }

    private func participantLine(_ state: SearchStatePayload) -> some View {
        let volunteers = state.participantCount

        let text: String
        switch coordinator.role {
        case .owner:
            switch volunteers {
            case 0:  text = "Ninguém se juntou à busca ainda"
            case 1:  text = "1 pessoa ajudando a procurar"
            default: text = "\(volunteers) pessoas ajudando a procurar"
            }
        case .participant:
            switch volunteers {
            case ...1: text = "Você está ajudando nesta busca"
            case 2:    text = "Você e mais 1 pessoa procurando"
            default:   text = "Você e mais \(volunteers - 1) pessoas procurando"
            }
        }

        return Label(text, systemImage: "person.2.fill")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detectionHistory(_ state: SearchStatePayload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detecções")
                .font(.display(17))

            if state.detections.isEmpty {
                Text("Nenhum sinal detectado ainda.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.detections) { detection in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: detection.id == state.latestDetection?.id
                              ? "dot.radiowaves.left.and.right"
                              : "mappin")
                            .foregroundStyle(detection.id == state.latestDetection?.id
                                             ? Theme.signal : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sinal detectado perto de \(detection.participantLabel)")
                                .font(.subheadline)
                            Text(detection.timestamp, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "raio %.0f m", detection.radiusMeters))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SearchMapView: View {
    let state: SearchStatePayload

    var recenterRequests: Int = 0

    @State private var camera: MapCameraPosition = .automatic

    @State private var visibleRegion: MKCoordinateRegion?

    var body: some View {
        Map(position: $camera) {
            Annotation("Início da busca", coordinate: state.origin.clCoordinate) {
                Image(systemName: "flag.fill")
                    .padding(6)
                    .background(Theme.brandSoft, in: Circle())
                    .foregroundStyle(.white)
            }

            if state.ownerTrail.count > 1 {
                MapPolyline(coordinates: state.ownerTrail.map(\.coordinate.clCoordinate))
                    .stroke(Theme.brand.opacity(0.75), lineWidth: 4)
            }

            let previous = state.previousDetections
            if previous.count > 1 {
                MapPolyline(coordinates: previous.map(\.coordinate.clCoordinate))
                    .stroke(
                        Theme.signal.opacity(0.5),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
            }
            ForEach(previous) { detection in
                Annotation(
                    detection.timestamp.formatted(date: .omitted, time: .shortened),
                    coordinate: detection.coordinate.clCoordinate
                ) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(Theme.signal.opacity(0.6))
                }
            }

            if let latest = state.latestDetection {
                MapCircle(
                    center: latest.coordinate.clCoordinate,
                    radius: latest.radiusMeters
                )
                .foregroundStyle(Theme.signalWash)
                .stroke(Theme.signal, lineWidth: 2)

                Annotation(
                    "Sinal perto de \(latest.participantLabel)",
                    coordinate: latest.coordinate.clCoordinate
                ) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .padding(6)
                        .background(Theme.signal, in: Circle())
                        .foregroundStyle(.white)
                }
            }

            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat))
        .mapControls { }
        .onChange(of: recenterRequests) { _, _ in
            withAnimation { camera = .userLocation(fallback: .automatic) }
        }
        .onMapCameraChange { context in
            visibleRegion = context.region
        }
        .onAppear { frameContent() }
        .onChange(of: state.latestDetection?.id) { _, _ in
            frameIfDetectionIsOffscreen()
        }
    }

    private func frameIfDetectionIsOffscreen() {
        guard let latest = state.latestDetection else { return }

        guard let region = visibleRegion else {
            frameContent()
            return
        }

        let point = latest.coordinate.clCoordinate
        let latitudeMargin = region.span.latitudeDelta / 2
        let longitudeMargin = region.span.longitudeDelta / 2

        let isVisible =
            abs(point.latitude - region.center.latitude) < latitudeMargin * 0.85 &&
            abs(point.longitude - region.center.longitude) < longitudeMargin * 0.85

        guard !isVisible else { return }
        withAnimation { frameContent() }
    }

    private func frameContent() {
        var coordinates = [state.origin.clCoordinate]
        coordinates += state.ownerTrail.map(\.coordinate.clCoordinate)
        coordinates += state.detections.map(\.coordinate.clCoordinate)

        guard coordinates.count > 1 else {
            camera = .region(MKCoordinateRegion(
                center: state.origin.clCoordinate,
                latitudinalMeters: 300,
                longitudinalMeters: 300
            ))
            return
        }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (latitudes.min()! + latitudes.max()!) / 2,
            longitude: (longitudes.min()! + longitudes.max()!) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((latitudes.max()! - latitudes.min()!) * 1.6, 0.0025),
            longitudeDelta: max((longitudes.max()! - longitudes.min()!) * 1.6, 0.0025)
        )
        camera = .region(MKCoordinateRegion(center: center, span: span))
    }
}
