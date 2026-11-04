import Foundation
import Combine
import UIKit

struct Pet: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var breed: String
    var nicknames: [String]
    var note: String
    var photoFilename: String?

    init(
        id: UUID = UUID(),
        name: String = "",
        breed: String = "",
        nicknames: [String] = [],
        note: String = "",
        photoFilename: String? = nil
    ) {
        self.id = id
        self.name = name
        self.breed = breed
        self.nicknames = nicknames
        self.note = note
        self.photoFilename = photoFilename
    }
}

@MainActor
final class PetStore: ObservableObject {
    @Published private(set) var pets: [Pet] = []

    private let fileManager = FileManager.default

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var indexURL: URL {
        documentsURL.appendingPathComponent("pets.json")
    }

    private var photosURL: URL {
        documentsURL.appendingPathComponent("pet-photos", isDirectory: true)
    }

    init() {
        try? fileManager.createDirectory(at: photosURL, withIntermediateDirectories: true)
        load()
    }

    func save(_ pet: Pet) {
        if let index = pets.firstIndex(where: { $0.id == pet.id }) {
            pets[index] = pet
        } else {
            pets.append(pet)
        }
        persist()
    }

    func delete(_ pet: Pet) {
        if let filename = pet.photoFilename {
            try? fileManager.removeItem(at: photosURL.appendingPathComponent(filename))
        }
        pets.removeAll { $0.id == pet.id }
        persist()
    }

    func storePhoto(_ image: UIImage, for pet: Pet) -> String? {
        guard let data = PetPhoto.encodeForStorage(image) else { return nil }
        let filename = "\(pet.id.uuidString).jpg"
        do {
            try data.write(to: photosURL.appendingPathComponent(filename), options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    func image(for pet: Pet) -> UIImage? {
        guard let filename = pet.photoFilename,
              let data = try? Data(contentsOf: photosURL.appendingPathComponent(filename))
        else { return nil }
        return UIImage(data: data)
    }

    func payload(for pet: Pet) -> PetPayload {
        PetPayload(
            name: pet.name,
            breed: pet.breed,
            nicknames: pet.nicknames,
            note: pet.note,
            major: BeaconConfig.prototypeIdentity.major,
            minor: BeaconConfig.prototypeIdentity.minor,
            photoBase64: image(for: pet).flatMap(PetPhoto.encodeForTransport)
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        pets = (try? JSONDecoder().decode([Pet].self, from: data)) ?? []
    }

    private func persist() {
        try? JSONEncoder().encode(pets).write(to: indexURL, options: .atomic)
    }
}

enum PetPhoto {
    private static let storageEdge: CGFloat = 800

    private static let transportSteps: [(edge: CGFloat, quality: CGFloat)] = [
        (320, 0.65),
        (240, 0.55),
        (180, 0.45),
        (120, 0.35)
    ]

    private static let transportBudget = 220_000

    static func encodeForStorage(_ image: UIImage) -> Data? {
        resized(image, maxEdge: storageEdge)?.jpegData(compressionQuality: 0.85)
    }

    static func encodeForTransport(_ image: UIImage) -> String? {
        for step in transportSteps {
            guard let data = resized(image, maxEdge: step.edge)?
                .jpegData(compressionQuality: step.quality)
            else { continue }

            let encoded = data.base64EncodedString()
            if encoded.count <= transportBudget {
                return encoded
            }
        }

        return resized(image, maxEdge: transportSteps.last!.edge)?
            .jpegData(compressionQuality: transportSteps.last!.quality)?
            .base64EncodedString()
    }

    static func decode(_ base64: String?) -> UIImage? {
        guard let base64, let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }

    private static func resized(_ image: UIImage, maxEdge: CGFloat) -> UIImage? {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge else { return image }

        let scale = maxEdge / longest
        let target = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )

        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
