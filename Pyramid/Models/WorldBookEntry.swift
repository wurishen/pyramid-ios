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
        probability: Int = 100,
        insertionPosition: WorldBookInsertionPosition = .afterSystem,
        isEnabled: Bool = true,
        isConstant: Bool = false,
        priority: Int = 0,
        matchMode: WorldBookMatchMode = .contains,
        // V3 字段按逻辑对分组（weight/decay、caseSensitive/scanDepth、groupWeight/useGroupScoring），
        // 方便调用方一眼看出「该字段属于哪个语义维度」。其余 V3 字段沿用导入顺序。
        externalId: Int? = nil,
        groupKey: String? = nil,
        weight: Double? = nil,
        decay: Double? = nil,
        caseSensitive: Bool? = nil,
        scanDepth: Int? = nil,
        groupWeight: Double? = nil,
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
        self.probability = probability
        self.insertionPosition = insertionPosition
        self.isEnabled = isEnabled
        self.isConstant = isConstant
        self.priority = priority
        self.matchMode = matchMode
        self.externalId = externalId
        self.groupKey = groupKey
        self.weight = weight
        self.decay = decay
        self.caseSensitive = caseSensitive
        self.scanDepth = scanDepth
        self.groupWeight = groupWeight
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

    // MARK: - SillyTavern JSON 解析（JSONValue 路径，供 adoptEmbeddedWorldBook / 通用导入复用）

    /// 把一条 SillyTavern V3 entry 的 `JSONValue.object(...)` 解析为 `WorldBookEntry`。
    ///
    /// 旧路径 `parseSillyTavernEntry([String: Any])`（`WorldBookStore` private）只在
    /// `JSONSerialization` 解码的 `Any` 上工作；当上游是 `JSONValue`（即
    /// `character.characterBookRaw` 透传出来的对象）时，`JSONValue` **不能**用
    /// `as? [String: Any]` 桥接 → 旧路径恒产空 entries。本方法直接从 `JSONValue` 读字段，
    /// 保留所有 NSNumber / 数组 / 对象 / 字符串语义，让内嵌世界书真正可用。
    ///
    /// **不接受**非 `.object` 输入；调用方负责把 `.array` 元素 / `.object` 子值传过来。
    ///
    /// **MVU 隔离**：若 `extensions.initvar == true`（MVU 约定的 [initvar] 世界书条目标记），
    /// **不**返回 entry —— 该条目按 MVU 语义是 init 来源、不是 lore 注入目标。
    /// 即使它带 keywords、也**不能**作为正文被注入。MVP 暂不消费 initvar 内容的子树
    /// （参见 `docs/ST_OPEN_QUESTIONS.md` §6），但必须隔离避免被注入成 lore。
    static func parse(sillyTavern raw: JSONValue) -> WorldBookEntry? {
        guard case .object(let dict) = raw else { return nil }
        if let initvar = dict["extensions"].flatMap({ initvarFlag(in: $0) }), initvar {
            return nil
        }

        var entry = WorldBookEntry()

        let content = dict["content"].flatMap(Self.stringValue) ?? ""
        entry.content = content

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comment = dict["comment"].flatMap(Self.stringValue),
           !comment.trimmingCharacters(in: .whitespaces).isEmpty {
            entry.title = comment
        } else if let name = dict["name"].flatMap(Self.stringValue),
                  !name.trimmingCharacters(in: .whitespaces).isEmpty {
            entry.title = name
        } else if !trimmedContent.isEmpty {
            let maxLen = 50
            entry.title = trimmedContent.count > maxLen
                ? String(trimmedContent.prefix(maxLen)) + "…"
                : trimmedContent
        } else {
            entry.title = "未命名"
        }

        // keywords：`key` 或 `keys`，数组 / 单字符串都接受
        let keyField = dict["key"] ?? dict["keys"]
        if let arr = keyField.flatMap(Self.stringArrayValue) {
            entry.keywords = arr.flatMap(Self.splitKeywords)
        } else if let s = keyField.flatMap(Self.stringValue) {
            entry.keywords = Self.splitKeywords(s)
        }

        let secondaryField = dict["keysecondary"] ?? dict["keySecondary"]
        if let arr = secondaryField.flatMap(Self.stringArrayValue) {
            entry.secondaryKeywords = arr.flatMap(Self.splitKeywords)
        } else if let s = secondaryField.flatMap(Self.stringValue) {
            entry.secondaryKeywords = Self.splitKeywords(s)
        }

        entry.isConstant = dict["constant"].flatMap(Self.boolValue) ?? false
        entry.isEnabled = !(dict["disable"].flatMap(Self.boolValue) ?? false)

        // order / priority / insertion_order：越小越优先（小=优先），与原生 priority 一致。
        if let order = dict["order"].flatMap(Self.intValue) {
            entry.priority = order
        } else if let priority = dict["priority"].flatMap(Self.intValue) {
            entry.priority = priority
        } else if let insertion = dict["insertion_order"].flatMap(Self.intValue) {
            entry.priority = insertion
        }

        if let matchWholeWords = dict["matchWholeWords"].flatMap(Self.boolValue), matchWholeWords {
            entry.matchMode = .exact
        }

        // useProbability=false 视为不启用概率（=100 恒触发）。
        if let useProbability = dict["useProbability"].flatMap(Self.boolValue), !useProbability {
            entry.probability = 100
        } else if let p = dict["probability"].flatMap(Self.intValue) {
            entry.probability = min(max(p, 0), 100)
        }

        if let depth = dict["depth"].flatMap(Self.intValue) {
            entry.scanDepth = depth
        } else if let scanDepth = dict["scanDepth"].flatMap(Self.intValue) {
            entry.scanDepth = scanDepth
        }

        // V3 位置 0..6；5/6 折叠到 afterHistory；positionRaw 保留原始值用于 round-trip。
        if let position = dict["position"].flatMap(Self.intValue) {
            entry.positionRaw = position
            switch position {
            case 0:
                entry.insertionPosition = .beforeSystem
            case 3, 4, 5, 6:
                entry.insertionPosition = .afterHistory
            default:
                entry.insertionPosition = .afterSystem
            }
        }

        // V3 字段透传
        entry.externalId = dict["uid"].flatMap(Self.intValue)
        entry.groupKey = dict["group"].flatMap(Self.stringValue)
        entry.groupWeight = dict["group_weight"].flatMap(Self.doubleValue)
        entry.weight = dict["weight"].flatMap(Self.doubleValue)
        entry.decay = dict["decay"].flatMap(Self.doubleValue)
        entry.caseSensitive = dict["case_sensitive"].flatMap(Self.boolValue)
        entry.useGroupScoring = dict["useGroupScoring"].flatMap(Self.boolValue)
        entry.automationId = dict["automationId"].flatMap(Self.stringValue)
        entry.roleRaw = dict["role"].flatMap(Self.intValue)
        entry.vectorized = dict["vectorized"].flatMap(Self.boolValue)
        entry.sticky = dict["sticky"].flatMap(Self.intValue)
        entry.cooldown = dict["cooldown"].flatMap(Self.intValue)
        entry.delay = dict["delay"].flatMap(Self.intValue)
        entry.displayIndex = dict["displayIndex"].flatMap(Self.intValue)
        entry.triggers = dict["triggers"].flatMap(Self.stringArrayValue) ?? []
        entry.outletName = dict["outletName"].flatMap(Self.stringValue)
        entry.excludes = dict["excludes"].flatMap(Self.stringArrayValue) ?? []
        entry.selectiveLogicRaw = dict["selectiveLogic"].flatMap(Self.intValue)
        // extensions 透传：任意 JSONValue 都收；与 characterBookRaw 行为对齐。
        if let ext = dict["extensions"] {
            entry.extensionsRaw = ext
        }

        return entry
    }

    // MARK: - JSONValue → Foundation 辅助

    /// `extensions.initvar == true` 判定。MVU 用 `extensions.initvar` 标记 [initvar] 世界书条目，
    /// 那类条目是 init 来源、不是 lore 注入目标 —— 见 `parse(sillyTavern:)` 顶部的隔离说明。
    /// 仅在 MVU 递归子树内查 `initvar`；非 extensions 位置的同名 key 不算。
    private static func initvarFlag(in extensions: JSONValue) -> Bool? {
        guard case .object(let ext) = extensions else { return nil }
        guard let value = ext["initvar"] else { return nil }
        return boolValue(value)
    }

    private static func stringValue(_ v: JSONValue) -> String? {
        if case .string(let s) = v { return s }
        return nil
    }

    private static func boolValue(_ v: JSONValue) -> Bool? {
        if case .bool(let b) = v { return b }
        return nil
    }

    private static func intValue(_ v: JSONValue) -> Int? {
        if case .int(let i) = v { return i }
        if case .double(let d) = v, d.rounded() == d, d >= Double(Int.min), d <= Double(Int.max) {
            return Int(d)
        }
        // ST 偶尔把 uid 写成字符串数字（"42"）。
        if case .string(let s) = v, let i = Int(s) { return i }
        return nil
    }

    private static func doubleValue(_ v: JSONValue) -> Double? {
        if case .double(let d) = v { return d }
        if case .int(let i) = v { return Double(i) }
        return nil
    }

    private static func stringArrayValue(_ v: JSONValue) -> [String]? {
        if case .array(let arr) = v {
            return arr.map { stringValue($0) }.compactMap { $0 }
        }
        return nil
    }

    /// 按 `,` / `，` / 空白切词。复用 `WorldBookStore` 旧路径里的语义。
    private static func splitKeywords(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，")
            .union(.whitespacesAndNewlines))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
