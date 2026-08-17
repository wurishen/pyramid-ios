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

    // SillyTavern 兼容字段（均为可选，新字段；旧数据 decode 时由 init(from:) 给默认值）。
    var firstMes: String
    var alternateGreetings: [String]
    var mesExample: String
    var creatorNotes: String
    var postHistoryInstructions: String
    var tags: [String]
    var creator: String
    var characterVersion: String

    init(
        id: UUID = UUID(),
        name: String = "",
        avatarData: Data? = nil,
        description: String = "",
        personality: String = "",
        scenario: String = "",
        systemPrompt: String = "",
        worldBookId: UUID? = nil,
        firstMes: String = "",
        alternateGreetings: [String] = [],
        mesExample: String = "",
        creatorNotes: String = "",
        postHistoryInstructions: String = "",
        tags: [String] = [],
        creator: String = "",
        characterVersion: String = ""
    ) {
        self.id = id
        self.name = name
        self.avatarData = avatarData
        self.description = description
        self.personality = personality
        self.scenario = scenario
        self.systemPrompt = systemPrompt
        self.worldBookId = worldBookId
        self.firstMes = firstMes
        self.alternateGreetings = alternateGreetings
        self.mesExample = mesExample
        self.creatorNotes = creatorNotes
        self.postHistoryInstructions = postHistoryInstructions
        self.tags = tags
        self.creator = creator
        self.characterVersion = characterVersion
    }

    // MARK: - Codable：旧角色卡没有这些字段时全部 decodeIfPresent 给默认值。
    private enum CodingKeys: String, CodingKey {
        case id, name, avatarData, description, personality, scenario, systemPrompt, worldBookId
        case firstMes = "first_mes"
        case alternateGreetings = "alternate_greetings"
        case mesExample = "mes_example"
        case creatorNotes = "creator_notes"
        case postHistoryInstructions = "post_history_instructions"
        case tags, creator
        case characterVersion = "character_version"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.avatarData = try? c.decodeIfPresent(Data.self, forKey: .avatarData)
        self.description = (try? c.decode(String.self, forKey: .description)) ?? ""
        self.personality = (try? c.decode(String.self, forKey: .personality)) ?? ""
        self.scenario = (try? c.decode(String.self, forKey: .scenario)) ?? ""
        self.systemPrompt = (try? c.decode(String.self, forKey: .systemPrompt)) ?? ""
        self.worldBookId = try? c.decodeIfPresent(UUID.self, forKey: .worldBookId)
        self.firstMes = (try? c.decode(String.self, forKey: .firstMes)) ?? ""
        self.alternateGreetings = (try? c.decode([String].self, forKey: .alternateGreetings)) ?? []
        self.mesExample = (try? c.decode(String.self, forKey: .mesExample)) ?? ""
        self.creatorNotes = (try? c.decode(String.self, forKey: .creatorNotes)) ?? ""
        self.postHistoryInstructions = (try? c.decode(String.self, forKey: .postHistoryInstructions)) ?? ""
        self.tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        self.creator = (try? c.decode(String.self, forKey: .creator)) ?? ""
        self.characterVersion = (try? c.decode(String.self, forKey: .characterVersion)) ?? ""
    }

    func systemPromptText() -> String {
        var parts: [String] = []
        if !description.isEmpty { parts.append(description) }
        if !personality.isEmpty { parts.append(personality) }
        if !scenario.isEmpty { parts.append(scenario) }
        if !systemPrompt.isEmpty { parts.append(systemPrompt) }
        // mes_example 折进同一段 system prompt，酒馆风格：加个方括号小标题让 LLM 一眼看出这是示例段。
        let trimmedExample = mesExample.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExample.isEmpty {
            parts.append("[对话示例]\n\(trimmedExample)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// 该角色全部可用的开场白：[默认开场白, 备用开场白 1, 备用开场白 2, ...]。
    /// 旧数据无任何开场白 → 返回空数组；调用方据此决定是否弹选择器。
    var availableGreetings: [String] {
        var list: [String] = []
        let first = firstMes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !first.isEmpty { list.append(first) }
        list.append(contentsOf: alternateGreetings.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        return list
    }
}
