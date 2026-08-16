import Foundation

struct ChatSession: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var worldBookId: UUID?
    var systemPrompt: String?
    var appliedPresetId: UUID?
    var characterId: UUID?

    init(
        id: UUID = UUID(),
        title: String = "新会话",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        worldBookId: UUID? = nil,
        systemPrompt: String? = nil,
        appliedPresetId: UUID? = nil,
        characterId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.worldBookId = worldBookId
        self.systemPrompt = systemPrompt
        self.appliedPresetId = appliedPresetId
        self.characterId = characterId
    }
}
