import XCTest
@testable import PyramidCore

final class MacroExpanderTests: XCTestCase {

    func test_emptyStringPassthrough() {
        XCTAssertEqual(MacroExpander.expand("", user: "Alice", char: "Bob"), "")
    }

    func test_expandUser() {
        XCTAssertEqual(
            MacroExpander.expand("Hello {{user}}", user: "Alice", char: "Bob"),
            "Hello Alice"
        )
    }

    func test_expandChar() {
        XCTAssertEqual(
            MacroExpander.expand("Hi {{char}}", user: "Alice", char: "Bob"),
            "Hi Bob"
        )
    }

    func test_expandBothInSameText() {
        XCTAssertEqual(
            MacroExpander.expand("{{user}} meets {{char}}", user: "Alice", char: "Bob"),
            "Alice meets Bob"
        )
    }

    func test_caseInsensitiveUser() {
        XCTAssertEqual(MacroExpander.expand("{{USER}}", user: "A", char: "B"), "A")
        XCTAssertEqual(MacroExpander.expand("{{User}}", user: "A", char: "B"), "A")
        XCTAssertEqual(MacroExpander.expand("{{uSeR}}", user: "A", char: "B"), "A")
    }

    func test_caseInsensitiveChar() {
        XCTAssertEqual(MacroExpander.expand("{{CHAR}}", user: "A", char: "B"), "B")
        XCTAssertEqual(MacroExpander.expand("{{Char}}", user: "A", char: "B"), "B")
    }

    func test_whitespaceInsideBraces() {
        XCTAssertEqual(MacroExpander.expand("{{ user }}", user: "A", char: "B"), "A")
        XCTAssertEqual(MacroExpander.expand("{{user }}", user: "A", char: "B"), "A")
        XCTAssertEqual(MacroExpander.expand("{{ user}}", user: "A", char: "B"), "A")
    }

    func test_multipleOccurrences() {
        XCTAssertEqual(
            MacroExpander.expand("{{user}}-{{user}}-{{char}}", user: "A", char: "B"),
            "A-A-B"
        )
    }

    func test_unknownMacroLeftLiteral() {
        XCTAssertEqual(
            MacroExpander.expand("{{time}} and {{user}}", user: "A", char: "B"),
            "{{time}} and A"
        )
    }

    func test_valueWithRegexMetaChars() {
        // 替换模板里的 $1 / $2 等反向引用不能误用：replacement 当字面量处理。
        XCTAssertEqual(
            MacroExpander.expand("Hi {{user}}", user: "$1\\d", char: "B"),
            "Hi $1\\d"
        )
    }

    func test_emptyValues() {
        XCTAssertEqual(MacroExpander.expand("Hi {{user}}", user: "", char: ""), "Hi ")
    }
}
