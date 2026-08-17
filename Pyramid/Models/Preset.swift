import Foundation

struct Preset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var modelName: String?
    var systemPrompt: String?
    var worldBookId: UUID?
    /// 采样参数（nil = 不覆盖，沿用当前请求里的设置）。
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    /// Markdown 渲染：true=强制开 / false=强制关 / nil=沿用全局设置。
    /// 旧存档里没有此字段时，沿用全局（即默认为 nil）。
    var enableMarkdown: Bool?
    /// 关联的「显示用正则」ID 列表；为空 = 使用所有启用中的正则。
    var displayRegexIds: [UUID]

    init(
        id: UUID = UUID(),
        name: String,
        modelName: String? = nil,
        systemPrompt: String? = nil,
        worldBookId: UUID? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        enableMarkdown: Bool? = nil,
        displayRegexIds: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.modelName = modelName
        self.systemPrompt = systemPrompt
        self.worldBookId = worldBookId
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.enableMarkdown = enableMarkdown
        self.displayRegexIds = displayRegexIds
    }

    /// 是否「主动覆盖」了全局 Markdown 开关（不是 nil 就是覆盖）。
    var useGlobalMarkdown: Bool { enableMarkdown == nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        modelName = try? c.decodeIfPresent(String.self, forKey: .modelName)
        systemPrompt = try? c.decodeIfPresent(String.self, forKey: .systemPrompt)
        worldBookId = try? c.decodeIfPresent(UUID.self, forKey: .worldBookId)
        temperature = try? c.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try? c.decodeIfPresent(Double.self, forKey: .topP)
        maxTokens = try? c.decodeIfPresent(Int.self, forKey: .maxTokens)
        enableMarkdown = try? c.decodeIfPresent(Bool.self, forKey: .enableMarkdown)
        displayRegexIds = (try? c.decodeIfPresent([UUID].self, forKey: .displayRegexIds)) ?? []
    }
}
