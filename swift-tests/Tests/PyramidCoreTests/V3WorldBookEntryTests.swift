import XCTest
@testable import PyramidCore

/// Phase 2 数据保真层 + 字段映射测试。
///
/// `WorldBookStore.parseSillyTavernEntry` 是 `private static`（不在 SPM 测试可达范围
/// 里 —— `WorldBookStore.swift` 没 symlink 到 `swift-tests/Sources/PyramidCore/`）。
/// 这里走**更接近 iOS 端的另一条路径**：直接把 V3 角色卡的 entry JSON 用
/// `JSONDecoder` 解到 `WorldBookEntry`（走 `init(from:)` + `CodingKeys`），
/// 验证 17 个 V3 字段在 snake_case ↔ camelCase 映射下正确落到 typed 字段。
///
/// 注意：`parseSillyTavernEntry` 里的 NSNumber 桥接（Int / Double / Bool）走的是
/// `JSONSerialization` 的 `[String: Any]` 路径，而 `init(from:)` 走的是
/// `JSONDecoder` 的强类型路径。两者对纯 Int / Double / Bool 行为一致；
/// 这里不重复测 NSNumber 解包（那条线已经在 CharacterV3ImportTests 间接覆盖）。
final class V3WorldBookEntryTests: XCTestCase {

    // MARK: - 默认 init

    /// 默认 init：所有 V3 字段必须 nil / 空数组，旧行为不退化。
    func testInitDefaultsAllV3Fields() {
        let entry = WorldBookEntry()
        XCTAssertNil(entry.externalId)
        XCTAssertNil(entry.groupKey)
        XCTAssertNil(entry.groupWeight)
        XCTAssertNil(entry.weight)
        XCTAssertNil(entry.decay)
        XCTAssertNil(entry.caseSensitive)
        XCTAssertNil(entry.useGroupScoring)
        XCTAssertNil(entry.automationId)
        XCTAssertNil(entry.roleRaw)
        XCTAssertNil(entry.vectorized)
        XCTAssertNil(entry.sticky)
        XCTAssertNil(entry.cooldown)
        XCTAssertNil(entry.delay)
        XCTAssertNil(entry.displayIndex)
        XCTAssertEqual(entry.triggers, [])
        XCTAssertNil(entry.outletName)
        XCTAssertEqual(entry.excludes, [])
        XCTAssertNil(entry.selectiveLogicRaw)
        XCTAssertNil(entry.positionRaw)
        XCTAssertNil(entry.extensionsRaw)
        // 既有字段不退化
        XCTAssertEqual(entry.title, "")
        XCTAssertEqual(entry.content, "")
        XCTAssertEqual(entry.probability, 100)
        XCTAssertEqual(entry.insertionPosition, .afterSystem)
        XCTAssertEqual(entry.matchMode, .contains)
        XCTAssertTrue(entry.isEnabled)
        XCTAssertFalse(entry.isConstant)
    }

    // MARK: - V3 字段 → typed 字段

    /// V3 snake_case key → Swift camelCase 字段映射全表。
    /// 一次性把所有 17 个字段用 JSON 喂进去，再 decode，逐字段断言。
    func testV3KeysDecodeToTypedFields() throws {
        let json = """
        {
          "id": "\(UUID())",
          "title": "V3 entry",
          "content": "lore text",
          "keywords": ["foo"],
          "secondaryKeywords": ["bar"],
          "scanDepth": 4,
          "probability": 75,
          "insertionPosition": "afterHistory",
          "isEnabled": true,
          "isConstant": false,
          "priority": 10,
          "matchMode": "exact",
          "uid": 42,
          "group": "lore",
          "group_weight": 1.5,
          "weight": 0.7,
          "decay": 0.3,
          "case_sensitive": true,
          "useGroupScoring": true,
          "automationId": "auto-1",
          "role": 2,
          "vectorized": true,
          "sticky": 30,
          "cooldown": 60,
          "delay": 5,
          "displayIndex": 7,
          "triggers": ["triggerA", "triggerB"],
          "outletName": "outlet-1",
          "excludes": ["foo", "bar"],
          "selectiveLogic": 3,
          "position": 4,
          "extensions": {"third_party": {"k": 1}}
        }
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(WorldBookEntry.self, from: json)
        XCTAssertEqual(entry.externalId, 42)
        XCTAssertEqual(entry.groupKey, "lore")
        XCTAssertEqual(entry.groupWeight, 1.5)
        XCTAssertEqual(entry.weight, 0.7)
        XCTAssertEqual(entry.decay, 0.3)
        XCTAssertEqual(entry.caseSensitive, true)
        XCTAssertEqual(entry.useGroupScoring, true)
        XCTAssertEqual(entry.automationId, "auto-1")
        XCTAssertEqual(entry.roleRaw, 2)
        XCTAssertEqual(entry.vectorized, true)
        XCTAssertEqual(entry.sticky, 30)
        XCTAssertEqual(entry.cooldown, 60)
        XCTAssertEqual(entry.delay, 5)
        XCTAssertEqual(entry.displayIndex, 7)
        XCTAssertEqual(entry.triggers, ["triggerA", "triggerB"])
        XCTAssertEqual(entry.outletName, "outlet-1")
        XCTAssertEqual(entry.excludes, ["foo", "bar"])
        XCTAssertEqual(entry.selectiveLogicRaw, 3)
        XCTAssertEqual(entry.positionRaw, 4)
        XCTAssertNotNil(entry.extensionsRaw)
        // 既有字段不退化
        XCTAssertEqual(entry.title, "V3 entry")
        XCTAssertEqual(entry.insertionPosition, .afterHistory)
        XCTAssertEqual(entry.matchMode, .exact)
        XCTAssertEqual(entry.probability, 75)
        XCTAssertEqual(entry.priority, 10)
    }

    /// 每个 V3 字段单独缺失 → `nil`（不抛错），与既有 `decodeIfPresent` 语义一致。
    /// 抽 5 个代表性字段，避免每个字段一份 case。
    func testV3FieldsDecodeIfPresentNilSafe() throws {
        // 仅有既有字段，无 V3 字段
        let json = """
        {
          "id": "\(UUID())",
          "title": "Pyramid native",
          "content": "x",
          "keywords": ["k"],
          "isEnabled": true,
          "isConstant": false,
          "priority": 0
        }
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(WorldBookEntry.self, from: json)
        XCTAssertNil(entry.externalId, "uid 缺失 → externalId nil")
        XCTAssertNil(entry.groupKey, "group 缺失 → groupKey nil")
        XCTAssertNil(entry.weight, "weight 缺失 → nil")
        XCTAssertEqual(entry.triggers, [], "triggers 缺失 → []")
        XCTAssertEqual(entry.excludes, [], "excludes 缺失 → []")
        XCTAssertNil(entry.positionRaw, "position 缺失 → positionRaw nil")
        XCTAssertNil(entry.extensionsRaw, "extensions 缺失 → extensionsRaw nil")
    }

    /// `uid` 可以是 String（"42"）也能正确解析成 Int 42。
    /// 但 decodeIfPresent 是强类型 —— `uid: "42"` 实际会落到 string 路径。
    /// 这里测**纯 Int** uid 即可；String uid 是 parseSillyTavernEntry 的事（NSNumber / String 双重尝试）。
    func testUIDIntDecodes() throws {
        let json = """
        {
          "id": "\(UUID())",
          "title": "uid int",
          "content": "x",
          "keywords": ["k"],
          "isEnabled": true,
          "isConstant": false,
          "priority": 0,
          "uid": 7
        }
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(WorldBookEntry.self, from: json)
        XCTAssertEqual(entry.externalId, 7)
    }

    // MARK: - Round-trip

    /// 编码 → 解码：所有 V3 字段完整保留。
    func testRoundTripPreservesAllV3Fields() throws {
        let original = WorldBookEntry(
            title: "RT",
            content: "lore",
            keywords: ["a"],
            secondaryKeywords: ["b"],
            scanDepth: 3,
            probability: 80,
            insertionPosition: .beforeSystem,
            isEnabled: true,
            isConstant: false,
            priority: 5,
            matchMode: .exact,
            externalId: 99,
            groupKey: "g",
            groupWeight: 2.5,
            weight: 0.8,
            decay: 0.1,
            caseSensitive: true,
            useGroupScoring: false,
            automationId: "auto",
            roleRaw: 1,
            vectorized: true,
            sticky: 10,
            cooldown: 20,
            delay: 3,
            displayIndex: 4,
            triggers: ["x", "y"],
            outletName: "outlet",
            excludes: ["e1"],
            selectiveLogicRaw: 2,
            positionRaw: 5,
            extensionsRaw: JSONValue.object(["k": .int(1)])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorldBookEntry.self, from: data)
        XCTAssertEqual(decoded.externalId, 99)
        XCTAssertEqual(decoded.groupKey, "g")
        XCTAssertEqual(decoded.groupWeight, 2.5)
        XCTAssertEqual(decoded.weight, 0.8)
        XCTAssertEqual(decoded.decay, 0.1)
        XCTAssertEqual(decoded.caseSensitive, true)
        XCTAssertEqual(decoded.useGroupScoring, false)
        XCTAssertEqual(decoded.automationId, "auto")
        XCTAssertEqual(decoded.roleRaw, 1)
        XCTAssertEqual(decoded.vectorized, true)
        XCTAssertEqual(decoded.sticky, 10)
        XCTAssertEqual(decoded.cooldown, 20)
        XCTAssertEqual(decoded.delay, 3)
        XCTAssertEqual(decoded.displayIndex, 4)
        XCTAssertEqual(decoded.triggers, ["x", "y"])
        XCTAssertEqual(decoded.outletName, "outlet")
        XCTAssertEqual(decoded.excludes, ["e1"])
        XCTAssertEqual(decoded.selectiveLogicRaw, 2)
        XCTAssertEqual(decoded.positionRaw, 5)
        XCTAssertNotNil(decoded.extensionsRaw)
        // 既有字段也不退化
        XCTAssertEqual(decoded.title, "RT")
        XCTAssertEqual(decoded.content, "lore")
        XCTAssertEqual(decoded.insertionPosition, .beforeSystem)
        XCTAssertEqual(decoded.matchMode, .exact)
    }

    /// 旧 Pyramid JSON（无 V3 字段）能正常 decode：所有 V3 字段 nil。
    func testLegacyJSONWithoutV3FieldsDecodes() throws {
        let json = """
        {
          "id": "\(UUID())",
          "title": "Legacy",
          "content": "x",
          "keywords": ["k"],
          "isEnabled": true,
          "isConstant": false,
          "priority": 0
        }
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(WorldBookEntry.self, from: json)
        XCTAssertNil(entry.externalId)
        XCTAssertNil(entry.positionRaw)
        XCTAssertEqual(entry.triggers, [])
    }

    /// partial V3 JSON：部分字段存在、部分缺失 → 存在的 decode、缺失的 nil。
    func testPartialV3FieldsDecode() throws {
        let json = """
        {
          "id": "\(UUID())",
          "title": "Partial",
          "content": "x",
          "keywords": ["k"],
          "isEnabled": true,
          "isConstant": false,
          "priority": 0,
          "uid": 1,
          "weight": 0.5,
          "triggers": ["only-trigger"]
        }
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(WorldBookEntry.self, from: json)
        XCTAssertEqual(entry.externalId, 1, "uid 存在 → 1")
        XCTAssertEqual(entry.weight, 0.5, "weight 存在 → 0.5")
        XCTAssertEqual(entry.triggers, ["only-trigger"], "triggers 存在")
        // 其他 V3 字段仍 nil
        XCTAssertNil(entry.groupKey)
        XCTAssertNil(entry.roleRaw)
        XCTAssertNil(entry.positionRaw)
        XCTAssertEqual(entry.excludes, [])
    }

    // MARK: - insertionPosition 枚举

    /// insertionPosition 3 值枚举正常解码；默认值 .afterSystem。
    func testInsertionPositionEnumRoundTrip() throws {
        for pos in [WorldBookInsertionPosition.beforeSystem,
                    .afterSystem,
                    .afterHistory] {
            let entry = WorldBookEntry(insertionPosition: pos)
            let data = try JSONEncoder().encode(entry)
            let decoded = try JSONDecoder().decode(WorldBookEntry.self, from: data)
            XCTAssertEqual(decoded.insertionPosition, pos)
        }
    }

    /// insertionPosition 缺省时 decode 给 .afterSystem（与既有 fallback 一致）。
    func testInsertionPositionDefaultsToAfterSystem() throws {
        let json = """
        {
          "id": "\(UUID())",
          "title": "no position",
          "content": "x",
          "keywords": ["k"],
          "isEnabled": true,
          "isConstant": false,
          "priority": 0
        }
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(WorldBookEntry.self, from: json)
        XCTAssertEqual(entry.insertionPosition, .afterSystem)
    }

    // MARK: - matchMode 枚举

    /// matchMode 2 值枚举 round-trip（当前 Pyramid 只支持 contains / exact）。
    func testMatchModeEnumRoundTrip() throws {
        for mode in [WorldBookMatchMode.contains, .exact] {
            let entry = WorldBookEntry(matchMode: mode)
            let data = try JSONEncoder().encode(entry)
            let decoded = try JSONDecoder().decode(WorldBookEntry.self, from: data)
            XCTAssertEqual(decoded.matchMode, mode)
        }
    }

    // MARK: - extensionsRaw 透传

    /// extensions 任意 JSON 结构都能透传到 extensionsRaw（dict / array / 标量都行）。
    func testExtensionsRawPassthrough() throws {
        // extensions 是 dict
        let json1 = """
        {
          "id": "\(UUID())",
          "title": "ext dict",
          "content": "x",
          "keywords": ["k"],
          "isEnabled": true,
          "isConstant": false,
          "priority": 0,
          "extensions": {"third_party": {"nested": [1, 2, 3]}}
        }
        """.data(using: .utf8)!
        let entry1 = try JSONDecoder().decode(WorldBookEntry.self, from: json1)
        guard case .object(let dict) = entry1.extensionsRaw else {
            return XCTFail("extensionsRaw 应为 object")
        }
        XCTAssertNotNil(dict["third_party"])

        // extensions 是 null → extensionsRaw nil（decodeIfPresent 不会接收 null）
        let json2 = """
        {
          "id": "\(UUID())",
          "title": "ext null",
          "content": "x",
          "keywords": ["k"],
          "isEnabled": true,
          "isConstant": false,
          "priority": 0,
          "extensions": null
        }
        """.data(using: .utf8)!
        let entry2 = try JSONDecoder().decode(WorldBookEntry.self, from: json2)
        XCTAssertNil(entry2.extensionsRaw, "extensions: null → extensionsRaw nil")
    }
}
