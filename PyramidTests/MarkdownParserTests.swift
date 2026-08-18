import XCTest
@testable import Pyramid

/// `MarkdownParser` 块级解析的单元测试。
/// Pyramid iOS app 内 PyramidTests target 跑这些；不在 swift-tests 包里跑
/// （因为 MarkdownParser 与 SwiftUI/UIKit 同文件，没法抽到 SPM）。
final class MarkdownParserTests: XCTestCase {

    func testEmptyTextProducesNoBlocks() {
        XCTAssertEqual(MarkdownParser.blocks(from: ""), [])
    }

    func testSingleLineIsParagraph() {
        XCTAssertEqual(MarkdownParser.blocks(from: "hello world"),
                       [.paragraph("hello world")])
    }

    func testHeadingLevels() {
        XCTAssertEqual(MarkdownParser.blocks(from: "# h1"), [.heading(1, "h1")])
        XCTAssertEqual(MarkdownParser.blocks(from: "## h2"), [.heading(2, "h2")])
        XCTAssertEqual(MarkdownParser.blocks(from: "### h3"), [.heading(3, "h3")])
        XCTAssertEqual(MarkdownParser.blocks(from: "###### h6"), [.heading(6, "h6")])
    }

    func testFencedCodeBlock() {
        let input = "```\nlet x = 1\nprint(x)\n```"
        let expected: [MarkdownBlock] = [.codeBlock("let x = 1\nprint(x)")]
        XCTAssertEqual(MarkdownParser.blocks(from: input), expected)
    }

    func testFencedCodeBlockPreservesTrailingLines() {
        let input = "```\ncode\n```\nafter"
        XCTAssertEqual(MarkdownParser.blocks(from: input),
                       [.codeBlock("code"), .paragraph("after")])
    }

    func testThematicBreak() {
        XCTAssertEqual(MarkdownParser.blocks(from: "---"), [.thematicBreak])
        XCTAssertEqual(MarkdownParser.blocks(from: "***"), [.thematicBreak])
        XCTAssertEqual(MarkdownParser.blocks(from: "___"), [.thematicBreak])
        XCTAssertEqual(MarkdownParser.blocks(from: "-----"), [.thematicBreak])
        XCTAssertEqual(MarkdownParser.blocks(from: "- - -"), [.thematicBreak])
    }

    func testBlockquote() {
        XCTAssertEqual(MarkdownParser.blocks(from: "> hello"), [.blockquote("hello")])
        XCTAssertEqual(MarkdownParser.blocks(from: "> line one\n> line two"),
                       [.blockquote("line one\nline two")])
    }

    func testUnorderedList() {
        XCTAssertEqual(MarkdownParser.blocks(from: "- a\n- b\n- c"),
                       [.unorderedList(["a", "b", "c"])])
        XCTAssertEqual(MarkdownParser.blocks(from: "* star\n+ plus"),
                       [.unorderedList(["star", "plus"])])
    }

    func testOrderedList() {
        XCTAssertEqual(MarkdownParser.blocks(from: "1. one\n2. two"),
                       [.orderedList(["one", "two"])])
        XCTAssertEqual(MarkdownParser.blocks(from: "10. ten\n11. eleven"),
                       [.orderedList(["ten", "eleven"])])
    }

    func testBlankLinesSeparateBlocks() {
        let input = "# Title\n\nparagraph\n\n- item"
        XCTAssertEqual(MarkdownParser.blocks(from: input),
                       [.heading(1, "Title"), .paragraph("paragraph"), .unorderedList(["item"])])
    }

    func testParagraphMergesConsecutiveLines() {
        XCTAssertEqual(MarkdownParser.blocks(from: "line one\nline two"),
                       [.paragraph("line one\nline two")])
    }

    func testUnknownSyntaxFallsBackToParagraph() {
        // '#######' (7 个 #) 不是合法 heading（h1-h6），应降级为段落。
        XCTAssertEqual(MarkdownParser.blocks(from: "####### too many"),
                       [.paragraph("####### too many")])
    }
}
