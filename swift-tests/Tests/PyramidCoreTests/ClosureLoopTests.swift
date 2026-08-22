import XCTest
@testable import PyramidCore

/// P10 端到端闭环测试（Test A–J）。
///
/// 锁定「角色卡表达 → Native IR → 状态变化 → IR 重算 → 触发动画 / 切换分支」
/// 整条链路 —— 不重复建立第二套状态、Action 或 Renderer，全部复用：
///
/// - TavernExpression / TavernTranspiler.transpile
/// - HTMLTranspiler.transpile / RenderNodeTranspiler.transpile（legacy 桥接）
/// - NativeActionDispatcher.patches(for:currentTree:) → VariableStore.apply
/// - NativeCondition.evaluate(in:) → 切换 branch
/// - MacroRenderer.render(segments:, tree:) → 文本绑定求值
/// - AnimationIntentAnalyzer.parseInlineStyle / animation(forClassToggle:) →
///   AnimationIR（含 trigger）
///
/// **不**测试 SwiftUI view body —— view 层只承载渲染，状态/语义由
/// 上面这些纯函数承担；这里测的是它们各自 + 串联后的不变量。
///
/// **数据约定**：sessionId 用 `UUID()` 现造；VariableStore 在 macOS-only
/// Foundation 测试里直接构造（不需要 UIHosting），按 call-on-instance
/// 走 raw(forSession:) 验证。
final class ClosureLoopTests: XCTestCase {

    // MARK: - Test A：纯文本闭环

    /// Test A: 纯文本 → transpile → 不依赖状态。
    func testATextExpressionNoState() {
        let ir = TavernTranspiler.transpile(.text("hello pyramid"))
        guard case let .text(content) = ir else {
            return XCTFail("应是 .text，实为 \(ir)")
        }
        XCTAssertEqual(content, "hello pyramid")
    }

    // MARK: - Test B：button → dispatcher → store.apply → IR 重算

    /// Test B: 用户点击 button → dispatcher 算 patch → store.apply → @Published
    /// 触发 → 重新 transpile → IR 反映新值。
    func testBButtonActionUpdatesStoreAndRegeneratesIR() {
        var tree: JSONValue = .object(["HP": .int(80)])

        // 1) button 携带 NativeAction。
        let button: NativeIRNode = .button(
            label: "加血",
            action: .updateVariable(path: "/HP", value: JSONValue.int(100))
        )
        guard case let .button(_, action) = button else { return XCTFail("应为 button") }

        // 2) dispatcher 算 patch（不直接 inout 写，而是经 VariableStore.apply 持久化）。
        let dispatcher = NativeActionDispatcher()
        let ops = dispatcher.patches(for: action, currentTree: tree) ?? []
        XCTAssertEqual(ops.count, 1, "应产生 1 条等价 patch")

        // 3) 模拟 VariableStore.apply 路径：把 patch 应用到 tree 上。
        try? JSONPatchApplier.apply(ops, to: &tree)

        // 4) 重新 transpile → IR 反映新值。
        let newIR = TavernTranspiler.transpile(.statData(tree))
        guard case let .container(_, children, _) = newIR else { return XCTFail() }
        let hpField = children.first { node in
            if case let .number(_, label) = node { return label == "HP" }
            return false
        }
        guard case let .number(value, _) = hpField else {
            return XCTFail("HP 应是 .number")
        }
        XCTAssertEqual(value, 100.0, "dispatch + apply 后 IR 必须反映新值")
    }

    // MARK: - Test C：input → store.apply → 重读显示

    /// Test C: input 提交 → dispatcher → store 持久化 → 重新读出当前值。
    func testCTextInputWritesAndReadsBack() {
        let store = VariableStore()
        let sid = UUID()
        store.seedIfEmpty(sessionId: sid, initData: ["name": .string("")])

        let path = "/name"
        let dispatcher = NativeActionDispatcher()
        let ops = dispatcher.patches(
            for: .updateVariable(path: path, value: .string("Alice")),
            currentTree: store.raw(forSession: sid)
        ) ?? []
        XCTAssertFalse(ops.isEmpty, "input commit 应产生 patch")
        try? store.apply(ops, to: sid)

        // 重读：input 视图下次渲染时通过 store.raw 拿到 "Alice"。
        let tree = store.raw(forSession: sid)
        guard case let .object(dict) = tree,
              case let .string(s) = dict["name"] ?? .null else {
            return XCTFail()
        }
        XCTAssertEqual(s, "Alice")
    }

    // MARK: - Test D：select 切换 → store → currentLabel 重算

    /// Test D: select 选项 → 写入 store → 重读 currentLabel。
    func testDSelectOptionWritesAndReadsBack() {
        let store = VariableStore()
        let sid = UUID()
        store.seedIfEmpty(sessionId: sid, initData: ["mood": .string("happy")])

        let path = "/mood"
        let dispatcher = NativeActionDispatcher()
        let ops = dispatcher.patches(
            for: .updateVariable(path: path, value: .string("sad")),
            currentTree: store.raw(forSession: sid)
        ) ?? []
        try? store.apply(ops, to: sid)

        let tree = store.raw(forSession: sid)
        guard case let .object(dict) = tree,
              case let .string(s) = dict["mood"] ?? .null else {
            return XCTFail()
        }
        XCTAssertEqual(s, "sad", "select 后 store 应反映新值")
    }

    // MARK: - Test E：boundText 绑定 → 当前树求值

    /// Test E: boundText(segments) 对当前变量树求值；unresolved 时回退原文。
    func testEBoundTextResolvesFromCurrentTree() {
        let segments = TavernMacroParser.parse("余额：{{getvar::/金币}}")
        XCTAssertFalse(segments.isEmpty, "应解析出至少 1 个 binding")

        // 起始空树 → 解析到的 binding unresolved → 原文 fallback。
        let emptyTree: JSONValue = .object([:])
        XCTAssertEqual(MacroRenderer.render(segments: segments, tree: emptyTree),
                       "余额：{{getvar::/金币}}")

        // 写入 /金币=200 → resolve 出 "200"。
        var withGold: JSONValue = .object(["金币": .int(200)])
        XCTAssertEqual(MacroRenderer.render(segments: segments, tree: withGold),
                       "余额：200")

        // 更新 /金币 → 同一 segments 重算 → 新文本。
        withGold = .object(["金币": .int(350)])
        XCTAssertEqual(MacroRenderer.render(segments: segments, tree: withGold),
                       "余额：350")
    }

    // MARK: - Test F：branch 切换 → 同一 IR 在不同 tree 下选不同分支

    /// Test F: condition.evaluate 决定 active branch；tree 变化 → 切换分支。
    func testFBranchEvaluationFollowsStoreState() {
        let cond = NativeCondition.predicate(
            NativePredicate(path: "/HP", op: .gt, operand: .int(50))
        )
        let trueBranch: [NativeIRNode] = [.text(content: "alive")]
        let falseBranch: [NativeIRNode] = [.text(content: "dead")]

        let lowHP: JSONValue = .object(["HP": .int(30)])
        let highHP: JSONValue = .object(["HP": .int(80)])

        XCTAssertFalse(cond.evaluate(in: lowHP), "HP=30 不应通过 .gt 50")
        XCTAssertTrue(cond.evaluate(in: highHP), "HP=80 应通过 .gt 50")

        // 同一 IR 在两棵树下选不同分支。
        let branchNode: NativeIRNode = .branch(
            condition: cond, whenTrue: trueBranch, whenFalse: falseBranch
        )
        guard case let .branch(_, wT, wF) = branchNode else { return XCTFail() }
        let activeLow = cond.evaluate(in: lowHP) ? wT : wF
        let activeHigh = cond.evaluate(in: highHP) ? wT : wF
        guard case let .text(lowText) = activeLow.first ?? .text(content: "") else {
            return XCTFail()
        }
        guard case let .text(highText) = activeHigh.first ?? .text(content: "") else {
            return XCTFail()
        }
        XCTAssertEqual(lowText, "dead")
        XCTAssertEqual(highText, "alive")
    }

    // MARK: - Test G：container.animation 透传到 NativeIR

    /// Test G: container(animation:) 保留 animation 字段；renderer 看到非 nil
    /// animation → 用对应 transition 呈现。
    func testGContainerCarriesAnimationIntent() {
        let node: NativeIRNode = .container(
            title: "面板",
            children: [.text(content: "hi")],
            animation: NativeAnimation(kind: .fade, durationMs: 300)
        )
        guard case let .container(title, children, animation) = node else {
            return XCTFail()
        }
        XCTAssertEqual(title, "面板")
        XCTAssertEqual(children.count, 1)
        XCTAssertNotNil(animation)
        XCTAssertEqual(animation?.kind, .fade)
    }

    // MARK: - Test H：完整 tavern → transpile → store → IR 重算

    /// Test H: statData → transpile → 取出 button → dispatcher → store mutation
    /// → 重新 transpile → 新 IR 反映新值。
    func testHFullStatDataTranspileClosure() {
        let initialTree: JSONValue = .object([
            "HP": .int(50),
            "金币": .int(100),
        ])

        // 1) 角色卡表达：一条 .statData + 一条 .buttonHint。
        let stat = TavernExpression.statData(initialTree)
        let healButton = TavernExpression.buttonHint(
            label: "加血",
            action: .updateVariable(path: "/HP", value: JSONValue.int(100))
        )

        let irStat = TavernTranspiler.transpile(stat)
        let irButton = TavernTranspiler.transpile(healButton)

        guard case let .container(_, children, _) = irStat else { return XCTFail() }
        XCTAssertEqual(children.count, 2)
        guard case let .button(_, action) = irButton else { return XCTFail() }

        // 2) 把 dispatcher 算出的 patch 应用到同一棵树。
        var mutated = initialTree
        let ops = NativeActionDispatcher().patches(for: action, currentTree: mutated) ?? []
        try? JSONPatchApplier.apply(ops, to: &mutated)

        // 3) 重新 transpile → HP = 100。
        let irAfter = TavernTranspiler.transpile(.statData(mutated))
        guard case let .container(_, afterChildren, _) = irAfter else { return XCTFail() }
        let hp = afterChildren.first { node in
            if case let .number(_, label) = node { return label == "HP" }
            return false
        }
        guard case let .number(value, _) = hp else { return XCTFail() }
        XCTAssertEqual(value, 100.0)
    }

    // MARK: - Test I：动画 trigger 来自 action / path / appear

    /// Test I: AnimationIntentAnalyzer 产生的 AnimationIR.trigger 三种形态
    /// —— onAppear / onPathChange / onAction —— 在闭环里分别由什么驱动。
    func testIAnimationTriggersForClosurePath() {
        // onAppear：CSS transition 被解析为默认 trigger = onAppear。
        let appearAnim = AnimationIntentAnalyzer.parseInlineStyle("transition: opacity 0.3s ease-in")?.first
        XCTAssertEqual(appearAnim?.trigger, .onAppear)

        // onAction(class-toggle)：Script class-toggle 走 onAction(key:)。
        let classAnim = AnimationIntentAnalyzer.animation(forClassToggle: "show")?.first
        if case let .onAction(key) = classAnim?.trigger ?? .onAppear {
            XCTAssertTrue(key.hasPrefix("class-toggle:"))
        } else {
            XCTFail("class-toggle 应配 .onAction")
        }

        // onAction(style.opacity)：Script style 写入走 onAction(key: "style.opacity")。
        let styleAnim = AnimationIntentAnalyzer.animation(forStyleAssignment: "opacity", value: "1")
        if case let .onAction(key) = styleAnim?.trigger ?? .onAppear {
            XCTAssertEqual(key, "style.opacity")
        } else {
            XCTFail("style.opacity 应配 .onAction")
        }
    }

    // MARK: - Test J：完整联动（button + branch + 动画意图）端到端

    /// Test J: 终极闭环 —— 角色卡定义「HP>50 显示 alive；点 button 加血；
    /// 加血时 class-toggle=fade-in 触发 onAction 动画」。
    /// 验证：
    ///   - 起始 HP=30 → branch 走 false ("dead")
    ///   - 点击 button → store HP=100 → branch 重算走 true ("alive")
    ///   - AnimationIR.trigger = onAction(class-toggle:fade-in)
    func testJEndToEndButtonBranchAndAnimation() {
        // (1) 起始数据。
        var tree: JSONValue = .object(["HP": .int(30)])

        // (2) transpile 角色卡表达 → 取出 IR。
        let button: NativeIRNode = .button(
            label: "加血",
            action: .updateVariable(path: "/HP", value: JSONValue.int(100))
        )
        let branch: NativeIRNode = .branch(
            condition: NativeCondition.predicate(
                NativePredicate(path: "/HP", op: .gt, operand: .int(50))
            ),
            whenTrue: [.text(content: "alive")],
            whenFalse: [.text(content: "dead")]
        )
        let fadeIn = AnimationIntentAnalyzer.animation(forClassToggle: "fade-in")?.first

        guard case let .button(_, action) = button else { return XCTFail() }
        guard case let .branch(cond, whenTrue, whenFalse) = branch else { return XCTFail() }

        // (3) 起始分支判定。
        let initialActive = cond.evaluate(in: tree) ? whenTrue : whenFalse
        guard case let .text(initialText) = initialActive.first ?? .text(content: "") else {
            return XCTFail()
        }
        XCTAssertEqual(initialText, "dead", "HP=30 起始应是 dead")

        // (4) 点击 → dispatcher → store mutation。
        let ops = NativeActionDispatcher().patches(for: action, currentTree: tree) ?? []
        try? JSONPatchApplier.apply(ops, to: &tree)

        // (5) 重算分支。
        let afterActive = cond.evaluate(in: tree) ? whenTrue : whenFalse
        guard case let .text(afterText) = afterActive.first ?? .text(content: "") else {
            return XCTFail()
        }
        XCTAssertEqual(afterText, "alive", "HP=100 后应切到 alive")
        XCTAssertEqual(tree, .object(["HP": .int(100)]), "tree 反映 HP=100")

        // (6) 动画 trigger 验证：onAction(key:) 应在 NativeView 的 dispatch token
        // 变化时驱动 SwiftUI 重放（NativeView.dispatchToken 路径）。
        if case let .onAction(key) = fadeIn?.trigger ?? .onAppear {
            XCTAssertTrue(key.contains("class-toggle:fade-in"))
        } else {
            XCTFail("fade-in 应配 .onAction(class-toggle:fade-in)")
        }
    }
}