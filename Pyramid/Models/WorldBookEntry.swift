import Foundation

enum WorldBookMatchMode: String, Codable, CaseIterable {
    case contains
    case exact
}

enum WorldBookInsertionPosition: String, Codable, CaseIterable {
    case beforeSystem
    case afterSystem
    case afterHistory
}

struct WorldBookEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var content: String
    var keywords: [String]
    var secondaryKeywords: [String]
    var scanDepth: Int?
    var probability: Int
    var insertionPosition: WorldBookInsertionPosition
    var isEnabled: Bool
    var isConstant: Bool
    var priority: Int
    var matchMode: WorldBookMatchMode

    // MARK: - V3 (SillyTavern Character Card V3 / World Book V3) 字段映射
    //
    // 原生 Pyramid 不消费这些字段（运行时不读），仅作 round-trip 透传：导入时
    // `parseSillyTavernEntry` 从 ST JSON 读出，导出时跟随 Character 一起走
    // BackupService。`positionRaw` 保留 ST 原始 0-6 整数，避免 1-2 / 3-6 折叠
    // 造成导出 → 二次导入值漂移。
    //
    // 全部 optional + decodeIfPresent；旧数据缺字段 → nil。
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
    var extensionsRaw: JSONValue?

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        keywords: [String] = [],
        secondaryKeywords: [String] = [],
        scanDepth: Int? = nil,
        probability: Int = 100,
        insertionPosition: WorldBookInsertionPosition = .afterSystem,
        isEnabled: Bool = true,
        isConstant: Bool = false,
        priority: Int = 0,
        matchMode: WorldBookMatchMode = .contains,
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
        extensionsRaw: JSONValue? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.keywords = keywords
        self.secondaryKeywords = secondaryKeywords
        self.scanDepth = scanDepth
        self.probability = probability
        self.insertionPosition = insertionPosition
        self.isEnabled = isEnabled
        self.isConstant = isConstant
        self.priority = priority
        self.matchMode = matchMode
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
        self.extensionsRaw = extensionsRaw
    }

    // MARK: - Codable：V3 字段 optional + decodeIfPresent，旧数据 / Pyramid 原生条目
    // 缺字段 → nil；snake_case 字段名显式映射（与 Character.swift 风格一致）。
    private enum CodingKeys: String, CodingKey {
        case id, title, content, keywords, secondaryKeywords
        case scanDepth, probability, insertionPosition
        case isEnabled, isConstant, priority, matchMode
        case externalId = "uid"
        case groupKey = "group"
        case groupWeight = "group_weight"
        case weight
        case decay
        case caseSensitive = "case_sensitive"
        case useGroupScoring
        case automationId
        case roleRaw = "role"
        case vectorized
        case sticky
        case cooldown
        case delay
        case displayIndex
        case triggers
        case outletName
        case excludes
        case selectiveLogicRaw = "selectiveLogic"
        case positionRaw = "position"
        case extensionsRaw = "extensions"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        content = try c.decode(String.self, forKey: .content)
        keywords = try c.decode([String].self, forKey: .keywords)
        secondaryKeywords = (try? c.decode([String].self, forKey: .secondaryKeywords)) ?? []
        scanDepth = try? c.decodeIfPresent(Int.self, forKey: .scanDepth)
        probability = (try? c.decode(Int.self, forKey: .probability)) ?? 100
        insertionPosition = (try? c.decode(WorldBookInsertionPosition.self, forKey: .insertionPosition)) ?? .afterSystem
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        isConstant = try c.decode(Bool.self, forKey: .isConstant)
        priority = try c.decode(Int.self, forKey: .priority)
        matchMode = (try? c.decode(WorldBookMatchMode.self, forKey: .matchMode)) ?? .contains
        // V3 字段：旧数据 / Pyramid 原生条目全部缺，decodeIfPresent 给 nil。
        externalId = try? c.decodeIfPresent(Int.self, forKey: .externalId)
        groupKey = try? c.decodeIfPresent(String.self, forKey: .groupKey)
        groupWeight = try? c.decodeIfPresent(Double.self, forKey: .groupWeight)
        weight = try? c.decodeIfPresent(Double.self, forKey: .weight)
        decay = try? c.decodeIfPresent(Double.self, forKey: .decay)
        caseSensitive = try? c.decodeIfPresent(Bool.self, forKey: .caseSensitive)
        useGroupScoring = try? c.decodeIfPresent(Bool.self, forKey: .useGroupScoring)
        automationId = try? c.decodeIfPresent(String.self, forKey: .automationId)
        roleRaw = try? c.decodeIfPresent(Int.self, forKey: .roleRaw)
        vectorized = try? c.decodeIfPresent(Bool.self, forKey: .vectorized)
        sticky = try? c.decodeIfPresent(Int.self, forKey: .sticky)
        cooldown = try? c.decodeIfPresent(Int.self, forKey: .cooldown)
        delay = try? c.decodeIfPresent(Int.self, forKey: .delay)
        displayIndex = try? c.decodeIfPresent(Int.self, forKey: .displayIndex)
        triggers = (try? c.decode([String].self, forKey: .triggers)) ?? []
        outletName = try? c.decodeIfPresent(String.self, forKey: .outletName)
        excludes = (try? c.decode([String].self, forKey: .excludes)) ?? []
        selectiveLogicRaw = try? c.decodeIfPresent(Int.self, forKey: .selectiveLogicRaw)
        positionRaw = try? c.decodeIfPresent(Int.self, forKey: .positionRaw)
        extensionsRaw = try? c.decodeIfPresent(JSONValue.self, forKey: .extensionsRaw)
    }
}
