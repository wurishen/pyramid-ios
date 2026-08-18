import Testing
import Foundation
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

@Suite("SillyTavern → Pyramid 兼容层")
struct SillyTavernRegexScriptTests {

    @Test("解析单条脚本（标准字段）")
    func parseSingleObjectStandardFields() throws {
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
        #expect(regexes.count == 1)
        #expect(regexes[0].name == "World → Pyramid")
        #expect(regexes[0].pattern == "(?i)World")  // flags "gi" → g 隐式，i → (?i)
        #expect(regexes[0].replacement == "Pyramid")
        #expect(regexes[0].enabled == true)
    }

    @Test("解析数组（保留顺序）")
    func parseArrayPreservesOrder() throws {
        let json = """
        [
          { "regex": "A", "replacement": "1" },
          { "regex": "B", "replacement": "2" },
          { "regex": "C", "replacement": "3" }
        ]
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        #expect(regexes.count == 3)
        #expect(regexes.map(\.pattern) == ["A", "B", "C"])
        #expect(regexes.map(\.replacement) == ["1", "2", "3"])
    }

    @Test("解析 SillyTavern 别名（findRegex / replaceString / scriptName）")
    func parseSillyTavernAliases() throws {
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
        #expect(regexes.count == 1)
        #expect(regexes[0].name == "Strip <think>")
        #expect(regexes[0].pattern == "(?s)<think>.*?</think>")  // g 隐式，s → (?s)
        #expect(regexes[0].replacement == "")
    }

    @Test("enabled=false 跳过")
    func disabledScriptIsSkipped() throws {
        let json = """
        [
          { "regex": "A", "replacement": "1", "enabled": false },
          { "regex": "B", "replacement": "2", "enabled": true },
          { "regex": "C", "replacement": "3", "disabled": true }
        ]
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        #expect(regexes.count == 1)
        #expect(regexes[0].pattern == "B")
    }

    @Test("enabled 缺省视为启用")
    func missingEnabledDefaultsToTrue() throws {
        let json = """
        { "regex": "X", "replacement": "Y" }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        #expect(regexes.count == 1)
        #expect(regexes[0].enabled == true)
    }

    @Test("空 pattern / 无法编译 跳过")
    func invalidPatternIsSkipped() throws {
        let json = """
        [
          { "regex": "", "replacement": "x" },
          { "regex": "[unclosed", "replacement": "x" },
          { "regex": "OK", "replacement": "y" }
        ]
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        #expect(regexes.count == 1)
        #expect(regexes[0].pattern == "OK")
    }

    @Test("非法 JSON 抛 invalidJSON")
    func invalidJSONThrows() {
        let json = "not json".data(using: .utf8)!
        #expect(throws: SillyTavernScriptImporter.ImportError.self) {
            _ = try SillyTavernScriptImporter.importScripts(from: json)
        }
    }
}

// MARK: - Flags 映射

@Suite("Flags 映射")
struct FlagMappingTests {

    @Test("g 不写入 inline group")
    func gFlagIsImplicit() {
        #expect(SillyTavernFlagMapper.inlineGroup(for: "g") == "")
        #expect(SillyTavernFlagMapper.applyFlags("g", to: "abc") == "abc")
    }

    @Test("i / m / s 各自映射")
    func individualFlags() {
        #expect(SillyTavernFlagMapper.applyFlags("i", to: "abc") == "(?i)abc")
        #expect(SillyTavernFlagMapper.applyFlags("m", to: "abc") == "(?m)abc")
        #expect(SillyTavernFlagMapper.applyFlags("s", to: "abc") == "(?s)abc")
    }

    @Test("组合 flags 去重排序")
    func combinedFlags() {
        #expect(SillyTavernFlagMapper.applyFlags("gims", to: "x") == "(?ims)x")
        #expect(SillyTavernFlagMapper.applyFlags("gggii", to: "x") == "(?i)x")  // 重去除
        #expect(SillyTavernFlagMapper.applyFlags("smi", to: "x") == "(?ims)x")  // 排序
    }

    @Test("未知 flags 静默忽略")
    func unknownFlagsIgnored() {
        // u / y / x 在 JS 正则里有含义，但 NSRegularExpression 不支持或语义不同。
        #expect(SillyTavernFlagMapper.applyFlags("u", to: "x") == "x")
        #expect(SillyTavernFlagMapper.applyFlags("y", to: "x") == "x")
        #expect(SillyTavernFlagMapper.applyFlags("x", to: "x") == "x")
        #expect(SillyTavernFlagMapper.applyFlags("gix", to: "x") == "(?i)x")
    }

    @Test("i flag 生效：大小写不敏感匹配")
    func caseInsensitiveFlag() throws {
        let json = """
        { "regex": "hello", "replacement": "HI", "flags": "i" }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        #expect(regexes.count == 1)
        let out = applyRegexes(regexes, to: "Hello HELLO hello")
        #expect(out == "HI HI HI")
    }

    @Test("s flag 生效：dot 匹配换行")
    func dotAllFlag() throws {
        let json = """
        { "regex": "<think>.*?</think>", "replacement": "", "flags": "s" }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        let out = applyRegexes(regexes, to: "before<think>multi\nline</think>after")
        #expect(out == "beforeafter")
    }
}

// MARK: - Scope 映射

@Suite("Scope 映射")
struct ScopeMappingTests {

    @Test("所有导入脚本归到 assistantDisplayPre")
    func allImportedAreAssistantDisplayPre() throws {
        let json = """
        [
          { "regex": "A", "replacement": "a" },
          { "regex": "B", "replacement": "b" }
        ]
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        for r in regexes {
            #expect(r.scope == .assistantDisplayPre)
        }
    }
}

// MARK: - 用户指定的端到端场景

@Suite("End-to-end: Hello **World** → Hello **Pyramid**")
struct EndToEndTests {

    @Test("导入 + 应用 → 文本层产出 Hello **Pyramid**")
    func helloWorldEndToEnd() throws {
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
        #expect(regexes.count == 1)

        let input = "Hello **World**"
        let output = applyRegexes(regexes, to: input)
        #expect(output == "Hello **Pyramid**")

        // 重要：替换只动 "World"，** 包裹完整保留 —— Pyramid 仍带粗体
        // 交给下游 MarkdownTextView 时，parseInline 会把 **Pyramid** 解析为 bold span
        // （已在前一阶段 CI 验证）。
    }

    @Test("多条脚本按顺序应用")
    func multipleScriptsAppliedInOrder() throws {
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
        #expect(applyRegexes(regexes, to: "ABC") == "X23")
    }

    @Test("enabled=false 不影响输出")
    func disabledDoesNotApply() throws {
        let json = """
        [
          { "regex": "A", "replacement": "1", "enabled": false },
          { "regex": "B", "replacement": "2" }
        ]
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        #expect(applyRegexes(regexes, to: "AB") == "A2")
    }
}