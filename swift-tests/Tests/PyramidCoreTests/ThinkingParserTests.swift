import XCTest
@testable import PyramidCore

/// ThinkingParser：思维链 `<think>` 块提取的行为锁定。
final class ThinkingParserTests: XCTestCase {

    /// 单个已闭合块：思考被剥离，正文保留并去首尾空白。
    func testSingleClosedBlock() {
        let input = "<think>推理过程A</think>\n\n正文内容。"
        let r = ThinkingParser.parse(input)
        XCTAssertEqual(r.thinking, "推理过程A")
        XCTAssertFalse(r.isIncomplete)
        XCTAssertEqual(r.body, "正文内容。")
    }

    /// 多个块按顺序合并；中间的普通文本留在正文。
    func testMultipleBlocksMergedInOrder() {
        let input = "<think>A</think>开头<think>B</think>结尾"
        let r = ThinkingParser.parse(input)
        XCTAssertEqual(r.thinking, "A\n\nB")
        XCTAssertEqual(r.body, "开头结尾")
    }

    /// 大小写不敏感 + 开标签允许属性 + thinking 别名。
    func testCaseInsensitiveAndAttributes() {
        let input = "<THINK foo=\"1\">X</Think>正文<thinking>y</thinking>"
        let r = ThinkingParser.parse(input)
        XCTAssertEqual(r.thinking, "X\n\ny")
        XCTAssertEqual(r.body, "正文")
    }

    /// 流式 / 截断：未闭合 → 其后全部视为思考，isIncomplete = true。
    func testUnterminatedBlockIsIncomplete() {
        let input = "<think>\n还在推理"
        let r = ThinkingParser.parse(input)
        XCTAssertEqual(r.thinking, "\n还在推理".trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(r.isIncomplete)
        XCTAssertEqual(r.body, "")
    }

    /// 已闭合块之后的孤立开标签才触发未闭合兜底；闭合块优先。
    func testClosedBlockThenUnterminatedTail() {
        let input = "<think>完整块</think>答案<think>截断的"
        let r = ThinkingParser.parse(input)
        XCTAssertEqual(r.thinking, "完整块\n\n截断的")
        XCTAssertTrue(r.isIncomplete)
        XCTAssertEqual(r.body, "答案")
    }

    /// 无标签 → 原样返回（连首尾空白都不动）。
    func testNoTagsPassthroughUntouched() {
        let input = "  普通正文\n"
        let r = ThinkingParser.parse(input)
        XCTAssertNil(r.thinking)
        XCTAssertFalse(r.isIncomplete)
        XCTAssertEqual(r.body, input)
    }

    /// 自定义标签列表生效；空列表不动原文。
    func testCustomTagListAndEmptyList() {
        let custom = ThinkingParser.parse("<reasoning>R</reasoning>正文", tags: ["reasoning"])
        XCTAssertEqual(custom.thinking, "R")
        XCTAssertEqual(custom.body, "正文")

        let none = ThinkingParser.parse("<think>T</think>正文", tags: [])
        XCTAssertNil(none.thinking)
        XCTAssertEqual(none.body, "<think>T</think>正文")
    }

    /// 空思考块（只有空白）不算有思维链，但剥离仍然发生。
    func testWhitespaceOnlyBlockStrippedWithoutThinking() {
        let input = "<think>   </think>正文"
        let r = ThinkingParser.parse(input)
        XCTAssertNil(r.thinking)
        XCTAssertFalse(r.isIncomplete)
        XCTAssertEqual(r.body, "正文")
    }

    /// 多行思考内容完整保留。
    func testMultilineBlockPreserved() {
        let input = "<think>第一行\n第二行\n\n第三段</think>\n回复。"
        let r = ThinkingParser.parse(input)
        XCTAssertEqual(r.thinking, "第一行\n第二行\n\n第三段")
        XCTAssertEqual(r.body, "回复。")
    }
}
