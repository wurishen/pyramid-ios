import Foundation
import SwiftUI

final class CharacterStore: ObservableObject {
    @Published var characters: [Character] = []

    init() {
        load()
    }

    func upsert(_ character: Character) {
        if let index = characters.firstIndex(where: { $0.id == character.id }) {
            characters[index] = character
        } else {
            characters.append(character)
        }
        save()
    }

    func delete(_ id: UUID) {
        characters.removeAll { $0.id == id }
        save()
    }

    func character(for id: UUID?) -> Character? {
        guard let id else { return nil }
        return characters.first { $0.id == id }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.characters),
              let decoded = try? JSONDecoder().decode([Character].self, from: data) else {
            return
        }
        characters = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(characters) {
            UserDefaults.standard.set(data, forKey: StorageKeys.characters)
        }
    }
}

private enum StorageKeys {
    static let characters = "characters"
}
