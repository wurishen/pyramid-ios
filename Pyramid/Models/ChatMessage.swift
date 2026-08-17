import Foundation

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let role: Role
    var content: String
    var createdAt: Date?
    /// 是否参与上下文（送进 API）。true = 包含；false = 仅 UI 可见、被裁出 history。
    /// 旧数据 decodeIfPresent 给默认值 true，向后兼容。
    var isIncluded: Bool

    init(id: UUID = UUID(), role: Role, content: String, createdAt: Date? = Date(), isIncluded: Bool = true) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.isIncluded = isIncluded
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, createdAt, isIncluded
    }

    // 自定义解码：旧会话 JSON 里没有 isIncluded 字段时按 true 处理。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(Role.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        self.isIncluded = (try? c.decode(Bool.self, forKey: .isIncluded)) ?? true
    }

    enum Role: String, Codable {
        case user
        case assistant
    }
}
