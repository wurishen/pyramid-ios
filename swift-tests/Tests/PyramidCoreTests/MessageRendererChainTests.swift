import XCTest
@testable import PyramidCore

/// MessageCard.contentCard 走 MessageRenderer.preprocess → applyDisplayRegex
/// (委托到 MessageRendererCore.orderedRegexes + apply) → MarkdownTextView(text:)。
/// 这套测试针对 `MessageRendererCore.apply` 直接验证：它就是 iOS 渲染流水线里
/// 真实跑的那段纯算法——`MessageRenderer.applyDisplayRegex` 在拿到顺序后直接
/// 调用 NSRegularExpression 替换，逻辑与本 helper 完全一致。
///
/// 这些是「链路」测试而非单元测试：模拟真实消息进入 MessageCard 时的等价输入，
/// 验证经过 Regex 处理后交给下游 MarkdownTextView 的字符串就是预期的展示文本。
final class MessageRendererChainTests: XCTestCase {

    // MARK: - 公共工具

    private func regex(
        _ pattern: String,
        replacement: String,
        enabled: Bool = true
    ) -> DisplayRegex {
        DisplayRegex(
            name: pattern,
            pattern: pattern,
            replacement: replacement,
            enabled: enabled
        )
    }

    /// 等价于「MessageRenderer.preprocess」里 applyDisplayRegex 阶段（剥隐藏标签是另一段，与 Regex 无关）。
    /// 真实 iOS 调用：MessageRenderer.preprocess(Inputs(raw:role:settings:preset:displayRegexes:))
    /// → applyDisplayRegex → MessageRendererCore.apply(text:isAssistant:presetDisplayRegexIds:all:)。
    /// 本 helper 直接调用核心；preset 由 iOS 端在调用本函数前折算成 [UUID] 后传入。
    private func render(_ raw: String, rules: [DisplayRegex]) -> String {
        MessageRendererCore.apply(
            text: raw,
            isAssistant: true,
            presetDisplayRegexIds: [],
            all: rules
        )
    }

    // MARK: - 用户指定的 7 个测试

    /// 测试 1：输入 "Hello World"，规则 "World → Pyramid"，期望 "Hello Pyramid"
    func test1_singleReplacement() {
        let out = render("Hello World", rules: [regex("World", replacement: "Pyramid")])
        XCTAssertEqual(out, "Hello Pyramid")
    }

    /// 测试 2：输入 "Hello **World**"，规则 "World → Pyramid"。
    /// 期望清洗后是 "Hello **Pyramid**" —— ** 边界完整保留，
    /// 下游 MarkdownTextView.parseInline 会把 **Pyramid** 渲染成粗体 span（Phase 1 实机验证）。
    func test2_inlineMarkdownBoundariesPreserved() {
        let out = render("Hello **World**", rules: [regex("World", replacement: "Pyramid")])
        XCTAssertEqual(out, "Hello **Pyramid**")
    }

    /// 测试 3：输入 "Hello World"，规则 "World → **Pyramid**"。
    /// 期望清洗后是 "Hello **Pyramid**"，由 MarkdownTextView 把 Pyramid 渲染为真正的粗体。
    func test3_replacementCanInjectMarkdown() {
        let out = render("Hello World", rules: [regex("World", replacement: "**Pyramid**")])
        XCTAssertEqual(out, "Hello **Pyramid**")
    }

    /// 测试 4：enabled=false 的规则不执行。
    func test4_disabledRuleDoesNotApply() {
        let rules = [
            regex("World", replacement: "Pyramid", enabled: false),
            regex("Hello", replacement: "Hi")
        ]
        XCTAssertEqual(render("Hello World", rules: rules), "Hi World")
    }

    /// 测试 5：多条规则按数组顺序依次执行。
    /// 规则 1：World → Pyramid
    /// 规则 2：Pyramid → iOS
    /// 输入 "Hello World" → "Hello Pyramid" → "Hello iOS"
    func test5_multipleRulesApplyInOrder() {
        let rules = [
            regex("World", replacement: "Pyramid"),
            regex("Pyramid", replacement: "iOS")
        ]
        XCTAssertEqual(render("Hello World", rules: rules), "Hello iOS")
    }

    /// 测试 6：flags = i 能匹配 World / WORLD / world。
    /// SillyTavernFlagMapper 把 "i" 翻译成 (?i) 内联 flag group，
    /// 之后 MessageRendererCore.apply 把整条 pattern 喂给 NSRegularExpression 即可。
    func test6_caseInsensitiveFlag() throws {
        let pattern = SillyTavernFlagMapper.applyFlags("i", to: "World")
        XCTAssertEqual(pattern, "(?i)World")
        let out = render("Hello World WORLD world", rules: [regex(pattern, replacement: "Pyramid")])
        XCTAssertEqual(out, "Hello Pyramid Pyramid Pyramid")
    }

    /// 测试 7：经过 Regex 之后，Markdown 块级结构标记（# / - / ```）原样保留，
    /// 下一行 MarkdownTextView（MarkdownParser / MarkdownBlock / parseInline）才能正常切分。
    /// 本测试不直接调 MarkdownParser（它定义在 MarkdownTextView.swift 里，依赖 SwiftUI/UIKit，
    /// Linux SPM 包编译不到）；改成「文本层断言」：Regex 只命中指定子串，块级符号保持完整。
    /// 真实 iOS 设备上 MarkdownTextView 仍然能正确渲染这部分——iOS CI 上的 xcodebuild
    /// build 会编进完整 app 链路。
    func test7_markdownBlockStructureSurvivesRegex() {
        let raw = """
        # Title

        - item one
        - item two

        ```
        code block
        ```
        """
        let rules = [
            regex("item one", replacement: "**item one**"),
            regex("Title", replacement: "**Title**")
        ]
        let cleaned = render(raw, rules: rules)

        // Regex 仅替换指定子串；Markdown 块级标记（# / - / ```）原样保留
        XCTAssertTrue(cleaned.contains("# **Title**"), "标题行保留 # 前缀与替换后的 **Title**")
        XCTAssertTrue(cleaned.contains("- **item one**"), "第一条列表项含新加的 **")
        XCTAssertTrue(cleaned.contains("- item two"), "第二条列表项完全不变")
        XCTAssertTrue(cleaned.contains("```"), "围栏代码块的 ``` 必须保留")
        XCTAssertTrue(cleaned.contains("code block"), "代码块内容必须保留")

        // 块级数量：标题 1 + 列表 1 + 代码块 1 = 3 块，空行被 MarkdownParser 跳过后不影响
        let headingCount = cleaned.components(separatedBy: "\n").filter { $0.hasPrefix("# ") }.count
        let listItemCount = cleaned.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count
        let fenceCount = cleaned.components(separatedBy: "```").count - 1   // 一对 ``` 拆成 3 段
        XCTAssertEqual(headingCount, 1)
        XCTAssertEqual(listItemCount, 2)
        XCTAssertEqual(fenceCount, 2)   // 起止两个 ```
    }

    // MARK: - 与角色相关：用户消息不受影响

    /// 用户角色的消息不能被 DisplayRegex 改写——applyDisplayRegex 对非 .assistant 直接 return。
    func test_userRoleSkipsRegex() {
        let out = MessageRendererCore.apply(
            text: "Hello World",
            isAssistant: false,
            presetDisplayRegexIds: [],
            all: [regex("World", replacement: "Pyramid")]
        )
        XCTAssertEqual(out, "Hello World")
    }

    // MARK: - 预设顺序：preset.displayRegexIds 决定执行顺序

    /// preset 指定了 displayRegexIds 时按预设顺序执行；未指定的 enabled 规则作为兜底追加在后面。
    /// 这里不直接构造 Preset（Preset 在 Pyramid/Models/Preset.swift 里，未链接进 SPM 包）；
    /// 等价地用 [UUID] 测试核心算法：MessageRenderer.applyDisplayRegex 会把
    /// preset?.displayRegexIds ?? [] 喂给同一个 helper，行为一致。
    func test_presetOrderOverridesArrayOrder() {
        let rA = regex("A", replacement: "X")
        let rB = regex("B", replacement: "Y")
        let rC = regex("C", replacement: "Z")
        let out = MessageRendererCore.apply(
            text: "A B C",
            isAssistant: true,
            presetDisplayRegexIds: [rB.id, rC.id, rA.id],   // 强制 B → C → A
            all: [rA, rB, rC]
        )
        XCTAssertEqual(out, "X Y Z")
    }

    // MARK: - 与 SillyTavern 导入链路联动

    /// 用户场景：用户上传一份 SillyTavern JSON → importer 转换 → 把结果塞进 store →
    /// 消息进来自动应用。整条链路是否顺畅？
    func test_sillytavernImportDrivesAutoApply() throws {
        let json = """
        [
          { "name": "World → Pyramid", "regex": "World", "replacement": "Pyramid", "flags": "" },
          { "name": "Pyramid → iOS",   "regex": "Pyramid", "replacement": "iOS", "flags": "" }
        ]
        """.data(using: .utf8)!
        let rules = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(render("Hello World", rules: rules), "Hello iOS")
    }

    /// 真实 JSON 含 flags "i" + 嵌套 JSON 字符：整条从 import 到渲染全跑通。
    func test_sillytavernImportWithFlagsDrivesAutoApply() throws {
        let json = """
        [
          { "name": "case-insensitive", "regex": "world", "replacement": "Pyramid", "flags": "i" }
        ]
        """.data(using: .utf8)!
        let rules = try SillyTavernScriptImporter.importScripts(from: json)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].pattern, "(?i)world")
        XCTAssertEqual(render("Hello World WORLD world", rules: rules),
                       "Hello Pyramid Pyramid Pyramid")
    }
}