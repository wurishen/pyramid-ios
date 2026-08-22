import XCTest
@testable import PyramidCore

/// 第五阶段：真实 Tavern 表达转译链端到端验证。
///
/// 链路：Character Card extension（Display Regex）
///   → Deferred 显示层（Tier B 受控执行 + 产物分类）
///   → replacement 切片（原生表达 / 标记残留 / 纯文本）
///   → RenderNodeParser（原生 token → 结构化节点）
///   → TavernTranspiler / RenderNodeTranspiler → NativeIR。
///
/// **fixture 原则**：名称 / 字段 / UI 全是通用数据 —— 不存在任何 Pyramid 业务组件，
/// 键名不触发分支。所有断言针对通用能力，不绑定具体角色卡。
///
/// **锁定的不变量**：
/// 1. extension Display Regex 能进入 deferred 层
/// 2. replacement 的可识别表达进入 Native 转译通路
/// 3. 可转换表达产出 NativeIR
/// 4. `<NativeAction/>` 交互原语 → NativeAction
/// 5. VariableStore 更新后 NativeIR 重新生成（闭环）
/// 6. 未知表达原文保留（residual）
/// 7. HTML / CSS / JS 不被执行、不泄漏进文本流
/// 8. 同一内容只处理一次（Tier A / Tier B / parser 三层互不重复消费）
/// 9. 原始正文完整保留、顺序不变、raw 永不改写
/// 10. 普通 Display Regex 行为不回归
final class TavernChainIntegrationTests: XCTestCase {

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
        rules: [DisplayRegex],
        store: VariableStore? = nil,
        sessionId: UUID? = nil
    ) -> RenderEngine.Result {
        RenderEngine.render(
            raw: raw,
            context: RenderEngine.Context(
                isAssistant: true,
                presetDisplayRegexIds: [],
                allDisplayRegexes: rules,
                hideTagStripEnabled: false,
                hideTags: [],
                markdownEnabled: false,
                variableStore: store,
                sessionId: sessionId
            )
        )
    }

    private func residuals(in result: RenderEngine.Result) -> [MessageRendererCore.DeferredResidual] {
        result.tree.nodes.compactMap { node in
            if case let .deferredResidual(r) = node { return r }
            return nil
        }
    }

    private func placeholders(in result: RenderEngine.Result) -> [JSONValue] {
        result.tree.nodes.compactMap { node in
            if case let .statusPlaceholder(statData) = node { return statData }
            return nil
        }
    }

    private func actions(in result: RenderEngine.Result) -> [(label: String, action: NativeAction)] {
        result.tree.nodes.compactMap { node in
            if case let .nativeAction(label, action) = node { return (label, action) }
            return nil
        }
    }

    private func textContents(of result: RenderEngine.Result) -> [String] {
        result.tree.nodes.compactMap { node in
            if case let .text(s) = node { return s }
            return nil
        }
    }

    /// 递归收集 NativeIR 里所有 number 节点。
    private func irNumbers(_ ir: NativeIRNode) -> [(value: Double, label: String?)] {
        var out: [(Double, String?)] = []
        switch ir {
        case let .number(value, label):
            out.append((value, label))
        case let .container(_, children, _):
            out.append(contentsOf: children.flatMap(irNumbers))
        case let .list(items):
            out.append(contentsOf: items.flatMap(irNumbers))
        default:
            break
        }
        return out
    }

    // MARK: - 1. Extension Display Regex 进入 deferred

    func testExtensionDisplayRegexEntersDeferredTier() {
        let imported = SillyTavernRegexScript(
            name: "状态皮肤",
            regex: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "<div class=\"skin\">皮肤</div><StatusPlaceHolderImpl/>"
        )
        guard let rule = SillyTavernScriptImporter.convert(imported) else {
            return XCTFail("extension 脚本应能导入为 DisplayRegex")
        }
        XCTAssertTrue(MessageRendererCore.isDeferredCandidate(rule))
        XCTAssertEqual(
            MessageRendererCore.orderedDeferredRegexes(presetDisplayRegexIds: [], all: [rule]),
            [rule]
        )
    }

    // MARK: - 2. replacement 进入 Native 转译通路

    func testReplacementRoutesNativeExpressionsToTranspilerPath() {
        let expanded =
            "<div class=\"skin\">皮肤</div>" +
            "<StatusPlaceHolderImpl/>" +
            "<UpdateVariable>[{\"op\":\"replace\",\"path\":\"/金币\",\"value\":7}]</UpdateVariable>" +
            "<NativeAction label=\"加血\" kind=\"updateVariable\" path=\"/HP\" value=\"10\"/>"
        let pieces = MessageRendererCore.splitReplacement(expanded)
        let nativePieces = pieces.filter(\.isNativeExpression).map(\.content)
        XCTAssertEqual(nativePieces.count, 3)
        XCTAssertTrue(nativePieces.contains("<StatusPlaceHolderImpl/>"))
        XCTAssertTrue(nativePieces.contains(where: { $0.hasPrefix("<UpdateVariable>") }))
        XCTAssertTrue(nativePieces.contains(where: { $0.hasPrefix("<NativeAction") }))
        // 标记部分保持非 native，等待分流为残留
        XCTAssertTrue(pieces.contains(where: { !$0.isNativeExpression && $0.content.hasPrefix("<div") }))
    }

    // MARK: - 3. 可转换表达 → NativeIR

    func testConvertibleExpressionProducesNativeIR() {
        let statData = JSONValue.object(["HP": .int(50)])
        // 占位符 → TavernExpression.statusPlaceholder → NativeIRProjector
        let irFromPlaceholder = TavernTranspiler.transpile(.statusPlaceholder(statData))
        let nums = irNumbers(irFromPlaceholder)
        XCTAssertTrue(nums.contains(where: { $0.value == 50 && $0.label == "HP" }))

        // legacy RenderNode.nativeAction → RenderNodeTranspiler → .button
        let action = NativeAction.updateVariable(path: "/HP", value: .int(10))
        let buttonIR = RenderNodeTranspiler.transpile(.nativeAction(label: "加血", action: action))
        XCTAssertEqual(buttonIR, .button(label: "加血", action: action))
    }

    // MARK: - 4. 交互表达 → NativeAction

    func testNativeActionTokenBecomesExecutableNativeAction() {
        let cases: [(String, String, NativeAction)] = [
            (
                "<NativeAction label=\"加血\" kind=\"updateVariable\" path=\"/HP\" value=\"10\"/>",
                "加血",
                .updateVariable(path: "/HP", value: .int(10))
            ),
            (
                "<NativeAction label=\"命名\" kind=\"updateVariable\" path=\"/名字\" value=\"Alice\"/>",
                "命名",
                .updateVariable(path: "/名字", value: .string("Alice"))
            ),
            (
                "<NativeAction label=\"开关\" kind=\"toggle\" path=\"/开关\" />",
                "开关",
                .toggle(path: "/开关")
            ),
            (
                "<NativeAction label=\"空体配对\" kind=\"toggle\" path=\"/a\"></NativeAction>",
                "空体配对",
                .toggle(path: "/a")
            ),
        ]
        for (token, expectedLabel, expectedAction) in cases {
            guard case let .nativeAction(label, action) = RenderNodeParser.parseNativeActionBlock(token) else {
                return XCTFail("应解析为 nativeAction：\(token)")
            }
            XCTAssertEqual(label, expectedLabel)
            XCTAssertEqual(action, expectedAction)
        }
        // 数值形态：小数
        guard case let .nativeAction(_, decimalAction) = RenderNodeParser.parseNativeActionBlock(
            "<NativeAction label=\"d\" kind=\"updateVariable\" path=\"/x\" value=\"1.5\"/>"
        ) else {
            return XCTFail("小数值应可解析")
        }
        XCTAssertEqual(decimalAction, .updateVariable(path: "/x", value: .double(1.5)))
    }

    // MARK: - 5. VariableStore 更新 → NativeIR 重新生成（闭环）

    func testVariableStoreUpdateRegeneratesNativeIR() throws {
        let store = VariableStore()
        let sid = UUID()
        defer { store.removeSession(sid) }
        store.seedIfEmpty(sessionId: sid, initData: ["HP": .int(50)])

        let imported = SillyTavernRegexScript(
            name: "皮肤",
            regex: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "<div>皮肤</div><StatusPlaceHolderImpl/>" +
                "<NativeAction label=\"加血\" kind=\"updateVariable\" path=\"/HP\" value=\"10\"/>"
        )
        guard let skinRule = SillyTavernScriptImporter.convert(imported) else {
            return XCTFail("导入失败")
        }
        let raw = "开场\n<StatusPlaceHolderImpl/>\n结尾"

        // 第一轮渲染：IR 反映当前变量树（HP=50），按钮节点携带 updateVariable 动作。
        let first = renderAssistant(raw, rules: [skinRule], store: store, sessionId: sid)
        XCTAssertEqual(residuals(in: first).count, 1, "HTML 皮肤应冻结为残留")
        let irBefore = TavernTranspiler.transpile(.statusPlaceholder(store.raw(forSession: sid)))
        XCTAssertTrue(irNumbers(irBefore).contains(where: { $0.value == 50 && $0.label == "HP" }))
        let buttons = actions(in: first)
        XCTAssertEqual(buttons.count, 1)
        XCTAssertEqual(buttons[0].action, .updateVariable(path: "/HP", value: .int(10)))

        // 模拟按钮点击：dispatcher 计算等价 patch → VariableStore.apply 持久化。
        let dispatcher = NativeActionDispatcher()
        let ops = try XCTUnwrap(dispatcher.patches(
            for: buttons[0].action,
            currentTree: store.raw(forSession: sid)
        ))
        XCTAssertEqual(try store.apply(ops, to: sid), 1)

        // 第二轮渲染：同一 raw、同一规则 —— 变量变化后 IR 重新生成。
        // updateVariable 是**绝对替换**语义：点击后 HP == 10（按钮携带的值）。
        let second = renderAssistant(raw, rules: [skinRule], store: store, sessionId: sid)
        let irAfter = TavernTranspiler.transpile(.statusPlaceholder(store.raw(forSession: sid)))
        let numsAfter = irNumbers(irAfter)
        XCTAssertTrue(numsAfter.contains(where: { $0.value == 10 && $0.label == "HP" }),
                      "点击后 IR 应反映 HP 被替换为 10，实际 \(numsAfter)")
        XCTAssertFalse(numsAfter.contains(where: { $0.value == 50 }))
    }

    /// toggle 动作在变量树上的完整翻转。
    func testToggleActionFlipsBoolInTree() {
        var tree = JSONValue.object(["开关": .bool(false), "数字": .int(1)])
        let dispatcher = NativeActionDispatcher()
        XCTAssertTrue(dispatcher.dispatch(.toggle(path: "/开关"), to: &tree))
        XCTAssertEqual(tree, .object(["开关": .bool(true), "数字": .int(1)]))
        // 非 bool 目标 → dispatcher 返回 false（不可执行），树不变。
        XCTAssertFalse(dispatcher.dispatch(.toggle(path: "/数字"), to: &tree))
        XCTAssertEqual(tree, .object(["开关": .bool(true), "数字": .int(1)]))
    }

    // MARK: - 6/7. 未知表达保留 & HTML/CSS/JS 永不执行

    func testUnknownExpressionsPreservedVerbatimAsResidual() {
        let js = "<script src=\"https://evil.example/x.js\"></script>"
        let css = "<style>.a{color:red}</style>"
        let html = "<iframe src=\"https://evil.example\"></iframe><div>卡片</div>"
        let rule = makeRule(
            pattern: "\\[面板\\]",
            replacement: js + css + html
        )
        XCTAssertTrue(MessageRendererCore.isDeferredCandidate(rule), "含脚本标记的 replacement 应进 deferred")
        let result = renderAssistant("A[面板]B", rules: [rule])
        let rs = residuals(in: result)
        XCTAssertEqual(rs.count, 1)
        XCTAssertEqual(rs[0].replacement, js + css + html, "原文必须逐字保留")
        XCTAssertEqual(rs[0].sourcePattern, rule.pattern)
        // 文本流零泄漏；正文前后缀原样。
        XCTAssertEqual(textContents(of: result).joined(), "AB")
        for seg in result.tree.nodes {
            if case let .text(t) = seg {
                XCTAssertFalse(t.contains("<"), "文本流不得泄漏标记：\(t)")
            }
        }
    }

    // MARK: - 8. 无重复处理

    func testNoDoubleProcessingAcrossTiersAndParser() {
        let imported = SillyTavernRegexScript(
            name: "皮肤",
            regex: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "<div>A</div><StatusPlaceHolderImpl/>"
        )
        guard let skinRule = SillyTavernScriptImporter.convert(imported) else {
            return XCTFail("导入失败")
        }

        // (a) deferred 候选不出现在 Tier A 执行序列里 —— 同一规则不会跑两遍。
        XCTAssertTrue(MessageRendererCore.orderedRegexes(presetDisplayRegexIds: [], all: [skinRule]).isEmpty)

        // (b) 残留块对后续规则不可见：第二条规则即使 pattern 命中残留内容也改不了它。
        let secondPass = makeRule(name: "eat-div", pattern: "<div>A</div>", replacement: "被吃掉")
        let segments = MessageRendererCore.applyDeferred(
            text: "<StatusPlaceHolderImpl/>",
            presetDisplayRegexIds: [],
            all: [skinRule, secondPass]
        )
        guard case let .residual(res)? = segments.first(where: {
            if case .residual = $0 { return true }
            return false
        }) else {
            return XCTFail("应有残留段")
        }
        XCTAssertEqual(res.replacement, "<div>A</div>", "残留内容不得被后续规则改写")

        // (c) 对已处理输出再跑一遍 deferred 层：文本流中的再发 token 是新输入（允许），
        // 但整体结果幂等 —— 残留数与占位符数稳定，不会指数复制。
        let once = MessageRendererCore.applyDeferred(
            text: "<StatusPlaceHolderImpl/>",
            presetDisplayRegexIds: [],
            all: [skinRule]
        )
        let twice = MessageRendererCore.applyDeferred(
            text: once.compactMap { if case let .text(t) = $0 { return t } else { return nil } }.joined(),
            presetDisplayRegexIds: [],
            all: [skinRule]
        )
        let residualCount = { (segs: [MessageRendererCore.PreParseSegment]) -> Int in
            segs.filter { if case .residual = $0 { return true } else { return false } }.count
        }
        XCTAssertEqual(residualCount(once), 1)
        XCTAssertEqual(residualCount(twice), 1, "残留数保持稳定，不得指数复制")

        // (d) 全链路：parser 只产出一个占位符节点 —— token 被消费一次。
        let result = renderAssistant("<StatusPlaceHolderImpl/>", rules: [skinRule])
        XCTAssertEqual(placeholders(in: result).count, 1)
        XCTAssertEqual(residuals(in: result).count, 1)
    }

    // MARK: - 9. 正文完整性

    func testBodyIntegrityPreservedThroughFullChain() {
        let imported = SillyTavernRegexScript(
            name: "皮肤",
            regex: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "<style>x{}</style><StatusPlaceHolderImpl/><NativeAction label=\"加血\" kind=\"updateVariable\" path=\"/HP\" value=\"10\"/>"
        )
        guard let skinRule = SillyTavernScriptImporter.convert(imported) else {
            return XCTFail("导入失败")
        }
        let raw = "第一段。\n\n<StatusPlaceHolderImpl/>\n\n最后一段。"
        let result = renderAssistant(raw, rules: [skinRule])
        // 顺序：头文本 → 残留(CSS) → 占位符 → 按钮 → 尾文本
        XCTAssertEqual(result.tree.nodes.count, 5)
        guard case let .text(head) = result.tree.nodes[0],
              case .deferredResidual = result.tree.nodes[1],
              case .statusPlaceholder = result.tree.nodes[2],
              case .nativeAction = result.tree.nodes[3],
              case let .text(tail) = result.tree.nodes[4] else {
            return XCTFail("节点序列应为 文本/残留/占位符/动作/文本")
        }
        XCTAssertEqual(head, "第一段。\n\n")
        XCTAssertEqual(tail, "\n\n最后一段。")
        // raw 永不被改写
        XCTAssertEqual(raw, "第一段。\n\n<StatusPlaceHolderImpl/>\n\n最后一段。")
    }

    // MARK: - 10. 普通 Display Regex 不回归

    func testOrdinaryDisplayRegexBehaviorUnchanged() {
        let plain = makeRule(pattern: "World", replacement: "Pyramid")
        XCTAssertFalse(MessageRendererCore.isDeferredCandidate(plain))
        let result = renderAssistant("Hello World", rules: [plain])
        XCTAssertEqual(textContents(of: result).joined(), "Hello Pyramid")
        XCTAssertTrue(residuals(in: result).isEmpty)
    }

    // MARK: - 动态数据：变量全程不丢

    func testDynamicVariablesSurviveRegexToIR() throws {
        let store = VariableStore()
        let sid = UUID()
        defer { store.removeSession(sid) }
        store.seedIfEmpty(sessionId: sid, initData: ["HP": .int(1)])

        let rule = makeRule(pattern: "@STATUS@", replacement: "<StatusPlaceHolderImpl/>")
        let raw = "@STATUS@"

        // 状态一：HP=1
        let r1 = renderAssistant(raw, rules: [rule], store: store, sessionId: sid)
        XCTAssertEqual(placeholders(in: r1).count, 1)
        let ir1 = TavernTranspiler.transpile(.statusPlaceholder(store.raw(forSession: sid)))
        XCTAssertTrue(irNumbers(ir1).contains(where: { $0.value == 1 && $0.label == "HP" }))

        // 外部（如 UpdateVariable patch / 用户操作）改变变量后，同一 raw 重新产生对应 IR。
        let ops = [JSONPatchOperation(op: .replace, path: "/HP", value: .int(99))]
        XCTAssertEqual(try store.apply(ops, to: sid), 1)
        let r2 = renderAssistant(raw, rules: [rule], store: store, sessionId: sid)
        XCTAssertEqual(placeholders(in: r2).count, 1)
        let ir2 = TavernTranspiler.transpile(.statusPlaceholder(store.raw(forSession: sid)))
        XCTAssertTrue(irNumbers(ir2).contains(where: { $0.value == 99 && $0.label == "HP" }),
                      "变量更新后应重新投影出 HP=99")
    }

    // MARK: - 畸形交互表达：降级保真

    func testMalformedNativeActionFallsBackToTextPreservingRaw() {
        let malformed = [
            "<NativeAction kind=\"toggle\" path=\"/a\"/>",                                  // 缺 label
            "<NativeAction label=\"x\" kind=\"explode\" path=\"/a\"/>",                     // 未知 kind
            "<NativeAction label=\"x\" kind=\"updateVariable\" path=\"noprefix\" value=\"1\"/>", // path 非 pointer
            "<NativeAction label=\"x\" kind=\"updateVariable\" path=\"/a\"/>",              // 缺 value
            "<NativeAction label=\"x\" kind=\"toggle\" path=\"/a\">非空body</NativeAction>", // body 不识别 → 整段保真
            "<NativeInput label=\"缺path\"/>",                                              // input 缺 path
            "<NativeSelect label=\"s\" path=\"/a\" values=\" \"/>",                         // values 空白
            "<NativeSelect label=\"s\" path=\"/a\" values=\"v,,v2\"/>",                     // values 含空项
        ]
        for token in malformed {
            let parsed = RenderNodeParser.parse(token, statData: { .object([:]) }, applyPatches: { _ in 0 })
            XCTAssertEqual(parsed.nodes.count, 1, "\(token) 应整体降级为单节点")
            guard case let .text(t) = parsed.nodes[0] else {
                return XCTFail("\(token) 应降级为 .text")
            }
            XCTAssertEqual(t, token, "畸形 token 必须逐字保留：\(token)")
        }
    }

    // MARK: - 收尾验证：三种交互 + 动态嵌套数据 + 去重

    /// 第六条：button / selection / input 三种通用交互全部可用。
    /// 一条消息里同时出现三种控件，各自经 dispatcher → VariableStore 写入后，
    /// 重渲染的 IR 反映全部变化 —— 无任何字段名 / 业务分支参与。
    func testAllThreeInteractionKindsRoundTripThroughStore() throws {
        let store = VariableStore()
        let sid = UUID()
        defer { store.removeSession(sid) }
        store.seedIfEmpty(sessionId: sid, initData: ["开关": .bool(false)])

        let imported = SillyTavernRegexScript(
            name: "控制台",
            regex: "<StatusPlaceHolderImpl\\s*/?>",
            replacement:
                "<NativeAction label=\"翻转\" kind=\"toggle\" path=\"/开关\"/>" +
                "<NativeSelect label=\"选一个\" path=\"/选择\" values=\"red,blue\" labels=\"红,蓝\"/>" +
                "<NativeInput label=\"写点字\" path=\"/草稿\" placeholder=\"在此输入\"/>"
        )
        guard let rule = SillyTavernScriptImporter.convert(imported) else {
            return XCTFail("导入失败")
        }
        let raw = "<StatusPlaceHolderImpl/>"
        let result = renderAssistant(raw, rules: [rule], store: store, sessionId: sid)

        // 三个交互节点都产出（button / control-select / control-input）。
        XCTAssertEqual(actions(in: result).count, 1)
        var selectControl: NativeControl?
        var inputControl: NativeControl?
        for node in result.tree.nodes {
            if case let .nativeControl(c) = node {
                switch c.kind {
                case .select: selectControl = c
                case .input: inputControl = c
                }
            }
        }
        let sel = try XCTUnwrap(selectControl, "应有 select 控件")
        let inp = try XCTUnwrap(inputControl, "应有 input 控件")
        XCTAssertEqual(sel.options.map(\.value), ["red", "blue"])
        XCTAssertEqual(sel.options.map(\.label), ["红", "蓝"])
        XCTAssertEqual(inp.placeholder, "在此输入")

        // 模拟三种用户操作 → VariableStore → 重渲染。
        let dispatcher = NativeActionDispatcher()
        // (1) button toggle
        let ops1 = try XCTUnwrap(dispatcher.patches(for: actions(in: result)[0].action,
                                                    currentTree: store.raw(forSession: sid)))
        XCTAssertEqual(try store.apply(ops1, to: sid), 1)
        // (2) select「蓝」
        let ops2 = try XCTUnwrap(dispatcher.patches(
            for: .updateVariable(path: sel.path, value: .string(sel.options[1].value)),
            currentTree: store.raw(forSession: sid)))
        XCTAssertEqual(try store.apply(ops2, to: sid), 1)
        // (3) input 提交
        let ops3 = try XCTUnwrap(dispatcher.patches(
            for: .updateVariable(path: inp.path, value: .string("你好")),
            currentTree: store.raw(forSession: sid)))
        XCTAssertEqual(try store.apply(ops3, to: sid), 1)

        // 三处写入全部落库（变量树是通用 JSON Pointer 数据，不生成业务组件）。
        guard case .object(let treeAfter) = store.raw(forSession: sid) else {
            return XCTFail("变量树应是 object")
        }
        XCTAssertEqual(treeAfter["开关"], .bool(true), "toggle 应翻转")
        XCTAssertEqual(treeAfter["选择"], .string("blue"), "select 应写入选中值")
        XCTAssertEqual(treeAfter["草稿"], .string("你好"), "input 应写入提交文本")

        // 同一 raw 重渲染：三种交互节点重新产出（UI 可继续操作 —— 闭环成立）。
        let rerendered = renderAssistant(raw, rules: [rule], store: store, sessionId: sid)
        XCTAssertEqual(actions(in: rerendered).count, 1)
        var kinds = Set<NativeControl.Kind>()
        for node in rerendered.tree.nodes {
            if case let .nativeControl(c) = node { kinds.insert(c.kind) }
        }
        XCTAssertEqual(kinds, [.input, .select])

        // 控件桥接到新 IR 的形态：RenderNodeTranspiler 把控制原语映射为 textInput / selection。
        if case let .textInput(_, inputPath, _) = RenderNodeTranspiler.transpile(.nativeControl(inp)) {
            XCTAssertEqual(inputPath, inp.path)
        } else {
            XCTFail("input 控件应桥接为 .textInput")
        }
        if case let .selection(_, selPath, selOpts) = RenderNodeTranspiler.transpile(.nativeControl(sel)) {
            XCTAssertEqual(selPath, sel.path)
            XCTAssertEqual(selOpts, sel.options)
        } else {
            XCTFail("select 控件应桥接为 .selection")
        }
    }

    /// 第三条（动态数据）：深层嵌套结构经 patch 变化后，IR 重新投影出更新值；
    /// 结构是通用 JSON Pointer 树，不产生任何按字段名命名的组件。
    func testDeepNestedDynamicDataRegeneratesIR() throws {
        let store = VariableStore()
        let sid = UUID()
        defer { store.removeSession(sid) }
        store.seedIfEmpty(sessionId: sid, initData: [
            "区域": .object(["房间": .object(["计数": .int(1)]),
                            "标签": .array([.string("甲"), .string("乙")])])
        ])
        let rule = makeRule(pattern: "@T@", replacement: "<StatusPlaceHolderImpl/>")
        _ = renderAssistant("@T@", rules: [rule], store: store, sessionId: sid)

        let deepPatch = [JSONPatchOperation(op: .replace, path: "/区域/房间/计数", value: .int(42))]
        XCTAssertEqual(try store.apply(deepPatch, to: sid), 1)

        let ir = TavernTranspiler.transpile(.statusPlaceholder(store.raw(forSession: sid)))
        XCTAssertTrue(irNumbers(ir).contains(where: { $0.value == 42 && $0.label == "计数" }),
                      "深层嵌套值更新后应出现在新 IR 中")
    }

    /// 第五条补充：同一条规则同时出现在预设列表与全量列表（同一 id）→ 只执行一次。
    func testDuplicateRuleIDRunsExactlyOnce() {
        let rule = makeRule(pattern: "<StatusPlaceHolderImpl\\s*/?>", replacement: "[皮肤]")
        let ordered = MessageRendererCore.orderedDeferredRegexes(
            presetDisplayRegexIds: [rule.id],
            all: [rule, rule]
        )
        XCTAssertEqual(ordered.count, 1, "同一 id 不得重复执行")
        let segments = MessageRendererCore.applyDeferred(
            text: "<StatusPlaceHolderImpl/>",
            presetDisplayRegexIds: [rule.id],
            all: [rule, rule]
        )
        XCTAssertEqual(segments.compactMap { seg -> String? in
            if case let .text(t) = seg { return t }
            return nil
        }.joined(), "[皮肤]")
    }
}
