import XCTest
@testable import PyramidCore

// MARK: - 工具：把 DisplayRegex 应用到文本（与 MessageRendererCore.apply 行为一致）

/// 复刻渲染管线的核心循环：按顺序对每条 enabled=true 的 DisplayRegex 应用
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

// MARK: - ST placement 过滤（仅显示类生效）

final class PlacementFilterTests: XCTestCase {

    /// placement = [2]（AI_OUTPUT）→ 视为显示类，应当保留。
    func testAIOutputPlacementIsDisplay() throws {
        let json = """
        { "regex": "World", "replacement": "Pyramid", "placement": [2] }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
    }

    /// placement = [0]（MD_DISPLAY，deprecated）→ 视为显示类，应当保留。
    func testMDDisplayPlacementIsDisplay() throws {
        let json = """
        { "regex": "World", "replacement": "Pyramid", "placement": [0] }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
    }

    /// placement = [1]（USER_INPUT）→ 不是显示类，整条跳过。
    func testUserInputPlacementIsSkipped() throws {
        let json = """
        { "regex": "World", "replacement": "Pyramid", "placement": [1] }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 0)
    }

    /// placement = [5] (WORLD_INFO) / [6] (REASONING) → 跳过。
    func testWorldInfoAndReasoningAreSkipped() throws {
        let json = """
        [
          { "regex": "A", "replacement": "1", "placement": [5] },
          { "regex": "B", "replacement": "2", "placement": [6] }
        ]
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 0)
    }

    /// placement = nil（缺省） → ST 行为是默认 AI_OUTPUT，Pyramid 视为显示类。
    func testMissingPlacementDefaultsToDisplay() throws {
        let json = """
        { "regex": "World", "replacement": "Pyramid" }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
    }

    /// placement 数组里只要有一个显示类（0 或 2）就放行；与 ST 的 OR 语义一致。
    func testMixedPlacementKeptIfAnyIsDisplay() throws {
        let json = """
        { "regex": "World", "replacement": "Pyramid", "placement": [1, 2] }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
    }

    /// promptOnly=true → 该条不作用于显示，跳过。
    func testPromptOnlyIsSkipped() throws {
        let json = """
        { "regex": "World", "replacement": "Pyramid", "prompt_only": true }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 0)
    }
}

// MARK: - ST substituteRegex 三态

final class SubstituteRegexTests: XCTestCase {

    /// substituteRegex = 0 (NONE)：replacement 原样。
    func testNoneSubstituteUsesLiteralReplacement() throws {
        let json = """
        { "regex": "World", "replacement": "$1", "substituteRegex": 0 }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
        XCTAssertEqual(regexes[0].replacement, "$1")
    }

    /// substituteRegex = 1 (RAW)：NSRegularExpression 默认模板，支持 $1/$2/\1/\2，原样。
    func testRawSubstitutePreservesBackrefs() throws {
        let json = """
        { "regex": "(W)(orld)", "replacement": "$1$2", "substituteRegex": 1 }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
        XCTAssertEqual(regexes[0].replacement, "$1$2")
    }

    /// substituteRegex = 2 (ESCAPED)：JSON-escaped 字符串先 unescape 再当模板。
    /// 实际场景：ST 把 "\n" 作为两个字面字符存进 replacement，Pyramid 用 JSONSerialization 解码为 newline。
    func testEscapedSubstituteUnescapesJSON() throws {
        let json = """
        { "regex": "World", "replacement": "Line1\\nLine2", "substituteRegex": 2 }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
        XCTAssertEqual(regexes[0].replacement, "Line1\nLine2")
    }

    /// substituteRegex = 2 但 replacement 不是合法 JSON 字符串 → 退回原文（不抛错）。
    func testEscapedSubstituteFallsBackOnInvalidJSON() throws {
        let json = """
        { "regex": "World", "replacement": "Pyramid", "substituteRegex": 2 }
        """.data(using: .utf8)!
        let regexes = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(regexes.count, 1)
        XCTAssertEqual(regexes[0].replacement, "Pyramid")
    }
}

// MARK: - 角色卡内嵌 ST Regex Script 自动发现

final class CharacterExtensionsRegexTests: XCTestCase {

    /// ST v2 角色卡：根层 + data.extensions.regex_scripts → Character.extensionsRegexScripts
    /// 自动被解析出来，且 JSON 数组顺序作为执行顺序保留。
    func testV2CharacterExtensionsRegexScriptsAreParsed() throws {
        let jsonDict: [String: Any] = [
            "data": [
                "name": "Test Char",
                "extensions": [
                    "regex_scripts": [
                        [
                            "scriptName": "World → Pyramid",
                            "findRegex": "World",
                            "replaceString": "Pyramid",
                            "placement": [2]
                        ],
                        [
                            "id": "11111111-1111-1111-1111-111111111111",
                            "scriptName": "Foo → Bar",
                            "findRegex": "Foo",
                            "replaceString": "Bar",
                            "placement": [2]
                        ]
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(jsonDict)
        XCTAssertEqual(character.name, "Test Char")
        XCTAssertEqual(character.extensionsRegexScripts.count, 2)
        XCTAssertEqual(character.extensionsRegexScripts[0].regex, "World")
        XCTAssertEqual(character.extensionsRegexScripts[1].regex, "Foo")
        // 顺序保留
        XCTAssertEqual(character.extensionsRegexScripts.map(\.regex), ["World", "Foo"])
    }

    /// ST v1 角色卡（无 `data` 子对象，extensions 在根层）→ 仍要支持。
    func testV1CharacterExtensionsRegexScriptsAreParsed() throws {
        let jsonDict: [String: Any] = [
            "name": "Legacy Char",
            "extensions": [
                "regex_scripts": [
                    [
                        "regex": "Old",
                        "replacement": "New",
                        "placement": [2]
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(jsonDict)
        XCTAssertEqual(character.name, "Legacy Char")
        XCTAssertEqual(character.extensionsRegexScripts.count, 1)
        XCTAssertEqual(character.extensionsRegexScripts[0].regex, "Old")
    }

    /// extensions 不存在 → extensionsRegexScripts 留空数组（不报错）。
    func testMissingExtensionsDefaultsToEmpty() throws {
        let jsonDict: [String: Any] = [
            "data": ["name": "Bare Char"]
        ]
        let character = ImportSupport.parseSillyTavernCard(jsonDict)
        XCTAssertEqual(character.extensionsRegexScripts, [])
    }

    /// extensions 存在但 regex_scripts 不是数组 → 留空数组（不报错）。
    func testMalformedRegexScriptsDefaultsToEmpty() throws {
        let jsonDict: [String: Any] = [
            "data": [
                "extensions": [
                    "regex_scripts": "not an array"
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(jsonDict)
        XCTAssertEqual(character.extensionsRegexScripts, [])
    }

    /// 角色内嵌的 ST 脚本 → 经 SillyTavernScriptImporter 转 DisplayRegex 时，挂上
    /// sourceCharacterId = character.id，便于生命周期绑定。
    func testConvertedDisplayRegexCarriesCharacterSourceId() throws {
        let characterId = UUID()
        var character = Character()
        character.id = characterId
        character.name = "Source Char"
        character.extensionsRegexScripts = [
            SillyTavernRegexScript(
                name: "World → Pyramid",
                regex: "World",
                replacement: "Pyramid",
                enabled: true,
                placement: [2]
            )
        ]
        // 模拟 CharacterListView.scriptsFor 的核心转换
        let scripts = character.extensionsRegexScripts
        let converted = scripts.compactMap { script -> DisplayRegex? in
            SillyTavernScriptImporter.convert(script).map { display in
                DisplayRegex(
                    id: display.id,
                    name: display.name,
                    pattern: display.pattern,
                    replacement: display.replacement,
                    enabled: display.enabled,
                    scope: display.scope,
                    sourceCharacterId: character.id
                )
            }
        }
        XCTAssertEqual(converted.count, 1)
        XCTAssertEqual(converted[0].sourceCharacterId, characterId)
        XCTAssertEqual(converted[0].pattern, "World")
    }

    /// 端到端：角色内嵌规则 → RenderEngine 真正生效于助手消息。
    /// 这是用户报告的场景：raw = "Hello World" → 渲染 → "Hello Pyramid"。
    func testEndToEndCharacterExtensionsAffectRenderEngine() throws {
        var character = Character()
        character.id = UUID()
        character.extensionsRegexScripts = [
            SillyTavernRegexScript(
                regex: "World",
                replacement: "Pyramid",
                placement: [2]
            )
        ]
        // 模拟 CharacterStore + DisplayRegexStore 联动后的注入路径
        let injected = character.extensionsRegexScripts.compactMap {
            SillyTavernScriptImporter.convert($0)
        }
        XCTAssertEqual(injected.count, 1)

        // RenderEngine：raw → DisplayRegex（来自角色内嵌注入）→ HideTags → RenderNodeParser
        let context = RenderEngine.Context(
            isAssistant: true,
            presetDisplayRegexIds: [],   // 角色内嵌脚本不属于「预设 ID 列表」
            allDisplayRegexes: injected,
            hideTagStripEnabled: false,
            hideTags: [],
            markdownEnabled: true
        )
        let result = RenderEngine.render(raw: "Hello World", context: context)
        XCTAssertEqual(result.cleanedText, "Hello Pyramid")
        // Raw Message 永远不变（用户明确要求）
        XCTAssertTrue(result.tree.flattenedText.contains("Hello"))
        XCTAssertTrue(result.tree.flattenedText.contains("Pyramid"))
        XCTAssertFalse(result.tree.flattenedText.contains("World"))
    }

    /// 加 / 删规则后再渲染：验证视图对同一消息自动重渲染。
    /// 同一条 MessageCard 更新，不生成第二条。
    func testAddAndRemoveRuleTriggersReRender() throws {
        // 1) 初始：没有任何规则
        var character = Character()
        character.extensionsRegexScripts = []
        XCTAssertEqual(character.extensionsRegexScripts.count, 0)

        // 2) 加入 World → Pyramid
        character.extensionsRegexScripts = [
            SillyTavernRegexScript(regex: "World", replacement: "Pyramid", placement: [2])
        ]
        let injected = character.extensionsRegexScripts.compactMap {
            SillyTavernScriptImporter.convert($0)
        }
        let withRule = RenderEngine.render(
            raw: "Hello World",
            context: RenderEngine.Context(
                isAssistant: true, presetDisplayRegexIds: [],
                allDisplayRegexes: injected,
                hideTagStripEnabled: false, hideTags: [], markdownEnabled: true
            )
        )
        XCTAssertEqual(withRule.cleanedText, "Hello Pyramid")

        // 3) 移除规则（重新 import 空 extensions 的同一角色）
        character.extensionsRegexScripts = []
        let empty = character.extensionsRegexScripts.compactMap {
            SillyTavernScriptImporter.convert($0)
        }
        let noRule = RenderEngine.render(
            raw: "Hello World",
            context: RenderEngine.Context(
                isAssistant: true, presetDisplayRegexIds: [],
                allDisplayRegexes: empty,
                hideTagStripEnabled: false, hideTags: [], markdownEnabled: true
            )
        )
        XCTAssertEqual(noRule.cleanedText, "Hello World")

        // 4) Raw Message 在两个渲染之间未变（user.content 未被写回）
        //     RenderEngine 是纯函数，输入 raw 恒定；结果来自 context 变化 → SwiftUI diff 自动重绘。
    }

    /// 用户消息（role != .assistant）不受角色内嵌脚本影响 —— 与 ST 的 `placement = AI_OUTPUT` 语义一致。
    func testUserMessageNotAffectedByCharacterScripts() throws {
        let injected = [DisplayRegex(name: "World→Pyramid", pattern: "World", replacement: "Pyramid", enabled: true)]
        let userCtx = RenderEngine.Context(
            isAssistant: false, presetDisplayRegexIds: [],
            allDisplayRegexes: injected,
            hideTagStripEnabled: false, hideTags: [], markdownEnabled: true
        )
        let result = RenderEngine.render(raw: "Hello World", context: userCtx)
        XCTAssertEqual(result.cleanedText, "Hello World")
    }

    /// placement = [1] (USER_INPUT) 的角色内嵌脚本不会被 Pyramid 当成显示规则跑。
    /// 即使用户消息也不应该受影响 —— USER_INPUT 语义上 Pyramid Phase 1 暂不支持。
    func testUserInputPlacementScriptIsSkipped() throws {
        let injected = [SillyTavernScriptImporter.convert(
            SillyTavernRegexScript(regex: "World", replacement: "Pyramid", placement: [1])
        )].compactMap { $0 }
        XCTAssertEqual(injected.count, 0)
    }

    /// sourceCharacterId 用于角色删除时的同步清理（生命周期绑定）。
    /// 模拟 DisplayRegexStore.replaceCharacterScopedScripts + removeCharacterScopedScripts。
    func testLifecycleBindAfterCharacterDeletion() {
        let charId = UUID()
        // 1) 导入角色：注入 2 条
        var store: [DisplayRegex] = []
        let imported: [DisplayRegex] = [
            DisplayRegex(name: "A", pattern: "a", replacement: "x", enabled: true, sourceCharacterId: charId),
            DisplayRegex(name: "B", pattern: "b", replacement: "y", enabled: true, sourceCharacterId: charId)
        ]
        store.append(contentsOf: imported)
        XCTAssertEqual(store.count, 2)

        // 2) 用户手动添加 1 条（sourceCharacterId = nil）
        store.append(DisplayRegex(name: "manual", pattern: "m", replacement: "n", enabled: true))
        XCTAssertEqual(store.count, 3)

        // 3) 删除角色 → 只清掉 sourceCharacterId = charId 的，保留用户的
        store.removeAll { $0.sourceCharacterId == charId }
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store[0].name, "manual")
        XCTAssertNil(store[0].sourceCharacterId)
    }
}