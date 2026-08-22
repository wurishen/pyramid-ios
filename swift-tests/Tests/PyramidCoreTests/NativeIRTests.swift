import XCTest
@testable import PyramidCore

/// 第三阶段 Native IR / Action 闭环测试。
///
/// 锁定的不变量：
/// 1. `NativeIRProjector.project(statData:)` 不因字段名（HP / 好感度 / 金币 /
///    小手机电量 / 催眠程度）触发任何 Pyramid 业务组件 —— 任意字段只是 data。
/// 2. `.progress` 只由**数据形状** `{value, max}` 显式决定，不由键名决定。
/// 3. `NativeActionDispatcher.dispatch(_:to:)` 能在 `JSONValue` 树上执行
///    `.updateVariable` / `.toggle`，未实现的 `.navigate` / `.custom` 返回 false。
/// 4. UI 事件 → Action → VariableStore mutation → 重新生成 Native IR 闭环成立。
/// 5. `NativeAnimation` 是轻量"意图"描述，不锁死 CSS / WebView。
/// 6. `NativeIRNode` 与 legacy `RenderNode` / `DisplayBlock` 完全平行，互不依赖。
final class NativeIRTests: XCTestCase {

    // MARK: - Projection: 任意字段就是 data

    /// 用户场景 fixture：角色卡定义了一组数值字段（含 Pyramid 模板词 HP / 好感度
    /// 也含自定义字段 小手机电量 / 催��程度）。
    /// 投影层**不应该**因为字段名产生 HPComponent / AffectionComponent 之类的
    /// 业务组件 —— 所有数值统一走 `.number`；任何字段都可以存在。
    func testMixedDataProjectsToGenericIR() {
        let statData: JSONValue = .object([
            "HP": .int(80),
            "好感度": .int(65),
            "小手机电量": .int(73),
            "催眠程度": .int(42),
            "金币": .int(200),
        ])
        let ir = NativeIRProjector.project(statData: statData)

        guard case let .container(_, children, _) = ir else {
            return XCTFail("根部应是 container")
        }

        // 关键否定 1：没有任何节点被升级为 .progress（因为输入是裸 int，没有 value/max 形状）。
        let progressCount = children.filter { node in
            if case .progress = node { return true }
            return false
        }.count
        XCTAssertEqual(progressCount, 0, "裸数值不应被升级为 .progress")

        // 关键否定 2：没有 Pyramid 业务组件 —— 所有 5 个字段都是 .number，label 原样保留。
        let labels = Set(children.compactMap { node -> String? in
            if case let .number(_, label) = node { return label }
            return nil
        })
        XCTAssertEqual(labels, ["HP", "好感度", "小手机电量", "催眠程度", "金币"])

        // 关键否定 3：UI 不应注入 Pyramid 固定栏目。
        let rendered = describe(ir)
        for banned in ["时间", "位置", "选项"] {
            XCTAssertFalse(rendered.contains(banned),
                           "投影层不应凭空产生『\(banned)』栏目")
        }
    }

    /// 字符串字段 → `.field`（短）或 `.text`（长）。
    func testStringFieldsProjectToFieldOrText() {
        let statData: JSONValue = .object([
            "心情": .string("还行"),
            "日记": .string("今天在酒馆遇到一位老朋友，聊起了三年前的往事。"),
        ])
        let ir = NativeIRProjector.project(statData: statData)
        guard case let .container(_, children, _) = ir else { return XCTFail("根部应是 container") }
        XCTAssertEqual(children.count, 2)
        // 短串 → field；长串（> 30 字符）→ text。
        XCTAssertTrue(children.contains { node in
            if case let .field(label, _) = node { return label == "心情" }
            return false
        })
        XCTAssertTrue(children.contains { node in
            if case .text = node { return true }
            return false
        })
    }

    /// 角色卡不预置任何"时间 / 位置 / 选项"栏目；空 / 非 object 输入 → 占位 text。
    func testEmptyStatDataProducesPlaceholder() {
        let ir1 = NativeIRProjector.project(statData: .object([:]))
        guard case let .container(_, children1, _) = ir1 else { return XCTFail("根部应是 container") }
        XCTAssertEqual(children1.count, 1)
        if case let .text(text1) = children1[0] {
            XCTAssertTrue(text1.contains("等待变量"))
        } else {
            XCTFail("空树应降级为占位 text，实为 \(children1[0])")
        }

        let ir2 = NativeIRProjector.project(statData: .string("not an object"))
        guard case let .container(_, children2, _) = ir2 else { return XCTFail("根部应是 container") }
        XCTAssertEqual(children2.count, 1)
        if case .text = children2[0] { } else {
            XCTFail("非 object 输入应降级为占位 text")
        }
    }

    // MARK: - Progress: 数据形状驱动，不是字段名驱动

    /// `.progress` 由**显式 `{value, max}` 形状**决定。哪怕键名是 HP / 好感度 /
    /// 金币 / 小手机电量，只要有 `value`（可解析为数字）就升级为 progress。
    /// 反过来，裸 int 不会升级。
    func testProgressRecognizedFromValueMaxShapeNotName() {
        // 任何键名都应被识别为 progress —— 只要形态对。
        for key in ["HP", "好感度", "小手机电量", "催眠程度", "法力", "饱腹"] {
            let statData: JSONValue = .object([
                key: .object([
                    "value": .int(80),
                    "max": .int(100),
                ])
            ])
            let ir = NativeIRProjector.project(statData: statData)
            guard case let .container(_, children, _) = ir else {
                XCTFail("[\(key)] 根部应是 container")
                continue
            }
            guard case let .progress(label, value, max) = children[0] else {
                XCTFail("[\(key)] 显式 value/max 应升级为 progress，实为 \(children[0])")
                continue
            }
            XCTAssertEqual(label, key)
            XCTAssertEqual(value, 80)
            XCTAssertEqual(max, 100)
        }
    }

    /// 裸 int 不升级 → `.number`。
    func testBareIntDoesNotBecomeProgress() {
        let statData: JSONValue = .object(["HP": .int(80)])
        let ir = NativeIRProjector.project(statData: statData)
        guard case let .container(_, children, _) = ir else { return XCTFail() }
        XCTAssertTrue(children[0].isNumber)
        XCTAssertFalse(children[0].isProgress)
    }

    /// `value` / `max` 之一非��字 → 不升级。
    func testProgressRequiresNumericValue() {
        let statData: JSONValue = .object([
            "weird": .object([
                "value": .string("not a number"),
                "max": .int(100),
            ])
        ])
        let ir = NativeIRProjector.project(statData: statData)
        guard case let .container(_, children, _) = ir else { return XCTFail() }
        // 退化为 container 嵌套（不升级为 progress）。
        XCTAssertFalse(children[0].isProgress)
    }

    // MARK: - Action 闭环

    /// UI 事件 → Button → Action → VariableStore mutation → 重新生成 Native IR。
    /// 这条链路是第三阶段的核心交付物。
    func testButtonActionUpdatesStoreAndRegeneratesIR() {
        // 1. 起始状态：HP = 80。
        var tree: JSONValue = .object(["HP": .int(80)])

        // 2. 渲染起始 IR：HP → .number(80, "HP")。
        var ir = NativeIRProjector.project(statData: tree)
        XCTAssertEqual(extractNumbers(ir), [80.0])

        // 3. 角色卡定义一个 button：把 HP 改成 100。
        let button: NativeIRNode = .button(
            label: "加血",
            action: .updateVariable(path: "/HP", value: JSONValue.int(100))
        )

        // 4. 用户点击 → renderer 拿到 button.action，dispatcher 写入树。
        guard case let .button(_, action) = button else { return XCTFail("应为 button") }
        let dispatcher = NativeActionDispatcher()
        let handled = dispatcher.dispatch(action, to: &tree)
        XCTAssertTrue(handled, "dispatcher 应处理 updateVariable")

        // 5. 重新跑投影 → IR 必须反映 HP = 100。
        ir = NativeIRProjector.project(statData: tree)
        XCTAssertEqual(extractNumbers(ir), [100.0], "mutation 后 IR 必须反映新值")

        // 6. 树本身也确认被修改。
        guard case let .object(dict) = tree else { return XCTFail("tree 应是 object") }
        XCTAssertEqual(dict["HP"], .int(100))
    }

    /// `.toggle` action 翻转 bool 字段。闭环同样成立。
    func testToggleActionFlipsBoolAndRegeneratesIR() {
        var tree: JSONValue = .object([
            "wechat_unread": .bool(true),
            "static_field": .string("unchanged"),
        ])

        // button.toggle 把 wechat_unread 从 true 翻到 false。
        let action = NativeAction.toggle(path: "/wechat_unread")
        let dispatcher = NativeActionDispatcher()
        XCTAssertTrue(dispatcher.dispatch(action, to: &tree))

        guard case let .object(dict) = tree else { return XCTFail() }
        XCTAssertEqual(dict["wechat_unread"], .bool(false))
        XCTAssertEqual(dict["static_field"], .string("unchanged"))

        // 重新投影：wechat_unread 字段值翻成 "false"。
        let ir = NativeIRProjector.project(statData: tree)
        guard case let .container(_, children, _) = ir else { return XCTFail() }
        let unreadField = children.first { node in
            if case let .field(label, _) = node { return label == "wechat_unread" }
            return false
        }
        guard let unreadField, case let .field(label, value) = unreadField else { return XCTFail() }
        XCTAssertEqual(label, "wechat_unread")
        XCTAssertEqual(value, "false")
    }

    /// `.toggle` 命中非 bool 路径 → dispatcher 返回 false，不修改树。
    func testToggleOnNonBoolReturnsFalseWithoutMutation() {
        var tree: JSONValue = .object(["HP": .int(80)])
        let dispatcher = NativeActionDispatcher()
        let handled = dispatcher.dispatch(.toggle(path: "/HP"), to: &tree)
        XCTAssertFalse(handled, "非 bool 不应被 toggle")
        guard case let .object(dict) = tree else { return XCTFail() }
        XCTAssertEqual(dict["HP"], .int(80), "tree 不应被修改")
    }

    /// `.navigate` / `.custom` 本期不实现 → dispatcher 返回 false。
    func testUnimplementedActionsReturnFalse() {
        var tree: JSONValue = .object(["HP": .int(80)])
        let dispatcher = NativeActionDispatcher()
        XCTAssertFalse(dispatcher.dispatch(.navigate(target: "settings"), to: &tree))
        XCTAssertFalse(dispatcher.dispatch(
            .custom(key: "open_shop", payload: [:]),
            to: &tree
        ))
    }

    /// 不存在的 path → dispatcher 返回 false。
    func testUpdateOnMissingPathReturnsFalse() {
        var tree: JSONValue = .object(["HP": .int(80)])
        let dispatcher = NativeActionDispatcher()
        let handled = dispatcher.dispatch(
            .updateVariable(path: "/NotExisting", value: .int(0)),
            to: &tree
        )
        XCTAssertFalse(handled, "path 不存在时 updateVariable 应返回 false")
    }

    // MARK: - Animation: 轻量、不锁死 CSS

    /// `NativeAnimation` 只是"意图"：kind + 可选 durationMs。
    /// 不包含 easing 曲线 / 延迟 / 颜色等 CSS 概念 —— 那些由 renderer 选。
    func testAnimationIsLightweightIntent() {
        let a = NativeAnimation(kind: .fade, durationMs: 250)
        XCTAssertEqual(a.kind, .fade)
        XCTAssertEqual(a.durationMs, 250)

        let b = NativeAnimation(kind: .slide, durationMs: nil)
        XCTAssertEqual(b.kind, .slide)
        XCTAssertNil(b.durationMs)

        // 类型穷举验证：4 种 kind 互不相等。
        XCTAssertNotEqual(NativeAnimation.Kind.fade, NativeAnimation.Kind.slide)
        XCTAssertNotEqual(NativeAnimation.Kind.scale, NativeAnimation.Kind.transition)
    }

    /// `container(...animation:)` 能承载动画意图；nil 表示无动画。
    func testContainerCarriesOptionalAnimation() {
        let c1 = NativeIRNode.container(title: "状态", children: [], animation: nil)
        let c2 = NativeIRNode.container(
            title: "状态",
            children: [],
            animation: NativeAnimation(kind: .transition, durationMs: 200)
        )
        if case let .container(_, _, anim1) = c1 { XCTAssertNil(anim1) }
        else { XCTFail("c1 应是 container") }
        if case let .container(_, _, anim2) = c2 {
            XCTAssertEqual(anim2?.kind, .transition)
            XCTAssertEqual(anim2?.durationMs, 200)
        } else {
            XCTFail("c2 应是 container")
        }
    }

    // MARK: - 与 legacy IR 完全平行

    /// `NativeIRNode` 与 `RenderNode` / `DisplayBlock` 互不依赖 —— 任何一边
    /// 都可以单独存在（平行数据结构，不互相引用）。
    func testNativeIRIsParallelToLegacyIR() {
        let nativeNode: NativeIRNode = .number(value: 80, label: "HP")
        let legacyNode: RenderNode = .status(hp: 80, affection: 65)
        let legacyBlock: DisplayBlock = .number(value: 80, label: "HP")

        // 三者独立存在；没有任何一个引用另两个的类型。
        // 编译期能通过 + 运行期互不耦合。
        XCTAssertNotNil(nativeNode)
        XCTAssertNotNil(legacyNode)
        XCTAssertNotNil(legacyBlock)

        // 同字段名在不同 IR 里走不同形状 —— 这是**正确**的（新 IR 不模仿旧 IR）。
        if case let .number(_, label) = nativeNode {
            XCTAssertEqual(label, "HP")
        } else {
            XCTFail("nativeNode 应是 .number")
        }
    }

    // MARK: - helpers

    /// 把 IR 树里所有 `.number` 的 value 抽出来成数组。
    private func extractNumbers(_ node: NativeIRNode) -> [Double] {
        var out: [Double] = []
        walk(node) { n in
            if case let .number(value, _) = n { out.append(value) }
        }
        return out
    }

    /// 把 IR 树转成一段可读字符串，便于"包含 / 不包含"断言。
    private func describe(_ node: NativeIRNode) -> String {
        var out: [String] = []
        walk(node) { n in
            switch n {
            case let .text(s): out.append(s)
            case let .number(value, label): out.append("\(label ?? "")=\(value)")
            case let .progress(label, value, max): out.append("\(label)=\(value)/\(max.map(String.init) ?? "?")")
            case let .field(label, value): out.append("\(label)=\(value)")
            case let .list(items): out.append("[list \(items.count)]")
            case let .container(title, _, anim):
                out.append(title)
                if anim != nil { out.append("anim") }
            case let .button(label, _): out.append("[button:\(label)]")
            case let .textInput(label, path, _): out.append("[input:\(label ?? "")→\(path)]")
            case let .selection(label, path, _): out.append("[select:\(label ?? "")→\(path)]")
            case let .boundText(segments):
                out.append("[bound \(segments.count)段]")
            case let .branch(condition, whenTrue, whenFalse):
                out.append("[cond deps:\(condition.dependencies.count) T:\(whenTrue.count)/F:\(whenFalse.count)]")
            }
        }
        return out.joined(separator: " ")
    }

    private func walk(_ node: NativeIRNode, _ visit: (NativeIRNode) -> Void) {
        visit(node)
        if case let .container(_, children, _) = node {
            children.forEach { walk($0, visit) }
        }
        if case let .list(items) = node {
            items.forEach { walk($0, visit) }
        }
    }
}

// MARK: - NativeIRNode 形状 helpers（测试内私有）

private extension NativeIRNode {
    var isNumber: Bool {
        if case .number = self { return true }
        return false
    }
    var isProgress: Bool {
        if case .progress = self { return true }
        return false
    }
    var isField: Bool {
        if case .field = self { return true }
        return false
    }
}