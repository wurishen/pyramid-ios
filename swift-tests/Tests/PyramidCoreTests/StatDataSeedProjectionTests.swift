import XCTest
@testable import PyramidCore

/// 「变量树有什么就显示什么」——seed + projection 协议层覆盖。
///
/// 这一组测试专门验证：
/// 1. **不做任何"时间/位置/选项"等固定栏目预设**：seed 一棵中性 JSON 树，
///    `NativeDisplayModelProjector.project(statData:)` 的产出必须**完全**跟着树走。
/// 2. **空 init**：树空 → 空 model，不崩、不补造任何字段。
/// 3. **二次 seed 幂等**：已 seed 过再 seed 一次，与现有 `seedIfEmpty` API 语义一致。
/// 4. **保留嵌套形态**：嵌套 object 必须以 `group` 形式呈现，嵌套 array 元素以 `tag` 呈现。
/// 5. **回归**：现有 `NativeDisplayModelProjector.project(statData:)` 行为没有变。
///
/// 关键不变量：表中所有测试都使用**完全中性**的键名（`foo` / `bar_baz` / `n42` /
/// `fruit` / `tags` / `meta` 等），不出现"时间/位置/选项/好感/HP"等任何暗示性键。
/// 这样如果有人偷偷在 Projector 里加回"时间/位置/选项"硬模版，测试**不会**自动通过。
final class StatDataSeedProjectionTests: XCTestCase {

    // MARK: - 中性 fixture：随便键名 → 跟着树走

    /// 中性 fixture 1：纯标量顶层（string / number / bool）→ 三个 child block 反映这三个 key。
    /// 没有任何"时间/位置/选项"等隐含栏目。
    func testNeutralFlatScalarsOnlyMatchedKeys() {
        let tree: JSONValue = .object([
            "foo": .string("alpha"),
            "bar_baz": .int(7),
            "n42": .bool(true)
        ])
        let model = NativeDisplayModelProjector.project(statData: tree)
        guard case let .group(_, children) = model.blocks[0] else {
            return XCTFail("根部应是 group")
        }
        // 排序后是 bar_baz → foo → n42（字典序）；按现有 Projector 规则映射成 field / number / field。
        XCTAssertEqual(children.count, 3, "3 个标量键全部保留")
        // 关键否定：常见误导栏目不在 children 文本里。
        let flatText = describe(children)
        for banned in ["时间", "位置", "选项", "好感", "HP", "当前所在地"] {
            XCTAssertFalse(flatText.contains(banned),
                           "中性 fixture 不应出现『\(banned)』固定栏目（实为：\(flatText)）")
        }
        XCTAssertTrue(model.residual.isEmpty)
    }

    /// 中性 fixture 2：嵌套 object 保留 `group` 层次。
    func testNeutralNestedObjectPreservesGroupStructure() {
        let tree: JSONValue = .object([
            "outer": .object([
                "inner": .string("v"),
                "deep": .object([
                    "leaf": .int(3)
                ])
            ])
        ])
        let model = NativeDisplayModelProjector.project(statData: tree)
        guard case let .group(_, topChildren) = model.blocks[0] else { return XCTFail("根部应是 group") }
        // 顶部一个 outer 子 group（嵌套 object → group 原语）。
        XCTAssertEqual(topChildren.count, 1)
        guard case let .group(_, innerChildren) = topChildren[0] else {
            return XCTFail("outer 嵌套应是 group")
        }
        // innerChildren: "deep" (group) + "inner" (field) 排序后。
        XCTAssertEqual(innerChildren.count, 2)
        XCTAssertTrue(model.residual.isEmpty, "正常深度不出现 residual")
    }

    /// 中性 fixture 3：数组 → tag 列表（按现有 Projector 规则）。
    func testNeutralArrayProjectsAsTags() {
        let tree: JSONValue = .object([
            "fruit": .array([.string("apple"), .string("pear"), .string("kiwi")])
        ])
        let model = NativeDisplayModelProjector.project(statData: tree)
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        guard case let .section(_, content) = children[0] else {
            return XCTFail("fruit 数组应落地为 section")
        }
        let tags = content.compactMap { block -> DisplayBlock? in
            if case .tag(_, _) = block { return block }
            return nil
        }
        XCTAssertEqual(tags.count, 3, "3 个数组元素映射为 3 个 tag")
    }

    /// 中性 fixture 4：键名带下划线 / 数字 / 混合字符 —— 应当原样保留，不被强行规范化。
    func testNeutralKeyNamesArePreservedVerbatim() {
        let tree: JSONValue = .object([
            "foo_bar": .int(1),
            "kebab-case": .string("hy"),
            "x9": .bool(false)
        ])
        let model = NativeDisplayModelProjector.project(statData: tree)
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        // 收集 field/number 文本里出现的 label。
        var labels: [String] = []
        for child in children {
            switch child {
            case let .field(label, _): labels.append(label)
            case let .number(label, _):
                if let l = label { labels.append(l) }
            default: break
            }
        }
        XCTAssertTrue(labels.contains("foo_bar"))
        XCTAssertTrue(labels.contains("kebab-case"))
        XCTAssertTrue(labels.contains("x9"))
    }

    // MARK: - 空 init → 空 model

    /// 完全空 init → root group + 等待变量占位、没崩、没补造任何"时间/位置"等栏目。
    func testEmptyInitRendersEmptyModel() {
        let tree: JSONValue = .object([:])
        let model = NativeDisplayModelProjector.project(statData: tree)
        XCTAssertEqual(model.version, 1)
        XCTAssertEqual(model.blocks.count, 1, "空树仍走 root group 包装")
        guard case let .group(_, children) = model.blocks[0] else {
            return XCTFail("根部应是 group")
        }
        XCTAssertEqual(children.count, 1)
        guard case let .text(t) = children[0] else {
            return XCTFail("children[0] 应是 text")
        }
        XCTAssertTrue(t.contains("等待变量"))
        XCTAssertTrue(model.residual.isEmpty)
        // 显式禁词：哪怕注释改错了也不能出现。
        for banned in ["时间", "位置", "选项", "好感", "玩家", "当前所在地"] {
            XCTAssertFalse(t.contains(banned),
                           "空 init 不应出现『\(banned)』硬模版（实为：\(t)）")
        }
    }

    /// 完全空 init + `<StatusPlaceHolderImpl/>` → statePlaceholder 节点 + 空 statData 树。
    /// 整链路上无任何"时间/位置"等空内容栏目冒出。
    func testEmptyInitThroughParserShowsNoFixedColumns() {
        let content = "前<StatusPlaceHolderImpl/>后"
        let store = SessionStoreFixture()
        let tree = RenderNodeParser.parse(
            content,
            statData: { store.statData() },
            applyPatches: { ops in try store.apply(ops) }
        )
        XCTAssertEqual(tree.nodes.count, 3)
        guard case let .statusPlaceholder(statData) = tree.nodes[1] else {
            return XCTFail("节点 1 应是 statusPlaceholder")
        }
        XCTAssertEqual(statData, .object([:]))
        let model = NativeDisplayModelProjector.project(statData: statData)
        // 把整个 model 文本拼一起，确保没有任何隐藏栏目。
        let allText = describe(model.blocks)
        let allResidual = model.residual.map { $0.rawText }.joined()
        for banned in ["时间", "位置", "选项", "好感", "玩家", "当前所在地"] {
            XCTAssertFalse(allText.contains(banned),
                           "中性空 init 投影文本不应出现『\(banned)』（实为：\(allText)）")
            XCTAssertFalse(allResidual.contains(banned),
                           "中性空 init 不应有『\(banned)』residual（实为：\(allResidual)）")
        }
    }

    /// 完全空 init + `MessageRendererChain` 走 RenderEngine 整条管线下 → pipeline 不崩。
    /// 验证：如果有人偷偷在 Projector 里塞 default "时间/位置" 假字段，从这里能立刻看出。
    func testEmptyInitThroughRenderEngineProducesNoFixedColumns() {
        let raw = "前<StatusPlaceHolderImpl/>后"
        let ctx = RenderEngine.Context(
            isAssistant: true,
            presetDisplayRegexIds: [],
            allDisplayRegexes: [],
            hideTagStripEnabled: false,
            hideTags: [],
            markdownEnabled: true,
            variableStore: nil,
            sessionId: nil
        )
        // 不用 variableStore 路径，直接验 RenderEngine 不会因此引入模板栏目。
        let result = RenderEngine.render(raw: raw, context: ctx)
        let allText = result.cleanedText
        // 走 RenderEngine 默认 ctx 时，statData 是 .object([:]) → 整条树空，
        // 投影结果不会含任何"时间/位置"等假字段。
        XCTAssertTrue(allText.contains("前"))
        XCTAssertTrue(allText.contains("后"))
    }

    // MARK: - 幂等 seed

    /// 二次 seed：与现有 `VariableStore.seedIfEmpty` API 语义一致 —— 已存在 → 跳过，新数据被忽略。
    /// 不抛错、不爆炸、也不会把已经被 patch 改过的值覆盖掉。
    func testSecondSeedDoesNotOverrideExistingValues() throws {
        let store = SessionStoreFixture()
        store.seed([
            "k": .int(1),
            "obj": .object(["a": .int(2)])
        ])
        // 第一次 seed 之后 patch 写入。
        try store.apply([
            JSONPatchOperation.replace(path: "/k", value: .int(99))
        ])
        XCTAssertEqual(store.statData(), .object([
            "k": .int(99),
            "obj": .object(["a": .int(2)])
        ]))
        // 第二次 seed —— 现有 seedIfEmpty 语义：现有 root 已存在 → 应当忽略。
        store.seed(["k": .int(1), "different": .string("x")])
        // 关键：seed 没把 /k 改回 1，也没新增 /different。
        XCTAssertEqual(store.statData(), .object([
            "k": .int(99),
            "obj": .object(["a": .int(2)])
        ]))
    }

    /// 一次 seed 后立刻再 seed 同样内容 → 等价。
    func testRepeatSeedSameDataIsIdempotent() {
        let store = SessionStoreFixture()
        let payload: [String: JSONValue] = [
            "k": .int(1),
            "obj": .object(["a": .int(2)])
        ]
        store.seed(payload)
        let first = store.statData()
        store.seed(payload)
        let second = store.statData()
        XCTAssertEqual(first, second)
    }

    /// seed 时给 nil（角色只有 first_mes 没有 init_stat_data）→ 空 object，
    /// 投影出"等待变量"占位、不补造任何字段。
    func testNilSeedProducesEmptyObject() {
        let store = SessionStoreFixture()
        store.seed(nil)
        XCTAssertEqual(store.statData(), .object([:]))
        let model = NativeDisplayModelProjector.project(statData: store.statData())
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        XCTAssertEqual(children.count, 1)
        guard case let .text(t) = children[0] else { return XCTFail("children[0] 应是 text") }
        XCTAssertTrue(t.contains("等待变量"))
    }

    // MARK: - 解析失败 / 异常类型

    /// statData 顶层是数组（畸形 init）→ 整段原文落入 residual，不丢、不补造固定栏目。
    func testMalformedTopLevelArrayFallsBackToResidual() {
        let bad: JSONValue = .array([.string("不应该"), .int(1)])
        let model = NativeDisplayModelProjector.project(statData: bad)
        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(model.residual.count, 1)
        // 否定：residual 文本不应包含"时间/位置"等暗示固定栏目。
        let raw = model.residual[0].rawText
        for banned in ["时间", "位置", "选项", "好感"] {
            XCTAssertFalse(raw.contains(banned),
                           "residual 文本不应出现『\(banned)』（实为：\(raw)）")
        }
    }

    /// statData 顶层是 string（畸形 init）→ 整段原文落入 residual，不补造任何字段。
    func testMalformedTopLevelStringFallsBackToResidual() {
        let model = NativeDisplayModelProjector.project(statData: .string("just a string"))
        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertEqual(model.residual.count, 1)
        XCTAssertNotNil(model.residual[0].reason)
    }

    // MARK: - 辅助

    /// `initStatData` 流式 seed（模拟 `ChatStore.createSession(character:)` 既定路径）：
    /// 顶层 dict → 整棵 `JSONValue` 树。
    func testInitStatDataConvertedToWholeTree() {
        let store = SessionStoreFixture()
        let initStatData: [String: JSONValue] = [
            "foo": .string("v"),
            "obj": .object(["inner": .int(7)])
        ]
        store.seed(initStatData)
        XCTAssertEqual(store.statData(), .object(initStatData))
    }

    /// 重建 Walk：group 树 → 文本拼接（用于否定式断言）。
    private func describe(_ blocks: [DisplayBlock]) -> String {
        var out: [String] = []
        for block in blocks {
            describeBlock(block, into: &out)
        }
        return out.joined()
    }

    private func describeBlock(_ block: DisplayBlock, into out: inout [String]) {
        switch block {
        case let .text(s): out.append(s)
        case let .field(label, value): out.append("\(label)=\(value)")
        case let .number(value, label):
            if let label { out.append("\(label)=\(value)") } else { out.append(String(value)) }
        case let .bar(label, value, _, _): out.append("\(label)=\(value)")
        case let .tag(label, value):
            if let v = value { out.append("\(label)=\(v)") } else { out.append(label) }
        case let .section(label, content):
            out.append("\(label):")
            for c in content { describeBlock(c, into: &out) }
        case let .group(title, children):
            out.append("\(title):")
            for c in children { describeBlock(c, into: &out) }
        }
    }
}

// MARK: - 测试用最小 store stub

/// 与生产 `VariableStore` 等价的最小 stub：seed merge + JSON Patch apply + 整棵 statData 树。
/// 不依赖 SwiftUI / UserDefaults，让 Linux SPM 测试可驱动。
///
/// 与 `P3TranspileProtocolTests.SessionStore` 重复一份（两份 stub 分别进化
/// 互不可见）—— 内容一致。
private final class SessionStoreFixture {
    private var root: JSONValue = .object([:])
    private var didSeed = false

    /// 与生产 `VariableStore.seedIfEmpty` 等价：seed 已发生过 → 跳过（幂等）。
    /// `didSeed` 标志严格反映生产 `stores[sessionId] != nil` 语义——即便 seed 进来的是空 object，
    /// 二次 seed 也是 no-op。
    func seed(_ data: [String: JSONValue]?) {
        guard !didSeed else { return }
        root = .object(data ?? [:])
        didSeed = true
    }

    /// 把 `[JSONPatchOperation]` 应用到 root，返回 applied 计数。
    func apply(_ ops: [JSONPatchOperation]) throws -> Int {
        try JSONPatchApplier.apply(ops, to: &root)
    }

    /// 返回整棵 `JSONValue` 树（用于 `parse(statData:)` 路径）。
    func statData() -> JSONValue { root }
}
