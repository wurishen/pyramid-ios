import Foundation

struct WorldBook: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var entries: [WorldBookEntry]
    /// 是否纳入「全局启用」集合，与「角色绑定」「会话临时启用」并集构成注入源。
    /// 删除世界书时仍可保留入口（默认 true），便于「全局启用 / 绑当前角色」切换。
    var isGloballyEnabled: Bool

    init(id: UUID = UUID(),
         title: String,
         entries: [WorldBookEntry] = [],
         isGloballyEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.entries = entries
        self.isGloballyEnabled = isGloballyEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        entries = try c.decode([WorldBookEntry].self, forKey: .entries)
        // 旧版本数据没有该字段时默认 true（保持「所有书默认全局启用」的旧行为）。
        isGloballyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isGloballyEnabled)) ?? true
    }
}

struct WorldBookExport: Codable {
    var version: Int
    var books: [WorldBook]

    init(version: Int = 1, books: [WorldBook]) {
        self.version = version
        self.books = books
    }
}
