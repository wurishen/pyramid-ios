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
    /// 本会话覆盖的「对 AI 显示的用户名」。空字符串 = 沿用全局 `userDisplayName || userName`。
    var userDisplayNameOverride: String = ""
    /// 本会话在世界书作用域中「额外启用」的世界书 ID 集合。
    /// 注入时与「全局启用 + 角色绑定」并集取，不抑制其它作用域。
    var extraWorldBookIds: [UUID] = []
    /// 置顶。会话列表与网格中置顶段靠前显示。
    var isPinned: Bool = false
    /// 输入框未发送草稿，按会话保存；切换会话时不丢失用户正在编辑的内容。
    var draft: String = ""

    init(
        id: UUID = UUID(),
        title: String = "新会话",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        worldBookId: UUID? = nil,
        systemPrompt: String? = nil,
        appliedPresetId: UUID? = nil,
        characterId: UUID? = nil,
        userDisplayNameOverride: String = "",
        extraWorldBookIds: [UUID] = [],
        isPinned: Bool = false,
        draft: String = ""
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.worldBookId = worldBookId
        self.systemPrompt = systemPrompt
        self.appliedPresetId = appliedPresetId
        self.characterId = characterId
        self.userDisplayNameOverride = userDisplayNameOverride
        self.extraWorldBookIds = extraWorldBookIds
        self.isPinned = isPinned
        self.draft = draft
    }

    // 兼容旧版本存储数据（UserDefaults 里可能没有新字段）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        messages = try c.decode([ChatMessage].self, forKey: .messages)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        worldBookId = try? c.decodeIfPresent(UUID.self, forKey: .worldBookId)
        systemPrompt = try? c.decodeIfPresent(String.self, forKey: .systemPrompt)
        appliedPresetId = try? c.decodeIfPresent(UUID.self, forKey: .appliedPresetId)
        characterId = try? c.decodeIfPresent(UUID.self, forKey: .characterId)
        userDisplayNameOverride = (try? c.decodeIfPresent(String.self, forKey: .userDisplayNameOverride)) ?? ""
        extraWorldBookIds = (try? c.decodeIfPresent([UUID].self, forKey: .extraWorldBookIds)) ?? []
        isPinned = (try? c.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
        draft = (try? c.decodeIfPresent(String.self, forKey: .draft)) ?? ""
    }
}
