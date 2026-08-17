import Foundation

/// 「显示用正则」条目。仅作用于助手消息、且只在渲染前生效。
/// 作用域在本版本固定为 `assistant.display.pre`；不暴露更多 scope，避免无谓复杂度。
struct DisplayRegex: Codable, Identifiable, Equatable {
    enum Scope: String, Codable {
        case assistantDisplayPre = "assistant.display.pre"
    }

    var id: UUID
    var name: String
    var pattern: String
    var replacement: String
    var enabled: Bool
    /// 占位字段，固定为 `assistantDisplayPre`，写入时强制为该值；保留为后续扩展留口。
    var scope: Scope = .assistantDisplayPre

    init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        replacement: String,
        enabled: Bool = true,
        scope: Scope = .assistantDisplayPre
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.enabled = enabled
        self.scope = scope
    }

    /// 用 NSRegularExpression 校验 pattern 是否能编译。UI 保存前调用以避免崩溃。
    static func validate(pattern: String) throws {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw DisplayRegexError.empty }
        do {
            _ = try NSRegularExpression(pattern: trimmed, options: [.dotMatchesLineSeparators])
        } catch {
            throw DisplayRegexError.invalid(error.localizedDescription)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        pattern = try c.decode(String.self, forKey: .pattern)
        replacement = try c.decode(String.self, forKey: .replacement)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        let raw = (try? c.decodeIfPresent(String.self, forKey: .scope)) ?? Scope.assistantDisplayPre.rawValue
        scope = Scope(rawValue: raw) ?? .assistantDisplayPre
    }
}

enum DisplayRegexError: LocalizedError {
    case empty
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "正则不能为空"
        case .invalid(let message):
            return "正则不合法：\(message)"
        }
    }
}

final class DisplayRegexStore: ObservableObject {
    @Published var regexes: [DisplayRegex] = []

    init() {
        load()
    }

    func upsert(_ regex: DisplayRegex) {
        if let index = regexes.firstIndex(where: { $0.id == regex.id }) {
            regexes[index] = regex
        } else {
            regexes.append(regex)
        }
        save()
    }

    func delete(_ id: UUID) {
        regexes.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ id: UUID, enabled: Bool) {
        guard let index = regexes.firstIndex(where: { $0.id == id }) else { return }
        regexes[index].enabled = enabled
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: StorageKeys.displayRegexes),
              let decoded = try? JSONDecoder().decode([DisplayRegex].self, from: data) else { return }
        regexes = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(regexes) {
            UserDefaults.standard.set(data, forKey: StorageKeys.displayRegexes)
        }
    }

    private enum StorageKeys {
        static let displayRegexes = "displayRegexes"
    }
}
