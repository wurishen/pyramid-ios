import XCTest
@testable import PyramidCore

/// P3 native transpile 端到端测试，驱动 frozen fixture `swift-tests/Fixtures/native_transpile_fixture.json`。
///
/// Fixture 是协议形态（不是可玩角色卡），覆盖：
/// - 显示用正则的跳过规则（replacement 含 HTML beautify token → 跳过显示链）。
/// - promptOnly=true 的正则不进显示链。
/// - `<StatusPlaceHolderImpl/>` → statusPlaceholder 节点（数据来自 VariableStore）。
/// - `<<UpdateVariable>>[…JSON Patch…]<</UpdateVariable>>` → apply patches → variableUpdate 节点。
/// - `message.content` 原文永不被改写。
///
/// `RenderNodeParser` 暴露 closure-based 测试入口（`parse(_:snapshot:applyPatches:)`），
/// 让本测试不依赖 SwiftUI ObservableObject 也能驱动 store 行为 —— 与生产
/// `parse(_:variableStore:sessionId:)` 等价。
final class NativeTranspileFixtureTests: XCTestCase {

    // MARK: - 跳过规则（replacement HTML beautify token）

    /// fixture rule 1/2/6/7 的 replacement 含 <script / .load / <div / <style / <details →
    /// MessageRendererCore.isHtmlBeautify 判定为 true → orderedRegexes 过滤掉。
    func testHtmlBeautifyReplacementIsSkipped() {
        XCTAssertTrue(MessageRendererCore.isHtmlBeautify(replacement:
            "<div class='status-panel'><style>.status-panel{font:14px}</style><script src='x'></script></div>"
        ))
        XCTAssertTrue(MessageRendererCore.isHtmlBeautify(replacement:
            "<details class='variable-update'><summary>x</summary><div class='night-sky'></div></details>"
        ))
        XCTAssertTrue(MessageRendererCore.isHtmlBeautify(replacement:
            "<script src='x' onload=\"$('body').load('https://x');\"></script>"
        ))
        XCTAssertTrue(MessageRendererCore.isHtmlBeautify(replacement:
            "<object data='https://x'></object>"
        ))
        XCTAssertTrue(MessageRendererCore.isHtmlBeautify(replacement:
            "<iframe src='https://x'></iframe>"
        ))
    }

    /// fixture rule 3/4/5 promptOnly=true → 走 shouldRunOnDisplay 的另一条过滤路径。
    /// 即便 token 全部不在跳过列表里，promptOnly 也让规则不进入显示链。
    func testPromptOnlyIsFilteredFromDisplayChain() {
        let rule = DisplayRegex(
            name: "fixture-latest-3-floor-var-only",
            pattern: "<<UpdateVariable[^>]*>>[\\s\\S]*?<\\/UpdateVariable>",
            replacement: "",
            enabled: true,
            promptOnly: true
        )
        let ordered = MessageRendererCore.orderedRegexes(
            presetDisplayRegexIds: [],
            all: [rule]
        )
        XCTAssertTrue(ordered.isEmpty, "promptOnly 规则不应进入显示链")
    }

    /// fixture 跳过规则 + promptOnly 过滤同时生效：只有「非 beautify + 非 promptOnly + enabled」才进显示链。
    func testOrderedRegexesHonorsBothFilters() {
        let beautifyRule = DisplayRegex(
            name: "beautify",
            pattern: "x",
            replacement: "<div>x</div>",
            enabled: true
        )
        let promptOnlyRule = DisplayRegex(
            name: "promptOnly",
            pattern: "y",
            replacement: "z",
            enabled: true,
            promptOnly: true
        )
        let disabledRule = DisplayRegex(
            name: "disabled",
            pattern: "q",
            replacement: "r",
            enabled: false
        )
        let safeRule = DisplayRegex(
            name: "safe",
            pattern: "a",
            replacement: "b",
            enabled: true
        )
        let ordered = MessageRendererCore.orderedRegexes(
            presetDisplayRegexIds: [],
            all: [beautifyRule, promptOnlyRule, disabledRule, safeRule]
        )
        XCTAssertEqual(ordered.map(\.name), ["safe"])
    }

    // MARK: - 样例 1：StatusPlaceHolderImpl

    /// fixture sample 1：原文 `<StatusPlaceHolderImpl/>你好，欢迎回来。` →
    /// `[.statusPlaceholder(snapshot=[]), .text("你好，欢迎回来。")]`。
    /// snapshot 为空（未 seed）→ UI 显示「状态（等待变量）」占位文本。
    func testSampleMessageStatusPlaceholderParsesToStatusPlaceholder() {
        let content = "<StatusPlaceHolderImpl/>你好，欢迎回来。"
        let store = SessionStore()
        let tree = RenderNodeParser.parse(
            content,
            snapshot: { store.snapshot() },
            applyPatches: { ops in try store.apply(ops) }
        )
        XCTAssertEqual(tree.nodes.count, 2)
        guard case let .statusPlaceholder(snapshot) = tree.nodes[0] else {
            XCTFail("节点 0 应是 statusPlaceholder，实为 \(tree.nodes[0])")
            return
        }
        XCTAssertEqual(snapshot, [], "未 seed 时 snapshot 应为空")
        guard case let .text(text) = tree.nodes[1] else {
            XCTFail("节点 1 应是 text，实为 \(tree.nodes[1])")
            return
        }
        XCTAssertEqual(text, "你好，欢迎回来。")
    }

    /// snapshot 反映已 seed 的嵌套 JSON 树：fixture `init_stat_data` 经 JSON Pointer 拍扁。
    /// 不假定具体顺序（dict.sorted 顺序依赖 Swift 版本）；改用 set 比对。
    func testStatusPlaceholderSnapshotReflectsSeededVariables() {
        let content = "<StatusPlaceHolderImpl/>你好。"
        let store = SessionStore()
        store.seed([
            "时间": .string("清晨"),
            "玩家": .object(["当前所在地": .string("旅店")])
        ])
        let tree = RenderNodeParser.parse(
            content,
            snapshot: { store.snapshot() },
            applyPatches: { ops in try store.apply(ops) }
        )
        guard case let .statusPlaceholder(snapshot) = tree.nodes[0] else {
            XCTFail("节点 0 应是 statusPlaceholder")
            return
        }
        XCTAssertEqual(Set(snapshot.map(\.path)), ["/时间", "/玩家/当前所在地"])
        XCTAssertEqual(Set(snapshot.map(\.displayValue)), ["清晨", "旅店"])
    }

    // MARK: - 样例 2：UpdateVariable

    /// fixture sample 2：`<<UpdateVariable>>[…JSON Patch…]<</UpdateVariable>>` →
    /// apply patches → 写 store → variableUpdate 节点 + text 前缀。
    func testSampleMessageUpdateVariableAppliesPatches() throws {
        let content = "她转身离开。<<UpdateVariable>>[{\"op\":\"replace\",\"path\":\"/时间\",\"value\":\"傍晚\"},{\"op\":\"replace\",\"path\":\"/玩家/当前所在地\",\"value\":\"集市\"}]<</UpdateVariable>>"
        let store = SessionStore()
        store.seed([
            "时间": .string("清晨"),
            "玩家": .object(["当前所在地": .string("旅店")])
        ])
        let tree = RenderNodeParser.parse(
            content,
            snapshot: { store.snapshot() },
            applyPatches: { ops in try store.apply(ops) }
        )
        XCTAssertEqual(tree.nodes.count, 2)
        guard case let .text(lead) = tree.nodes[0] else {
            XCTFail("节点 0 应是 text")
            return
        }
        XCTAssertEqual(lead, "她转身离开。")
        guard case let .variableUpdate(summary) = tree.nodes[1] else {
            XCTFail("节点 1 应是 variableUpdate，实为 \(tree.nodes[1])")
            return
        }
        XCTAssertEqual(summary.appliedCount, 2)
        XCTAssertEqual(Set(summary.affectedPaths), ["/时间", "/玩家/当前所在地"])

        // 验证 store 真的被写入（不是仅生成 summary）。
        let snap = store.snapshot()
        XCTAssertEqual(Set(snap.map(\.path)), ["/时间", "/玩家/当前所在地"])
        XCTAssertEqual(Set(snap.map(\.displayValue)), ["傍晚", "集市"])
    }

    /// fixture `mvu_output_contract.ignored_examples`：`_` 前缀 path 被协议层吃掉，不写入。
    func testPrivatePathIsDroppedFromStoreAndSummary() throws {
        let content = "x<<UpdateVariable>>[{\"op\":\"add\",\"path\":\"/_ui/scroll\",\"value\":42}]<</UpdateVariable>>"
        let store = SessionStore()
        let tree = RenderNodeParser.parse(
            content,
            snapshot: { store.snapshot() },
            applyPatches: { ops in try store.apply(ops) }
        )
        // 最后一节点应是 variableUpdate；前缀 'x' 是 .text 一并存在。
        let lastIndex = tree.nodes.count - 1
        guard lastIndex >= 0, case let .variableUpdate(summary) = tree.nodes[lastIndex] else {
            XCTFail("最后一节点应是 variableUpdate，实为 \(tree.nodes)")
            return
        }
        XCTAssertEqual(summary.appliedCount, 1, "_ 路径 op 计入 applied")
        XCTAssertTrue(summary.affectedPaths.isEmpty, "_ 路径不进 affectedPaths（UI 不显示私有字段）")
        XCTAssertTrue(store.snapshot().isEmpty, "_ 路径不写入 store")
    }

    /// raw message 原文永不被改写 —— fixture `expect_message_content_unchanged: true`。
    /// RenderNodeParser 只读，不返回 mutator。
    func testRawMessageContentUnchanged() {
        let content = "<StatusPlaceHolderImpl/>你好。<<UpdateVariable>>[{\"op\":\"replace\",\"path\":\"/时间\",\"value\":\"傍晚\"}]<</UpdateVariable>>"
        let store = SessionStore()
        let originalLength = content.count
        _ = RenderNodeParser.parse(
            content,
            snapshot: { store.snapshot() },
            applyPatches: { ops in try store.apply(ops) }
        )
        XCTAssertEqual(content.count, originalLength, "原文长度不应变化")
        XCTAssertTrue(content.contains("<StatusPlaceHolderImpl/>"), "原文标签保留")
        XCTAssertTrue(content.contains("<<UpdateVariable>>"), "原文标签保留")
    }

    /// 解析失败 → 失败的 UpdateVariable 块降级为 .text，前缀/后缀作为独立 .text 节点。
    /// 整段原文（含标签）仍在树中保留 —— 不丢内容。
    func testMalformedJsonPatchFallsBackToText() {
        let content = "前缀<<UpdateVariable>>not-json<</UpdateVariable>>后缀"
        let store = SessionStore()
        let tree = RenderNodeParser.parse(
            content,
            snapshot: { store.snapshot() },
            applyPatches: { ops in try store.apply(ops) }
        )
        // 三段：前缀 .text("前缀") + 失败块 .text(rawBlock) + 后缀 .text("后缀")。
        XCTAssertEqual(tree.nodes.count, 3)
        // 把所有 .text 拼回去 = 原文。
        let reassembled = tree.nodes.compactMap { node -> String? in
            if case let .text(s) = node { return s }
            return nil
        }.joined()
        XCTAssertEqual(reassembled, content)
    }

    /// 无 store 接入的纯渲染场景：UpdateVariable 块降级为 .text（不打补丁，但也不丢内容）。
    /// 等价于 RenderEngine 路径上 `variableStore == nil`。
    func testNilStoreFallbackForUpdateVariable() {
        let content = "before<<UpdateVariable>>[{\"op\":\"replace\",\"path\":\"/时间\",\"value\":\"x\"}]<</UpdateVariable>>after"
        let tree = RenderNodeParser.parse(
            content,
            snapshot: { [] },
            applyPatches: { _ in throw NSError(domain: "RenderNodeParser", code: 0) }
        )
        let reassembled = tree.nodes.compactMap { node -> String? in
            if case let .text(s) = node { return s }
            return nil
        }.joined()
        XCTAssertEqual(reassembled, content, "nil store 时 UpdateVariable 块降级为 .text，整段不丢内容")
    }

    // MARK: - 边界：占位符与 UpdateVariable 紧邻

    func testAdjacentPlaceholderAndUpdate() throws {
        let content = "<StatusPlaceHolderImpl/><<UpdateVariable>>[{\"op\":\"replace\",\"path\":\"/时间\",\"value\":\"傍晚\"}]<</UpdateVariable>>"
        let store = SessionStore()
        store.seed(["时间": .string("清晨")])
        let tree = RenderNodeParser.parse(
            content,
            snapshot: { store.snapshot() },
            applyPatches: { ops in try store.apply(ops) }
        )
        // 两个相邻块 → 两个结构化节点。
        XCTAssertEqual(tree.nodes.count, 2)
        guard case .statusPlaceholder = tree.nodes[0] else {
            XCTFail("节点 0 应是 statusPlaceholder，实为 \(tree.nodes[0])")
            return
        }
        guard case let .variableUpdate(summary) = tree.nodes[1] else {
            XCTFail("节点 1 应是 variableUpdate，实为 \(tree.nodes[1])")
            return
        }
        XCTAssertEqual(summary.appliedCount, 1)
    }
}

// MARK: - 测试用最小 store（无 SwiftUI / UserDefaults）

/// RenderNodeParser closure-based 入口的最小 store stub。
/// 行为与生产 `VariableStore`（数据层）完全一致：seed + apply JSON Patch + snapshot。
final class SessionStore {
    private var root: JSONValue = .object([:])

    func seed(_ data: [String: JSONValue]) {
        root = .object(data)
    }

    @discardableResult
    func apply(_ ops: [JSONPatchOperation]) throws -> Int {
        try JSONPatchApplier.apply(ops, to: &root)
    }

    func snapshot() -> [VariableEntry] {
        VariableStoreFlattener.snapshot(root: root)
    }
}