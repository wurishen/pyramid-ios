import Foundation

struct Preset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var modelName: String?
    var systemPrompt: String?
    var worldBookId: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        modelName: String? = nil,
        systemPrompt: String? = nil,
        worldBookId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.modelName = modelName
        self.systemPrompt = systemPrompt
        self.worldBookId = worldBookId
    }
}
