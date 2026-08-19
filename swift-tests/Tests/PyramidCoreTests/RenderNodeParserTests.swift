import XCTest
@testable import PyramidCore

/// RenderNodeParser 12 个测试：覆盖 status 识别、HP/好感度解析、普通文本保持、
/// 非法块降级、同一 Raw Message 可重渲染不同树等。
final class RenderNodeParserTests: XCTestCase {

    // MARK: - 普通文本

    // 1. 普通文本没有 <status> 块 → 单个 .text 节点
    func test1_plainTextSingleNode() {
        let tree = RenderNodeParser.parse("Hello World")
        XCTAssertEqual(tree.nodes.count, 1)
        XCTAssertEqual(tree.nodes[0], .text("Hello World"))
    }

    // 2. 空字符串 → 单个 .text("") 节点
    func test2_emptyStringSingleText() {
        let tree = RenderNodeParser.parse("")
        XCTAssertEqual(tree.nodes.count, 1)
        XCTAssertEqual(tree.nodes[0], .text(""))
    }

    // 3. 多行普通文本（无 status 块）→ 单个 .text 节点
    func test3_multilinePlainText() {
        let input = "Line 1\nLine 2\n\nLine 4"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        XCTAssertEqual(tree.nodes[0], .text(input))
    }

    // MARK: - status 块识别

    // 4. 单个 <status> 块 → 单个 .status 节点
    func test4_singleStatusBlock() {
        let input = "<status>\nHP: 80\n好感度: 65\n</status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        XCTAssertEqual(tree.nodes[0], .status(hp: 80, affection: 65))
    }

    // 5. status 块前后有文本 → 3 个节点（text + status + text）
    func test5_statusWithSurroundingText() {
        let input = "你推开酒馆的木门。\n\n<status>\nHP: 80\n好感度: 65\n</status>\n\n老板抬头看了你一眼。"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 3)
        if case let .text(s) = tree.nodes[0] {
            XCTAssertTrue(s.hasPrefix("你推开酒馆"))
        } else { XCTFail("node 0 应为 .text") }
        XCTAssertEqual(tree.nodes[1], .status(hp: 80, affection: 65))
        if case let .text(s) = tree.nodes[2] {
            XCTAssertTrue(s.hasPrefix("老板抬头"))
        } else { XCTFail("node 2 应为 .text") }
    }

    // 6. 多个 status 块 → 交替节点
    func test6_multipleStatusBlocks() {
        let input = "<status>HP: 80\n好感度: 65</status> -- mid -- <status>HP: 50\n好感度: 30</status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 3)
        XCTAssertEqual(tree.nodes[0], .status(hp: 80, affection: 65))
        if case let .text(s) = tree.nodes[1] { XCTAssertTrue(s.contains("mid")) } else { XCTFail("node 1 应为 .text") }
        XCTAssertEqual(tree.nodes[2], .status(hp: 50, affection: 30))
    }

    // 7. status 标签允许带属性（不强制要求严格匹配）
    func test7_statusTagWithAttributes() {
        let input = "<status class=\"x\">\nHP: 100\n好感度: 0\n</status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        XCTAssertEqual(tree.nodes[0], .status(hp: 100, affection: 0))
    }

    // 8. 中文冒号 ":" 也能解析（兼容模型可能用全角冒号）
    func test8_statusWithFullWidthColon() {
        let input = "<status>HP：80\n好感度：65</status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        XCTAssertEqual(tree.nodes[0], .status(hp: 80, affection: 65))
    }

    // 9. status 块内多余空白行（空行 / 缩进）不影响解析
    func test9_statusWithBlankLinesAndIndent() {
        let input = "<status>\n   HP: 42  \n\n  好感度: 7  \n</status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        XCTAssertEqual(tree.nodes[0], .status(hp: 42, affection: 7))
    }

    // 10. status 块内额外的未知字段行被忽略（不影响 HP/好感度）
    func test10_statusExtraLinesIgnored() {
        let input = "<status>\nHP: 80\n好感度: 65\n金币: 100\n</status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        XCTAssertEqual(tree.nodes[0], .status(hp: 80, affection: 65))
    }

    // MARK: - 容错降级

    // 11. status 块内 HP 缺失 → 整块降级为 .text（不能消失）
    func test11_statusMissingHPFallbackToText() {
        let input = "<status>\n好感度: 65\n</status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        if case .text = tree.nodes[0] {
            // ok
        } else { XCTFail("HP 缺失应降级为 .text，实际：\(tree.nodes[0])") }
    }

    // 12. status 块内 好感度 缺失 → 整块降级为 .text
    func test12_statusMissingAffectionFallbackToText() {
        let input = "<status>\nHP: 80\n</status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        if case .text = tree.nodes[0] {
            // ok
        } else { XCTFail("好感度 缺失应降级为 .text，实际：\(tree.nodes[0])") }
    }

    // 13. status 块内 HP 不是整数 → 整块降级为 .text
    func test13_statusHPNotIntegerFallbackToText() {
        let input = "<status>\nHP: 全满\n好感度: 65\n</status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        if case .text = tree.nodes[0] {
            // ok
        } else { XCTFail("HP 非整数应降级为 .text，实际：\(tree.nodes[0])") }
    }

    // 14. status 块为空（<status></status>）→ 降级为 .text
    func test14_statusEmptyBlockFallbackToText() {
        let input = "<status></status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        if case .text = tree.nodes[0] {
            // ok
        } else { XCTFail("空 status 块应降级为 .text，实际：\(tree.nodes[0])") }
    }

    // 15. 半成品 status（只开不关）→ 整段 input 作为 .text（不丢失）
    func test15_unclosedStatusFallbackToText() {
        let input = "before <status>\nHP: 80\n好感度: 65\n(no close tag)"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        if case let .text(s) = tree.nodes[0] {
            XCTAssertEqual(s, input, "整段 input 应原样作为 .text，不能消失")
        } else { XCTFail("未闭合的 status 应降级为 .text，实际：\(tree.nodes[0])") }
    }

    // 16. 嵌套 status（酒馆实际可能写错）→ 外层解析，内层被吞或原样
    //     测试只要求不崩溃、不消失
    func test16_nestedStatusDoesNotCrash() {
        let input = "<status>HP: 80\n<status>好感度: 65</status>\n</status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertFalse(tree.nodes.isEmpty, "嵌套 status 也必须返回非空 RenderTree")
    }

    // MARK: - raw 不变性 + 多次重渲染

    // 17. 解析不修改入参（raw 是 string by value，本来就不会；但显式验证）
    func test17_inputUnchangedAfterParse() {
        let input: String = "Hello <status>HP: 80\n好感度: 65</status> World"
        let snapshot = input
        _ = RenderNodeParser.parse(input)
        XCTAssertEqual(input, snapshot)
    }

    // 18. 同一 Raw Message 多次 parse → 相同 RenderTree（无副作用 / 无缓存）
    func test18_idempotent() {
        let input = "before\n<status>\nHP: 80\n好感度: 65\n</status>\nafter"
        let t1 = RenderNodeParser.parse(input)
        let t2 = RenderNodeParser.parse(input)
        let t3 = RenderNodeParser.parse(input)
        XCTAssertEqual(t1, t2)
        XCTAssertEqual(t2, t3)
    }

    // 19. RenderNode 是 Equatable（用于 SwiftUI diff）
    func test19_renderNodeEquatable() {
        XCTAssertEqual(RenderNode.text("a"), RenderNode.text("a"))
        XCTAssertNotEqual(RenderNode.text("a"), RenderNode.text("b"))
        XCTAssertEqual(RenderNode.status(hp: 1, affection: 2), RenderNode.status(hp: 1, affection: 2))
        XCTAssertNotEqual(RenderNode.status(hp: 1, affection: 2), RenderNode.status(hp: 3, affection: 4))
    }

    // MARK: - 端到端：RenderEngine 集成

    // 20. RenderEngine.render 把 status 块解析进 tree（不是 cleanedText 拼接）
    func test20_renderEngineProducesTree() {
        let raw = "intro\n<status>\nHP: 80\n好感度: 65\n</status>\noutro"
        let ctx = RenderEngine.Context(
            isAssistant: true,
            presetDisplayRegexIds: [],
            allDisplayRegexes: [],
            hideTagStripEnabled: false,
            hideTags: [],
            markdownEnabled: true
        )
        let result = RenderEngine.render(raw: raw, context: ctx)
        // cleanedText（向后兼容 getter）只拼接 .text 节点 → 不含 status 标签
        XCTAssertFalse(result.cleanedText.contains("<status>"))
        XCTAssertTrue(result.cleanedText.contains("intro"))
        XCTAssertTrue(result.cleanedText.contains("outro"))
        // tree 中间是 .status 节点
        XCTAssertTrue(result.tree.nodes.contains(.status(hp: 80, affection: 65)))
    }

    // 21. 同 raw + 不同 context (markdownEnabled) → tree 内容相同（status 与 markdown 无关）
    func test21_contextChangeDoesNotAffectStatusNodes() {
        let raw = "<status>\nHP: 80\n好感度: 65\n</status>"
        let ctxM = RenderEngine.Context(
            isAssistant: true, presetDisplayRegexIds: [], allDisplayRegexes: [],
            hideTagStripEnabled: false, hideTags: [], markdownEnabled: true
        )
        let ctxNoM = RenderEngine.Context(
            isAssistant: true, presetDisplayRegexIds: [], allDisplayRegexes: [],
            hideTagStripEnabled: false, hideTags: [], markdownEnabled: false
        )
        let a = RenderEngine.render(raw: raw, context: ctxM)
        let b = RenderEngine.render(raw: raw, context: ctxNoM)
        XCTAssertEqual(a.tree, b.tree, "markdownEnabled 不应影响 tree 结构")
        XCTAssertNotEqual(a.markdownEnabled, b.markdownEnabled)
    }
}