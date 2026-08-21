import XCTest
@testable import PyramidCore

/// P6: Deferred 显示层回归测试。
///
/// **背景**：此前 `MessageRendererCore.shouldRunOnDisplay` 把「pattern 触碰原生
/// transpile token」或「replacement 含 HTML」的规则一律跳过 —— 角色卡 extension
/// 提供的 Placeholder 皮肤从未执行，占位符永远退化为通用变量树投影。
///
/// **锁定的不变量**：
/// 1. extension Regex 被导入（SillyTavernScriptImporter）→ 正常进入 deferred 层
/// 2. deferred 规则受控执行，替换产物不再被一刀切跳过
/// 3. 纯文本 replacement → 拼回文本流（普通 Renderer）
/// 4. 可识别 Tavern 表达 replacement → 拼回文本流 → RenderNodeParser → NativeIR
/// 5. 无法转换的 HTML replacement → `DeferredResidual` 原文保留，绝不静默丢弃
/// 6. 同一内容只处理一次：token 被 replacement 消费后不再二次 transpile
/// 7. 普通 Regex 行为不变；disabled / promptOnly 仍不进显示链
/// 8. 周边正文与顺序完整保留
final class DeferredDisplayRegexTests: XCTestCase {

    // MARK: - helpers

    private func makeRule(
        name: String = "test-rule",
        pattern: String,
        replacement: String,
        enabled: Bool = true,
        promptOnly: Bool = false
    ) -> DisplayRegex {
        DisplayRegex(
            name: name,
            pattern: pattern,
            replacement: replacement,
            enabled: enabled,
            promptOnly: promptOnly
        )
    }

    private func renderAssistant(
        _ raw: String,
        rules: [DisplayRegex]
    ) -> RenderEngine.Result {
        RenderEngine.render(
            raw: raw,
            context: RenderEngine.Context(
                isAssistant: true,
                presetDisplayRegexIds: [],
                allDisplayRegexes: rules,
                hideTagStripEnabled: false,
                hideTags: [],
                markdownEnabled: false
            )
        )
    }

    private func textContents(of result: RenderEngine.Result) -> [String] {
        result.tree.nodes.compactMap { node in
            if case let .text(s) = node { return s }
            return nil
        }
    }

    private func residuals(in result: RenderEngine.Result) -> [MessageRendererCore.DeferredResidual] {
        result.tree.nodes.compactMap { node in
            if case let .deferredResidual(r) = node { return r }
            return nil
        }
    }

    /// 一段典型的角色卡皮肤 replacement：HTML 包裹 + 原生表达。
    private static let mixedSkin =
        "<div class=\"status-card\">前情</div><StatusPlaceHolderImpl/>"

    // MARK: - 候选判定

    func testDeferredCandidateClassification() {
        // pattern 触碰原生 token → deferred
        XCTAssertTrue(MessageRendererCore.isDeferredCandidate(makeRule(
            pattern: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "[状态]"
        )))
        // replacement 含 HTML token → deferred
        XCTAssertTrue(MessageRendererCore.isDeferredCandidate(makeRule(
            pattern: "foo",
            replacement: "<div>x</div>"
        )))
        // 普通规则 → 不是 deferred（走 Tier A，行为不变）
        XCTAssertFalse(MessageRendererCore.isDeferredCandidate(makeRule(
            pattern: "World",
            replacement: "Pyramid"
        )))
        // disabled / promptOnly → 两层都不进
        XCTAssertFalse(MessageRendererCore.isDeferredCandidate(makeRule(
            pattern: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "x",
            enabled: false
        )))
        XCTAssertFalse(MessageRendererCore.isDeferredCandidate(makeRule(
            pattern: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "x",
            promptOnly: true
        )))
    }

    // MARK: - splitReplacement

    func testSplitReplacementSeparatesNativeFromMarkup() {
        let pieces = MessageRendererCore.splitReplacement(DeferredDisplayRegexTests.mixedSkin)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0], MessageRendererCore.ReplacementPiece(
            content: "<div class=\"status-card\">前情</div>",
            isNativeExpression: false
        ))
        XCTAssertEqual(pieces[1], MessageRendererCore.ReplacementPiece(
            content: "<StatusPlaceHolderImpl/>",
            isNativeExpression: true
        ))
    }

    func testSplitReplacementPureNativeAndPureText() {
        let native = MessageRendererCore.splitReplacement("<StatusPlaceHolderImpl/>")
        XCTAssertEqual(native.count, 1)
        XCTAssertTrue(native[0].isNativeExpression)

        let plain = MessageRendererCore.splitReplacement("[状态栏]")
        XCTAssertEqual(plain.count, 1)
        XCTAssertFalse(plain[0].isNativeExpression)
    }

    func testContainsTagMarkup() {
        XCTAssertTrue(MessageRendererCore.containsTagMarkup("<div>x</div>"))
        XCTAssertFalse(MessageRendererCore.containsTagMarkup("心情 <3 一整天"))
        XCTAssertFalse(MessageRendererCore.containsTagMarkup("纯文本"))
    }

    // MARK: - 端到端：导入 → 执行 → 分类 → NativeIR

    /// 核心回归：extension 导入的皮肤规则（pattern 命中占位符）不再被跳过；
    /// 混合产物中 HTML 部分冻结为残留、原生表达部分进入 parser 生成 NativeIR、
    /// 周边正文与顺序完整保留。
    func testSkinRegexExecutesMixedReplacement() {
        let imported = SillyTavernRegexScript(
            name: "状态皮肤",
            regex: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: DeferredDisplayRegexTests.mixedSkin
        )
        guard let rule = SillyTavernScriptImporter.convert(imported) else {
            return XCTFail("extension 皮肤脚本应能导入为 DisplayRegex")
        }
        let raw = "开头\n<StatusPlaceHolderImpl/>\n结尾"
        let result = renderAssistant(raw, rules: [rule])

        // 1) HTML 部分被保留（原文逐字）
        let rs = residuals(in: result)
        XCTAssertEqual(rs.count, 1)
        XCTAssertEqual(rs[0].replacement, "<div class=\"status-card\">前情</div>")
        XCTAssertEqual(rs[0].sourcePattern, rule.pattern)
        XCTAssertEqual(rs[0].ruleName, "状态皮肤")

        // 2) 原生表达进入 NativeIR：占位符节点存在（且只有一个 —— 不重复处理）
        let placeholders = result.tree.nodes.filter {
            if case .statusPlaceholder = $0 { return true }
            return false
        }
        XCTAssertEqual(placeholders.count, 1)

        // 3) 周边正文完整 + 顺序保留
        XCTAssertEqual(result.tree.nodes.count, 4)
        guard case let .text(head) = result.tree.nodes[0] else {
            return XCTFail("节点 0 应是开头文本")
        }
        XCTAssertEqual(head, "开头\n")
        guard case .deferredResidual = result.tree.nodes[1] else {
            return XCTFail("节点 1 应是残留块")
        }
        guard case .statusPlaceholder = result.tree.nodes[2] else {
            return XCTFail("节点 2 应是占位符")
        }
        guard case let .text(tail) = result.tree.nodes[3] else {
            return XCTFail("节点 3 应是结尾文本")
        }
        XCTAssertEqual(tail, "\n结尾")

        // raw 永不被改写
        XCTAssertEqual(raw, "开头\n<StatusPlaceHolderImpl/>\n结尾")
    }

    /// 纯文本 replacement → 拼回文本流，普通 Renderer 接管。
    func testPlainTextReplacementSplicesIntoTextFlow() {
        let rule = makeRule(
            name: "简洁皮肤",
            pattern: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "[状态栏]"
        )
        let result = renderAssistant("A<StatusPlaceHolderImpl/>B", rules: [rule])
        XCTAssertTrue(residuals(in: result).isEmpty)
        XCTAssertFalse(textContents(of: result).contains(where: { $0.contains("StatusPlaceHolder") }))
        XCTAssertEqual(textContents(of: result).joined(), "A[状态栏]B")
    }

    /// 全 HTML replacement → 整体残留，原文一字不丢；token 已被消费，
    /// 不再产生占位符面板（防重复 transpile）。
    func testUnconvertibleReplacementPreservedAsResidual() {
        let html = "<style>.a{color:red}</style><script src=\"//x/y.js\"></script><div>卡片</div>"
        let rule = makeRule(pattern: "<StatusPlaceHolderImpl\\s*/?>", replacement: html)
        let result = renderAssistant("<StatusPlaceHolderImpl/>", rules: [rule])
        let rs = residuals(in: result)
        XCTAssertEqual(rs.count, 1)
        XCTAssertEqual(rs[0].replacement, html)
        // token 已消费 → 无占位符节点
        for node in result.tree.nodes {
            if case .statusPlaceholder = node { XCTFail("不应再有占位符节点") }
        }
        // 文本流里没有泄漏 HTML
        XCTAssertFalse(textContents(of: result).contains(where: { $0.contains("<div>") }))
    }

    /// 空替换（剥除类规则）：按卡面意图移除 token，不崩溃、不动周边文本。
    func testEmptyReplacementStripsTokenWithoutSideEffects() {
        let rule = makeRule(pattern: "<StatusPlaceHolderImpl\\s*/?>", replacement: "")
        let result = renderAssistant("前<StatusPlaceHolderImpl/>后", rules: [rule])
        XCTAssertTrue(residuals(in: result).isEmpty)
        XCTAssertEqual(textContents(of: result).joined(), "前后")
    }

    /// 替换产物重发原生表达（如把 legacy 拼写规范化）→ 进入 Native Transpiler。
    func testRecognizableExpressionRoutedToParser() {
        let rule = makeRule(
            pattern: "<<StatusPlaceHolder>>",
            replacement: "<StatusPlaceHolderImpl/>"
        )
        let result = renderAssistant("hi <<StatusPlaceHolder>>!", rules: [rule])
        let placeholders = result.tree.nodes.filter {
            if case .statusPlaceholder = $0 { return true }
            return false
        }
        XCTAssertEqual(placeholders.count, 1)
    }

    // MARK: - 兼容性

    /// 普通 Regex 行为不变：仍走 Tier A，deferred 序列为空。
    func testOrdinaryRegexUnchanged() {
        let rule = makeRule(pattern: "World", replacement: "Pyramid")
        XCTAssertEqual(
            MessageRendererCore.orderedDeferredRegexes(presetDisplayRegexIds: [], all: [rule]).count,
            0
        )
        let result = renderAssistant("Hello World", rules: [rule])
        XCTAssertEqual(textContents(of: result).joined(), "Hello Pyramid")
    }

    /// disabled / promptOnly 的皮肤规则仍不进显示链；
    /// 占位符 fallback（通用变量树投影）保持原样。
    func testDisabledAndPromptOnlyStillExcluded() {
        let disabled = makeRule(
            pattern: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "<div>皮肤</div>",
            enabled: false
        )
        let promptOnly = makeRule(
            pattern: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "",
            promptOnly: true
        )
        let result = renderAssistant("<StatusPlaceHolderImpl/>", rules: [disabled, promptOnly])
        XCTAssertTrue(residuals(in: result).isEmpty)
        let placeholders = result.tree.nodes.filter {
            if case .statusPlaceholder = $0 { return true }
            return false
        }
        XCTAssertEqual(placeholders.count, 1, "fallback 通用投影应保留")
    }

    /// 预设优先级在 deferred 层同样生效。
    func testPresetOrderingAppliesToDeferredTier() {
        let first = makeRule(name: "first", pattern: "<StatusPlaceHolderImpl\\s*/?>", replacement: "一")
        let second = makeRule(name: "second", pattern: "<StatusPlaceHolderImpl\\s*/?>", replacement: "二")
        let ordered = MessageRendererCore.orderedDeferredRegexes(
            presetDisplayRegexIds: [second.id, first.id],
            all: [first, second]
        )
        XCTAssertEqual(ordered.map(\.name), ["second", "first"])
    }

    /// 多条 deferred 规则按序链式执行；残留块对后续规则不可见，
    /// 文本流中的再发表达可被后续规则继续改写。
    func testChainedDeferredRulesFreezeResidualAndRewriteText() {
        let wrap = makeRule(
            name: "wrap",
            pattern: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "<div>A</div><StatusPlaceHolderImpl/>"
        )
        let simplify = makeRule(
            name: "simplify",
            pattern: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "[状态]"
        )
        let segments = MessageRendererCore.applyDeferred(
            text: "<StatusPlaceHolderImpl/>",
            presetDisplayRegexIds: [],
            all: [wrap, simplify]
        )
        XCTAssertEqual(segments.count, 2)
        guard case let .residual(res) = segments[0] else {
            return XCTFail("段 0 应是残留块")
        }
        XCTAssertEqual(res.replacement, "<div>A</div>")
        XCTAssertEqual(res.ruleName, "wrap")
        guard case let .text(txt) = segments[1] else {
            return XCTFail("段 1 应是文本")
        }
        XCTAssertEqual(txt, "[状态]")
    }

    /// 用户消息不走任何显示正则层。
    func testUserMessagesBypassAllRegexTiers() {
        let rule = makeRule(pattern: "World", replacement: "<div>Pyramid</div>")
        let result = RenderEngine.render(
            raw: "Hello World",
            context: RenderEngine.Context(
                isAssistant: false,
                presetDisplayRegexIds: [],
                allDisplayRegexes: [rule],
                hideTagStripEnabled: false,
                hideTags: [],
                markdownEnabled: false
            )
        )
        XCTAssertEqual(result.tree.nodes, [.text("Hello World")])
    }
}
