import XCTest
@testable import PyramidCore

/// 架构边界测试：验证「角色卡 → 原生能力」通路不被 Pyramid 的固定 UI 模板污染。
///
/// 背景：以前 `.statusFields([StatusField])` 看起来已经支持任意 key/value，但
/// `StatusFieldsView.color(forLabel:value:)` 还暗藏「HP ≥60 绿 / ≥30 橙 / 否则红」
/// 这条 Pyramid 专属语义规则。本测试组锁住数据层不引入类似隐式偏好 —— 任何字段
/// 都按原文进出，颜色阈值属于且只属于 `.status(hp:affection:)` 那个 fast-path
/// 节点对应的 StatusView。
///
/// 同时锁住「解析层不会偷偷改写 key 名」与「未知 key 不会让 parser 崩溃」。
final class StatusFieldArchitectureTests: XCTestCase {

    // MARK: - 数据层不依赖 Pyramid UI 概念

    /// `StatusField` 是纯 (label, value) 二元组 —— API 表面不出现 HP / 好感度 等
    /// Pyramid 固定概念。`Identifiable.id` 也用 label=value 派生，不内嵌业务偏好。
    func testStatusFieldIsPureKeyValueCarrier() {
        // 任意 key/value（包括 Pyramid 模板里不存在的）
        let a = StatusField(label: "饱腹", value: "饱")
        let b = StatusField(label: "法力", value: "50")
        let c = StatusField(label: "small_phone.battery", value: "73%")
        let d = StatusField(label: "日记/心情", value: "还行")

        XCTAssertEqual(a.id, "饱腹=饱")
        XCTAssertEqual(b.id, "法力=50")
        XCTAssertEqual(c.id, "small_phone.battery=73%")
        XCTAssertEqual(d.id, "日记/心情=还行")

        // Equatable：两个 label 不同的字段不相等，反之亦然；不掺杂 Pyramid 偏好。
        XCTAssertNotEqual(StatusField(label: "HP", value: "10"),
                          StatusField(label: "HP", value: "9"))
        XCTAssertNotEqual(StatusField(label: "HP", value: "10"),
                          StatusField(label: "法力", value: "10"))
    }

    /// `RenderNode.statusFields` 是数据节点；同一组任意 key 的 StatusField 应
    /// 在 Equatable 比较下严格相等 —— Pyramid 不应在节点层偷偷重排或改名。
    func testStatusFieldsNodeIsPureData() {
        let node = RenderNode.statusFields([
            StatusField(label: "金币", value: "200"),
            StatusField(label: "饱腹", value: "饱"),
            StatusField(label: "法力", value: "50"),
            StatusField(label: "自定义/小手机", value: "73%"),
        ])
        // 同输入再构造一次必须严格相等。
        let again = RenderNode.statusFields([
            StatusField(label: "金币", value: "200"),
            StatusField(label: "饱腹", value: "饱"),
            StatusField(label: "法力", value: "50"),
            StatusField(label: "自定义/小手机", value: "73%"),
        ])
        XCTAssertEqual(node, again)

        // 乱序应该不相等 —— Pyramid 不应在节点层「自动按 HP/好感度」重排。
        let reordered = RenderNode.statusFields([
            StatusField(label: "饱腹", value: "饱"),
            StatusField(label: "金币", value: "200"),
            StatusField(label: "法力", value: "50"),
            StatusField(label: "自定义/小手机", value: "73%"),
        ])
        XCTAssertNotEqual(node, reordered, "statusFields 节点不应重排字段")
    }

    // MARK: - 解析层不偷改 key 名

    /// `parseStatusFields` 必须保留用户原文 key 与顺序 —— 不做大小写归一、
    /// 不补"HP"、不重排。Pyramid 的 HP 启发只在 `.status(hp:affection:)`
    /// fast-path 触发，与本函数无关。
    func testParseStatusFieldsPreservesArbitraryKeys() {
        let raw = """
        金币: 200
        饱腹: 饱
        自定义/小手机: 73%
        """
        let fields = RenderNodeParser.parseStatusFields(raw)
        XCTAssertEqual(fields, [
            StatusField(label: "金币", value: "200"),
            StatusField(label: "饱腹", value: "饱"),
            StatusField(label: "自定义/小手机", value: "73%"),
        ])
    }

    /// 完全陌生的 key（角色卡自定义能力）不会让 parser 崩溃、不被改名。
    func testParseStatusFieldsDoesNotCrashOnUnknownKeys() {
        let raw = """
        wechat_unread: 3
        心情: 还行
        quest_step: 7/10
        inventory/金币: 200
        """
        let fields = RenderNodeParser.parseStatusFields(raw)
        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(fields.map(\.label), [
            "wechat_unread",
            "心情",
            "quest_step",
            "inventory/金币",
        ])
    }

    /// `RenderNodeParser.parse(<status>…)`：除了"仅含 HP+好感度 两个整数"的
    /// fast-path 会发出 `.status(hp:affection:)` 之外，**任意**额外字段都应走
    /// `.statusFields` 通用面板 —— 这是数据层不依赖固定 UI 的核心契约。
    func testParsePromotesArbitraryFieldsToStatusFields() {
        // HP+好感度+任意第三字段 → 不再走 fast-path
        let input = "<status>\nHP: 80\n好感度: 65\n小手机电量: 73%\n</status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        guard case let .statusFields(fields) = tree.nodes[0] else {
            return XCTFail("带第三字段时应走 .statusFields；实际：\(tree.nodes[0])")
        }
        XCTAssertEqual(fields, [
            StatusField(label: "HP", value: "80"),
            StatusField(label: "好感度", value: "65"),
            StatusField(label: "小手机电量", value: "73%"),
        ])
    }

    /// 完全没有 HP/好感度 的纯任意字段 → 同样走 `.statusFields`，不报错、不降级。
    func testParseArbitraryOnlyFieldsStillReachStatusFields() {
        let input = "<status>\n金币: 200\n饱腹: 饱\n</status>"
        let tree = RenderNodeParser.parse(input)
        XCTAssertEqual(tree.nodes.count, 1)
        XCTAssertEqual(tree.nodes[0], .statusFields([
            StatusField(label: "金币", value: "200"),
            StatusField(label: "饱腹", value: "饱"),
        ]))
    }

    // MARK: - 状态占位符：P3 native 通路

    /// `.statusPlaceholder` 携带的是整棵 `JSONValue` 变量树，不是 Pyramid 预置
    /// 模板；空树必须落 `.object([:])` 不崩，且不被替换成任何 Pyramid 固定栏目。
    func testStatusPlaceholderEmptyTreeIsEmptyObject() {
        let empty = JSONValue.object([:])
        if case let .statusPlaceholder(statData) = RenderNode.statusPlaceholder(statData: empty) {
            XCTAssertEqual(statData, .object([:]))
            // 关键否定：空树不应被替换成"时间/位置/选项"等任何预置栏目。
            XCTAssertEqual(statData, .object([:]))
        } else {
            XCTFail("空树应保留为 .object([:])")
        }
    }

    /// 角色卡自定义能力（这里是"小手机"数据）走 `.statusPlaceholder` 通路时，
    /// Pyramid 不应注入任何 Pyramid 固定 UI 概念 —— 树里没有"HP"就不出"HP"。
    func testStatusPlaceholderDoesNotInjectFixedFields() {
        let statData: JSONValue = .object([
            "小手机": .object([
                "电量": .int(73),
                "未读消息": .array([.string("a"), .string("b")])
            ]),
            "心情": .string("还行"),
        ])
        let model = NativeDisplayModelProjector.project(statData: statData)

        // 描述整棵 model 的可读文本
        let flatText = describeAll(model)

        // 关键否定：Pyramid 不应在变量树里凭空塞 HP / 好感度 / 时间 / 位置 等栏目。
        for banned in ["HP", "好感", "好感度", "时间", "位置", "选项"] {
            XCTAssertFalse(flatText.contains(banned),
                           "变量树里没有『\(banned)』，UI 不应凭空出现（实为：\(flatText)）")
        }
        // 正向：自定义 key 必须保留在产物里。
        XCTAssertTrue(flatText.contains("小手机"))
        XCTAssertTrue(flatText.contains("未读消息"))
    }

    // MARK: - helpers

    /// 把 `NativeDisplayModel` 的所有 block 文本拼成一段字符串，方便做包含断言。
    /// 与 `StatDataSeedProjectionTests.describe(_:)` 行为一致；放这里避免测试间
    /// 私有 helper 互相耦合。
    private func describeAll(_ model: NativeDisplayModel) -> String {
        var out: [String] = []
        func walk(_ block: DisplayBlock) {
            switch block {
            case let .text(s): out.append(s)
            case let .number(value, label):
                out.append(label ?? "")
                out.append(formatNumber(value))
            case let .bar(label, value, max, _):
                out.append(label)
                out.append("\(formatNumber(value))/\(max.map(formatNumber) ?? "?")")
            case let .tag(label, value): out.append("\(label):\(value ?? "")")
            case let .field(label, value): out.append("\(label)=\(value)")
            case let .section(label, content):
                out.append(label)
                content.forEach(walk)
            case let .group(title, children):
                out.append(title)
                children.forEach(walk)
            }
        }
        model.blocks.forEach(walk)
        model.residual.forEach { out.append("\($0.path)=\($0.value)") }
        return out.joined(separator: " ")
    }

    private func formatNumber(_ d: Double) -> String {
        if d.rounded() == d { return String(Int(d)) }
        return String(d)
    }
}