import SwiftUI
import PhotosUI
import UIKit

struct MyPetsView: View {
    @EnvironmentObject private var store: PetStore
    @State private var editing: Pet?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Group {
                if store.pets.isEmpty {
                    EmptyStateView(
                        symbol: "pawprint",
                        title: "Nenhum pet cadastrado",
                        message: "Cadastre seu animal com uma foto. Assim, se ele se perder, "
                            + "a busca começa com um toque e quem ajudar vê o rosto dele."
                    )
                } else {
                    List {
                        ForEach(store.pets) { pet in
                            Button {
                                editing = pet
                            } label: {
                                PetRow(pet: pet)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            offsets.map { store.pets[$0] }.forEach(store.delete)
                        }
                    }
                }
            }
            .navigationTitle("Meus pets")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAdding = true
                    } label: {
                        Label("Cadastrar pet", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAdding) {
                PetFormView(pet: Pet())
            }
            .sheet(item: $editing) { pet in
                PetFormView(pet: pet)
            }
        }
    }
}

struct PetRow: View {
    @EnvironmentObject private var store: PetStore
    let pet: Pet

    var body: some View {
        HStack(spacing: 14) {
            PetAvatar(image: store.image(for: pet), size: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(pet.name)
                    .font(.display(18))
                if !pet.breed.isEmpty {
                    Text(pet.breed)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct PetAvatar: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Theme.brand.opacity(0.12)
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(Theme.brand.opacity(0.45))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct PetFormView: View {
    @EnvironmentObject private var store: PetStore
    @Environment(\.dismiss) private var dismiss

    @State private var pet: Pet
    @State private var nicknameDraft: String
    @State private var pickedItem: PhotosPickerItem?
    @State private var preview: UIImage?

    private let isNew: Bool

    init(pet: Pet) {
        _pet = State(initialValue: pet)
        _nicknameDraft = State(initialValue: pet.nicknames.joined(separator: ", "))
        isNew = pet.photoFilename == nil && pet.name.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        PetAvatar(image: preview ?? store.image(for: pet), size: 120)

                        PhotosPicker(selection: $pickedItem, matching: .images) {
                            Text(preview == nil && pet.photoFilename == nil
                                 ? "Escolher foto"
                                 : "Trocar foto")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } footer: {
                    Text("A foto vai para quem estiver ajudando na busca. "
                         + "É o que permite reconhecer o animal quando o sinal indicar que ele está perto.")
                }

                Section("O animal") {
                    TextField("Nome", text: $pet.name)
                    TextField("Raça ou descrição curta", text: $pet.breed)
                }

                Section {
                    TextField("apelidos separados por vírgula", text: $nicknameDraft)
                } header: {
                    Text("Como chamá-lo")
                } footer: {
                    Text("O aplicativo informa a proximidade, mas não a direção. "
                         + "Quem detectar o sinal chama o animal pelo nome.")
                }

                Section("Observação para quem encontrar") {
                    TextField("temperamento, medicação, cuidados", text: $pet.note, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle(isNew ? "Cadastrar pet" : pet.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar", action: save)
                        .disabled(pet.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .onChange(of: pickedItem) { _, item in
                Task { await loadPhoto(item) }
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else { return }
        preview = image
    }

    private func save() {
        pet.name = pet.name.trimmingCharacters(in: .whitespaces)
        pet.nicknames = nicknameDraft
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if let preview, let filename = store.storePhoto(preview, for: pet) {
            pet.photoFilename = filename
        }

        store.save(pet)
        dismiss()
    }
}

struct StartSearchForm: View {
    let onStart: (PetPayload) -> Void

    @EnvironmentObject private var store: PetStore
    @Environment(\.dismiss) private var dismiss
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Group {
                if store.pets.isEmpty {
                    VStack(spacing: 20) {
                        EmptyStateView(
                            symbol: "pawprint",
                            title: "Cadastre seu pet primeiro",
                            message: "A busca começa a partir de um animal cadastrado, "
                                + "com foto e nome, para que quem ajudar saiba o que procurar."
                        )
                        Button("Cadastrar pet") { isAdding = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.brand)
                    }
                } else {
                    List {
                        Section {
                            ForEach(store.pets) { pet in
                                Button {
                                    onStart(store.payload(for: pet))
                                    dismiss()
                                } label: {
                                    PetRow(pet: pet)
                                }
                                .buttonStyle(.plain)
                            }
                        } footer: {
                            Text("A busca avisa quem estiver num raio de 2 km e passa a "
                                 + "mostrar seu trajeto e os sinais detectados por quem ajudar.")
                        }
                    }
                }
            }
            .navigationTitle("Qual pet se perdeu?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .sheet(isPresented: $isAdding) {
                PetFormView(pet: Pet())
            }
        }
    }
}
