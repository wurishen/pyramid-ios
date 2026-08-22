import XCTest
@testable import PyramidCore

/// 第七阶段验收：通用条件 / 分支 / 动态 UI。
///
/// 覆盖：NOT/AND/OR 组合、结构化 token 解析、双分支预解析、显示期求值
/// （变量变化 → 分支切换，无需重发消息）、依赖记录、畸形 residual 保真。
final class TavernConditionTests: XCTestCase {
    // MARK: - helpers

    private func parse(_ raw: String, tree: JSONValue) -> [RenderNode] {
        RenderNodeParser.parse(raw, statData: { tree }, applyPatches: { _ in 0 }).nodes
    }

    /// 递归渲染：text 直出；宏绑定对树求值；条件选支递归 —— 与 MessageCard 同语义的最小渲染器。
    private func render(_ nodes: [RenderNode], in tree: JSONValue) -> String {
        nodes.map { n -> String in
            switch n {
            case .text(let s): return s
            case .macroText(let segs): return MacroRenderer.render(segments: segs, tree: tree)
            case .condition(let c): return render(c.activeBranch(in: tree).nodes, in: tree)
            default: return ""
            }
        }.joined()
    }

    private func when(_ path: String, _ op: NativePredicate.Op, _ value: JSONValue? = nil) -> NativeCondition {
        .predicate(NativePredicate(path: path, op: op, operand: value))
    }

    // MARK: 1. 组合子求值语义

    func testCombinatorEvaluateSemantics() {
        let tree: JSONValue = .object(["a": .int(5), "b": .string(""), "c": .bool(false)])

        // 单位元：空 all 恒真、空 any 恒假。
        XCTAssertTrue(NativeCondition.all([]).evaluate(in: tree))
        XCTAssertFalse(NativeCondition.any([]).evaluate(in: tree))

        // NOT 纯取反：缺失路径 eq=false → NOT eq=true。
        XCTAssertTrue(NativeCondition.not(when("/missing", .eq, .int(1))).evaluate(in: tree))
        XCTAssertFalse(NativeCondition.not(when("/a", .eq, .int(5))).evaluate(in: tree))

        // AND：全真才真。OR：一真即真。
        XCTAssertTrue(NativeCondition.all([when("/a", .gt, .int(0)), when("/b", .isEmpty)]).evaluate(in: tree))
        XCTAssertFalse(NativeCondition.all([when("/a", .gt, .int(0)), when("/c", .truthy)]).evaluate(in: tree))
        XCTAssertTrue(NativeCondition.any([when("/c", .truthy), when("/b", .isEmpty)]).evaluate(in: tree))
        XCTAssertFalse(NativeCondition.any([when("/c", .truthy), when("/x", .exists)]).evaluate(in: tree))

        // 任意嵌套：all(any(not(p), q), r)。
        let nested = NativeCondition.all([
            NativeCondition.any([
                NativeCondition.not(when("/a", .gt, .int(100))),
                when("/b", .nonEmpty),
            ]),
            when("/c", .eq, .bool(false)),
        ])
        XCTAssertTrue(nested.evaluate(in: tree), "not(a>100)=真 → any 真；c=false → 全真")
    }

    // MARK: 2-3. 结构化 token 解析 + 组合嵌套

    func testStructuredTokenParseAndEvaluate() {
        let raw = """
        <NativeIf>
          <NativeWhen path="/金币" op="gte" value="25"/>
          <NativeThen>够钱买药水</NativeThen>
          <NativeElse>钱不够</NativeElse>
        </NativeIf>
        """
        let rich: JSONValue = .object(["金币": .int(30)])
        let poor: JSONValue = .object(["金币": .int(3)])

        let nodes = parse("前缀\(raw)后缀", tree: rich)
        XCTAssertEqual(nodes.count, 3, "前缀文本 + 条件节点 + 后缀文本")
        guard case let .condition(node) = nodes[1] else {
            return XCTFail("中间应为 .condition 节点")
        }
        XCTAssertEqual(render(node.activeBranch(in: rich).nodes, in: rich), "够钱买药水")
        XCTAssertEqual(render(node.activeBranch(in: poor).nodes, in: poor), "钱不够")
        XCTAssertEqual(node.condition.dependencies, ["/金币"])
    }

    func testStructuredCombinatorNesting() {
        let raw = """
        <NativeIf>
          <NativeAll>
            <NativeWhen path="/开门" op="truthy"/>
            <NativeAny>
              <NativeWhen path="/有钥匙" op="truthy"/>
              <NativeNot><NativeWhen path="/力量" op="lt" value="10"/></NativeNot>
            </NativeAny>
          </NativeAll>
          <NativeThen>门开了</NativeThen>
          <NativeElse>门没开</NativeElse>
        </NativeIf>
        """
        let openForce: JSONValue = .object(["开门": .bool(true), "有钥匙": .bool(false), "力量": .int(20)])
        let openWeakKeyless: JSONValue = .object(["开门": .bool(true), "有钥匙": .bool(false), "力量": .int(3)])
        let openStrongNoForceField: JSONValue = .object(["开门": .bool(true), "有钥匙": .bool(false), "力量": .int(15)])
        let closed: JSONValue = .object(["开门": .bool(false), "有钥匙": .bool(true), "力量": .int(99)])

        guard case let .condition(node)? = parse(raw, tree: openForce).first else {
            return XCTFail("应为 .condition 节点")
        }
        XCTAssertEqual(Set(node.condition.dependencies), ["/开门", "/力量", "/有钥匙"], "组合条件收集全部叶子路径并去重")
        XCTAssertEqual(render(node.activeBranch(in: openStrongNoForceField).nodes, in: openStrongNoForceField), "门开了",
                       "无钥匙但 NOT(力量<10)=真（15≥10）→ OR 成立 → AND 成立")
        XCTAssertEqual(render(node.activeBranch(in: openWeakKeyless).nodes, in: openWeakKeyless), "门没开",
                       "无钥匙且力量<10 → OR 不成立")
        XCTAssertEqual(render(node.activeBranch(in: closed).nodes, in: closed), "门没开")
    }

    /// 叶形态 + `<NativeElse/>`：顶层 Else 正确切分；**嵌套内层 If 的 Else 不被误切**。
    func testLeafFormWithElseSplit() {
        let raw = "<NativeIf path=\"/下雨\" op=\"truthy\">带伞<NativeElse/>晴天</NativeIf>"
        guard case let .condition(node)? = parse(raw, tree: .object(["下雨": .bool(true)])).first else {
            return XCTFail("应为 .condition 节点")
        }
        XCTAssertEqual(node.whenTrue.count, 1)
        if case let .text(t)? = node.whenTrue.first { XCTAssertEqual(t, "带伞") } else {
            XCTFail("true 分支应为文本")
        }
        XCTAssertEqual(node.whenFalse.count, 1)
        XCTAssertEqual(render(node.whenTrue, in: .object(["下雨": .bool(true)])), "带伞")
        XCTAssertEqual(render(node.whenFalse, in: .object(["下雨": .bool(false)])), "晴天")

        let nestedRaw = "<NativeIf path=\"/a\" op=\"truthy\">外层" +
            "<NativeIf path=\"/b\" op=\"truthy\">内层<NativeElse/>b假</NativeIf>" +
            "<NativeElse/>a假</NativeIf>"
        guard case let .condition(outer)? = parse(nestedRaw, tree: .object(["a": .bool(true), "b": .bool(false)])).first else {
            return XCTFail("外层应为 .condition 节点")
        }
        XCTAssertEqual(outer.whenTrue.count, 2, "文本 + 内层条件")
        XCTAssertEqual(render(outer.whenTrue, in: .object(["a": .bool(true), "b": .bool(false)])), "外层b假",
                       "顶层 Else 只切本层的——内层自己的 Else 归内层")
        XCTAssertEqual(render(outer.activeBranch(in: .object(["a": .bool(false)])).nodes,
                             in: .object(["a": .bool(false)])), "a假")
    }

    // MARK: 4. 畸形 → residual 保真

    func testMalformedStructuredStaysVerbatim() {
        let cases = [
            // 缺 Then/Else 块。
            "<NativeIf><NativeWhen path=\"/a\" op=\"truthy\"/></NativeIf>",
            // 条件与 Then 之间夹裸文本。
            "<NativeIf>说明文字<NativeWhen path=\"/a\" op=\"truthy\"/><NativeThen>T</NativeThen></NativeIf>",
            // 未闭合的组合块。
            "<NativeIf><NativeAll><NativeWhen path=\"/a\" op=\"truthy\"/><NativeThen>T</NativeThen></NativeIf>",
            // 空 All（无孩子）。
            "<NativeIf><NativeAll></NativeAll><NativeThen>T</NativeThen></NativeIf>",
            // When 未知 op。
            "<NativeIf><NativeWhen path=\"/a\" op=\"explode\"/><NativeThen>T</NativeThen></NativeIf>",
            // Then 后尾随裸文本。
            "<NativeIf><NativeWhen path=\"/a\" op=\"truthy\"/><NativeThen>T</NativeThen>尾巴</NativeIf>",
            // 比较缺 value。
            "<NativeIf><NativeWhen path=\"/a\" op=\"eq\"/><NativeThen>T</NativeThen></NativeIf>",
        ]
        for raw in cases {
            XCTAssertEqual(parse(raw, tree: .object(["a": .bool(true)])), [.text(raw)],
                           "畸形结构化条件必须逐字保留：「无法解析」≠ false")
        }
    }

    // MARK: 5. isEmpty / nonEmpty

    func testEmptyNonEmptyOps() {
        let tree: JSONValue = .object([
            "空串": .string(""), "有字": .string("hi"),
            "空数组": .array([]), "有货": .array([.int(1)]),
            "空对象": .object([:]), "非空对象": .object(["k": .null]),
            "空值": .null, "数字": .int(0),
        ])
        func p(_ op: NativePredicate.Op, _ path: String) -> Bool {
            NativePredicate(path: path, op: op, operand: nil).evaluate(in: tree)
        }
        XCTAssertTrue(p(.isEmpty, "/空串"))
        XCTAssertTrue(p(.isEmpty, "/空数组"))
        XCTAssertTrue(p(.isEmpty, "/空对象"))
        XCTAssertTrue(p(.isEmpty, "/空值"), "null 计为空")
        XCTAssertFalse(p(.isEmpty, "/数字"), "数字 0 是有效内容，不为空")
        XCTAssertFalse(p(.isEmpty, "/missing"), "路径缺失 → isEmpty 为 false（不误报）")

        XCTAssertFalse(p(.nonEmpty, "/空串"))
        XCTAssertTrue(p(.nonEmpty, "/有字"))
        XCTAssertTrue(p(.nonEmpty, "/有货"))
        XCTAssertTrue(p(.nonEmpty, "/非空对象"), "含 null 键的对象不算空容器")
        XCTAssertTrue(p(.nonEmpty, "/数字"))
        XCTAssertFalse(p(.nonEmpty, "/missing"))
    }

    // MARK: 6. IR 桥接（链路完整）

    func testTranspilerBridgesConditionToBranchIR() {
        let raw = "<NativeIf path=\"/hp\" op=\"lt\" value=\"20\">危急！{{getvar::/名字}}</NativeIf>"
        guard case let .condition(node)? = parse(raw, tree: .object(["hp": .int(10)])).first else {
            return XCTFail("应为 .condition 节点")
        }
        guard case let .branch(condition, whenTrue, whenFalse) =
            RenderNodeTranspiler.transpile(.condition(node)) else {
            return XCTFail("应桥接为 .branch IR")
        }
        XCTAssertEqual(condition, node.condition, "条件结构完整透传")
        XCTAssertEqual(whenTrue.count, node.whenTrue.count, "true 分支逐节点转译")
        if case let .boundText(segments)? = whenTrue.first,
           case let .macroText(expected)? = node.whenTrue.first {
            XCTAssertEqual(segments, expected, "分支内的宏绑定以 boundText 进入 IR")
        } else {
            XCTFail("true 分支首节点应为绑定文本")
        }
        XCTAssertEqual(whenFalse, [], "无 Else → false 分支为空 IR")
    }

    // MARK: 7. 动态更新：解析一次，变量变化自动切支（无需重发消息）

    func testDynamicSwitchWithoutReparse() {
        let raw = "<NativeIf path=\"/状态\" op=\"eq\" value=\"战斗\">⚔️ 战斗中<NativeElse/>🛌 休息</NativeIf>"
        let v1: JSONValue = .object(["状态": .string("战斗")])

        guard case let .condition(node)? = parse(raw, tree: v1).first else {
            return XCTFail("应为 .condition 节点")
        }

        // 第一次求值：战斗分支。
        let first = node.activeBranch(in: v1)
        XCTAssertTrue(first.isTrue)
        XCTAssertEqual(render(first.nodes, in: v1), "⚔️ 战斗中")

        // 变量更新（模拟按钮 patch 写入后的新树）→ **同一个解析产物**重新求值即切支。
        let v2: JSONValue = .object(["状态": .string("休息")])
        let second = node.activeBranch(in: v2)
        XCTAssertFalse(second.isTrue, "未重新解析，仅重算")
        XCTAssertEqual(render(second.nodes, in: v2), "🛌 休息")
        XCTAssertEqual(node.raw, raw, "原文随节点携带，可追溯")
    }

    /// 端到端：按钮 patch 翻转变量 → 条件分支随之切换（解析一次的完整闭环）。
    func testEndToEndButtonFlipsBranch() throws {
        let doc = """
        <NativeAction label="点火把" kind="updateVariable" path="/火把" value="true"/>
        <NativeIf path="/火把" op="truthy">火光照亮洞穴<NativeElse/>一片漆黑</NativeIf>
        """
        var tree: JSONValue = .object(["火把": .bool(false)])
        let nodes = parse(doc, tree: tree)

        // 初始：暗分支。
        var condNode: NativeConditionNode?
        for n in nodes {
            if case let .condition(c) = n { condNode = c }
        }
        guard case let .nativeAction(_, action)? = nodes.first,
              case let .updateVariable(path, value) = action,
              let cond = condNode else {
            return XCTFail("应为 按钮 + 条件节点")
        }
        XCTAssertEqual(path, "/火把")
        XCTAssertFalse(cond.condition.evaluate(in: tree))
        XCTAssertEqual(render(cond.whenFalse, in: tree), "一片漆黑")

        // 点击按钮 → dispatcher patch → 新树。
        try JSONPatchApplier.apply([JSONPatchOperation(op: .replace, path: path, value: value)], to: &tree)

        // 重算（不重解析）→ 亮分支。
        XCTAssertTrue(cond.condition.evaluate(in: tree))
        XCTAssertEqual(render(cond.activeBranch(in: tree).nodes, in: tree), "火光照亮洞穴")
    }

    // MARK: 8. 分支内保留交互控件

    func testBranchesKeepInteractiveControls() {
        let leafRaw = "<NativeIf path=\"/商店\" op=\"truthy\">" +
            "<NativeInput label=\"备注\" path=\"/备注\"/>" +
            "<NativeSelect label=\"购买\" path=\"/选择\" option=\"药水|地图\"/>" +
            "<NativeAction label=\"离开\" kind=\"updateVariable\" path=\"/商店\" value=\"false\"/>" +
            "</NativeIf>"
        guard case let .condition(node)? = parse(leafRaw, tree: .object(["商店": .bool(true)])).first else {
            return XCTFail("应为 .condition 节点")
        }
        XCTAssertEqual(node.whenTrue.count, 3, "输入框 + 单选 + 按钮全部保留为类型化节点")
        XCTAssertTrue(node.whenTrue.contains { $0.isNativeControl }, "控件节点不降级为纯文本")
        XCTAssertTrue(node.whenTrue.contains { $0.isNativeActionButton }, "按钮节点保留动作语义")
    }

    // MARK: 9. 超深保护

    func testExcessiveNestingDegradesToResidual() {
        var raw = "<NativeIf path=\"/v\" op=\"truthy\">叶"
        for _ in 0..<12 {
            raw += "<NativeIf path=\"/v\" op=\"truthy\">深"
        }
        for _ in 0..<12 {
            raw += "</NativeIf>"
        }
        raw += "</NativeIf>"

        let tree: JSONValue = .object(["v": .bool(true)])
        let joined = render(parse(raw, tree: tree), in: tree)
        XCTAssertTrue(joined.contains("叶"), "前 8 层正常展开")
        XCTAssertTrue(joined.contains("<NativeIf path=\"/v\" op=\"truthy\">深"),
                      "超过 maxDepth 的内层块整体 residual 原文保真，绝不静默丢弃")
    }

    // MARK: 10. 依赖记录 API

    func testDependencyCollection() {
        let cond = NativeCondition.all([
            when("/位置", .eq, .string("酒馆")),
            NativeCondition.any([when("/金币", .gte, .int(10)), when("/金币", .gte, .int(50))]),
            NativeCondition.not(when("/禁言", .truthy)),
        ])
        XCTAssertEqual(cond.dependencies, ["/位置", "/金币", "/禁言"], "跨层级去重收集")
    }
}

// MARK: - 小工具（测试内私有）

private extension RenderNode {
    var isNativeControl: Bool {
        if case .nativeControl = self { return true }
        return false
    }

    var isNativeActionButton: Bool {
        if case .nativeAction = self { return true }
        return false
    }
}
