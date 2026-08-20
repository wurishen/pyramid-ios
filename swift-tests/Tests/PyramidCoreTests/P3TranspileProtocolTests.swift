import XCTest
@testable import PyramidCore

/// P3 native transpile 协议层覆盖（不依赖任何 frozen JSON / 卡味样例）：
///
/// - `<UpdateVariable>…</UpdateVariable>`（canonical 单 `<`，酒馆 / MVU 源码一致）
///   → 解析 JSON Patch → 写 store → `.variableUpdate(summary)`。
/// - `<<UpdateVariable>>…<</UpdateVariable>>`（历史遗留双 `<` 拼写）
///   → 同上，确保旧数据不立刻全挂。
/// - `<StatusPlaceHolderImpl/>` → `.statusPlaceholder(statData)`，statData 是当前会话
///   整棵 `JSONValue` 树（`VariableStore.raw(forSession:)`），不预置任何固定栏目。
/// - HTML beautify replacement（含 `<script / .load / <object / <iframe / <details / <style / <div`）
///   → `MessageRendererCore.isHtmlBeautify` 命中 → `orderedRegexes` 过滤。
/// - `promptOnly == true` 的 `DisplayRegex` 不进显示链。
/// - `message.content` 原文永不被改写。
/// - `_` 前缀 path 在协议层静默 skip（不进 store / `affectedPaths`）。
///
/// 所有用例只使用**中性路径**（`/时间`、`/玩家/当前所在地`、`/_ui/...`），不含角色名 /
/// 卡面路径 / 脚本名等卡面语义。
final class P3TranspileProtocolTests: XCTestCase {

    // MARK: - UpdateVariable canonical（单 `<`）

    /// canonical `<UpdateVariable>…</UpdateVariable>`：解析 JSON Patch → 写 store →
    /// `.variableUpdate(summary)` + 前缀/后缀文本保持为 `.text`。
    func testCanonicalUpdateVariableAppliesPatches() {
        let content = "prefix <UpdateVariable>[{\"op\":\"replace\",\"path\":\"/时间\",\"value\":\"傍晚\"},{\"op\":\"replace\",\"path\":\"/玩家/当前所在地\",\"value\":\"集市\"}]</UpdateVariable> suffix"
        let store = SessionStore()
        store.seed([
            "时间": .string("清晨"),
            "玩家": .object(["当前所在地": .string("旅店")])
        ])

        let tree = RenderNodeParser.parse(
            content,
            statData: { store.statData() },
            applyPatches: { ops in try store.apply(ops) }
        )

        XCTAssertEqual(tree.nodes.count, 3, "前缀 + variableUpdate + 后缀")
        guard case let .text(prefix) = tree.nodes[0] else {
            XCTFail("节点 0 应是 text，实为 \(tree.nodes[0])")
            return
        }
        XCTAssertEqual(prefix, "prefix ")

        guard case let .variableUpdate(summary) = tree.nodes[1] else {
            XCTFail("节点 1 应是 variableUpdate，实为 \(tree.nodes[1])")
            return
        }
        XCTAssertEqual(summary.appliedCount, 2)
        XCTAssertEqual(Set(summary.affectedPaths), ["/时间", "/玩家/当前所在地"])

        guard case let .text(suffix) = tree.nodes[2] else {
            XCTFail("节点 2 应是 text，实为 \(tree.nodes[2])")
            return
        }
        XCTAssertEqual(suffix, " suffix")

        // store 真的被写入，不是仅生成 summary。
        let snap = store.snapshot()
        XCTAssertEqual(Set(snap.map(\.path)), ["/时间", "/玩家/当前所在地"])
        XCTAssertEqual(Set(snap.map(\.displayValue)), ["傍晚", "集市"])
    }

    /// canonical 单 `<` + 空 `<UpdateVariable></UpdateVariable>` → 解析为空 patch 列表 →
    /// 该块降级为 `.text(原文)`，整段不丢内容。
    func testCanonicalUpdateVariableEmptyBodyFallsBackToText() {
        let content = "head<UpdateVariable></UpdateVariable>tail"
        let store = SessionStore()
        let tree = RenderNodeParser.parse(
            content,
            statData: { store.statData() },
            applyPatches: { ops in try store.apply(ops) }
        )
        // 三段 .text 拼回去 == 原文（不丢内容）。
        let reassembled = tree.nodes.compactMap { node -> String? in
            if case let .text(s) = node { return s }
            return nil
        }.joined()
        XCTAssertEqual(reassembled, content)
    }

    /// canonical 单 `<` + JSON 畸形 → 降级为 `.text(整段含标签)`，前缀/后缀独立保留。
    func testCanonicalUpdateVariableMalformedJsonFallsBackToText() {
        let content = "prefix<UpdateVariable>not-json</UpdateVariable>suffix"
        let store = SessionStore()
        let tree = RenderNodeParser.parse(
            content,
            statData: { store.statData() },
            applyPatches: { ops in try store.apply(ops) }
        )
        XCTAssertEqual(tree.nodes.count, 3, "前缀 + 失败块 + 后缀")
        let reassembled = tree.nodes.compactMap { node -> String? in
            if case let .text(s) = node { return s }
            return nil
        }.joined()
        XCTAssertEqual(reassembled, content, "降级路径必须把整段原文拼回去")
    }

    /// canonical 单 `<` + `_` 前缀 path → op 计入 applied，但 `affectedPaths` 与 store 都不包含。
    func testCanonicalUpdateVariablePrivatePathIsDropped() {
        let content = "<UpdateVariable>[{\"op\":\"add\",\"path\":\"/_ui/scroll\",\"value\":42}]</UpdateVariable>"
        let store = SessionStore()
        let tree = RenderNodeParser.parse(
            content,
            statData: { store.statData() },
            applyPatches: { ops in try store.apply(ops) }
        )
        guard case let .variableUpdate(summary) = tree.nodes[0] else {
            XCTFail("节点 0 应是 variableUpdate，实为 \(tree.nodes[0])")
            return
        }
        XCTAssertEqual(summary.appliedCount, 1, "_ 路径 op 计入 applied 计数")
        XCTAssertTrue(summary.affectedPaths.isEmpty, "_ 路径不进 affectedPaths（UI 不显示私有字段）")
        XCTAssertTrue(store.snapshot().isEmpty, "_ 路径不写入 store")
    }

    // MARK: - UpdateVariable legacy 双 `<` fallback

    /// 历史遗留双 `<` 拼写：与 canonical 行为一致 —— apply patch → `.variableUpdate(summary)`。
    /// 允许旧数据不立刻全挂。
    func testLegacyDoubleAngleUpdateVariableAppliesPatches() {
        let content = "<<UpdateVariable>>[{\"op\":\"replace\",\"path\":\"/时间\",\"value\":\"傍晚\"}]<</UpdateVariable>>"
        let store = SessionStore()
        store.seed(["时间": .string("清晨")])
        let tree = RenderNodeParser.parse(
            content,
            statData: { store.statData() },
            applyPatches: { ops in try store.apply(ops) }
        )
        XCTAssertEqual(tree.nodes.count, 1)
        guard case let .variableUpdate(summary) = tree.nodes[0] else {
            XCTFail("节点 0 应是 variableUpdate（双 `<` 兼容路径），实为 \(tree.nodes[0])")
            return
        }
        XCTAssertEqual(summary.appliedCount, 1)
        XCTAssertEqual(summary.affectedPaths, ["/时间"])
    }

    /// canonical 与 legacy 在同一段输入里并存：两个块都被识别。
    func testCanonicalAndLegacyUpdateVariableBothRecognized() {
        let content =
            "<UpdateVariable>[{\"op\":\"replace\",\"path\":\"/时间\",\"value\":\"a\"}]</UpdateVariable>" +
            " mid " +
            "<<UpdateVariable>>[{\"op\":\"replace\",\"path\":\"/玩家/当前所在地\",\"value\":\"b\"}]<</UpdateVariable>>"
        let store = SessionStore()
        store.seed([
            "时间": .string("x"),
            "玩家": .object(["当前所在地": .string("y")])
        ])
        let tree = RenderNodeParser.parse(
            content,
            statData: { store.statData() },
            applyPatches: { ops in try store.apply(ops) }
        )
        // 期望：variableUpdate(canonical) → text(" mid ") → variableUpdate(legacy)。
        // 无尾部 text 节点（cursor 已走到 nsInput.length）。
        XCTAssertEqual(tree.nodes.count, 3)
        guard case let .variableUpdate(s1) = tree.nodes[0] else {
            XCTFail("节点 0 应是 canonical variableUpdate")
            return
        }
        XCTAssertEqual(s1.affectedPaths, ["/时间"])
        guard case let .text(mid) = tree.nodes[1] else {
            XCTFail("节点 1 应是 text")
            return
        }
        XCTAssertEqual(mid, " mid ")
        guard case let .variableUpdate(s2) = tree.nodes[2] else {
            XCTFail("节点 2 应是 legacy variableUpdate")
            return
        }
        XCTAssertEqual(s2.affectedPaths, ["/玩家/当前所在地"])
    }

    // MARK: - StatusPlaceHolderImpl

    /// `<StatusPlaceHolderImpl/>` → `.statusPlaceholder(statData)`；statData 是整棵 JSONValue 树。
    /// 树就是变量树本身——**不**预置任何"时间/位置/选项"等固定栏目；seed 什么、就 emit 什么。
    func testStatusPlaceholderRecognized() {
        let content = "<StatusPlaceHolderImpl/>"
        let store = SessionStore()
        store.seed([
            "时间": .string("清晨"),
            "玩家": .object(["当前所在地": .string("旅店")])
        ])
        let tree = RenderNodeParser.parse(
            content,
            statData: { store.statData() },
            applyPatches: { ops in try store.apply(ops) }
        )
        XCTAssertEqual(tree.nodes.count, 1)
        guard case let .statusPlaceholder(statData) = tree.nodes[0] else {
            XCTFail("节点 0 应是 statusPlaceholder，实为 \(tree.nodes[0])")
            return
        }
        // 树形结构透传：顶层 object 保留「时间」/「玩家」两个 key；
        // 「玩家」本身也是 object，路径是 /玩家/当前所在地。
        guard case .object(let top) = statData else {
            XCTFail("statData 应为 object，实为 \(statData)")
            return
        }
        XCTAssertEqual(top["时间"], .string("清晨"))
        XCTAssertEqual(top["玩家"], .object(["当前所在地": .string("旅店")]))
    }

    /// 未 seed 时 `<StatusPlaceHolderImpl/>` → statData = `.object([:])` →
    /// UI 走「状态（等待变量）」占位。不补造任何"时间/位置"等假字段。
    func testStatusPlaceholderEmptyStatDataWhenUnseeded() {
        let content = "<StatusPlaceHolderImpl/>hello"
        let store = SessionStore()
        let tree = RenderNodeParser.parse(
            content,
            statData: { store.statData() },
            applyPatches: { ops in try store.apply(ops) }
        )
        XCTAssertEqual(tree.nodes.count, 2)
        guard case let .statusPlaceholder(statData) = tree.nodes[0] else {
            XCTFail("节点 0 应是 statusPlaceholder")
            return
        }
        XCTAssertEqual(statData, .object([:]))
        guard case let .text(t) = tree.nodes[1] else {
            XCTFail("节点 1 应是 text")
            return
        }
        XCTAssertEqual(t, "hello")
    }

    /// `RawMessage` 是空对象 seed → `.statusPlaceholder(.object([:]))` → 投影得到单「等待变量」占位，
    /// **不**发射任何"时间/位置"等固定栏目 block。
    func testStatusPlaceholderEmptyStatDataRendersNoFixedColumns() {
        let content = "<StatusPlaceHolderImpl/>"
        let store = SessionStore()
        let tree = RenderNodeParser.parse(
            content,
            statData: { store.statData() },
            applyPatches: { ops in try store.apply(ops) }
        )
        guard case let .statusPlaceholder(statData) = tree.nodes[0] else {
            XCTFail("节点 0 应是 statusPlaceholder")
            return
        }
        let model = NativeDisplayModelProjector.project(statData: statData)
        // 唯一 block 是 root group + 单条「等待变量」文本，不允许任何"时间/位置/选项"等固定栏目。
        XCTAssertEqual(model.blocks.count, 1)
        guard case let .group(_, children) = model.blocks[0] else {
            XCTFail("根部应是 group")
            return
        }
        XCTAssertEqual(children.count, 1)
        guard case let .text(t) = children[0] else {
            XCTFail("children[0] 应是 text")
            return
        }
        XCTAssertTrue(t.contains("等待变量"))
        // 显式禁止"时间/位置/选项"等固定栏目出现，反向回归。
        let banned = ["时间", "位置", "选项", "当前所在地", "好感"]
        for word in banned {
            XCTAssertFalse(t.contains(word), "空 statData 不应出现『\(word)』固定栏目")
        }
    }

    /// StatusPlaceHolderImpl 与 UpdateVariable 紧邻 → 两个结构化节点，顺序保留。
    func testStatusPlaceholderAdjacentToUpdateVariable() {
        let content =
            "<StatusPlaceHolderImpl/><UpdateVariable>[{\"op\":\"replace\",\"path\":\"/时间\",\"value\":\"傍晚\"}]</UpdateVariable>"
        let store = SessionStore()
        store.seed(["时间": .string("清晨")])
        let tree = RenderNodeParser.parse(
            content,
            statData: { store.statData() },
            applyPatches: { ops in try store.apply(ops) }
        )
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

    // MARK: - 跳过规则：HTML beautify

    /// `replacement` 含 `<script / .load(` / `<object` / `<iframe` / `<details` / `<style` / `<div` →
    /// `MessageRendererCore.isHtmlBeautify` 判定为 true → `orderedRegexes` 过滤。
    func testHtmlBeautifyReplacementIsSkipped() {
        let beautifyReplacements = [
            "<div class='x'><style>.x{}</style></div>",
            "<details class='x'><summary>x</summary><div class='y'></div></details>",
            "<script src='x' onload=\"$('body').load('https://x');\"></script>",
            "<object data='https://x'></object>",
            "<iframe src='https://x'></iframe>"
        ]
        for replacement in beautifyReplacements {
            XCTAssertTrue(
                MessageRendererCore.isHtmlBeautify(replacement: replacement),
                "应识别 beautify replacement: \(replacement)"
            )
        }
    }

    /// 非 beautify replacement（纯文本 / 简单占位符）→ 不被识别为 beautify。
    func testPlainReplacementIsNotBeautify() {
        XCTAssertFalse(MessageRendererCore.isHtmlBeautify(replacement: ""))
        XCTAssertFalse(MessageRendererCore.isHtmlBeautify(replacement: "prefix"))
        XCTAssertFalse(MessageRendererCore.isHtmlBeautify(replacement: "$1"))
    }

    /// `touchesNativeTranspile` 兜底：含 `StatusPlaceHolderImpl` / `UpdateVariable` 的 pattern
    /// → 即便 `promptOnly` 字段缺失（默认 false），也不进显示链。
    func testTouchesNativeTranspileFiltersRegardlessOfPromptOnly() {
        let legacyPlaceholderRule = DisplayRegex(
            name: "legacy-status-placeholder",
            pattern: "<StatusPlaceHolderImpl\\s*/?>",
            replacement: "",
            enabled: true
            // promptOnly 缺省 = false —— 模拟旧版本导入的存量规则
        )
        let legacyUpdateRule = DisplayRegex(
            name: "legacy-update-variable",
            pattern: "<UpdateVariable\\b[^>]*>[\\s\\S]*?</UpdateVariable>",
            replacement: "",
            enabled: true
        )
        let safeRule = DisplayRegex(
            name: "safe",
            pattern: "x",
            replacement: "y",
            enabled: true
        )
        let ordered = MessageRendererCore.orderedRegexes(
            presetDisplayRegexIds: [],
            all: [legacyPlaceholderRule, legacyUpdateRule, safeRule]
        )
        XCTAssertEqual(ordered.map(\.name), ["safe"],
                       "命中 native transpile token 的规则一律不进显示链")
    }

    // MARK: - 跳过规则：promptOnly

    /// `promptOnly == true` → 即便 token 不在跳过列表里，也不进显示链。
    func testPromptOnlyFilteredFromDisplayChain() {
        let promptOnlyRule = DisplayRegex(
            name: "prompt-only",
            pattern: "<UpdateVariable\\b[^>]*>[\\s\\S]*?</UpdateVariable>",
            replacement: "",
            enabled: true,
            promptOnly: true
        )
        let ordered = MessageRendererCore.orderedRegexes(
            presetDisplayRegexIds: [],
            all: [promptOnlyRule]
        )
        XCTAssertTrue(ordered.isEmpty, "promptOnly 规则不应进入显示链")
    }

    /// `orderedRegexes` 同时应用 beautify / promptOnly / disabled / touchesNativeTranspile 四道过滤。
    func testOrderedRegexesAppliesAllFilters() {
        let beautifyRule = DisplayRegex(
            name: "beautify", pattern: "x", replacement: "<div>x</div>", enabled: true
        )
        let promptOnlyRule = DisplayRegex(
            name: "promptOnly", pattern: "y", replacement: "z", enabled: true, promptOnly: true
        )
        let disabledRule = DisplayRegex(
            name: "disabled", pattern: "q", replacement: "r", enabled: false
        )
        let transpileRule = DisplayRegex(
            name: "transpile", pattern: "<UpdateVariable>.*?</UpdateVariable>", replacement: "", enabled: true
        )
        let safeRule = DisplayRegex(
            name: "safe", pattern: "a", replacement: "b", enabled: true
        )
        let ordered = MessageRendererCore.orderedRegexes(
            presetDisplayRegexIds: [],
            all: [beautifyRule, promptOnlyRule, disabledRule, transpileRule, safeRule]
        )
        XCTAssertEqual(ordered.map(\.name), ["safe"])
    }

    // MARK: - message.content 永不被改写

    /// RenderNodeParser 只读；调用前后原文长度 + 关键标签都保持。
    func testRawMessageContentNeverMutated() {
        let content =
            "<StatusPlaceHolderImpl/>hi <UpdateVariable>[{\"op\":\"replace\",\"path\":\"/时间\",\"value\":\"傍晚\"}]</UpdateVariable> bye"
        let store = SessionStore()
        let original = content
        _ = RenderNodeParser.parse(
            content,
            statData: { store.statData() },
            applyPatches: { ops in try store.apply(ops) }
        )
        XCTAssertEqual(content, original, "原文必须完全不变")
        XCTAssertTrue(content.contains("<StatusPlaceHolderImpl/>"))
        XCTAssertTrue(content.contains("<UpdateVariable>"))
        XCTAssertTrue(content.contains("</UpdateVariable>"))
    }

    // MARK: - 测试用最小 store stub

    /// 与生产 `VariableStore`（数据层）等价的最小 stub：seed merge + JSON Patch apply + snapshot 拍扁。
    /// 不依赖 SwiftUI / UserDefaults，让 Linux SPM 测试可驱动。
    private final class SessionStore {
        private var root: JSONValue = .object([:])

        /// 与生产 `VariableStore.seedIfEmpty` 等价：merge 进现有 root，不覆盖已存在的 key。
        func seed(_ data: [String: JSONValue]) {
            mergeSeed(data, into: &root)
        }

        /// 把 `[JSONPatchOperation]` 应用到 root，返回 applied 计数；`_` 路径静默 skip 但计入计数。
        func apply(_ ops: [JSONPatchOperation]) throws -> Int {
            try JSONPatchApplier.apply(ops, to: &root)
        }

        /// 把 root 拍扁成 `[VariableEntry]`（按 JSON Pointer path，仅供旧断言使用）。
        func snapshot() -> [VariableEntry] {
            VariableStoreFlattener.snapshot(root: root)
        }

        /// 返回整棵 `JSONValue` 树（按当前根），用于新版 `parse(statData:)` 路径。
        /// 树就是变量树本身——不预置任何"时间/位置/选项"等固定栏目。
        func statData() -> JSONValue { root }

        private func mergeSeed(_ data: [String: JSONValue], into root: inout JSONValue) {
            guard case .object(var current) = root else {
                root = .object(data)
                return
            }
            for (key, value) in data {
                mergeValue(value, into: &current, key: key)
            }
            root = .object(current)
        }

        private func mergeValue(_ value: JSONValue, into dict: inout [String: JSONValue], key: String) {
            // 已存在 object + 新值也是 object → 递归 merge；否则不覆盖。
            if case .object(let existing) = dict[key], case .object(let incoming) = value {
                var merged = existing
                for (k, v) in incoming {
                    mergeValue(v, into: &merged, key: k)
                }
                dict[key] = .object(merged)
                return
            }
            if dict[key] == nil {
                dict[key] = value
            }
        }
    }
}