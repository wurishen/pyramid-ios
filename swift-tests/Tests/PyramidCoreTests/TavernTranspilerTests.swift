import XCTest
@testable import PyramidCore

/// Phase 5: Tavern Transpiler 通用层覆盖。
///
/// **锁定的不变量**（来自用户的 12 项要求）：
/// 1. 纯文本 → `.text`
/// 2. 任意字段（含 HP / 好感度 / 自定义）→ 通用 data；**不**触发业务组件
/// 3. 数值 → `.number`；不依赖字段名
/// 4. `{value, max}` 显式形状 → `.progress`；**不**由字段名决定
/// 5. list / container → `.list` / `.container`（结构判断，非字段名）
/// 6. button hint → `.button` 含 `NativeAction`
/// 7. UI 事件 → Action → VariableStore mutation → 重新生成 Native IR 闭环成立
/// 8. 动画意图 → `NativeAnimation`
/// 9. 未知结构 → `.unknown` 通道；保留 raw 原文 + 标记原因
/// 10. 字段名不决定组件类型（否定测试：HP / 好感度 / 自定义字段都走相同通路）
/// 11. 不识别 UI 不丢数据（raw 字段原样保留）
/// 12. **不**执行任意 JavaScript / HTML / CSS（结构保证：纯 Foundation 数据转换）
///
/// **架构不变量**：
/// - `TavernTranspiler` 与 `RenderNodeTranspiler` 互不依赖；两条 pipeline 各自独立存在。
/// - 不创建第二套 parser；不创建业务组件（HPComponent / PhoneComponent / ShopComponent 等）。
/// - legacy `.status(hp:affection:)` → Native IR 后只是两条 field，**不**触发 HP 颜色梯度。
final class TavernTranspilerTests: XCTestCase {

    // MARK: - 1. 文本 / 数值

    /// 纯文本 → `.text` 原样透传。
    func testTextExpressionProducesTextNode() {
        let ir = TavernTranspiler.transpile(.text("hello"))
        guard case let .text(content) = ir else {
            return XCTFail("应是 .text，实为 \(ir)")
        }
        XCTAssertEqual(content, "hello")
    }

    /// 数值字段投影到 `.number`，label 原样保留。
    func testStatDataIntProjectsToNumber() {
        let ir = TavernTranspiler.transpile(
            .statData(.object(["HP": .int(80)]))
        )
        guard case let .container(_, children, _) = ir else { return XCTFail("根部应是 container") }
        XCTAssertEqual(children.count, 1)
        guard case let .number(value, label) = children[0] else {
            return XCTFail("应是 .number，实为 \(children[0])")
        }
        XCTAssertEqual(value, 80)
        XCTAssertEqual(label, "HP")
    }

    // MARK: - 2 + 10. 任意字段就是 data（HP / 好感度 / 自定义都走同一通路）

    /// 关键否定测试：HP / 好感度 / 金币 / 小手机电量 / 催眠程度 / 自定义字段
    /// **全部**走 `.number` —— 没有任何字段被升级为业务组件。
    func testArbitraryFieldsAreAllData() {
        let fields = ["HP", "好感度", "金币", "小手机电量", "催眠程度", "my_custom_field_42"]
        var dict: [String: JSONValue] = [:]
        for f in fields { dict[f] = .int(42) }

        let ir = TavernTranspiler.transpile(.statData(.object(dict)))
        guard case let .container(_, children, _) = ir else { return XCTFail() }

        // 全部 6 条都应是 .number，没有任何 .progress / .container（嵌套）/ 自定义节点。
        // labels 用 Set 比较 —— projector 按 key 字典序排序，与 fields 原序不一致。
        let labels = Set(children.compactMap { node -> String? in
            if case let .number(_, label) = node { return label }
            return nil
        })
        XCTAssertEqual(labels, Set(fields), "全部 6 个字段都应映射到 .number")

        let bannedSubstrings = ["HPComponent", "AffectionComponent", "BatteryComponent"]
        let described = describe(ir)
        for banned in bannedSubstrings {
            XCTAssertFalse(described.contains(banned),
                           "投影层不应出现业务组件名 \(banned)")
        }
    }

    // MARK: - 4. 数据形状 {value, max} 决定 progress

    /// 任意字段名 + `{value, max}` 形状 → `.progress`。
    /// 包括 Pyramid 模板词（HP / 好感度）和角色卡自定义字段（小手机电量）。
    func testProgressComesFromShapeNotFromName() {
        for key in ["HP", "好感度", "小手机电量", "催眠程度", "法力", "金币"] {
            let ir = TavernTranspiler.transpile(.statData(.object([
                key: .object(["value": .int(80), "max": .int(100)])
            ])))
            guard case let .container(_, children, _) = ir else {
                return XCTFail("[\(key)] 根应是 container")
            }
            guard case let .progress(label, value, max) = children[0] else {
                return XCTFail("[\(key)] 应升级为 .progress，实为 \(children[0])")
            }
            XCTAssertEqual(label, key)
            XCTAssertEqual(value, 80)
            XCTAssertEqual(max, 100)
        }
    }

    /// 裸 int 不升级 → `.number`。
    func testBareIntDoesNotBecomeProgress() {
        let ir = TavernTranspiler.transpile(.statData(.object(["HP": .int(80)])))
        guard case let .container(_, children, _) = ir else { return XCTFail() }
        XCTAssertTrue(TavernIRShape.isNumber(children[0]))
        XCTAssertFalse(TavernIRShape.isProgress(children[0]))
    }

    // MARK: - 5. list / container

    /// 数组字段投影成 `.list`。
    func testStatDataArrayProjectsToList() {
        let ir = TavernTranspiler.transpile(.statData(.object([
            "tags": .array([.string("a"), .string("b"), .string("c")])
        ])))
        guard case let .container(_, children, _) = ir else { return XCTFail() }
        guard case let .list(items) = children[0] else {
            return XCTFail("应是 .list，实为 \(children[0])")
        }
        XCTAssertEqual(items.count, 3)
    }

    /// 嵌套 object → `.container` 递归。
    func testStatDataNestedObjectProjectsToContainer() {
        let ir = TavernTranspiler.transpile(.statData(.object([
            "玩家": .object([
                "当前所在地": .string("集市"),
                "HP": .int(80),
            ])
        ])))
        guard case let .container(_, children, _) = ir else { return XCTFail() }
        guard case let .container(title, grand, _) = children[0] else {
            return XCTFail("嵌套应是 .container，实为 \(children[0])")
        }
        XCTAssertEqual(title, "玩家")
        XCTAssertEqual(grand.count, 2)
    }

    // MARK: - 6 + 7. 按钮 / Action / 闭环

    /// `.buttonHint` → `.button` 含 `NativeAction`。
    func testButtonHintProducesButtonWithAction() {
        let action = NativeAction.updateVariable(path: "/HP", value: .int(100))
        let ir = TavernTranspiler.transpile(.buttonHint(label: "加血", action: action))
        guard case let .button(label, storedAction) = ir else {
            return XCTFail("应是 .button，实为 \(ir)")
        }
        XCTAssertEqual(label, "加血")
        if case let .updateVariable(path, value) = storedAction {
            XCTAssertEqual(path, "/HP")
            XCTAssertEqual(value, .int(100))
        } else {
            XCTFail("action 应是 updateVariable，实为 \(storedAction)")
        }
    }

    /// 完整闭环：UI 事件 → Button → Action → VariableStore mutation → 重新生成 IR。
    func testButtonActionUpdatesStoreAndRegeneratesIR() {
        // 1. 起始：HP = 80。
        var tree: JSONValue = .object(["HP": .int(80)])

        // 2. 起始 IR。
        var ir = TavernTranspiler.transpile(.statData(tree))
        XCTAssertEqual(extractNumbers(ir), [80.0])

        // 3. 角色卡定义一个按钮：HP 改成 100。
        let buttonIR = TavernTranspiler.transpile(
            .buttonHint(
                label: "加血",
                action: .updateVariable(path: "/HP", value: .int(100))
            )
        )
        guard case let .button(_, action) = buttonIR else { return XCTFail("应是 button") }

        // 4. 用户点击 → dispatcher 写入树。
        let dispatcher = NativeActionDispatcher()
        XCTAssertTrue(dispatcher.dispatch(action, to: &tree))

        // 5. 重新跑 transpile → IR 必须反映 HP = 100。
        ir = TavernTranspiler.transpile(.statData(tree))
        XCTAssertEqual(extractNumbers(ir), [100.0])
    }

    // MARK: - 8. 动画意图

    /// `.animationHint` → 带 animation 的 container。
    func testAnimationHintProducesContainerWithAnimation() {
        let anim = NativeAnimation(kind: .fade, durationMs: 250)
        let ir = TavernTranspiler.transpile(.animationHint(anim))
        guard case let .container(_, _, storedAnim) = ir else {
            return XCTFail("应是 container，实为 \(ir)")
        }
        XCTAssertEqual(storedAnim?.kind, .fade)
        XCTAssertEqual(storedAnim?.durationMs, 250)
    }

    /// 4 种 kind 都可被 Transpiler 承载。
    func testAllAnimationKindsAreSupported() {
        for kind in [NativeAnimation.Kind.fade, .slide, .scale, .transition] {
            let ir = TavernTranspiler.transpile(
                .animationHint(NativeAnimation(kind: kind, durationMs: nil))
            )
            guard case let .container(_, _, anim) = ir else { return XCTFail() }
            XCTAssertEqual(anim?.kind, kind)
        }
    }

    // MARK: - 9 + 11. 未知结构 → residual / fallback（不丢数据）

    /// `.unknown` → container 含 reason + raw。
    /// **关键**：raw 必须原样保留 —— UI 即使不识别也要看得到原文。
    func testUnknownExpressionPreservesRawText() {
        let raw = "<some-unrecognized-tag>{a:1,b:2}</some-unrecognized-tag>"
        let ir = TavernTranspiler.transpile(.unknown(reason: "unrecognized XML", raw: raw))
        guard case let .container(title, children, _) = ir else { return XCTFail() }

        XCTAssertEqual(title, "未识别")
        XCTAssertTrue(children.contains { node in
            if case let .text(content) = node { return content.contains("unrecognized XML") }
            return false
        }, "应有 text 子节点说明原因")
        XCTAssertTrue(children.contains { node in
            if case let .field(label, value) = node { return label == "raw" && value == raw }
            return false
        }, "raw 原文必须原样保留在 field(raw) 里")
    }

    /// 空 `<status>` 块 → `.unknown` 通道（不丢原文）。
    func testEmptyStatusBlockFallsBackToUnknown() {
        let ir = TavernTranspiler.transpile(.statusBlock(text: "   \n  \n"))
        guard case let .container(title, _, _) = ir else { return XCTFail() }
        XCTAssertEqual(title, "未识别", "空 status 块应走 unknown 通道")
    }

    /// `<status>` 块含 `key: value` 行 → 拆成 field；label 原样保留，**不**做字段名解析。
    func testStatusBlockKeyValueLinesBecomeFields() {
        let text = """
        HP: 80
        好感度: 65
        这是一段自由文本
        心情: 平静
        """
        let ir = TavernTranspiler.transpile(.statusBlock(text: text))
        guard case let .container(_, children, _) = ir else { return XCTFail() }
        // 3 条 field + 1 条 text。
        XCTAssertEqual(children.count, 4)
        // labels 原样透传（"HP"、"好感度"、"心情"）—— 没有任何字段名被改成业务术语。
        let labels = Set(children.compactMap { node -> String? in
            if case let .field(label, _) = node { return label }
            return nil
        })
        XCTAssertEqual(labels, ["HP", "好感度", "心情"])
    }

    /// `<status>` 支持 ASCII `:` 与全角 `：`。
    func testStatusBlockSupportsFullWidthColon() {
        let ir = TavernTranspiler.transpile(.statusBlock(text: "金币：200"))
        guard case let .container(_, children, _) = ir else { return XCTFail() }
        XCTAssertEqual(children.count, 1)
        guard case let .field(label, value) = children[0] else { return XCTFail() }
        XCTAssertEqual(label, "金币")
        XCTAssertEqual(value, "200")
    }

    // MARK: - 12. 不执行 JavaScript / HTML / CSS

    /// **结构保证**：Transpiler 模块只 import Foundation；
    /// 不 import WebKit / JavaScriptCore / SwiftUI / UIKit。
    /// 这是编译期保证 —— 不需要运行期测试。
    ///
    /// 这里做一个**否定测试**：即使输入里塞了 `<script>...</script>`，
    /// Transpiler 也只把它当成文本/未知通道，绝不"执行"任何脚本。
    func testJavaScriptContentNeverExecuted() {
        let js = "<script>alert('pwn')</script>"
        let ir = TavernTranspiler.transpile(.unknown(reason: "looks like script", raw: js))
        // IR 树里没有任何 label 叫 alert / pwn / script 是 native 组件 —— 它们都
        // 只是字符串数据。
        let described = describe(ir)
        XCTAssertTrue(described.contains("alert"), "脚本原文必须以 raw / text 形式保留")
        // 但没有任何节点叫 "alert" 之类带语义的 native component —— 全部是 raw / text。
        XCTAssertFalse(described.contains("[button:alert]"))
        XCTAssertFalse(described.contains("script:"))
    }

    /// `.text` 里塞 HTML / CSS → 原样保留为文本。
    func testHtmlCssContentKeptAsText() {
        let html = "<div style=\"color:red\">hello</div>"
        let ir = TavernTranspiler.transpile(.text(html))
        guard case let .text(content) = ir else { return XCTFail() }
        XCTAssertEqual(content, html, "HTML/CSS 当成纯文本，不解析、不剥离")
    }

    // MARK: - 架构不变量：legacy bridge

    /// legacy `.text` → Native IR `.text` —— 内容原样保留。
    func testLegacyTextNodeBridgesToText() {
        let ir = RenderNodeTranspiler.transpile(.text("hello world"))
        guard case let .text(content) = ir else { return XCTFail() }
        XCTAssertEqual(content, "hello world")
    }

    /// legacy `.statusFields` → Native IR container + fields。
    /// labels 原样保留（HP / 好感度 / 自定义字段都一样）。
    func testLegacyStatusFieldsBridgesToContainerWithFields() {
        let ir = RenderNodeTranspiler.transpile(.statusFields([
            StatusField(label: "HP", value: "80"),
            StatusField(label: "好感度", value: "65"),
            StatusField(label: "小手机电量", value: "73"),
        ]))
        guard case let .container(title, children, _) = ir else { return XCTFail() }
        XCTAssertEqual(title, "状态")
        XCTAssertEqual(children.count, 3)
        let labels = Set(children.compactMap { node -> String? in
            if case let .field(label, _) = node { return label }
            return nil
        })
        XCTAssertEqual(labels, ["HP", "好感度", "小手机电量"])
    }

    /// legacy `.status(hp:affection:)` → Native IR 两条 field。
    /// **关键否定**：labels 是 "hp" / "affection"，但**没有任何 HP 颜色规则**。
    /// renderer 收到的是两条 field，会按 field 渲染，不会画进度条或加颜色。
    func testLegacyStatusTupleBridgesToPlainFields() {
        let ir = RenderNodeTranspiler.transpile(.status(hp: 80, affection: 65))
        guard case let .container(_, children, _) = ir else { return XCTFail() }
        XCTAssertEqual(children.count, 2)

        let hpField = children.first { node in
            if case let .field(label, _) = node { return label == "hp" }
            return false
        }
        let affField = children.first { node in
            if case let .field(label, _) = node { return label == "affection" }
            return false
        }
        XCTAssertNotNil(hpField, "应有 hp field")
        XCTAssertNotNil(affField, "应有 affection field")

        // **关键否定**：没有任何节点是 .progress —— legacy HP 颜色梯度**不在** Native IR 里。
        let progressCount = children.filter { node in
            if case .progress = node { return true }
            return false
        }.count
        XCTAssertEqual(progressCount, 0,
                       "legacy status 落到 Native IR 后不升级为 progress（HP 颜色规则在旧 StatusView，与 IR 正交）")
    }

    /// legacy `.statusPlaceholder` → 走 NativeIRProjector 同一条通路。
    /// 这证明：legacy placeholder 与新 transpile 走**完全相同**的 projector，
    /// 不存在第二份 projector。
    func testLegacyStatusPlaceholderUsesSameProjector() {
        let statData: JSONValue = .object(["HP": .int(80)])
        let bridgeIR = RenderNodeTranspiler.transpile(.statusPlaceholder(statData: statData))
        let directIR = TavernTranspiler.transpile(.statusPlaceholder(statData))
        XCTAssertEqual(bridgeIR, directIR,
                       "legacy bridge 与新 transpile 必须共用同一份 NativeIRProjector 输出")
    }

    /// legacy `.variableUpdate` → Native IR container 含 applied + paths。
    func testLegacyVariableUpdateBridgesToSummaryContainer() {
        let ir = RenderNodeTranspiler.transpile(
            .variableUpdate(summary: .init(appliedCount: 3, affectedPaths: ["/HP", "/好感度", "/金币"]))
        )
        guard case let .container(title, children, _) = ir else { return XCTFail() }
        XCTAssertEqual(title, "变量更新")
        XCTAssertTrue(children.contains { node in
            if case let .field(label, value) = node { return label == "applied" && value == "3" }
            return false
        })
        XCTAssertTrue(children.contains { node in
            if case let .field(label, value) = node {
                return label == "paths" && value.contains("/HP") && value.contains("/好感度")
            }
            return false
        })
    }

    /// `RenderTree` → 单一 `NativeIRNode.list` —— 上层（renderer / 测试）拿到
    /// 的是一棵有序 list。
    func testLegacyRenderTreeBridgesToListNode() {
        let tree = RenderTree(nodes: [
            .text("hello "),
            .status(hp: 80, affection: 65),
            .text(" world"),
        ])
        let ir = RenderNodeTranspiler.transpile(tree)
        guard case let .list(items) = ir else { return XCTFail("应是 .list，实为 \(ir)") }
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(TavernIRShape.isText(items[0]))
        XCTAssertTrue(TavernIRShape.isContainer(items[1]))
        XCTAssertTrue(TavernIRShape.isText(items[2]))
    }

    /// `TavernTranspiler` 与 `RenderNodeTranspiler` 互不依赖：
    /// 编译期已经保证（一个文件不引用另一个文件），运行期再确认一遍：
    /// 它们之间没有"约定"——分别 transpile 同一条 `.statusFields` 出来的 IR
    /// 应**完全相等**。
    func testBothTranspilersAgreeOnStatusFields() {
        let legacy = RenderNodeTranspiler.transpile(.statusFields([
            StatusField(label: "HP", value: "80"),
            StatusField(label: "好感度", value: "65"),
        ]))
        let modern = TavernTranspiler.transpile(.statusFields([
            StatusField(label: "HP", value: "80"),
            StatusField(label: "好感度", value: "65"),
        ]))
        XCTAssertEqual(legacy, modern,
                       "两条 pipeline 转 .statusFields 必须产相同 IR（共用同一份语义）")
    }

    // MARK: - helpers

    private func extractNumbers(_ node: NativeIRNode) -> [Double] {
        var out: [Double] = []
        func visit(_ n: NativeIRNode) {
            if case let .number(value, _) = n { out.append(value) }
            if case let .container(_, children, _) = n {
                for c in children { visit(c) }
            }
            if case let .list(items) = n {
                for i in items { visit(i) }
            }
        }
        visit(node)
        return out
    }

    private func describe(_ node: NativeIRNode) -> String {
        var out: [String] = []
        func visit(_ n: NativeIRNode) {
            switch n {
            case let .text(s): out.append(s)
            case let .number(value, label): out.append("\(label ?? "")=\(value)")
            case let .progress(label, value, max):
                let maxStr: String = max.map { "\($0)" } ?? "?"
                out.append("\(label)=\(value)/\(maxStr)")
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
            if case let .container(_, children, _) = n {
                for c in children { visit(c) }
            }
            if case let .list(items) = n {
                for i in items { visit(i) }
            }
        }
        visit(node)
        return out.joined(separator: " ")
    }
}

// MARK: - NativeIRNode 形状 helpers（测试内私有）
//
// 故意只放 inline 静态函数,避免与 NativeIRTests.swift 顶部的同名
// `private extension NativeIRNode` 冲突 —— Swift 5.9 同 module 多文件
// private extension 解析不可靠。

private enum TavernIRShape {
    static func isNumber(_ n: NativeIRNode) -> Bool {
        if case .number = n { return true }
        return false
    }
    static func isProgress(_ n: NativeIRNode) -> Bool {
        if case .progress = n { return true }
        return false
    }
    static func isText(_ n: NativeIRNode) -> Bool {
        if case .text = n { return true }
        return false
    }
    static func isContainer(_ n: NativeIRNode) -> Bool {
        if case .container = n { return true }
        return false
    }
}