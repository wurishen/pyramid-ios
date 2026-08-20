import XCTest
@testable import PyramidCore

/// V3 `character_book` 的 entries 解析回归测试。
///
/// 历史 bug：`WorldBookStore.adoptEmbeddedWorldBook` 把 `JSONValue.object`
/// 当 `[String: Any]` 桥接 (`raw["entries"] as? [Any]` / `as? [String: Any]`)，
/// `JSONValue` 不是 `Any` 桥接目标 → 两路恒失败 → entryDicts = [] →
/// 内嵌世界书永远"条目 (0)"。
///
/// 修复路径：纯 `JSONValue` 解析搬到 `WorldBook.parseSillyTavernEntries(from:)`
/// （同时调用 `WorldBookEntry.parse(sillyTavern:)`）。这两个静态在
/// `WorldBook.swift` / `WorldBookEntry.swift` 里，**纯 Foundation 依赖**，
/// 可在 Linux SPM 直接驱动。
///
/// 测试数据用中性内容（"lore"、"characterA"、"eventB"），不绑定任何具体卡面。
final class EmbeddedWorldBookParseTests: XCTestCase {

    // MARK: - JSONValue 路径基本解析

    /// `entries` 为 array（V3 规范形态）：2 条完整 ST entry → count == 2。
    func testParseEntriesFromArray() {
        let entries: [JSONValue] = [
            .object([
                "uid": .int(1),
                "key": .array([.string("lore")]),
                "keysecondary": .array([.string("background")]),
                "content": .string("First lore paragraph."),
                "comment": .string("First entry comment"),
                "constant": .bool(false),
                "disable": .bool(false),
                "order": .int(100),
                "probability": .int(100),
                "depth": .int(4),
                "position": .int(1),
                "useProbability": .bool(true)
            ]),
            .object([
                "uid": .int(2),
                "key": .array([.string("event")]),
                "content": .string("Second lore paragraph."),
                "comment": .string("Second entry comment"),
                "order": .int(200)
            ])
        ]
        let parsed = WorldBook.parseSillyTavernEntries(from: .array(entries))
        XCTAssertEqual(parsed.count, 2)

        let first = parsed[0]
        XCTAssertEqual(first.content, "First lore paragraph.")
        XCTAssertEqual(first.title, "First entry comment", "comment 优先于 name / content 截断")
        XCTAssertEqual(first.keywords, ["lore"])
        XCTAssertEqual(first.secondaryKeywords, ["background"])
        XCTAssertEqual(first.priority, 100, "ST order 越小越优先，与原生 priority 同语义")
        XCTAssertEqual(first.probability, 100)
        XCTAssertEqual(first.scanDepth, 4)
        XCTAssertEqual(first.insertionPosition, .afterSystem, "position=1 → afterSystem")
        XCTAssertEqual(first.positionRaw, 1, "positionRaw 保留 ST 原始值用于 round-trip")
        XCTAssertTrue(first.isEnabled)
        XCTAssertFalse(first.isConstant)
        XCTAssertEqual(first.externalId, 1)

        let second = parsed[1]
        XCTAssertEqual(second.title, "Second entry comment")
        XCTAssertEqual(second.keywords, ["event"])
        XCTAssertEqual(second.priority, 200)
        XCTAssertEqual(second.externalId, 2)
    }

    /// `entries` 为数字键 object（ST legacy / 部分导出工具）：按键序取 value → count 正确。
    func testParseEntriesFromNumericKeyedObject() {
        let entries: JSONValue = .object([
            "0": .object([
                "uid": .int(10),
                "content": .string("Legacy entry zero."),
                "order": .int(50)
            ]),
            "1": .object([
                "uid": .int(11),
                "content": .string("Legacy entry one."),
                "order": .int(60)
            ]),
            "2": .object([
                "uid": .int(12),
                "content": .string("Legacy entry two."),
                "order": .int(70)
            ])
        ])
        let parsed = WorldBook.parseSillyTavernEntries(from: entries)
        XCTAssertEqual(parsed.count, 3, "数字键字典三种 entry 都解析")
        XCTAssertEqual(parsed.map(\.externalId), [10, 11, 12], "按 Int 升序保持稳定顺序")
        XCTAssertEqual(parsed.map(\.priority), [50, 60, 70])
    }

    /// 非 array / 非 object → 空数组，不抛错。
    func testParseEntriesFromInvalidShapeReturnsEmpty() {
        XCTAssertTrue(WorldBook.parseSillyTavernEntries(from: .null).isEmpty)
        XCTAssertTrue(WorldBook.parseSillyTavernEntries(from: .string("not entries")).isEmpty)
        XCTAssertTrue(WorldBook.parseSillyTavernEntries(from: .int(42)).isEmpty)
        XCTAssertTrue(WorldBook.parseSillyTavernEntries(from: .bool(true)).isEmpty)
    }

    /// entries 字段缺失（dict 里没 "entries"）→ .null fallback → 空数组。
    func testParseEntriesMissingFieldReturnsEmpty() {
        let book: JSONValue = .object(["name": .string("Book without entries")])
        let entriesValue = book.objectValue?["entries"] ?? .null
        XCTAssertTrue(WorldBook.parseSillyTavernEntries(from: entriesValue).isEmpty)
    }

    /// array 里混入非 object 元素（string / int）→ compactMap 掉，不抛错。
    func testParseEntriesArrayFiltersNonObjects() {
        let entries: [JSONValue] = [
            .object(["uid": .int(1), "content": .string("ok")]),
            .string("garbage"),
            .int(42),
            .null,
            .object(["uid": .int(2), "content": .string("also ok")])
        ]
        let parsed = WorldBook.parseSillyTavernEntries(from: .array(entries))
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.map(\.externalId), [1, 2])
    }

    // MARK: - title 派生

    /// 没有 comment 也没有 name → 用 content 前 50 字（截断 + …）。
    func testTitleFallsBackToContentSnippet() {
        let long = String(repeating: "x", count: 80)
        let entry = WorldBookEntry.parse(sillyTavern: .object([
            "content": .string(long)
        ]))!
        XCTAssertEqual(entry.title.count, 51) // 50 + "…"
        XCTAssertTrue(entry.title.hasSuffix("…"))
    }

    /// 啥都没有 → "未命名"。
    func testTitleFallsBackToUntitled() {
        let entry = WorldBookEntry.parse(sillyTavern: .object([
            "content": .string("   \n  ")
        ]))!
        XCTAssertEqual(entry.title, "未命名")
    }

    // MARK: - V3 字段透传

    /// V3 全字段（17 个）透传到 typed WorldBookEntry。
    func testParseV3FieldsAllPresent() {
        let entry = WorldBookEntry.parse(sillyTavern: .object([
            "uid": .int(99),
            "group": .string("lore_group"),
            "group_weight": .double(1.5),
            "weight": .double(0.7),
            "decay": .double(0.3),
            "case_sensitive": .bool(true),
            "useGroupScoring": .bool(true),
            "automationId": .string("auto_1"),
            "role": .int(0),
            "vectorized": .bool(false),
            "sticky": .int(5),
            "cooldown": .int(10),
            "delay": .int(2),
            "displayIndex": .int(7),
            "triggers": .array([.string("t1"), .string("t2")]),
            "outletName": .string("main"),
            "excludes": .array([.string("e1")]),
            "selectiveLogic": .int(1),
            "extensions": .object(["third_party": .object(["k": .string("v")])])
        ]))!

        XCTAssertEqual(entry.externalId, 99)
        XCTAssertEqual(entry.groupKey, "lore_group")
        XCTAssertEqual(entry.groupWeight, 1.5)
        XCTAssertEqual(entry.weight, 0.7)
        XCTAssertEqual(entry.decay, 0.3)
        XCTAssertEqual(entry.caseSensitive, true)
        XCTAssertEqual(entry.useGroupScoring, true)
        XCTAssertEqual(entry.automationId, "auto_1")
        XCTAssertEqual(entry.roleRaw, 0)
        XCTAssertEqual(entry.vectorized, false)
        XCTAssertEqual(entry.sticky, 5)
        XCTAssertEqual(entry.cooldown, 10)
        XCTAssertEqual(entry.delay, 2)
        XCTAssertEqual(entry.displayIndex, 7)
        XCTAssertEqual(entry.triggers, ["t1", "t2"])
        XCTAssertEqual(entry.outletName, "main")
        XCTAssertEqual(entry.excludes, ["e1"])
        XCTAssertEqual(entry.selectiveLogicRaw, 1)
        XCTAssertNotNil(entry.extensionsRaw)
    }

    /// `matchWholeWords: true` → `matchMode == .exact`。
    func testParseMatchWholeWords() {
        let entry = WorldBookEntry.parse(sillyTavern: .object([
            "content": .string("x"),
            "matchWholeWords": .bool(true)
        ]))!
        XCTAssertEqual(entry.matchMode, .exact)
    }

    /// `disable: true` → `isEnabled == false`。
    func testParseDisableFlipsEnabled() {
        let entry = WorldBookEntry.parse(sillyTavern: .object([
            "content": .string("x"),
            "disable": .bool(true)
        ]))!
        XCTAssertFalse(entry.isEnabled)
    }

    /// `useProbability: false` → `probability == 100`（恒触发）。
    func testParseUseProbabilityFalseForcesFullProbability() {
        let entry = WorldBookEntry.parse(sillyTavern: .object([
            "content": .string("x"),
            "probability": .int(30),
            "useProbability": .bool(false)
        ]))!
        XCTAssertEqual(entry.probability, 100, "useProbability=false 视为不启用概率")
    }

    /// `position` 0 / 3 / 4 / 5 / 6 → beforeSystem / afterHistory / afterHistory / afterHistory / afterHistory。
    func testParsePositionMapping() {
        let cases: [(Int, WorldBookInsertionPosition)] = [
            (0, .beforeSystem),
            (1, .afterSystem),
            (2, .afterSystem),
            (3, .afterHistory),
            (4, .afterHistory),
            (5, .afterHistory),
            (6, .afterHistory)
        ]
        for (raw, expected) in cases {
            let entry = WorldBookEntry.parse(sillyTavern: .object([
                "content": .string("x"),
                "position": .int(raw)
            ]))!
            XCTAssertEqual(entry.insertionPosition, expected, "position=\(raw)")
            XCTAssertEqual(entry.positionRaw, raw, "positionRaw 保留原始值")
        }
    }

    /// `uid` 是字符串数字（ST 偶发形态）→ 解析为 Int。
    func testParseStringUid() {
        let entry = WorldBookEntry.parse(sillyTavern: .object([
            "uid": .string("123"),
            "content": .string("x")
        ]))!
        XCTAssertEqual(entry.externalId, 123)
    }

    /// `priority` / `order` / `insertion_order` 优先级：order > priority > insertion_order。
    func testParsePriorityPrecedence() {
        let cases: [(String, Int)] = [
            ("order", 10),
            ("priority", 20),
            ("insertion_order", 30)
        ]
        for (key, expected) in cases {
            let entry = WorldBookEntry.parse(sillyTavern: .object([
                "content": .string("x"),
                key: .int(expected)
            ]))!
            XCTAssertEqual(entry.priority, expected, "只有 \(key)")
        }
        // 同时给 order + priority → order 赢
        let both = WorldBookEntry.parse(sillyTavern: .object([
            "content": .string("x"),
            "order": .int(10),
            "priority": .int(99)
        ]))!
        XCTAssertEqual(both.priority, 10, "order 优先于 priority")
    }

    // MARK: - 数字键字典的混合键序

    /// 数字键字典里混入非数字键 → 数字键按 Int 升序在前，非数字键字典序在后。
    func testParseNumericKeyedObjectWithMixedKeys() {
        let entries: JSONValue = .object([
            "2": .object(["uid": .int(20), "content": .string("c")]),
            "alpha": .object(["uid": .int(30), "content": .string("d")]),
            "0": .object(["uid": .int(10), "content": .string("a")]),
            "1": .object(["uid": .int(11), "content": .string("b")])
        ])
        let parsed = WorldBook.parseSillyTavernEntries(from: entries)
        XCTAssertEqual(parsed.map(\.externalId), [10, 11, 20, 30])
    }

    // MARK: - characterBookRaw == nil 形态（通过解析器层确认）

    /// `characterBookRaw` 不存在（顶层 nil）→ 直接 .null → 解析器层 no-op。
    /// 真正的"adopt 返回 nil"由 `WorldBookStore.adoptEmbeddedWorldBook` 守护
    /// （guard .object 早退），本测试只确认解析器对 .null 输入不崩。
    func testParseNilCharacterBookRawDoesNotCrash() {
        XCTAssertTrue(WorldBook.parseSillyTavernEntries(from: .null).isEmpty)
    }
}

private extension JSONValue {
    /// 便捷从 .object 取子 dict；非 object → nil。
    var objectValue: [String: JSONValue]? {
        if case .object(let d) = self { return d }
        return nil
    }
}
