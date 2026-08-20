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

    // MARK: - SillyTavern V3 entries 解析（JSONValue 路径）

    /// 把 SillyTavern V3 `character_book.entries` 的 `JSONValue` 解析成 `[WorldBookEntry]`。
    ///
    /// ST 历史上两种 entry 容器形态都见过，本方法都接：
    /// - `.array([.object, .object, ...])`（ST V3 规范形态）
    /// - `.object({"0": .object, "1": .object, ...})`（ST legacy / 某些导出工具）
    ///
    /// 数字键字典按 Int 升序保持稳定顺序；非 `.object` / 非 `.array` 输入 → 返回 `[]`，
    /// 不抛错（与 `WorldBookStore.adoptEmbeddedWorldBook` 的"不丢 characterBookRaw 整体"语义对齐）。
    static func parseSillyTavernEntries(from raw: JSONValue) -> [WorldBookEntry] {
        switch raw {
        case .array(let items):
            return items.compactMap { item -> WorldBookEntry? in
                WorldBookEntry.parse(sillyTavern: item)
            }
        case .object(let dict):
            // ST legacy：数字键字典；按 Int 升序保持稳定顺序，Int 解析失败降级字典序。
            let orderedKeys = dict.keys.sorted { (a, b) in
                switch (Int(a), Int(b)) {
                case (let ai?, let bi?): return ai < bi
                case (.some, .none): return true
                case (.none, .some): return false
                default: return a < b
                }
            }
            return orderedKeys.compactMap { key -> WorldBookEntry? in
                guard let value = dict[key] else { return nil }
                return WorldBookEntry.parse(sillyTavern: value)
            }
        default:
            return []
        }
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
