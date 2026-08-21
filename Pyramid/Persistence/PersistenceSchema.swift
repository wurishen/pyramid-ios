import Foundation
import SwiftData

// MARK: - SwiftData Schema（foundation only）
//
// 这些 `@Model` 类与 `Pyramid/Models/` 下的 value-type structs 形状一致，
// 但**现阶段没有任何 store / view 读它们**。本文件存在的目的是：
//
// 1. 让 Xcode 在 `PyramidApp` 注入 `ModelContainer` 时能完成 schema 校验（编译期发现字段不合法）。
// 2. 给后续「UserDefaults / JSONEncoder → SwiftData」迁移提供目标模型。
// 3. 后续运行时可以从 value-type → `@Model` 走 `init(_ struct:)` 或 `toStruct()` 做迁移，
//    schema 字段对齐已在此时锁定，避免迁移期再补字段触发轻量级迁移失败。
//
// 字段命名 / 默认值 / 可空性与对应 struct 完全一致；只有「enum 字段」（ChatMessage.Role、
// DisplayRegex.Scope）被拍平为 `Raw String`，方便 SwiftData 直接持久化。

// MARK: - 会话

@Model
final class SDChatSession {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var worldBookId: UUID?
    var systemPrompt: String?
    var appliedPresetId: UUID?
    var characterId: UUID?
    var userDisplayNameOverride: String
    var extraWorldBookIds: [UUID]
    var isPinned: Bool
    var draft: String

    @Relationship(deleteRule: .cascade, inverse: \SDChatMessage.session)
    var messages: [SDChatMessage] = []

    init(
        id: UUID = UUID(),
        title: String = "新会话",
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
}

@Model
final class SDChatMessage {
    @Attribute(.unique) var id: UUID
    /// "user" / "assistant" —— SwiftData 不直接持久化 enum，平铺为字符串。
    var roleRaw: String
    var content: String
    var createdAt: Date?
    var isIncluded: Bool

    var session: SDChatSession?

    init(
        id: UUID = UUID(),
        roleRaw: String,
        content: String,
        createdAt: Date? = Date(),
        isIncluded: Bool = true
    ) {
        self.id = id
        self.roleRaw = roleRaw
        self.content = content
        self.createdAt = createdAt
        self.isIncluded = isIncluded
    }
}

// MARK: - 世界书

@Model
final class SDWorldBook {
    @Attribute(.unique) var id: UUID
    var title: String
    var isGloballyEnabled: Bool

    @Relationship(deleteRule: .cascade, inverse: \SDWorldBookEntry.book)
    var entries: [SDWorldBookEntry] = []

    init(
        id: UUID = UUID(),
        title: String,
        isGloballyEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.isGloballyEnabled = isGloballyEnabled
    }
}

@Model
final class SDWorldBookEntry {
    @Attribute(.unique) var id: UUID
    var book: SDWorldBook?

    // V1 核心
    var title: String
    var content: String
    var keywords: [String]
    var secondaryKeywords: [String]
    var scanDepth: Int?
    var probability: Int
    /// "beforeSystem" / "afterSystem" / "afterHistory"
    var insertionPositionRaw: String
    var isEnabled: Bool
    var isConstant: Bool
    var priority: Int
    /// "contains" / "exact"
    var matchModeRaw: String

    // V3 字段（与 WorldBookEntry 一一对应；保持 nullable + 默认值，兼容旧数据）
    var externalId: Int?
    var groupKey: String?
    var groupWeight: Double?
    var weight: Double?
    var decay: Double?
    var caseSensitive: Bool?
    var useGroupScoring: Bool?
    var automationId: String?
    var roleRaw: Int?
    var vectorized: Bool?
    var sticky: Int?
    var cooldown: Int?
    var delay: Int?
    var displayIndex: Int?
    var triggers: [String]
    var outletName: String?
    var excludes: [String]
    var selectiveLogicRaw: Int?
    var positionRaw: Int?
    /// extensionsRaw 走 SwiftData 的 `Data`（把 `JSONValue` Codable 序列化后存二进制）。
    var extensionsRawData: Data?

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        keywords: [String] = [],
        secondaryKeywords: [String] = [],
        scanDepth: Int? = nil,
        probability: Int = 100,
        insertionPositionRaw: String = "afterSystem",
        isEnabled: Bool = true,
        isConstant: Bool = false,
        priority: Int = 0,
        matchModeRaw: String = "contains",
        externalId: Int? = nil,
        groupKey: String? = nil,
        groupWeight: Double? = nil,
        weight: Double? = nil,
        decay: Double? = nil,
        caseSensitive: Bool? = nil,
        useGroupScoring: Bool? = nil,
        automationId: String? = nil,
        roleRaw: Int? = nil,
        vectorized: Bool? = nil,
        sticky: Int? = nil,
        cooldown: Int? = nil,
        delay: Int? = nil,
        displayIndex: Int? = nil,
        triggers: [String] = [],
        outletName: String? = nil,
        excludes: [String] = [],
        selectiveLogicRaw: Int? = nil,
        positionRaw: Int? = nil,
        extensionsRawData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.keywords = keywords
        self.secondaryKeywords = secondaryKeywords
        self.scanDepth = scanDepth
        self.probability = probability
        self.insertionPositionRaw = insertionPositionRaw
        self.isEnabled = isEnabled
        self.isConstant = isConstant
        self.priority = priority
        self.matchModeRaw = matchModeRaw
        self.externalId = externalId
        self.groupKey = groupKey
        self.groupWeight = groupWeight
        self.weight = weight
        self.decay = decay
        self.caseSensitive = caseSensitive
        self.useGroupScoring = useGroupScoring
        self.automationId = automationId
        self.roleRaw = roleRaw
        self.vectorized = vectorized
        self.sticky = sticky
        self.cooldown = cooldown
        self.delay = delay
        self.displayIndex = displayIndex
        self.triggers = triggers
        self.outletName = outletName
        self.excludes = excludes
        self.selectiveLogicRaw = selectiveLogicRaw
        self.positionRaw = positionRaw
        self.extensionsRawData = extensionsRawData
    }
}

// MARK: - 角色

@Model
final class SDCharacter {
    @Attribute(.unique) var id: UUID
    var name: String
    @Attribute(.externalStorage) var avatarData: Data?
    var descriptionText: String
    var personality: String
    var scenario: String
    var systemPrompt: String
    var worldBookId: UUID?
    var embeddedWorldBookId: UUID?
    var isEmbeddedWorldBookEnabled: Bool

    // ST 兼容字段
    var firstMes: String
    var alternateGreetings: [String]
    var mesExample: String
    var creatorNotes: String
    var postHistoryInstructions: String
    var tags: [String]
    var creator: String
    var characterVersion: String
    var extensionsRegexScriptsData: Data?

    // V3 角色卡扩展（ST V3 character_book 内嵌条目表的「结构化」备份，便于二次导出时 round-trip）
    var characterBookRawData: Data?
    var initStatData: Data?

    // V3 多语言 / 创作者元数据
    var creatorNotesMultilingual: Data?
    var source: [String]
    var groupOnlySet: Data?

    init(
        id: UUID = UUID(),
        name: String = "",
        avatarData: Data? = nil,
        descriptionText: String = "",
        personality: String = "",
        scenario: String = "",
        systemPrompt: String = "",
        worldBookId: UUID? = nil,
        embeddedWorldBookId: UUID? = nil,
        isEmbeddedWorldBookEnabled: Bool = true,
        firstMes: String = "",
        alternateGreetings: [String] = [],
        mesExample: String = "",
        creatorNotes: String = "",
        postHistoryInstructions: String = "",
        tags: [String] = [],
        creator: String = "",
        characterVersion: String = "",
        extensionsRegexScriptsData: Data? = nil,
        characterBookRawData: Data? = nil,
        initStatData: Data? = nil,
        creatorNotesMultilingual: Data? = nil,
        source: [String] = [],
        groupOnlySet: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarData = avatarData
        self.descriptionText = descriptionText
        self.personality = personality
        self.scenario = scenario
        self.systemPrompt = systemPrompt
        self.worldBookId = worldBookId
        self.embeddedWorldBookId = embeddedWorldBookId
        self.isEmbeddedWorldBookEnabled = isEmbeddedWorldBookEnabled
        self.firstMes = firstMes
        self.alternateGreetings = alternateGreetings
        self.mesExample = mesExample
        self.creatorNotes = creatorNotes
        self.postHistoryInstructions = postHistoryInstructions
        self.tags = tags
        self.creator = creator
        self.characterVersion = characterVersion
        self.extensionsRegexScriptsData = extensionsRegexScriptsData
        self.characterBookRawData = characterBookRawData
        self.initStatData = initStatData
        self.creatorNotesMultilingual = creatorNotesMultilingual
        self.source = source
        self.groupOnlySet = groupOnlySet
    }
}

// MARK: - 预设

@Model
final class SDPreset {
    @Attribute(.unique) var id: UUID
    var name: String
    var modelName: String?
    var systemPrompt: String?
    var worldBookId: UUID?
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var enableMarkdown: Bool?
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
}

// MARK: - 显示用正则

@Model
final class SDDisplayRegex {
    @Attribute(.unique) var id: UUID
    var name: String
    var pattern: String
    var replacement: String
    var enabled: Bool
    /// 固定 "assistant.display.pre"
    var scopeRaw: String
    var promptOnly: Bool
    var sourceCharacterId: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        pattern: String,
        replacement: String,
        enabled: Bool = true,
        scopeRaw: String = "assistant.display.pre",
        promptOnly: Bool = false,
        sourceCharacterId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.enabled = enabled
        self.scopeRaw = scopeRaw
        self.promptOnly = promptOnly
        self.sourceCharacterId = sourceCharacterId
    }
}
