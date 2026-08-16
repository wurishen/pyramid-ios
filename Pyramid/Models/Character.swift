import Foundation

struct Character: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var avatarData: Data?
    var description: String
    var personality: String
    var scenario: String
    var systemPrompt: String
    var worldBookId: UUID?

    init(
        id: UUID = UUID(),
        name: String = "",
        avatarData: Data? = nil,
        description: String = "",
        personality: String = "",
        scenario: String = "",
        systemPrompt: String = "",
        worldBookId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarData = avatarData
        self.description = description
        self.personality = personality
        self.scenario = scenario
        self.systemPrompt = systemPrompt
        self.worldBookId = worldBookId
    }

    func systemPromptText() -> String {
        var parts: [String] = []
        if !description.isEmpty { parts.append(description) }
        if !personality.isEmpty { parts.append(personality) }
        if !scenario.isEmpty { parts.append(scenario) }
        if !systemPrompt.isEmpty { parts.append(systemPrompt) }
        return parts.joined(separator: "\n\n")
    }
}
