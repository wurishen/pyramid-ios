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

    init(
        id: UUID = UUID(),
        name: String,
        modelName: String? = nil,
        systemPrompt: String? = nil,
        worldBookId: UUID? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.modelName = modelName
        self.systemPrompt = systemPrompt
        self.worldBookId = worldBookId
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

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
    }
}
