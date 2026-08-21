import XCTest
@testable import PyramidCore

final class WorldBookServiceTests: XCTestCase {

    // MARK: - Helpers

    private func entry(
        keywords: [String] = [],
        secondary: [String] = [],
        content: String = "body",
        title: String = "T",
        enabled: Bool = true,
        constant: Bool = false,
        probability: Int = 100,
        priority: Int = 100,
        matchMode: WorldBookMatchMode = .contains,
        scanDepth: Int? = nil
    ) -> WorldBookEntry {
        WorldBookEntry(
            keywords: keywords,
            secondaryKeywords: secondary,
            content: content,
            title: title,
            isEnabled: enabled,
            isConstant: constant,
            probability: probability,
            priority: priority,
            matchMode: matchMode,
            scanDepth: scanDepth
        )
    }

    // MARK: - selectedEntries

    func test_disabledEntryIsExcluded() {
        let e = entry(keywords: ["猫"], enabled: false)
        let result = WorldBookService.selectedEntries(for: "我看见一只猫", history: [], entries: [e])
        XCTAssertTrue(result.isEmpty)
    }

    func test_isConstantAlwaysMatches() {
        let e = entry(keywords: ["狗"], constant: true)
        let result = WorldBookService.selectedEntries(for: "不相关的输入", history: [], entries: [e])
        XCTAssertEqual(result.count, 1)
    }

    func test_primaryKeywordContains() {
        let e = entry(keywords: ["猫"])
        XCTAssertEqual(WorldBookService.selectedEntries(for: "我有猫", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "我有狗", history: [], entries: [e]).count, 0)
    }

    func test_caseInsensitiveMatch() {
        let e = entry(keywords: ["Cat"])
        XCTAssertEqual(WorldBookService.selectedEntries(for: "I see a cat", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "I see a CAT", history: [], entries: [e]).count, 1)
    }

    func test_primaryAndSecondaryRequired() {
        let e = entry(keywords: ["猫"], secondary: ["橘"])
        XCTAssertEqual(WorldBookService.selectedEntries(for: "我看见橘猫", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "我看见猫", history: [], entries: [e]).count, 0)
    }

    func test_exactMatchWholeWordBoundary() {
        let e = entry(keywords: ["cat"], matchMode: .exact)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "a cat sits", history: [], entries: [e]).count, 1)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "concatenate", history: [], entries: [e]).count, 0)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "cat_5", history: [], entries: [e]).count, 0)
        XCTAssertEqual(WorldBookService.selectedEntries(for: "cat,", history: [], entries: [e]).count, 1)
    }

    func test_priorityOrderingAscending() {
        let a = entry(title: "A", keywords: ["x"], priority: 200)
        let b = entry(title: "B", keywords: ["x"], priority: 50)
        let c = entry(title: "C", keywords: ["x"], priority: 100)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [a, b, c])
        XCTAssertEqual(result.map(\.title), ["B", "C", "A"])
    }

    func test_scanDepthIncludesHistory() {
        let e = entry(keywords: ["旧"], scanDepth: 2)
        let h1 = ChatMessage(role: .user, content: "无关内容")
        let h2 = ChatMessage(role: .assistant, content: "提到旧事")
        let result = WorldBookService.selectedEntries(for: "现在", history: [h1, h2], entries: [e])
        XCTAssertEqual(result.count, 1)
    }

    func test_maxEntriesCap() {
        let entries = (1...25).map { i in
            entry(title: "E\(i)", keywords: ["hit"])
        }
        let result = WorldBookService.selectedEntries(for: "hit", history: [], entries: entries)
        XCTAssertEqual(result.count, WorldBookService.maxEntries)
        XCTAssertEqual(result.count, 20)
    }

    func test_maxCharactersCapSkipsExpensive() {
        let cheap = entry(title: "S", keywords: ["hit"], content: String(repeating: "x", count: 10))
        let huge = entry(title: "H", keywords: ["hit"], content: String(repeating: "y", count: WorldBookService.maxCharacters))
        let result = WorldBookService.selectedEntries(for: "hit", history: [], entries: [huge, cheap])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "S")
    }

    func test_probabilityZeroNeverInjects() {
        let e = entry(keywords: ["x"], constant: false, probability: 0)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [e])
        XCTAssertTrue(result.isEmpty)
    }

    func test_probabilityHundredAlwaysInjects() {
        let e = entry(keywords: ["x"], probability: 100)
        let result = WorldBookService.selectedEntries(for: "x", history: [], entries: [e])
        XCTAssertEqual(result.count, 1)
    }

    func test_probabilityGateDeterministicForSameInput() {
        let e = entry(keywords: ["x"], probability: 50)
        let a = WorldBookService.selectedEntries(for: "x", history: [], entries: [e])
        let b = WorldBookService.selectedEntries(for: "x", history: [], entries: [e])
        XCTAssertEqual(a.map(\.id), b.map(\.id))
    }

    // MARK: - lowercasedKeywords

    func test_lowercasedKeywordsLowercases() {
        let e = entry(keywords: ["Cat", "DOG"], secondary: ["WhIsKeY"])
        let result = WorldBookService.lowercasedKeywords(for: e)
        XCTAssertEqual(result.primary, ["cat", "dog"])
        XCTAssertEqual(result.secondary, ["whiskey"])
    }

    func test_lowercasedKeywordsCacheIsStable() {
        let e = entry(keywords: ["X"])
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
        let e1 = entry(title: "First", content: "one")
        let e2 = entry(title: "Second", content: "two")
        let out = WorldBookService.injectionText(for: [e1, e2])
        XCTAssertTrue(out.contains("[世界书]"))
        XCTAssertTrue(out.contains("### First"))
        XCTAssertTrue(out.contains("one"))
        XCTAssertTrue(out.contains("### Second"))
        XCTAssertTrue(out.contains("two"))
    }
}
