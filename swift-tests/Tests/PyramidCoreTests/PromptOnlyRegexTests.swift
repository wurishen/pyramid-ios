import XCTest
@testable import PyramidCore

final class PromptOnlyRegexTests: XCTestCase {

    // MARK: - Helpers

    private func regex(
        _ pattern: String,
        replacement: String,
        enabled: Bool = true,
        promptOnly: Bool = false
    ) -> DisplayRegex {
        DisplayRegex(
            name: pattern,
            pattern: pattern,
            replacement: replacement,
            enabled: enabled,
            promptOnly: promptOnly
        )
    }

    // MARK: - shouldRunOnPrompt

    func test_disabledPromptOnlyExcluded() {
        let r = regex("<x/>", replacement: "", enabled: false, promptOnly: true)
        XCTAssertFalse(MessageRendererCore.shouldRunOnPrompt(r))
    }

    func test_nonPromptOnlyExcluded() {
        let r = regex("<x/>", replacement: "", promptOnly: false)
        XCTAssertFalse(MessageRendererCore.shouldRunOnPrompt(r))
    }

    func test_promptOnlyHtmlBeautifyExcluded() {
        let r = regex("<x/>", replacement: "<script>", promptOnly: true)
        XCTAssertFalse(MessageRendererCore.shouldRunOnPrompt(r))
    }

    func test_promptOnlyAllowed() {
        let r = regex("<x/>", replacement: "", promptOnly: true)
        XCTAssertTrue(MessageRendererCore.shouldRunOnPrompt(r))
    }

    // MARK: - orderedPromptOnlyRegexes

    func test_orderedPromptOnlyFiltersNonPromptOnly() {
        let displayOnly = regex("A", replacement: "X")
        let promptOnly = regex("B", replacement: "Y", promptOnly: true)
        let ordered = MessageRendererCore.orderedPromptOnlyRegexes(
            presetDisplayRegexIds: [],
            all: [displayOnly, promptOnly]
        )
        XCTAssertEqual(ordered.count, 1)
        XCTAssertEqual(ordered.first?.pattern, "B")
    }

    func test_orderedPromptOnlyPresetOrderWins() {
        let r1 = regex("A", replacement: "X", promptOnly: true)
        let r2 = regex("B", replacement: "Y", promptOnly: true)
        let r3 = regex("C", replacement: "Z", promptOnly: true)
        let ordered = MessageRendererCore.orderedPromptOnlyRegexes(
            presetDisplayRegexIds: [r3.id, r1.id],
            all: [r1, r2, r3]
        )
        XCTAssertEqual(ordered.map(\.pattern), ["C", "A", "B"])
    }

    // MARK: - applyPromptOnly

    func test_applyPromptOnlyStripsPlaceholder() {
        let r = regex(
            "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "",
            promptOnly: true
        )
        let result = MessageRendererCore.applyPromptOnly(
            text: "前面的话 <StatusPlaceHolderImpl/> 后面的话",
            presetDisplayRegexIds: [],
            all: [r]
        )
        XCTAssertEqual(result, "前面的话  后面的话")
    }

    func test_applyPromptOnlyIgnoresDisplayOnlyRegex() {
        let displayOnly = regex("<x/>", replacement: "STRIPPED")
        let promptOnly = regex("<y/>", replacement: "PROMPT", promptOnly: true)
        let result = MessageRendererCore.applyPromptOnly(
            text: "<x/> <y/>",
            presetDisplayRegexIds: [],
            all: [displayOnly, promptOnly]
        )
        XCTAssertEqual(result, "<x/> PROMPT")
    }

    func test_applyPromptOnlyEmptyWhenNoRules() {
        let result = MessageRendererCore.applyPromptOnly(
            text: "原文不动",
            presetDisplayRegexIds: [],
            all: []
        )
        XCTAssertEqual(result, "原文不动")
    }

    func test_applyPromptOnlyRunsOnUserMessages() {
        let r = regex("<think>.*?</think>", replacement: "", promptOnly: true)
        let result = MessageRendererCore.applyPromptOnly(
            text: "<think>internal</think> 公开内容",
            presetDisplayRegexIds: [],
            all: [r]
        )
        XCTAssertEqual(result, " 公开内容")
    }

    func test_applyPromptOnlySequenceOrder() {
        // r1: 把 foo → bar；r2: 把 bar → baz。最终 foo 应变 baz。
        let r1 = regex("foo", replacement: "bar", promptOnly: true)
        let r2 = regex("bar", replacement: "baz", promptOnly: true)
        let result = MessageRendererCore.applyPromptOnly(
            text: "foo",
            presetDisplayRegexIds: [],
            all: [r1, r2]
        )
        XCTAssertEqual(result, "baz")
    }
}
