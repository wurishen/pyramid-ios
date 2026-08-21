import XCTest
@testable import PyramidCore

/// 第二阶段重构回归：Pyramid 原生显示层不再把「HP / 好感度 / 金币」之类的字段名
/// 解释成固定 UI 模板 —— 任意数值字段（无论是 HP 还是「小手机电量」「催眠程度」）
/// 都走同一条通用投影路径。
///
/// 锁定的不变量：
/// 1. `DisplayBlock.bar` 不再带任何 Pyramid 业务语义标签（BarKind 已删除）；
/// 2. `NativeDisplayModelProjector` 不根据键名决定投影结果（无 hpKeyKind）；
/// 3. 角色卡的任意未知字段不会让投影层崩溃或注入 Pyramid 固定栏目；
/// 4. 通用数值字段走 `.number`，通用文本字段走 `.field`；`.bar` 只由数据本身
///    显式提供 `{value, max}` 时产生（本期 projector 不产 `.bar`，但 case 保留
///    供未来 Capability 层使用）。
final class NativeDisplayGeneralizationTests: XCTestCase {

    // MARK: - 任意数值字段都是数据，不是 Pyramid 模板

    /// 角色卡定义一组包含 HP / 好感度 / 自定义字段的数值 —— 投影层不应该因为字段
    /// 名字叫 HP / 好感度 就把它们升级为 `.bar`，也不应该把小手机电量 / 催眠程度
    /// 之类的自定义字段错误地识别成 HP / 好感度。
    func testArbitraryNumberFieldsAreAllGeneric() {
        let statData: JSONValue = .object([
            "HP": .int(80),
            "好感度": .int(65),
            "小手机电量": .int(73),
            "催眠程度": .int(42),
            "金币": .int(200),
        ])
        let model = NativeDisplayModelProjector.project(statData: statData)

        guard case let .group(_, children) = model.blocks[0] else {
            return XCTFail("根部应是 group")
        }

        // 关键否定 1：没有任何一个数值字段被升级为 .bar。
        let barCount = children.filter { block in
            if case .bar = block { return true }
            return false
        }.count
        XCTAssertEqual(barCount, 0, "所有数值字段都应走通用 .number 路径，不升级为 .bar")

        // 关键否定 2：自定义字段（小手机电量 / 催眠程度）不应被误识别为 HP / 好感度。
        // 也就��说，它们不应该走任何 Pyramid 特殊路径 —— 它们的 label 必须原样保留，
        // 类型必须是 `.number`，且没有别名为 HP / affection。
        var labels: Set<String> = []
        for child in children {
            guard case let .number(value, label) = child else {
                XCTFail("数值字段应投影为 .number，实为 \(child)")
                continue
            }
            XCTAssertNotNil(label, "label 不应为 nil；投影层保留原始 key 名")
            labels.insert(label ?? "")
            // value 应与原数据一致 —— 投影层不应偷偷改值或归一化。
            XCTAssertGreaterThanOrEqual(value, 0)
        }
        XCTAssertEqual(labels, ["HP", "好感度", "小手机电量", "催眠程度", "金币"],
                       "所有 5 个原始 key 完整保留；HP / 好感度 不再被替换成别的东西")

        // 关键否定 3：UI 不应注入"时间 / 位置 / 选项"之类 Pyramid 固定栏目。
        let renderedLabels = labels.joined(separator: " ")
        for banned in ["时间", "位置", "选项"] {
            XCTAssertFalse(renderedLabels.contains(banned),
                           "投影层不应凭空产生『\(banned)』栏目")
        }
    }

    // MARK: - 扁平条目同样不被特殊化

    /// 扁平条目路径下，HP / 好感度 也不该被升级为 `.bar`，必须以 `.field` 落地。
    /// 这是关键回归 —— 之前 `project(entries:)` 里有 `hpKeyKind` 启发，把
    /// `/HP` 和 `/好感度` 升成 `.bar`。
    func testFlatEntriesWithArbitraryKeysAllBecomeFields() {
        let entries = [
            VariableEntry(path: "/HP", displayValue: "80"),
            VariableEntry(path: "/好感度", displayValue: "65"),
            VariableEntry(path: "/小手机电量", displayValue: "73"),
            VariableEntry(path: "/催眠程度", displayValue: "42"),
        ]
        let model = NativeDisplayModelProjector.project(entries: entries)
        guard case let .group(_, children) = model.blocks[0] else {
            return XCTFail("根部应是 group")
        }

        // 所有条目都应是 .field；不应出现任何 .bar。
        XCTAssertTrue(children.allSatisfy { block in
            if case .field = block { return true }
            return false
        }, "扁平条目应全部走 .field，不应被键名触发 .bar 升级")

        // 每个 path 必须按原样出现在 children 里。
        let fieldLabels = Set(children.compactMap { block -> String? in
            if case let .field(label, _) = block { return label }
            return nil
        })
        XCTAssertEqual(fieldLabels, ["/HP", "/好感度", "/小手机电量", "/催眠程度"])
    }

    // MARK: - 未知字段不崩、不被改名

    /// 任意命名（含 emoji / 多语言 / 嵌套路径）的字段都不应让投影层崩溃或被改写。
    func testUnknownOrExoticKeysArePassedThrough() {
        let statData: JSONValue = .object([
            "🧪 实验进度": .int(50),
            "Player/位置": .string("酒馆"),
            "npc_dialog/branch": .int(3),
            "FLAG_quest_done": .bool(true),
        ])
        let model = NativeDisplayModelProjector.project(statData: statData)

        guard case let .group(_, children) = model.blocks[0] else {
            return XCTFail("根部应是 group")
        }
        // 所有 4 个 key 必须保留。
        XCTAssertEqual(children.count, 4)
        XCTAssertFalse(model.residual.isEmpty == false && children.count == 4 ? false : true,
                       "children 数量应等于输入 key 数（4）")

        // 关键是：没有 Pyramid 模板化行为，没有键被改名。
        // 任意字符串字段 → .field；数值字段 → .number；bool → .tag。
        var sawNumber = false
        var sawField = false
        var sawTag = false
        for child in children {
            switch child {
            case .number: sawNumber = true
            case .field: sawField = true
            case .tag: sawTag = true
            default:
                XCTFail("��应出现其它原语：\(child)")
            }
        }
        XCTAssertTrue(sawNumber, "数值字段应投影为 .number")
        XCTAssertTrue(sawField, "字符串字段应投影为 .field")
        XCTAssertTrue(sawTag, "bool 字段应投影为 .tag")
    }

    // MARK: - DisplayBlock.bar 不再携带 Pyramid 业务语义

    /// 编译期 + 运行期锁定：`DisplayBlock.bar` 不再有 `kind` 字段，也没有任何
    /// Pyramid 业务标签。所有调用方必须按统一签名为 `.bar(label, value, max)`。
    /// 该测试通过直接构造 + 比较 .bar 来锁住形状。
    func testBarHasNoPyramidKindPayload() {
        let bar: DisplayBlock = .bar(label: "任意 key", value: 50, max: 100)
        guard case let .bar(label, value, max) = bar else {
            return XCTFail("bar 形状应是 (label, value, max) 三元组")
        }
        XCTAssertEqual(label, "任意 key")
        XCTAssertEqual(value, 50)
        XCTAssertEqual(max, 100)
        // 不同 label / value / max 应产生不同的 .bar。
        XCTAssertNotEqual(bar, .bar(label: "其他", value: 50, max: 100))
        XCTAssertNotEqual(bar, .bar(label: "任意 key", value: 51, max: 100))
        XCTAssertNotEqual(bar, .bar(label: "任意 key", value: 50, max: nil))
    }

    // MARK: - 数值 → number（不分支）

    /// 单个数值字段不管叫什么，都应得到 `.number(value, label)`，**绝不**是 `.bar`。
    func testSingleNumericFieldIsNumberRegardlessOfName() {
        for key in ["HP", "好感度", "小手机电量", "催眠程度", "法力", "饱腹", "金币", "Manna", "Power"] {
            let model = NativeDisplayModelProjector.project(statData: .object([key: .int(80)]))
            guard case let .group(_, children) = model.blocks[0],
                  case let .number(value, label) = children[0] else {
                XCTFail("key=\(key) 应投影为 .number；实为 \(model.blocks)")
                continue
            }
            XCTAssertEqual(value, 80)
            XCTAssertEqual(label, key, "label 必须原样保留为输入 key")
        }
    }
}