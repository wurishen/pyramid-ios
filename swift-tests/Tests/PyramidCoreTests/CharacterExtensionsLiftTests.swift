import XCTest
@testable import PyramidCore

/// Phase 2 typed-lift 测试。
///
/// `CharacterExtensionsLift` 入口：`ImportSupport.parseSillyTavernCard(_:)`
/// 内部走 `applyRawPassthrough`，对 `data.extensions` 子键做 typed lift + strip。
///
/// 测试重点：
/// - lifted 键（`talkativeness` / `fav` / `depth_prompt`）落到 typed 字段，且**不再**
///   出现在 `extensionsRaw`（避免重复）。
/// - 非白名单键（`world`、未知第三方扩展）继续走 `extensionsRaw` 保真。
/// - lift 失败（depth_prompt 畸形、talkativeness 类型错）→ 键保留在 extensionsRaw，
///   typed 字段不动。
final class CharacterExtensionsLiftTests: XCTestCase {

    // MARK: - talkativeness

    /// `extensions.talkativeness` → typed Double，extensionsRaw 不再含此键。
    func testTalkativenessLifted() throws {
        let json: [String: Any] = [
            "spec": "chara_card_v3",
            "data": [
                "name": "T1",
                "extensions": [
                    "talkativeness": 0.42,
                    "world": "before"
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.talkativeness, 0.42)
        guard case .object(let ext) = character.extensionsRaw else {
            return XCTFail("extensionsRaw 应为 object")
        }
        XCTAssertNotNil(ext["world"])
        XCTAssertNil(ext["talkativeness"], "lifted 键不应重复存于 extensionsRaw")
    }

    /// `talkativeness` > 1.0 → clamp 到 1.0。
    func testTalkativenessClampedAboveOne() throws {
        let json: [String: Any] = [
            "data": [
                "name": "T over",
                "extensions": ["talkativeness": 5.0]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.talkativeness, 1.0)
    }

    /// `talkativeness` < 0.0 → clamp 到 0.0。
    func testTalkativenessClampedBelowZero() throws {
        let json: [String: Any] = [
            "data": [
                "name": "T under",
                "extensions": ["talkativeness": -2.0]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.talkativeness, 0.0)
    }

    /// `talkativeness` 类型错（如 String "0.5"）→ typed nil，键从 extensionsRaw strip
    /// （当前实现总是 strip —— 只有 depth_prompt 解析失败时保留 raw 不动）。
    func testTalkativenessWrongTypeStripsRaw() throws {
        let json: [String: Any] = [
            "data": [
                "name": "T wrong",
                "extensions": ["talkativeness": "0.5" as String]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertNil(character.talkativeness)
        XCTAssertNil(character.extensionsRaw, "类型错也 strip（避免无效数据残留）")
    }

    /// `talkativeness` 缺失 → typed nil，extensionsRaw 不受影响（也无此键）。
    func testTalkativenessMissing() throws {
        let json: [String: Any] = [
            "data": [
                "name": "T miss",
                "extensions": ["world": "after"]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertNil(character.talkativeness)
        guard case .object(let ext) = character.extensionsRaw else {
            return XCTFail()
        }
        XCTAssertNotNil(ext["world"])
    }

    // MARK: - fav

    /// `extensions.fav` → typed Bool。
    func testFavLifted() throws {
        let json: [String: Any] = [
            "data": [
                "name": "F1",
                "extensions": [
                    "fav": true,
                    "world": "before"
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.isFavorite, true)
        guard case .object(let ext) = character.extensionsRaw else {
            return XCTFail()
        }
        XCTAssertNil(ext["fav"], "lifted 键不应重复存于 extensionsRaw")
    }

    /// `fav: false` 也照样 lift（不是默认 nil）。
    func testFavFalseLifted() throws {
        let json: [String: Any] = [
            "data": [
                "name": "F2",
                "extensions": ["fav": false]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.isFavorite, false)
    }

    /// `fav` 类型错（如 String "true"）→ typed nil，键**保留**在 extensionsRaw
    /// （fav 的 removeValue 在 `if let` 内，类型错时不进 strip）。
    func testFavWrongTypeKeepsRaw() throws {
        let json: [String: Any] = [
            "data": [
                "name": "F3",
                "extensions": ["fav": "true" as String]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertNil(character.isFavorite)
        guard case .object(let ext) = character.extensionsRaw else {
            return XCTFail()
        }
        XCTAssertNotNil(ext["fav"], "fav 类型错 → 保留在 extensionsRaw")
    }

    // MARK: - depth_prompt

    /// 完整 depth_prompt → typed lift；extensionsRaw 全部 strip 后变 nil。
    func testDepthPromptLifted() throws {
        let json: [String: Any] = [
            "data": [
                "name": "DP1",
                "extensions": [
                    "depth_prompt": [
                        "role": "system",
                        "depth": 4,
                        "content": "你是一个温柔的助手"
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertNotNil(character.depthPrompt)
        XCTAssertEqual(character.depthPrompt?.role, .system)
        XCTAssertEqual(character.depthPrompt?.depth, 4)
        XCTAssertEqual(character.depthPrompt?.content, "你是一个温柔的助手")
        XCTAssertEqual(character.depthPrompt?.position, .inChat)
        // extensions 只剩 depth_prompt，lift 后整本 extensions 空 → extensionsRaw nil
        XCTAssertNil(character.extensionsRaw,
                     "lift 后 extensions 空 → extensionsRaw nil（空字典不写入）")
    }

    /// depth_prompt 缺 role → 默认 .system。
    func testDepthPromptMissingRoleDefaultsToSystem() throws {
        let json: [String: Any] = [
            "data": [
                "name": "DP2",
                "extensions": [
                    "depth_prompt": [
                        "depth": 2,
                        "content": "x"
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.depthPrompt?.role, .system)
        XCTAssertEqual(character.depthPrompt?.depth, 2)
    }

    /// depth_prompt 缺 depth → 默认 4。
    func testDepthPromptMissingDepthDefaultsToFour() throws {
        let json: [String: Any] = [
            "data": [
                "name": "DP3",
                "extensions": [
                    "depth_prompt": [
                        "role": "user",
                        "content": "x"
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.depthPrompt?.depth, 4)
    }

    /// depth_prompt 含 position: "before" → 正常 lift。
    func testDepthPromptBeforePositionLifted() throws {
        let json: [String: Any] = [
            "data": [
                "name": "DP before",
                "extensions": [
                    "depth_prompt": [
                        "role": "system",
                        "depth": 0,
                        "content": "before content",
                        "position": "before"
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.depthPrompt?.position, .before)
    }

    /// depth_prompt 含 position: "in-chat"（带连字符，ST 原义）→ 正常 lift。
    func testDepthPromptInChatHyphenLifted() throws {
        let json: [String: Any] = [
            "data": [
                "name": "DP in-chat",
                "extensions": [
                    "depth_prompt": [
                        "role": "user",
                        "depth": 2,
                        "content": "x",
                        "position": "in-chat"
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.depthPrompt?.position, .inChat)
    }

    /// depth_prompt 畸形（content 缺失）→ typed nil，键保留在 extensionsRaw。
    func testDepthPromptMalformedKeepsRaw() throws {
        let json: [String: Any] = [
            "data": [
                "name": "DP broken",
                "extensions": [
                    "depth_prompt": [
                        "role": "system",
                        "depth": 4
                        // content missing
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertNil(character.depthPrompt)
        guard case .object(let ext) = character.extensionsRaw else {
            return XCTFail()
        }
        XCTAssertNotNil(ext["depth_prompt"], "解析失败 → 保留在 extensionsRaw")
    }

    /// depth_prompt 缺 depth 但 role 非 system → depth 仍给默认值 4（与 ST 一致）。
    /// 这里只验证字段落地，不验证运行时注入语义。
    func testDepthPromptNonSystemRoleLifts() throws {
        let json: [String: Any] = [
            "data": [
                "name": "DP user role",
                "extensions": [
                    "depth_prompt": [
                        "role": "user",
                        "content": "hello"
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.depthPrompt?.role, .user)
        XCTAssertEqual(character.depthPrompt?.depth, 4)
    }

    /// depth_prompt 缺 content → lift 失败（content 是必需字段）。
    func testDepthPromptMissingContentFails() throws {
        let json: [String: Any] = [
            "data": [
                "name": "DP no content",
                "extensions": [
                    "depth_prompt": [
                        "role": "system",
                        "depth": 4
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertNil(character.depthPrompt, "缺 content → lift 失败 → typed nil")
        guard case .object(let ext) = character.extensionsRaw else {
            return XCTFail()
        }
        XCTAssertNotNil(ext["depth_prompt"], "lift 失败 → 保留 raw 不丢字段")
    }

    // MARK: - 与既有字段 / regex_scripts 共存

    /// extensions 同时含 lifted 键 + regex_scripts + 第三方扩展 → 各走各的管道，不冲突。
    func testExtensionsMixedWithRegexScriptsAndThirdParty() throws {
        let json: [String: Any] = [
            "spec": "chara_card_v3",
            "data": [
                "name": "Mixed",
                "extensions": [
                    "talkativeness": 0.5,
                    "fav": true,
                    "depth_prompt": [
                        "role": "system",
                        "depth": 4,
                        "content": "mixed"
                    ],
                    "world": "before",
                    "third_party_extension": ["nested": ["deep": ["value": 42]]],
                    "regex_scripts": [
                        ["regex": "A", "replacement": "1"]
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        // typed lifts
        XCTAssertEqual(character.talkativeness, 0.5)
        XCTAssertEqual(character.isFavorite, true)
        XCTAssertEqual(character.depthPrompt?.content, "mixed")
        // regex scripts 走 typed
        XCTAssertEqual(character.extensionsRegexScripts.count, 1)
        // extensionsRaw 只剩未 lifted 键
        guard case .object(let ext) = character.extensionsRaw else {
            return XCTFail()
        }
        XCTAssertNotNil(ext["world"])
        XCTAssertNotNil(ext["third_party_extension"])
        // lifted 键与 regex_scripts 全部剥离
        XCTAssertNil(ext["talkativeness"])
        XCTAssertNil(ext["fav"])
        XCTAssertNil(ext["depth_prompt"])
        XCTAssertNil(ext["regex_scripts"])
    }

    /// 所有 extensions 子键都 lifted / strip 后 → extensionsRaw nil（空字典不写入）。
    func testAllExtensionsLiftedLeavesRawNil() throws {
        let json: [String: Any] = [
            "data": [
                "name": "All lifted",
                "extensions": [
                    "talkativeness": 0.5,
                    "fav": true,
                    "depth_prompt": ["role": "system", "depth": 4, "content": "x"],
                    "regex_scripts": []
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertNotNil(character.depthPrompt)
        XCTAssertEqual(character.talkativeness, 0.5)
        XCTAssertEqual(character.isFavorite, true)
        // 没有非白名单键 → extensionsRaw nil
        XCTAssertNil(character.extensionsRaw)
    }

    // MARK: - 边界

    /// tavern_helper 是 V3 另一个独立便捷指针，与 lift 互不影响。
    func testTavernHelperCoexistsWithLift() throws {
        let json: [String: Any] = [
            "data": [
                "name": "Helper",
                "extensions": [
                    "talkativeness": 0.6,
                    "tavern_helper": ["scripts": [["name": "h1"]]]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.talkativeness, 0.6)
        guard case .object(let helper) = character.tavernHelperRaw else {
            return XCTFail("tavernHelperRaw 应为 object")
        }
        XCTAssertNotNil(helper["scripts"])
    }

    /// `extensions` 不存在 → typed 字段全部 nil，raw 全部 nil，不能报错。
    func testNoExtensionsLeavesAllTypedNil() throws {
        let json: [String: Any] = [
            "data": ["name": "Bare"]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertNil(character.talkativeness)
        XCTAssertNil(character.isFavorite)
        XCTAssertNil(character.depthPrompt)
        XCTAssertNil(character.extensionsRaw)
        XCTAssertNil(character.tavernHelperRaw)
    }

    // MARK: - init_stat_data lift

    /// `extensions.init_stat_data`（MVU 初始变量树）→ typed `initStatData` 字段；extensionsRaw 不再含此键。
    /// 真实 init 内容是嵌套 object / array / 标量混合；整体走 JSONValue 透传。
    func testInitStatDataLiftedToTyped() throws {
        let json: [String: Any] = [
            "data": [
                "name": "Init",
                "extensions": [
                    "init_stat_data": [
                        "时间": "傍晚",
                        "玩家": [
                            "当前所在地": "集市",
                            "金币": 50
                        ],
                        "$meta": ["strictTemplate": false]
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        guard let init = character.initStatData else {
            return XCTFail("initStatData 应当被 lift")
        }
        XCTAssertEqual(init["时间"], .string("傍晚"))
        XCTAssertEqual(init["玩家"], .object([
            "当前所在地": .string("集市"),
            "金币": .int(50)
        ]))
        XCTAssertEqual(init["$meta"], .object(["strictTemplate": .bool(false)]))
        // 已被 lift → extensionsRaw 不再含此键；其它 extensions 都为空时整体 nil。
        if case .object(let ext) = character.extensionsRaw {
            XCTAssertNil(ext["init_stat_data"], "lifted 键不应重复存于 extensionsRaw")
        }
    }

    /// `init_stat_data` 是数组（畸形）→ 不 lift、不污染 typed 字段，原值保留在 extensionsRaw 走 export。
    func testInitStatDataNonObjectFallsBackToRaw() throws {
        let json: [String: Any] = [
            "data": [
                "name": "Bad",
                "extensions": [
                    "init_stat_data": ["not", "an", "object"] as [String]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertNil(character.initStatData, "非 object init_stat_data 不应 lift")
        guard case .object(let ext) = character.extensionsRaw else {
            return XCTFail("extensionsRaw 应为 object")
        }
        XCTAssertNotNil(ext["init_stat_data"], "lift 失败应保留在 extensionsRaw")
    }

    /// `init_stat_data` 不存在 → typed nil、extensionsRaw 不受影响。
    func testInitStatDataAbsentLeavesTypedNil() throws {
        let json: [String: Any] = [
            "data": [
                "name": "NoInit",
                "extensions": [
                    "talkativeness": 0.5
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertNil(character.initStatData)
        // extensionsRaw 仅有 talkativeness lift 后的剩余；init_stat_data 不存在时不该有"NoInit"多余字段。
        XCTAssertNil(character.extensionsRaw, "talkativeness 都被 lift 走了，extensionsRaw 应 nil")
    }

    /// `init_stat_data` 与其它 extensions 字段（talkativeness / world）共存 → 各自走自己的路径，
    /// `init_stat_data` lift 到 typed 字段，其它 lift 后剩余仍写 extensionsRaw。
    func testInitStatDataCoexistsWithOtherExtensionsFields() throws {
        let json: [String: Any] = [
            "data": [
                "name": "Mix",
                "extensions": [
                    "talkativeness": 0.7,
                    "world": "before",
                    "init_stat_data": [
                        "foo": "bar"
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.talkativeness, 0.7)
        XCTAssertEqual(character.initStatData, ["foo": .string("bar")])
        // talkativeness、init_stat_data 都被 lift → extensionsRaw 只剩 world。
        guard case .object(let ext) = character.extensionsRaw else {
            return XCTFail("extensionsRaw 应为 object")
        }
        XCTAssertEqual(ext["world"], .string("before"))
        XCTAssertNil(ext["talkativeness"])
        XCTAssertNil(ext["init_stat_data"])
    }
}
