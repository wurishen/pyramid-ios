import XCTest
@testable import PyramidCore

/// `NativeDisplayModel` + `NativeDisplayModelProjector` 的纯算法覆盖。
///
/// 所有用例**纯代码内构造**中性数据（time / player / location / hp / gold 等通用词；
/// 中文键只用"时间""玩家"等通用词；**不引入**角色名 / 卡面路径 / 脚本名）。
/// 不依赖任何 frozen JSON / fixture 文件。
final class NativeDisplayModelTests: XCTestCase {

    // MARK: - 顶层结构

    /// 空对象 → 单 `group("状态", [text("等待变量")])` 占位，无 residual。
    func testEmptyObjectRendersWaitingGroup() {
        let model = NativeDisplayModelProjector.project(statData: .object([:]))
        XCTAssertEqual(model.version, 1)
        guard case let .group(title, children) = model.blocks.first else {
            XCTFail("blocks[0] 应是 group，实为 \(String(describing: model.blocks.first))")
            return
        }
        XCTAssertEqual(title, "状态")
        XCTAssertEqual(children.count, 1)
        guard case let .text(t) = children[0] else {
            XCTFail("children[0] 应是 text")
            return
        }
        XCTAssertTrue(t.contains("等待变量"), "空对象应给出「等待变量」占位")
        XCTAssertTrue(model.residual.isEmpty)
    }

    /// 顶层非对象（数组 / 字符串 / 数字）→ 整段原文落入 residual，不丢。
    func testNonObjectTopLevelFallsBackToResidual() {
        let cases: [JSONValue] = [
            .array([.int(1), .int(2)]),
            .string("just a string"),
            .int(42),
            .bool(true),
            .null
        ]
        for value in cases {
            let model = NativeDisplayModelProjector.project(statData: value)
            XCTAssertEqual(model.blocks.count, 1, "非 object 顶层 → 单 text 占位")
            XCTAssertEqual(model.residual.count, 1, "原文必须保留到 residual")
            XCTAssertNotNil(model.residual.first?.reason)
        }
    }

    // MARK: - 标量

    /// 短 string → `field(label, value)`。
    func testShortStringBecomesField() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "time": .string("傍晚")
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        guard case let .field(label, value) = children[0] else {
            XCTFail("children[0] 应是 field，实为 \(children[0])")
            return
        }
        XCTAssertEqual(label, "time")
        XCTAssertEqual(value, "傍晚")
    }

    /// 长 string（> 30 字符）→ `section(label, [text])`。
    func testLongStringBecomesSection() {
        let long = String(repeating: "a", count: 31)
        let model = NativeDisplayModelProjector.project(statData: .object([
            "description": .string(long)
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        guard case let .section(label, content) = children[0] else {
            XCTFail("children[0] 应是 section，实为 \(children[0])")
            return
        }
        XCTAssertEqual(label, "description")
        XCTAssertEqual(content.count, 1)
        guard case let .text(t) = content[0] else { return XCTFail("section.content[0] 应是 text") }
        XCTAssertEqual(t.count, 31)
    }

    /// 标量 number → 通用键 → `number(value, label)`，**不**自动转 bar。
    func testScalarNumberWithoutBarHeuristicBecomesNumber() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "gold": .int(50)
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        guard case let .number(value, label) = children[0] else {
            XCTFail("children[0] 应是 number，实为 \(children[0])")
            return
        }
        XCTAssertEqual(value, 50)
        XCTAssertEqual(label, "gold")
    }

    /// 标量 number + HP 键名 → `bar(kind: hp, max: 100)`。
    func testHPKeyBecomesBarKindHP() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "HP": .int(80)
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        guard case let .bar(label, value, max, kind) = children[0] else {
            XCTFail("children[0] 应是 bar，实为 \(children[0])")
            return
        }
        XCTAssertEqual(label, "HP")
        XCTAssertEqual(value, 80)
        XCTAssertEqual(max, 100)
        XCTAssertEqual(kind, .hp)
    }

    /// 标量 number + 好感度键 → `bar(kind: affection, max: 100)`。
    func testAffectionKeyBecomesBarKindAffection() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "好感度": .int(65)
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        guard case let .bar(label, value, max, kind) = children[0] else {
            XCTFail("children[0] 应是 bar，实为 \(children[0])")
            return
        }
        XCTAssertEqual(label, "好感度")
        XCTAssertEqual(value, 65)
        XCTAssertEqual(max, 100)
        XCTAssertEqual(kind, .affection)
    }

    /// 标量 bool → `tag(label, value)`（value 是 "true"/"false"）。
    func testBoolBecomesTagWithValue() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "isRaining": .bool(true),
            "isNight": .bool(false)
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        // 排序按 key 字典序：isNight < isRaining
        guard case let .tag(label1, value1) = children[0] else {
            XCTFail("children[0] 应是 tag")
            return
        }
        XCTAssertEqual(label1, "isNight")
        XCTAssertEqual(value1, "false")
        guard case let .tag(label2, value2) = children[1] else {
            XCTFail("children[1] 应是 tag")
            return
        }
        XCTAssertEqual(label2, "isRaining")
        XCTAssertEqual(value2, "true")
    }

    // MARK: - 嵌套对象

    /// 一层嵌套 object → `group(title, [field, ...])`，递归正常。
    func testNestedObjectBecomesGroup() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "player": .object([
                "location": .string("集市"),
                "hp": .int(80)
            ])
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        guard case let .group(title, grandchildren) = children[0] else {
            XCTFail("children[0] 应是 group，实为 \(children[0])")
            return
        }
        XCTAssertEqual(title, "player")
        XCTAssertEqual(grandchildren.count, 2)
        // hp 命中 bar 启发，location 是 string → field
        let kinds = Set(grandchildren.map { block -> String in
            switch block {
            case .bar: return "bar"
            case .field: return "field"
            default: return "other"
            }
        })
        XCTAssertEqual(kinds, ["bar", "field"])
    }

    /// 深度 ≤ 3 正常嵌套；深度 4 文本化；深度 ≥ 5 residual。
    /// 构造 depth=5 的嵌套：`/a/b/c/d/e` 共 5 层。
    func testDepthLimitTruncatesAndResidualizes() {
        let deepTree: JSONValue = .object([
            "a": .object([
                "b": .object([
                    "c": .object([
                        "d": .object([
                            "e": .string("deep")
                        ])
                    ])
                ])
            ])
        ])
        let model = NativeDisplayModelProjector.project(statData: deepTree)
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        // depth 1: a → group
        guard case let .group(_, bChildren) = children[0] else { return XCTFail("a 应是 group") }
        // depth 2: b → group
        guard case let .group(_, cChildren) = bChildren[0] else { return XCTFail("b 应是 group") }
        // depth 3: c → group
        guard case let .group(_, dChildren) = cChildren[0] else { return XCTFail("c 应是 group") }
        // depth 4 == maxDepth: d → text "d: e: deep"
        guard case let .text(dText) = dChildren[0] else {
            XCTFail("d 应是 text（depth == maxDepth 文本化），实为 \(dChildren[0])")
            return
        }
        XCTAssertTrue(dText.contains("e: deep"))
        XCTAssertTrue(model.residual.isEmpty, "depth 4 走文本化，不进 residual")
    }

    /// depth > maxDepth → 整棵 subtree 落入 residual，**不丢原文**。
    /// 构造方式：depth 4 的数组里嵌 object 元素 → 元素进 projectValue 时 depth=5 > maxDepth=4。
    /// 文档依据：`ST_TO_NATIVE_MAPPING.md` §4.3 —— depth ≥ 5 residual。
    func testDepthBeyondMaxGoesToResidual() {
        // 树：a/b/c/d = [obj{x:string "too deep"}]；d 是 array at depth 4，
        // 元素 obj 又嵌入时进 depth 5 → residual。
        let deepTree: JSONValue = .object([
            "a": .object([
                "b": .object([
                    "c": .object([
                        "d": .array([
                            .object(["x": .string("too deep")])
                        ])
                    ])
                ])
            ])
        ])
        let model = NativeDisplayModelProjector.project(statData: deepTree)
        XCTAssertFalse(model.residual.isEmpty, "深度 > 4 必须有 residual")
        let reasons = model.residual.compactMap(\.reason)
        XCTAssertTrue(reasons.contains(where: { $0.contains("depth") }), "reason 必须说明 depth 触发")
        let rawTexts = model.residual.map(\.rawText)
        XCTAssertTrue(rawTexts.contains(where: { $0.contains("too deep") }), "原文必须保留")
    }

    // MARK: - 数组

    /// 字符串数组 → `section` 包装，每项 `tag(label, value: nil)`。
    func testStringArrayBecomesSectionOfTags() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "inventory": .array([.string("apple"), .string("pear"), .string("gold")])
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        guard case let .section(label, content) = children[0] else {
            XCTFail("children[0] 应是 section，实为 \(children[0])")
            return
        }
        XCTAssertEqual(label, "inventory")
        XCTAssertEqual(content.count, 3)
        let labels = content.compactMap { block -> String? in
            if case let .tag(label, value) = block { return label }
            return nil
        }
        XCTAssertEqual(Set(labels), ["apple", "pear", "gold"])
    }

    /// 混合数组（string + bool + number）→ 全部归一为对应原语。
    func testMixedArrayElementsAllProjected() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "mixed": .array([.string("a"), .bool(true), .int(7)])
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        guard case let .section(label, content) = children[0] else {
            XCTFail("children[0] 应是 section")
            return
        }
        XCTAssertEqual(label, "mixed")
        XCTAssertEqual(content.count, 3)
        // string → tag(a, nil)
        guard case let .tag(l0, v0) = content[0] else { return XCTFail("content[0] 应是 tag") }
        XCTAssertEqual(l0, "a")
        XCTAssertNil(v0)
        // bool → tag(#1, "true")
        guard case let .tag(l1, v1) = content[1] else { return XCTFail("content[1] 应是 tag") }
        XCTAssertEqual(l1, "#1")
        XCTAssertEqual(v1, "true")
        // int → number(7, nil)
        guard case let .number(v2, l2) = content[2] else { return XCTFail("content[2] 应是 number") }
        XCTAssertEqual(v2, 7)
        XCTAssertNil(l2)
    }

    /// 数组里的 object 元素 → 递归为 group（不丢形态）。
    func testArrayOfObjectsRecursesToGroups() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "items": .array([
                .object(["name": .string("apple"), "qty": .int(3)]),
                .object(["name": .string("pear"), "qty": .int(1)])
            ])
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        guard case let .section(label, content) = children[0] else {
            XCTFail("children[0] 应是 section")
            return
        }
        XCTAssertEqual(label, "items")
        XCTAssertEqual(content.count, 2)
        for block in content {
            guard case let .group(title, _) = block else {
                XCTFail("数组元素的 object 应展开为 group，实为 \(block)")
                return
            }
            XCTAssertEqual(title.hasPrefix("#"), true, "数组下标 element 用 #i 标记")
        }
    }

    /// 数组里的 null 元素 → 跳过（不展示）。
    func testNullArrayElementsAreDropped() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "list": .array([.string("a"), .null, .string("b")])
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        guard case let .section(_, content) = children[0] else { return XCTFail("section") }
        XCTAssertEqual(content.count, 2, "null 元素必须跳过")
    }

    // MARK: - $meta / $internal / display_data / delta_data 跳过

    /// `$meta` / `$internal` / `$arrayMeta` / `display_data` / `delta_data` 整棵子树跳过。
    /// 文档依据：`ST_FALLBACK_RULES.md` §4 + `ST_SOURCE_CONCLUSIONS.md` §4。
    func testInternalKeysAreSkipped() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "time": .string("傍晚"),
            "$meta": .object([
                "required": .array([.string("HP")]),
                "template": .string("x")
            ]),
            "$internal": .object([
                "display_data": .string("hidden"),
                "delta_data": .string("hidden")
            ]),
            "display_data": .object(["x": .int(1)]),
            "delta_data": .object(["y": .int(2)])
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        // 应该只剩 1 个 children（time）；其他 4 个内部键全跳过。
        XCTAssertEqual(children.count, 1, "内部键整棵跳过；只保留 time")
        guard case let .field(label, value) = children[0] else {
            XCTFail("children[0] 应是 field")
            return
        }
        XCTAssertEqual(label, "time")
        XCTAssertEqual(value, "傍晚")
        XCTAssertTrue(model.residual.isEmpty, "内部键走 drop（不展示 + 不进 residual）")
    }

    /// `$meta` 跳过但同一对象的其他键仍正常投影。
    func testMetaSkippedOthersStillProject() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "$meta": .object(["a": .int(1)]),
            "player": .object(["location": .string("集市")])
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        XCTAssertEqual(children.count, 1)
        guard case .group = children[0] else {
            XCTFail("children[0] 应是 group（player）")
            return
        }
    }

    // MARK: - 幂等

    /// 同一输入两次 project → 结果 Equal（排序 + 纯函数保证）。
    func testIdempotent() {
        let input: JSONValue = .object([
            "time": .string("傍晚"),
            "player": .object(["location": .string("集市"), "HP": .int(80)]),
            "inventory": .array([.string("apple"), .string("pear")])
        ])
        let a = NativeDisplayModelProjector.project(statData: input)
        let b = NativeDisplayModelProjector.project(statData: input)
        XCTAssertEqual(a, b)
    }

    /// 同一输入的字典序等价但 key 顺序不同 → 结果 Equal（project 不依赖输入顺序）。
    func testStableAcrossKeyOrder() {
        let a = NativeDisplayModelProjector.project(statData: .object([
            "a": .int(1),
            "b": .int(2),
            "c": .int(3)
        ]))
        let b = NativeDisplayModelProjector.project(statData: .object([
            "c": .int(3),
            "a": .int(1),
            "b": .int(2)
        ]))
        XCTAssertEqual(a, b)
    }

    // MARK: - VariableEntry 拍扁路径

    /// 空 entries → 空占位 group。
    func testEmptyEntriesRendersWaitingGroup() {
        let model = NativeDisplayModelProjector.project(entries: [])
        guard case let .group(title, children) = model.blocks.first else {
            XCTFail("blocks[0] 应是 group")
            return
        }
        XCTAssertEqual(title, "状态")
        XCTAssertEqual(children.count, 1)
        XCTAssertTrue(model.residual.isEmpty)
    }

    /// 非空 entries → 按 path 排序后渲染为多 `field`。
    func testEntriesBecomeFieldsByPath() {
        let entries = [
            VariableEntry(path: "/time", displayValue: "傍晚"),
            VariableEntry(path: "/player/location", displayValue: "集市")
        ]
        let model = NativeDisplayModelProjector.project(entries: entries)
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        XCTAssertEqual(children.count, 2)
        for child in children {
            guard case .field = child else {
                XCTFail("entries 应全部投影为 field，实为 \(child)")
                return
            }
        }
    }

    /// HP-like path → model 含 `.bar(.hp)`，让 StatusPlaceholderView 的 ProgressView 分支命中。
    /// 这是 1→2 投影层 + 显示层闭环的关键断言：旧 flat 路径只产 field，新路径产 bar。
    func testEntriesWithHPKeyProducesBarBlock() {
        let entries = [
            VariableEntry(path: "/HP", displayValue: "80"),
            VariableEntry(path: "/player/location", displayValue: "集市")
        ]
        let model = NativeDisplayModelProjector.project(entries: entries)
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        let barBlocks = children.compactMap { block -> DisplayBlock? in
            if case .bar = block { return block } else { return nil }
        }
        XCTAssertEqual(barBlocks.count, 1, "HP 路径必须投影为 bar")
        guard case let .bar(label, value, max, kind) = barBlocks[0] else {
            XCTFail("barBlocks[0] 应是 bar")
            return
        }
        XCTAssertEqual(label, "HP")
        XCTAssertEqual(value, 80)
        XCTAssertEqual(max, 100)
        XCTAssertEqual(kind, .hp)
    }

    /// 好感度 path → `.bar(.affection)`：确保另一条 bar kind 启发也走到显示层。
    func testEntriesWithAffectionKeyProducesAffectionBar() {
        let entries = [
            VariableEntry(path: "/好感度", displayValue: "65"),
            VariableEntry(path: "/time", displayValue: "傍晚")
        ]
        let model = NativeDisplayModelProjector.project(entries: entries)
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        let bars = children.compactMap { block -> DisplayBlock? in
            if case .bar(_, _, _, let kind) = block { return kind == .affection ? block : nil }
            return nil
        }
        XCTAssertEqual(bars.count, 1)
    }

    // MARK: - 健壮性

    /// 嵌套 object 不应丢失任何键（除非内部键）。
    func testNestedObjectPreservesAllKeys() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "player": .object([
                "location": .string("集市"),
                "HP": .int(80),
                "好感度": .int(65)
            ])
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        guard case let .group(_, grandchildren) = children[0] else { return XCTFail("player 嵌套 group") }
        XCTAssertEqual(grandchildren.count, 3, "3 个键全部保留")
        XCTAssertTrue(model.residual.isEmpty)
    }

    /// 顶层 null 字段 → drop（不展示，不进 residual）。
    func testNullTopLevelFieldIsDropped() {
        let model = NativeDisplayModelProjector.project(statData: .object([
            "time": .string("傍晚"),
            "absent": .null
        ]))
        guard case let .group(_, children) = model.blocks[0] else { return XCTFail("根部应是 group") }
        XCTAssertEqual(children.count, 1)
        XCTAssertTrue(model.residual.isEmpty)
    }
}