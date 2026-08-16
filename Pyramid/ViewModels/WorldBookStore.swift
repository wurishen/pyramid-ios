import Foundation
import SwiftUI

final class WorldBookStore: ObservableObject {
    @Published var entries: [WorldBookEntry] = []

    init() {
        load()
    }

    func add(_ entry: WorldBookEntry) {
        entries.append(entry)
        save()
    }

    func update(_ entry: WorldBookEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.entries),
              let decoded = try? JSONDecoder().decode([WorldBookEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: StorageKeys.entries)
        }
    }
}

private enum StorageKeys {
    static let entries = "worldBookEntries"
}
