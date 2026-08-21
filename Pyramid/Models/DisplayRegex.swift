import Foundation
#if canImport(Combine) && !PYRAMID_SPM_BUILD
import Combine
#endif

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
    /// P3 native transpile：true = 仅 outgoing prompt 阶段生效（剥离酒馆思维链 / 状态栏等），
    /// 不在 iOS 显示链执行（与 fixture「只发送最新3楼的变量更新」「仅格式思维链」「对 AI 隐藏状态栏」对齐）。
    /// 旧数据无此字段 → decodeIfPresent false（不破坏历史行为）。
    var promptOnly: Bool = false
    /// 来源角色 ID。非 nil = 由该角色卡内嵌的 SillyTavern Regex Script 自动转出；
    /// 删除该角色时 DisplayRegexStore 会同步清掉这些条目（生命周期绑定）。
    /// nil = 用户手动创建。
    /// 旧数据没有此字段 → decodeIfPresent 给 nil。
    var sourceCharacterId: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        replacement: String,
        enabled: Bool = true,
        scope: Scope = .assistantDisplayPre,
        sourceCharacterId: UUID? = nil,
        promptOnly: Bool = false
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.enabled = enabled
        self.scope = scope
        self.sourceCharacterId = sourceCharacterId
        self.promptOnly = promptOnly
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
        sourceCharacterId = try? c.decodeIfPresent(UUID.self, forKey: .sourceCharacterId)
        promptOnly = (try? c.decodeIfPresent(Bool.self, forKey: .promptOnly)) ?? false
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

#if canImport(Combine) && !PYRAMID_SPM_BUILD
/// `ObservableObject` + `@Published` 依赖 Combine —— 仅在 Apple 平台编译。
/// Linux / 其他无 Combine 的平台：只有 DisplayRegex struct + DisplayRegexError 可用，
/// 足够纯 Foundation 的 SillyTavern 兼容层测试使用。
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

    // MARK: - 角色内嵌 ST Regex Script 自动绑定

    /// 把 `scripts` 中所有条目作为「来源角色 = characterId」的 DisplayRegex 替换现有集合。
    /// 已存在同 sourceCharacterId 的条目全部清除后写入新条目 —— 适用于角色导入 / 重新保存场景。
    /// 调用方（CharacterStore）负责把 Character.extensionsRegexScripts 经
    /// SillyTavernScriptImporter.convert 转成的 DisplayRegex 列表传入。
    /// 不会改写用户手动添加的 DisplayRegex（它们的 sourceCharacterId 为 nil）。
    func replaceCharacterScopedScripts(characterId: UUID, scripts: [DisplayRegex]) {
        regexes.removeAll { $0.sourceCharacterId == characterId }
        regexes.append(contentsOf: scripts)
        save()
    }

    /// 删除指定 sourceCharacterId 的所有 DisplayRegex（角色被删除时调用）。
    func removeCharacterScopedScripts(characterId: UUID) {
        regexes.removeAll { $0.sourceCharacterId == characterId }
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
#endif