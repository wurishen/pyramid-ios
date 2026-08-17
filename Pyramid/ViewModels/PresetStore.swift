import Foundation
import SwiftUI

final class PresetStore: ObservableObject {
    @Published var presets: [Preset] = []

    init() {
        load()
    }

    func upsert(_ preset: Preset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        save()
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.presets),
              let decoded = try? JSONDecoder().decode([Preset].self, from: data) else {
            return
        }
        presets = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: StorageKeys.presets)
        }
    }
}

private enum StorageKeys {
    static let presets = "presets"
}
