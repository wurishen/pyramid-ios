import XCTest
@testable import PyramidCore

final class WorldBookServiceTests: XCTestCase {

    // MARK: - Helpers

    private func makeEntry(
        title: String = "T",
        content: String = "body",
        keywords: [String] = [],
        secondary: [String] = [],
        scanDepth: Int? = nil,
        probability: Int = 100,
        enabled: Bool = true,
        constant: Bool = false,
        priority: Int = 100,
        matchMode: WorldBookMatchMode = .contains
    ) -> WorldBookEntry {
        WorldBookEntry(
            title: title,
            content: content,
            keywords: keywords,
            secondaryKeywords: secondary,
            scanDepth: scanDepth,
            probability: probability,
            isEnabled: enabled,
            isConstant: constant,
            priority: priority,
            matchMode: matchMode
        )
    }

    // MARK: - selectedEntries

    func test_disabledEntryIsExcluded() {
        let e = makeEntry(keywords: ["猫"], enabled: false)
        let result = WorldBookService.selectedEntries(for: "我看见一只猫", history: [], entries: [e])
        XCTAssertTrue(result.isEmpty)
    }

    func test_isConstantAlwaysMatches() {
        let e = makeEntry(keywords: ["狗"], constant: true)
        let result = WorldBookService.selectedEntries(for: "不相关的输入", history: [], entries: [e])
        XCTAssertEqual(result.count, 1)
    }

    func test_primaryKeywordContains() {
        let e = makeEntry(keywords: ["猫"])
        XCTAssertEqual(WorldBookService.selectedEntries(for: "我有猫", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "我有狗", history: [], entries: [e]).count, 0)
    }

    func test_caseInsensitiveMatch() {
        let e = makeEntry(keywords: ["Cat"])
        XCTAssertEqual(WorldBookService.selectedEntries(for: "I see a cat", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "I see a CAT", history: [], entries: [e]).count, 1)
    }

    func test_primaryAndSecondaryRequired() {
        let e = makeEntry(keywords: ["猫"], secondary: ["橘"])
        XCTAssertEqual(WorldBookService.selectedEntries(for: "我看见橘猫", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "我看见猫", history: [], entries: [e]).count, 0)
    }

    func test_exactMatchWholeWordBoundary() {
        let e = makeEntry(keywords: ["cat"], matchMode: .exact)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "a cat sits", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "concatenate", history: [], entries: [e]).count, 0)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "cat_5", history: [], entries: [e]).count, 0)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "cat,", history: [], entries: [e]).count, 1)
    }

    func test_priorityOrderingAscending() {
        let a = makeEntry(title: "A", keywords: ["x"], priority: 200)
        let b = makeEntry(title: "B", keywords: ["x"], priority: 50)
        let c = makeEntry(title: "C", keywords: ["x"], priority: 100)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [a, b, c])
        XCTAssertEqual(result.map(\.title), ["B", "C", "A"])
    }

    func test_scanDepthIncludesHistory() {
        let e = makeEntry(keywords: ["旧"], scanDepth: 2)
        let h1 = ChatMessage(role: .user, content: "无关内容")
        let h2 = ChatMessage(role: .assistant, content: "提到旧事")
        let result = WorldBookService.selectedEntries(for: "现在", history: [h1, h2], entries: [e])
        XCTAssertEqual(result.count, 1)
    }

    func test_maxEntriesCap() {
        let entries = (1...25).map { i in
            makeEntry(title: "E\(i)", keywords: ["hit"])
        }
        let result = WorldBookService.selectedEntries(for: "hit", history: [], entries: entries)
        XCTAssertEqual(result.count, WorldBookService.maxEntries)
        XCTAssertEqual(result.count, 20)
    }

    func test_maxCharactersCapSkipsExpensive() {
        let cheap = makeEntry(title: "S", content: String(repeating: "x", count: 10), keywords: ["hit"])
        let huge = makeEntry(title: "H", content: String(repeating: "y", count: WorldBookService.maxCharacters), keywords: ["hit"])
        let result = WorldBookService.selectedEntries(for: "hit", history: [], entries: [huge, cheap])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "S")
    }

    func test_probabilityZeroNeverInjects() {
        let e = makeEntry(keywords: ["x"], probability: 0, constant: false)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [e])
        XCTAssertTrue(result.isEmpty)
    }

    func test_probabilityHundredAlwaysInjects() {
        let e = makeEntry(keywords: ["x"], probability: 100)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [e])
        XCTAssertEqual(result.count, 1)
    }

    func test_probabilityGateDeterministicForSameInput() {
        let e = makeEntry(keywords: ["x"], probability: 50)
        let a = WorldBookService.selectedEntries(for: "x", history: [], entries: [e])
        let b = WorldBookService.selectedEntries(for: "x", history: [], entries: [e])
        XCTAssertEqual(a.map(\.id), b.map(\.id))
    }

    // MARK: - lowercasedKeywords

    func test_lowercasedKeywordsLowercases() {
        let e = makeEntry(keywords: ["Cat", "DOG"], secondary: ["WhIsKeY"])
        let result = WorldBookService.lowercasedKeywords(for: e)
        XCTAssertEqual(result.primary, ["cat", "dog"])
        XCTAssertEqual(result.secondary, ["whiskey"])
    }

    func test_lowercasedKeywordsCacheIsStable() {
        let e = makeEntry(keywords: ["X"])
        let a = WorldBookService.lowercasedKeywords(for: e)
        let b = WorldBookService.lowercasedKeywords(for: e)
        XCTAssertEqual(a.primary, b.primary)
        XCTAssertEqual(a.secondary, b.secondary)
    }

    // MARK: - groupByPosition

    func test_groupByPositionBuckets() {
        let a = WorldBookEntry(insertionPosition: .beforeSystem)
        let b = WorldBookEntry(insertionPosition: .afterHistory)
        let c = WorldBookEntry(insertionPosition: .beforeSystem)
        let grouped = WorldBookService.groupByPosition([a, b, c])
        XCTAssertEqual(grouped[.beforeSystem]?.count, 2)
        XCTAssertEqual(grouped[.afterHistory]?.count, 1)
        XCTAssertNil(grouped[.afterSystem])
    }

    // MARK: - injectionText

    func test_injectionTextEmpty() {
        XCTAssertEqual(WorldBookService.injectionText(for: []), "")
    }

    func test_injectionTextHeaderAndEntries() {
        let e1 = makeEntry(title: "First", content: "one")
        let e2 = makeEntry(title: "Second", content: "two")
        let out = WorldBookService.injectionText(for: [e1, e2])
        XCTAssertTrue(out.contains("[世界书]"))
        XCTAssertTrue(out.contains("### First"))
        XCTAssertTrue(out.contains("one"))
        XCTAssertTrue(out.contains("### Second"))
        XCTAssertTrue(out.contains("two"))
    }

    // MARK: - V3 caseSensitive

    func test_caseSensitiveRequiresExactCase() {
        let e = WorldBookEntry(
            keywords: ["Cat"],
            caseSensitive: true
        )
        XCTAssertEqual(WorldBookService.selectedEntries(for: "I see a Cat", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "I see a cat", history: [], entries: [e]).count, 0)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "I see a CAT", history: [], entries: [e]).count, 0)
    }

    func test_caseSensitiveFalseMatchesAnyCase() {
        let e = WorldBookEntry(
            keywords: ["Cat"],
            caseSensitive: false
        )
        XCTAssertEqual(WorldBookService.selectedEntries(for: "I see a cat", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "I see a CAT", history: [], entries: [e]).count, 1)
    }

    func test_caseSensitiveNilDefaultsToInsensitive() {
        // 不设 caseSensitive 应等同于 false
        let e = WorldBookEntry(keywords: ["Cat"])
        XCTAssertEqual(WorldBookService.selectedEntries(for: "I see a CAT", history: [], entries: [e]).count, 1)
    }

    func test_caseSensitiveHistoryLinesAlsoCaseSensitive() {
        // caseSensitive 应同时影响 history 上下文
        let e = WorldBookEntry(keywords: ["SILENT"], scanDepth: 1, caseSensitive: true)
        let h = ChatMessage(role: .user, content: "silent hill")
        let h2 = ChatMessage(role: .user, content: "SILENT hill")
        XCTAssertEqual(WorldBookService.selectedEntries(for: "now", history: [h], entries: [e]).count, 0)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "now", history: [h2], entries: [e]).count, 1)
    }

    // MARK: - V3 excludes

    func test_excludesSuppressesEntry() {
        let e = WorldBookEntry(
            keywords: ["酒馆"],
            excludes: ["关闭"]
        )
        XCTAssertEqual(WorldBookService.selectedEntries(for: "酒馆开着", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "酒馆已经关闭", history: [], entries: [e]).count, 0)
    }

    func test_excludesEmptyArrayIsNoOp() {
        let e = WorldBookEntry(
            keywords: ["酒馆"],
            excludes: []
        )
        XCTAssertEqual(WorldBookService.selectedEntries(for: "酒馆", history: [], entries: [e]).count, 1)
    }

    func test_excludesMultipleAnyMatchExcludes() {
        // 任一 exclude 命中即排除
        let e = WorldBookEntry(
            keywords: ["冒险"],
            excludes: ["战斗", "死亡"]
        )
        XCTAssertEqual(WorldBookService.selectedEntries(for: "开始冒险", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "冒险中发生战斗", history: [], entries: [e]).count, 0)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "冒险者面临死亡", history: [], entries: [e]).count, 0)
    }

    func test_excludesCaseInsensitiveByDefault() {
        // caseSensitive=nil → exclude 默认也按 case-insensitive 比对
        let e = WorldBookEntry(
            keywords: ["x"],
            excludes: ["STOP"]
        )
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x please stop", history: [], entries: [e]).count, 0)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x please STOP", history: [], entries: [e]).count, 0)
    }

    // MARK: - V3 triggers

    func test_triggersRequireAtLeastOneMatch() {
        // V3 默认：primary AND (任一 trigger)
        let e = WorldBookEntry(
            keywords: ["冒险"],
            triggers: ["哥布林", "洞穴"]
        )
        XCTAssertEqual(WorldBookService.selectedEntries(for: "冒险开始", history: [], entries: [e]).count, 0,
                       "primary 命中但 trigger 都未命中 → 排除")
        XCTAssertEqual(WorldBookService.selectedEntries(for: "冒险中遇到哥布林", history: [], entries: [e]).count, 1,
                       "trigger 之一命中 → 注入")
        XCTAssertEqual(WorldBookService.selectedEntries(for: "冒险中进入洞穴", history: [], entries: [e]).count, 1,
                       "另一个 trigger 命中 → 注入")
        XCTAssertEqual(WorldBookService.selectedEntries(for: "去哥布林", history: [], entries: [e]).count, 0,
                       "primary 没命中 → 排除")
    }

    func test_triggersEmptyArrayBehavesAsBefore() {
        let e = WorldBookEntry(keywords: ["x"], triggers: [])
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x", history: [], entries: [e]).count, 1)
    }

    // MARK: - V3 selectiveLogic

    func test_selectiveLogic_AND_ANY_default() {
        // selectiveLogic = 0（默认）：secondary 至少一个命中即通过
        let e = WorldBookEntry(
            keywords: ["x"],
            secondaryKeywords: ["猫", "狗"],
            selectiveLogicRaw: 0
        )
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x 猫", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x 狗", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x", history: [], entries: [e]).count, 0)
    }

    func test_selectiveLogic_NOT_ALL_excludesOnFullMatch() {
        // 1 = NOT_ALL：全部 secondary 命中 → 排除
        let e = WorldBookEntry(
            keywords: ["x"],
            secondaryKeywords: ["猫", "狗"],
            selectiveLogicRaw: 1
        )
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x 猫", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x 狗", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x 猫 狗", history: [], entries: [e]).count, 0,
                       "两个 secondary 都命中 → NOT_ALL 排除")
    }

    func test_selectiveLogic_NOT_ANY_excludesOnAnyMatch() {
        // 2 = NOT_ANY：任一 secondary 命中 → 排除
        let e = WorldBookEntry(
            keywords: ["x"],
            secondaryKeywords: ["猫", "狗"],
            selectiveLogicRaw: 2
        )
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x 猫", history: [], entries: [e]).count, 0)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x 狗", history: [], entries: [e]).count, 0)
    }

    func test_selectiveLogic_AND_ALL_requiresFullMatch() {
        // 3 = AND_ALL：全部 secondary 都必须命中
        let e = WorldBookEntry(
            keywords: ["x"],
            secondaryKeywords: ["猫", "狗"],
            selectiveLogicRaw: 3
        )
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x 猫", history: [], entries: [e]).count, 0)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x 猫 狗", history: [], entries: [e]).count, 1)
    }

    // MARK: - V3 weight

    func test_weightZeroDisablesEntry() {
        let e = WorldBookEntry(keywords: ["x"], weight: 0)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x", history: [], entries: [e]).count, 0)
    }

    func test_weightNegativeDisablesEntry() {
        let e = WorldBookEntry(keywords: ["x"], weight: -1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "x", history: [], entries: [e]).count, 0)
    }

    func test_weightActsAsTiebreaker() {
        // priority 相同的两个 entry：weight 大的排得更前
        let a = WorldBookEntry(title: "A", keywords: ["x"], priority: 100, weight: 50)
        let b = WorldBookEntry(title: "B", keywords: ["x"], priority: 100, weight: 200)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [a, b])
        XCTAssertEqual(result.map(\.title), ["B", "A"])
    }

    // MARK: - V3 decay

    func test_decayOneIsIdentity() {
        // decay=1 → 不应改变排序
        let a = WorldBookEntry(title: "A", keywords: ["x"], priority: 100, decay: 1)
        let b = WorldBookEntry(title: "B", keywords: ["x"], priority: 200, decay: 1)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [a, b])
        XCTAssertEqual(result.map(\.title), ["A", "B"])
    }

    func test_decayZeroPushesEntryLater() {
        // decay=0 → 应大幅推迟（A 比 B 优先级低（priority 数字大）即使 priority 数字更小）
        let decaying = WorldBookEntry(title: "D", keywords: ["x"], priority: 100, decay: 0)
        let baseline = WorldBookEntry(title: "B", keywords: ["x"], priority: 150, decay: 1)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [decaying, baseline])
        XCTAssertEqual(result.map(\.title), ["B", "D"],
                       "decay=0 推后的 D 应排在 priority=150 的 B 之后")
    }

    func test_decayPartialIsInterpolated() {
        // decay=0.5 → 推后 500（(1-0.5)*1000）；priority 数字 < +500 的差 仍排在前
        let a = WorldBookEntry(title: "A", keywords: ["x"], priority: 100, decay: 0.5)
        let b = WorldBookEntry(title: "B", keywords: ["x"], priority: 700, decay: 1)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [a, b])
        // A: 100 + 500 = 600; B: 700 → A 排前
        XCTAssertEqual(result.map(\.title), ["A", "B"])
    }

    // MARK: - V3 useGroupScoring

    func test_groupScoringKeepsTopPerGroup() {
        // 同 groupKey 的两个条目仅保留 priority 较小的那一个
        let groupA1 = WorldBookEntry(title: "G1", keywords: ["x"], priority: 50,
                                      groupKey: "weather", useGroupScoring: true)
        let groupA2 = WorldBookEntry(title: "G2", keywords: ["x"], priority: 100,
                                      groupKey: "weather", useGroupScoring: true)
        let outgroup = WorldBookEntry(title: "OUT", keywords: ["x"], priority: 200)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [groupA1, groupA2, outgroup])
        XCTAssertEqual(result.map(\.title), ["G1", "OUT"],
                       "同组只留 priority=50 那一条；非组外条目不受影响")
    }

    func test_groupScoringRespectsGroupWeightTiebreaker() {
        // priority 相同的组内成员按 groupWeight 高者优先
        let heavier = WorldBookEntry(title: "H", keywords: ["x"], priority: 100,
                                      groupKey: "g", groupWeight: 200, useGroupScoring: true)
        let lighter = WorldBookEntry(title: "L", keywords: ["x"], priority: 100,
                                      groupKey: "g", groupWeight: 50, useGroupScoring: true)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [lighter, heavier])
        XCTAssertEqual(result.map(\.title), ["H"])
    }

    func test_groupScoringDisabledDoesNotFilter() {
        // useGroupScoring=nil/false → 即使 groupKey 相同也不合并
        let a = WorldBookEntry(title: "A", keywords: ["x"], priority: 100, groupKey: "g")
        let b = WorldBookEntry(title: "B", keywords: ["x"], priority: 200, groupKey: "g")
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [a, b])
        XCTAssertEqual(result.map(\.title), ["A", "B"])
    }

    func test_groupScoringEmptyGroupKeyTreatedAsUngrouped() {
        // useGroupScoring=true 但 groupKey 为空 → 不分组
        let a = WorldBookEntry(title: "A", keywords: ["x"], priority: 100,
                                groupKey: "", useGroupScoring: true)
        let b = WorldBookEntry(title: "B", keywords: ["x"], priority: 200,
                                groupKey: "", useGroupScoring: true)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [a, b])
        XCTAssertEqual(result.map(\.title), ["A", "B"])
    }

    // MARK: - V3 组合场景

    func test_caseSensitiveTriggersAndExcludesTogether() {
        // 全组合：caseSensitive=true 时 triggers/excludes 也大小写敏感
        let e = WorldBookEntry(
            keywords: ["Dragon"],
            caseSensitive: true,
            triggers: ["Fire"],
            excludes: ["STOP"]
        )
        XCTAssertEqual(WorldBookService.selectedEntries(for: "Dragon Fire", history: [], entries: [e]).count, 1,
                       "primary + trigger 都命中，无 exclude → 注入")
        XCTAssertEqual(WorldBookService.selectedEntries(for: "Dragon fire", history: [], entries: [e]).count, 0,
                       "trigger 大小写敏感：'Fire' 不匹配 'fire'")
        XCTAssertEqual(WorldBookService.selectedEntries(for: "Dragon Fire STOP", history: [], entries: [e]).count, 0,
                       "exclude 'STOP' 与原文大小写一致 → 排除")
        XCTAssertEqual(WorldBookService.selectedEntries(for: "Dragon Fire stop", history: [], entries: [e]).count, 1,
                       "exclude 大小写敏感：'STOP' 不匹配 'stop'，不排除")
    }

    func test_effectiveSortKeyDecayPlusWeight() {
        // decay 与 weight 同时作用：weight 提前，decay 推后，但 priority 仍是主键
        let normal = WorldBookEntry(title: "N", keywords: ["x"], priority: 100, weight: 50, decay: 1)
        let decayed = WorldBookEntry(title: "D", keywords: ["x"], priority: 100, weight: 1000, decay: 0)
        // N: 100 + 0 + (-0.05) = 99.95
        // D: 100 + 1000 + (-1.0) = 1099 → D 排后（priority 推后 +1000 远超 weight -1）
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [normal, decayed])
        XCTAssertEqual(result.map(\.title), ["N", "D"])
    }
}
