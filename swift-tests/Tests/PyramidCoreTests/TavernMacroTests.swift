import XCTest
@testable import PyramidCore

/// P6 通用 Tavern Macro / Binding / Condition 回归测试。
///
/// 覆盖任务书 12 条硬性要求：
/// getvar 读取、多宏共存保序、深层 JSON Pointer、绑定重算、
/// Input/Select 联动、已知宏转换、未知宏逐字保真、条件 true/false 分支、
/// 畸形条件残留、不执行脚本。
final class TavernMacroTests: XCTestCase {

    // MARK: - 解析器基础

    /// 无宏文本零开销直通：单 literal 片段。
    func testPlainTextStaysLiteral() {
        XCTAssertEqual(TavernMacroParser.parse("普通文本，没有宏"), [.literal("普通文本，没有宏")])
        XCTAssertFalse(TavernMacroParser.containsMacroToken("普通文本"))
    }

    /// 要求 1 + 7：`{{getvar::/x}}` 读变量；裸名规范化为根级指针。
    func testGetvarReadsVariable() {
        let segments = TavernMacroParser.parse("金币：{{getvar::/金币}}")
        guard case .literal(let prefix) = segments[0],
              case .binding(let binding) = segments[1] else {
            return XCTFail("应为 literal + binding")
        }
        XCTAssertEqual(prefix, "金币：")
        XCTAssertEqual(binding.path, "/金币")
        XCTAssertEqual(binding.value(in: .object(["金币": .int(50)])), .resolved("50"))
    }

    /// 裸名参数 → 根级 JSON Pointer；大小写与空白容忍。
    func testBareNameNormalizationAndCaseInsensitivity() {
        let segments = TavernMacroParser.parse("{{ GetVar :: 灵力 }}")
        guard case .binding(let b) = segments[0] else {
            return XCTFail("应为 binding")
        }
        XCTAssertEqual(b.path, "/灵力")
        XCTAssertTrue(b.raw.hasPrefix("{{"))
    }

    /// 要求 2 + 3：多宏同文、顺序保持。
    func testMultipleMacrosPreserveOrder() {
        let tree = JSONValue.object(["x": .int(1), "y": .int(2)])
        let rendered = MacroRenderer.render(
            segments: TavernMacroParser.parse("A {{getvar::/x}} B {{getvar::/y}} C"),
            tree: tree
        )
        XCTAssertEqual(rendered, "A 1 B 2 C", "字面量与绑定必须严格按原文顺序交错")
    }

    /// 要求 4：深层 JSON Pointer（/区域/房间/计数 与 /a/b/c/d）读取。
    func testDeepPointerRead() {
        let tree: JSONValue = .object([
            "区域": .object(["房间": .object(["计数": .int(7)])]),
            "a": .object(["b": .object(["c": .object(["d": .string("深")])])]),
        ])
        XCTAssertEqual(
            MacroRenderer.render(segments: TavernMacroParser.parse("{{getvar::/区域/房间/计数}}"), tree: tree),
            "7"
        )
        XCTAssertEqual(
            MacroRenderer.render(segments: TavernMacroParser.parse("{{getvar::/a/b/c/d}}"), tree: tree),
            "深"
        )
    }

    /// 要求 5：解析一次的 Binding，store 更新后重算即得新值（不重新解析表达式）。
    func testBindingReevaluatesAfterStoreUpdate() throws {
        let store = VariableStore()
        let sid = UUID()
        defer { store.removeSession(sid) }
        store.seedIfEmpty(sessionId: sid, initData: ["计数": .int(1)])

        // 「解析一次」：片段只生成一份。
        let segments = TavernMacroParser.parse("计数={{getvar::/计数}}")

        let before = MacroRenderer.render(segments: segments, tree: store.raw(forSession: sid))
        XCTAssertEqual(before, "计数=1")

        _ = try store.apply([JSONPatchOperation(op: .replace, path: "/计数", value: .int(42))], to: sid)

        // 同一份片段对新树求值 → 新值。变量名不决定 UI 类型 —— 只是查表结果变化。
        let after = MacroRenderer.render(segments: segments, tree: store.raw(forSession: sid))
        XCTAssertEqual(after, "计数=42")
    }

    /// 要求 6：Input 控件写变量后，同一消息里的文本 Binding 同步更新（端到端）。
    func testControlWriteUpdatesTextBinding() throws {
        let store = VariableStore()
        let sid = UUID()
        defer { store.removeSession(sid) }
        store.seedIfEmpty(sessionId: sid, initData: [:])

        let raw = "<NativeInput label=\"改名\" path=\"/名字\"/>名字是{{getvar::/名字}}"
        let parsed = RenderNodeParser.parse(raw, statData: { store.raw(forSession: sid) },
                                            applyPatches: { try store.apply($0, to: sid) })

        // 初始：变量缺失 → 绑定回退原文。
        guard case let .macroText(segments)? = parsed.nodes.last else {
            return XCTFail("末节点应为 macroText")
        }
        var controlNode: NativeControl?
        for node in parsed.nodes {
            if case let .nativeControl(c) = node { controlNode = c }
        }
        let control = try XCTUnwrap(controlNode)
        XCTAssertEqual(MacroRenderer.render(segments: segments, tree: store.raw(forSession: sid)),
                       "名字是{{getvar::/名字}}",
                       "缺失变量回退原文（residual），整条消息不消失")

        // 模拟控件提交 → dispatcher patch → store 写入。
        let dispatcher = NativeActionDispatcher()
        let ops = try XCTUnwrap(dispatcher.patches(
            for: .updateVariable(path: control.path, value: .string("阿澈")),
            currentTree: store.raw(forSession: sid)
        ))
        XCTAssertEqual(try store.apply(ops, to: sid), 1)

        // 同一份解析产物重新求值 → 同步更新。
        XCTAssertEqual(MacroRenderer.render(segments: segments, tree: store.raw(forSession: sid)),
                       "名字是阿澈")
    }

    // MARK: - 未知宏保真

    /// 要求 8：未知宏原文保留（不删除 / 不置空 / 不映射组件）。
    func testUnknownMacroPreservedVerbatim() {
        let raw = "{{unknown::something}}"
        let rendered = MacroRenderer.render(segments: TavernMacroParser.parse(raw), tree: .object([:]))
        XCTAssertEqual(rendered, raw)
    }

    /// 要求 8 补充：setvar / user / roll 等本期不支持的一律原样。
    func testUnsupportedKnownMacrosStayLiteral() {
        let raw = "{{setvar::hp::99}} {{user}} {{roll:1d20}}"
        XCTAssertEqual(
            MacroRenderer.render(segments: TavernMacroParser.parse(raw), tree: .object([:])),
            raw
        )
    }

    /// 要求 9：未知宏不影响同一消息中的其它内容。
    func testUnknownMacroDoesNotAffectNeighbors() {
        let tree = JSONValue.object(["y": .string("值Y")])
        let rendered = MacroRenderer.render(
            segments: TavernMacroParser.parse("A {{unknown::x}} B {{getvar::/y}}"),
            tree: tree
        )
        XCTAssertEqual(rendered, "A {{unknown::x}} B 值Y")
    }

    /// 未配对 `{{` 是普通文本；嵌套花括号取最内层完整 token，外层残余保真。
    func testUnbalancedAndNestedBracesStaySafe() {
        XCTAssertEqual(
            MacroRenderer.render(segments: TavernMacroParser.parse("孤 {{ 左括号"), tree: .object([:])),
            "孤 {{ 左括号"
        )
        // `{{setvar::a::{{getvar::b}}}}`：内层完整 token 进 binding，外层残余逐字保留。
        let tree = JSONValue.object(["b": .int(3)])
        XCTAssertEqual(
            MacroRenderer.render(segments: TavernMacroParser.parse("{{setvar::a::{{getvar::b}}}}"), tree: tree),
            "{{setvar::a::3}}"
        )
    }

    /// 缺失变量 / 无法内联形态回退原文；null、对象、数组都不产出伪造内容。
    func testMissingAndNonInlineableValuesFallBackToRaw() {
        let raw = "{{getvar::/不存在}}"
        XCTAssertEqual(
            MacroRenderer.render(segments: TavernMacroParser.parse(raw),
                                 tree: .object(["其它": .int(1)])),
            raw
        )
        let weird: JSONValue = .object([
            "n": .null, "arr": .array([.int(1)]), "obj": .object(["k": .int(2)]),
        ])
        for path in ["/n", "/arr", "/obj"] {
            let token = "{{getvar::\(path)}}"
            XCTAssertEqual(
                MacroRenderer.render(segments: TavernMacroParser.parse(token), tree: weird),
                token,
                "\(path) 无法内联 → 回退原文"
            )
        }
    }

    // MARK: - Condition

    private func parseCondition(_ body: String, tree: JSONValue) -> [RenderNode] {
        RenderNodeParser.parse(body, statData: { tree }, applyPatches: { _ in 0 }).nodes
    }

    /// 要求 10：通用 true/false 分支 —— 成立显示、隐藏即消失（原始 raw 消息仍在）。
    func testConditionTrueFalseBranches() {
        let tree: JSONValue = .object(["开关": .bool(true), "金币": .int(30)])

        let truthy = parseCondition("<NativeIf path=\"/开关\" op=\"truthy\">开着的</NativeIf>", tree: tree)
        XCTAssertEqual(truthy.count, 1)
        XCTAssertEqual(truthy[0], .text("开着的"))

        let hidden = parseCondition("<NativeIf path=\"/开关\" op=\"truthy\">不该出现</NativeIf>",
                                    tree: .object(["开关": .bool(false)]))
        // 隐藏分支 → 空 text 占位（内容不渲染；原文在 raw 消息里永不丢）。
        XCTAssertEqual(hidden, [.text("")])

        let eqNumeric = parseCondition("<NativeIf path=\"/金币\" op=\"gte\" value=\"25\">够钱</NativeIf>", tree: tree)
        XCTAssertEqual(eqNumeric, [.text("够钱")])

        let eqFail = parseCondition("<NativeIf path=\"/金币\" op=\"lt\" value=\"25\">穷</NativeIf>", tree: tree)
        XCTAssertEqual(eqFail, [.text("")])
    }

    /// 条件谓词单元语义：数值互通、字符串序、exists/notExists、ne 缺失路径为 false。
    func testPredicateSemantics() {
        let tree: JSONValue = .object([
            "整数": .int(10),
            "小数": .double(10.0),
            "词": .string("apple"),
            "空串": .string(""),
        ])
        func p(_ op: NativePredicate.Op, path: String, value: JSONValue? = nil) -> Bool {
            NativePredicate(path: path, op: op, operand: value).evaluate(in: tree)
        }
        XCTAssertTrue(p(.eq, path: "/整数", value: .double(10.0)), "int/double 数值互通")
        XCTAssertTrue(p(.ne, path: "/整数", value: .int(11)))
        XCTAssertFalse(p(.eq, path: "/缺失", value: .int(10)))
        XCTAssertFalse(p(.ne, path: "/缺失", value: .int(10)), "路径缺失时 ne 也为 false")
        XCTAssertTrue(p(.lt, path: "/词", value: .string("banana")), "字符串字典序")
        XCTAssertFalse(p(.gt, path: "/词", value: .string("banana")))
        XCTAssertTrue(p(.exists, path: "/空串"))
        XCTAssertTrue(p(.truthy, path: "/整数"))
        XCTAssertFalse(p(.truthy, path: "/空串"))
        XCTAssertFalse(p(.truthy, path: "/缺失"))
        XCTAssertTrue(NativePredicate(path: "/x", op: .notExists, operand: nil).evaluate(in: tree))
    }

    /// 要求 11：无法解析的条件（缺属性 / 未知 op / 形状畸形）→ 整段 residual 保真。
    func testMalformedConditionStaysVerbatim() {
        let cases = [
            "<NativeIf path=\"/a\">缺 op</NativeIf>",
            "<NativeIf op=\"truthy\">缺 path</NativeIf>",
            "<NativeIf path=\"/a\" op=\"explode\">未知 op</NativeIf>",
            "<NativeIf path=\"/a\" op=\"eq\">比较缺 value</NativeIf>",
            "<NativeIf path=\"badpointer\" op=\"truthy\">path 非指针</NativeIf>",
            "<NativeIf path=\"/a\" op=\"truthy\">没有闭合标签",
        ]
        for raw in cases {
            XCTAssertEqual(parseCondition(raw, tree: .object([:])), [.text(raw)],
                           "畸形条件必须逐字保留：\(raw)")
        }
    }

    /// 要求 12：不执行任意脚本 —— 宏只是查表；值里的「代码」当纯文本渲染。
    func testNoScriptExecution() {
        let evil: JSONValue = .object([
            "js": .string("fetch('https://evil.example').then(r => r.text())"),
            "html": .string("<script>alert(1)</script>"),
        ])
        let rendered = MacroRenderer.render(
            segments: TavernMacroParser.parse("X {{getvar::/js}} Y {{getvar::/html}} Z"),
            tree: evil
        )
        XCTAssertEqual(rendered,
                       "X fetch('https://evil.example').then(r => r.text()) Y <script>alert(1)</script> Z",
                       "变量值只做文本化，绝不解释执行")
    }

    // MARK: - 管线集成

    /// parser 产出 macroText 节点；RenderNodeTranspiler 桥接为 boundText IR；
    /// TavernExpression.macroText 同样落到 boundText —— Macro → Value/Binding → NativeIR 全链路。
    func testPipelineProducesBoundTextIR() {
        let tree = JSONValue.object(["位置": .string("旧仓库")])
        let parsed = RenderNodeParser.parse(
            "当前位置：{{getvar::/位置}}（{{getvar::/楼层}}层）",
            statData: { tree },
            applyPatches: { _ in 0 }
        )
        guard case let .macroText(segments)? = parsed.nodes.first else {
            return XCTFail("首节点应为 macroText")
        }
        XCTAssertEqual(segments.count, 5, "literal+binding+literal+binding+literal")

        if case let .boundText(irSegments) = RenderNodeTranspiler.transpile(.macroText(segments)) {
            XCTAssertEqual(irSegments, segments, "IR 结构完整透传，信息不丢")
        } else {
            XCTFail("应桥接为 .boundText")
        }
        if case let .boundText(tSegments) = TavernTranspiler.transpile(.macroText(segments)) {
            XCTAssertEqual(tSegments, segments)
        } else {
            XCTFail("TavernExpression.macroText 应转出 .boundText")
        }
    }

    /// 条件块嵌套宏 + 嵌套条件：成立分支里的宏照常求值。
    func testConditionBodyContainsMacrosAndNesting() {
        let tree: JSONValue = .object([
            "开着": .bool(true),
            "层数": .int(2),
            "宝藏": .int(9),
        ])
        let raw = "<NativeIf path=\"/开着\" op=\"truthy\">灯亮着，{{getvar::/宝藏}} 金币" +
            "<NativeIf path=\"/层数\" op=\"gte\" value=\"2\">，楼梯向下</NativeIf></NativeIf>"
        let nodes = parseCondition(raw, tree: tree)
        let joined = nodes.map { node -> String in
            switch node {
            case .text(let t): return t
            case .macroText(let segs): return MacroRenderer.render(segments: segs, tree: tree)
            default: return ""
            }
        }.joined()
        XCTAssertEqual(joined, "灯亮着，9 金币，楼梯向下")
    }

    /// deferred 层把 `<NativeIf>` 整体路由进文本流（parser 可见），畸形不命中 → 冻结残留。
    func testDeferredLayerRoutesNativeIf() {
        let wellFormed = MessageRendererCore.splitReplacement(
            "前缀<NativeIf path=\"/a\" op=\"truthy\">体</NativeIf>后缀"
        ).filter(\.isNativeExpression)
        XCTAssertEqual(wellFormed.map(\.content), ["<NativeIf path=\"/a\" op=\"truthy\">体</NativeIf>"],
                       "合法 NativeIf 应作为原生表达进入文本流")
        XCTAssertFalse(
            MessageRendererCore.splitReplacement("<NativeIf path=\"/a\" op=\"truthy\">未闭合").contains(where: \.isNativeExpression),
            "畸形 NativeIf 不命中白名单 → 残留冻结保真"
        )
    }

    /// 性能约定：解析一次 → 多次求值。同一份 segments 对不同树求值互不影响（纯函数）。
    func testSegmentsAreReusablePureValues() {
        let segments = TavernMacroParser.parse("{{getvar::/v}}")
        XCTAssertEqual(segments, TavernMacroParser.parse("{{getvar::/v}}"), "相同输入 → 相同解析产物（可缓存复用）")
        XCTAssertEqual(
            MacroRenderer.render(segments: segments, tree: .object(["v": .int(1)])),
            "1"
        )
        XCTAssertEqual(
            MacroRenderer.render(segments: segments, tree: .object(["v": .int(2)])),
            "2"
        )
    }
}
