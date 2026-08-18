import XCTest
@testable import PyramidCore

// MARK: - 工具：把 DisplayRegex 应用到文本（与 MessageRenderer.applyDisplayRegex 行为一致）

/// 复刻 MessageRenderer 的核心循环：按顺序对每条 enabled=true 的 DisplayRegex 应用
/// `NSRegularExpression(pattern: options: [.dotMatchesLineSeparators]).stringByReplacingMatches(...)`。
/// 这里用 inline flag group 已经被 importer 写入 pattern，所以不需要额外的 Options。
private func applyRegexes(_ regexes: [DisplayRegex], to text: String) -> String {
    var current = text
    for dr in regexes where dr.enabled {
        guard let compiled = try? NSRegularExpression(
            pattern: dr.pattern,
            options: [.dotMatchesLineSeparators]
        ) else { continue }
        let range = NSRange(current.startIndex..., in: current)
        current = compiled.stringByReplacingMatches(
            in: current,
            options: [],
            range: range,
            withTemplate: dr.replacement
        )
    }
    return current
}

// MARK: - JSON 解析

final class SillyTavernJSONParsingTests: XCTestCase {

    func testParsesSingleObjectStandardFields() throws {
        let json = """
        {
          "name": "World → Pyramid",
          "regex": "World",
          "replacement": "Pyramid",
          "enabled": true,
          "flags": "gi"
        }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
        XCTAssertEqual(regexes[0].name, "World → Pyramid")
        XCTAssertEqual(regexes[0].pattern, "(?i)World")  // flags "gi" → g 隐式，i → (?i)
        XCTAssertEqual(regexes[0].replacement, "Pyramid")
        XCTAssertEqual(regexes[0].enabled, true)
    }

    func testParsesArrayPreservesOrder() throws {
        let json = """
        [
          { "regex": "A", "replacement": "1" },
          { "regex": "B", "replacement": "2" },
          { "regex": "C", "replacement": "3" }
        ]
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 3)
        XCTAssertEqual(regexes.map(\.pattern), ["A", "B", "C"])
        XCTAssertEqual(regexes.map(\.replacement), ["1", "2", "3"])
    }

    func testParsesSillyTavernAliases() throws {
        let json = """
        {
          "scriptName": "Strip <think>",
          "findRegex": "<think>.*?</think>",
          "replaceString": "",
          "flags": "gs",
          "disabled": false
        }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
        XCTAssertEqual(regexes[0].name, "Strip <think>")
        XCTAssertEqual(regexes[0].pattern, "(?s)<think>.*?</think>")  // g 隐式，s → (?s)
        XCTAssertEqual(regexes[0].replacement, "")
    }

    func testDisabledScriptIsSkipped() throws {
        let json = """
        [
          { "regex": "A", "replacement": "1", "enabled": false },
          { "regex": "B", "replacement": "2", "enabled": true },
          { "regex": "C", "replacement": "3", "disabled": true }
        ]
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
        XCTAssertEqual(regexes[0].pattern, "B")
    }

    func testMissingEnabledDefaultsToTrue() throws {
        let json = """
        { "regex": "X", "replacement": "Y" }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
        XCTAssertEqual(regexes[0].enabled, true)
    }

    func testInvalidPatternIsSkipped() throws {
        let json = """
        [
          { "regex": "", "replacement": "x" },
          { "regex": "[unclosed", "replacement": "x" },
          { "regex": "OK", "replacement": "y" }
        ]
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
        XCTAssertEqual(regexes[0].pattern, "OK")
    }

    func testInvalidJSONThrows() {
        let json = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try SillyTavernScriptImporter.importScripts(from: json)) { error in
            guard case SillyTavernScriptImporter.ImportError.invalidJSON = error else {
                XCTFail("expected ImportError.invalidJSON, got \(error)")
                return
            }
        }
    }
}

// MARK: - Flags 映射

final class FlagMappingTests: XCTestCase {

    func testGFlagIsImplicit() {
        XCTAssertEqual(SillyTavernFlagMapper.inlineGroup(for: "g"), "")
        XCTAssertEqual(SillyTavernFlagMapper.applyFlags("g", to: "abc"), "abc")
    }

    func testIndividualFlags() {
        XCTAssertEqual(SillyTavernFlagMapper.applyFlags("i", to: "abc"), "(?i)abc")
        XCTAssertEqual(SillyTavernFlagMapper.applyFlags("m", to: "abc"), "(?m)abc")
        XCTAssertEqual(SillyTavernFlagMapper.applyFlags("s", to: "abc"), "(?s)abc")
    }

    func testCombinedFlags() {
        // 实现保留输入顺序、重复去重；NSRegularExpression 接受任何合法顺序的 inline group
        XCTAssertEqual(SillyTavernFlagMapper.applyFlags("ims", to: "x"), "(?ims)x")
        XCTAssertEqual(SillyTavernFlagMapper.applyFlags("gggii", to: "x"), "(?i)x")    // 重去除
        XCTAssertEqual(SillyTavernFlagMapper.applyFlags("smi", to: "x"), "(?smi)x")    // 保留输入顺序
    }

    func testUnknownFlagsIgnored() {
        XCTAssertEqual(SillyTavernFlagMapper.applyFlags("u", to: "x"), "x")
        XCTAssertEqual(SillyTavernFlagMapper.applyFlags("y", to: "x"), "x")
        XCTAssertEqual(SillyTavernFlagMapper.applyFlags("x", to: "x"), "x")
        XCTAssertEqual(SillyTavernFlagMapper.applyFlags("gix", to: "x"), "(?i)x")
    }

    func testCaseInsensitiveFlag() throws {
        let json = """
        { "regex": "hello", "replacement": "HI", "flags": "i" }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
        let out = applyRegexes(regexes, to: "Hello HELLO hello")
        XCTAssertEqual(out, "HI HI HI")
    }

    func testDotAllFlag() throws {
        let json = """
        { "regex": "<think>.*?</think>", "replacement": "", "flags": "s" }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        let out = applyRegexes(regexes, to: "before<think>multi\nline</think>after")
        XCTAssertEqual(out, "beforeafter")
    }
}

// MARK: - Scope 映射

final class ScopeMappingTests: XCTestCase {

    func testAllImportedAreAssistantDisplayPre() throws {
        let json = """
        [
          { "regex": "A", "replacement": "a" },
          { "regex": "B", "replacement": "b" }
        ]
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        for r in regexes {
            XCTAssertEqual(r.scope, .assistantDisplayPre)
        }
    }
}

// MARK: - 用户指定的端到端场景

final class EndToEndTests: XCTestCase {

    func testHelloWorldEndToEnd() throws {
        // 输入：Hello **World**
        // Regex：World → Pyramid
        // 期望：Hello **Pyramid**（文本层，** 还在；Markdown 渲染层由 iOS app 验证）
        let json = """
        {
          "name": "World → Pyramid",
          "regex": "World",
          "replacement": "Pyramid",
          "enabled": true,
          "flags": ""
        }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)

        let input = "Hello **World**"
        let output = applyRegexes(regexes, to: input)
        XCTAssertEqual(output, "Hello **Pyramid**")

        // 重要：替换只动 "World"，** 包裹完整保留 —— Pyramid 仍带粗体
        // 交给下游 MarkdownTextView 时，parseInline 会把 **Pyramid** 解析为 bold span
        // （已在前一阶段 CI 验证）。
    }

    func testMultipleScriptsAppliedInOrder() throws {
        // 第一条把 ABC → 123
        // 第二条把 1 → X
        // 期望 ABC → X23（不是 A23）
        let json = """
        [
          { "regex": "ABC", "replacement": "123" },
          { "regex": "1", "replacement": "X" }
        ]
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(applyRegexes(regexes, to: "ABC"), "X23")
    }

    func testDisabledDoesNotApply() throws {
        let json = """
        [
          { "regex": "A", "replacement": "1", "enabled": false },
          { "regex": "B", "replacement": "2" }
        ]
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(applyRegexes(regexes, to: "AB"), "A2")
    }
}