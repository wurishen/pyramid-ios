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
    /// V3 角色卡内嵌 character_book 自动构建的世界书 ID（isGloballyEnabled=false）。
    /// 由 `WorldBookStore.adoptEmbeddedWorldBook(for:)` 在导入时填入；
    /// 删除角色时一并清理（`WorldBookStore.deleteBook` 已守住 books.count > 1）。
    /// 与用户的 `worldBookId`（手动绑定）正交；优先级：全局 < embedded < manual < session extras。
    /// 旧数据无此字段 → nil。
    var embeddedWorldBookId: UUID?

    // SillyTavern 兼容字段（均为可选，新字段；旧数据 decode 时由 init(from:) 给默认值）。
    var firstMes: String
    var alternateGreetings: [String]
    var mesExample: String
    var creatorNotes: String
    var postHistoryInstructions: String
    var tags: [String]
    var creator: String
    var characterVersion: String
    /// SillyTavern 角色卡内嵌的 Regex Script（位于 `data.extensions.regex_scripts`）。
    /// 由 ImportSupport 在解析时从 ST v2 角色卡 / PNG 内嵌 chara 中读出，**原始 ST 字段保留**，
    /// 真正的 → DisplayRegex 转换由 CharacterStore 在角色入库时调用 SillyTavernScriptImporter 完成。
    /// 旧角色卡没有此字段 → decodeIfPresent 给空数组。
    var extensionsRegexScripts: [SillyTavernRegexScript]

    // MARK: - Phase 1：SillyTavern Character Card V3 原始结构透传

    /// 整块 `data.extensions` 透传。`regex_scripts` 在写入前被剥离
    /// （避免与上面的 typed `extensionsRegexScripts` 字段重复；regex_scripts 由
    /// `SillyTavernScriptImporter` 单独消费为 `DisplayRegex`，跟 raw 通道正交）。
    /// `tavern_helper` **保留在此字段**里 —— 单独的 `tavernHelperRaw` 只是便捷指针。
    /// 旧数据无此字段 → nil。
    var extensionsRaw: JSONValue?
    /// `data.extensions.tavern_helper` 便捷指针；冗余存于 `extensionsRaw`。
    /// 旧数据无此字段 → nil。
    var tavernHelperRaw: JSONValue?
    /// 整块 `data.character_book` 透传；P1 阶段只存不消费（不做 MVU）。
    /// 旧数据无此字段 → nil。
    var characterBookRaw: JSONValue?

    init(
        id: UUID = UUID(),
        name: String = "",
        avatarData: Data? = nil,
        description: String = "",
        personality: String = "",
        scenario: String = "",
        systemPrompt: String = "",
        worldBookId: UUID? = nil,
        embeddedWorldBookId: UUID? = nil,
        firstMes: String = "",
        alternateGreetings: [String] = [],
        mesExample: String = "",
        creatorNotes: String = "",
        postHistoryInstructions: String = "",
        tags: [String] = [],
        creator: String = "",
        characterVersion: String = "",
        extensionsRegexScripts: [SillyTavernRegexScript] = [],
        extensionsRaw: JSONValue? = nil,
        tavernHelperRaw: JSONValue? = nil,
        characterBookRaw: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarData = avatarData
        self.description = description
        self.personality = personality
        self.scenario = scenario
        self.systemPrompt = systemPrompt
        self.worldBookId = worldBookId
        self.embeddedWorldBookId = embeddedWorldBookId
        self.firstMes = firstMes
        self.alternateGreetings = alternateGreetings
        self.mesExample = mesExample
        self.creatorNotes = creatorNotes
        self.postHistoryInstructions = postHistoryInstructions
        self.tags = tags
        self.creator = creator
        self.characterVersion = characterVersion
        self.extensionsRegexScripts = extensionsRegexScripts
        self.extensionsRaw = extensionsRaw
        self.tavernHelperRaw = tavernHelperRaw
        self.characterBookRaw = characterBookRaw
    }

    // MARK: - Codable：旧角色卡没有这些字段时全部 decodeIfPresent 给默认值。
    private enum CodingKeys: String, CodingKey {
        case id, name, avatarData, description, personality, scenario, systemPrompt, worldBookId
        case embeddedWorldBookId
        case firstMes = "first_mes"
        case alternateGreetings = "alternate_greetings"
        case mesExample = "mes_example"
        case creatorNotes = "creator_notes"
        case postHistoryInstructions = "post_history_instructions"
        case tags, creator
        case characterVersion = "character_version"
        case extensionsRegexScripts = "extensionsRegexScripts"
        case extensionsRaw = "extensionsRaw"
        case tavernHelperRaw = "tavernHelperRaw"
        case characterBookRaw = "characterBookRaw"
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
        self.embeddedWorldBookId = try? c.decodeIfPresent(UUID.self, forKey: .embeddedWorldBookId)
        self.firstMes = (try? c.decode(String.self, forKey: .firstMes)) ?? ""
        self.alternateGreetings = (try? c.decode([String].self, forKey: .alternateGreetings)) ?? []
        self.mesExample = (try? c.decode(String.self, forKey: .mesExample)) ?? ""
        self.creatorNotes = (try? c.decode(String.self, forKey: .creatorNotes)) ?? ""
        self.postHistoryInstructions = (try? c.decode(String.self, forKey: .postHistoryInstructions)) ?? ""
        self.tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        self.creator = (try? c.decode(String.self, forKey: .creator)) ?? ""
        self.characterVersion = (try? c.decode(String.self, forKey: .characterVersion)) ?? ""
        self.extensionsRegexScripts = (try? c.decode([SillyTavernRegexScript].self, forKey: .extensionsRegexScripts)) ?? []
        // Phase 1 V3 透传字段：旧数据 / Pyramid 原生角色卡没有 → nil。
        self.extensionsRaw = try? c.decodeIfPresent(JSONValue.self, forKey: .extensionsRaw)
        self.tavernHelperRaw = try? c.decodeIfPresent(JSONValue.self, forKey: .tavernHelperRaw)
        self.characterBookRaw = try? c.decodeIfPresent(JSONValue.self, forKey: .characterBookRaw)
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
