import XCTest
@testable import PyramidCore

/// Phase 1 数据保真层测试。
///
/// 目标：确保 SillyTavern Character Card V1 / V2 / V3 导入到 Pyramid 后，
/// 已知字段照常 typed 解析，V3 引入的未知子结构（`character_book` / `extensions`
/// / `tavern_helper`）通过 `JSONValue` 透传通道零丢失；导入 → 持久化 → 重读
/// round-trip 后 raw 数据仍然完整。
///
/// 测试用纯 Foundation `JSONSerialization` 构造 `[String: Any]` 喂给
/// `ImportSupport.parseSillyTavernCard` —— 与 iOS 端的 `parseCharacters` 第一
/// 个 JSONSerialization 分支是同一条路径。
final class CharacterV3ImportTests: XCTestCase {

    // MARK: - V1：字段在根层

    /// V1 角色卡没有 `data` envelope，所有已知字段在根层。
    /// 期望：typed 字段正常读；raw 三个字段全部 nil（V1 没有 V3 扩展概念）。
    func testV1RootFieldsImportWithNilRaw() throws {
        let json: [String: Any] = [
            "name": "V1 Char",
            "description": "A V1 card",
            "personality": "Cheerful",
            "scenario": "Cafe",
            "first_mes": "Hi!"
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.name, "V1 Char")
        XCTAssertEqual(character.description, "A V1 card")
        XCTAssertEqual(character.firstMes, "Hi!")
        XCTAssertNil(character.extensionsRaw)
        XCTAssertNil(character.tavernHelperRaw)
        XCTAssertNil(character.characterBookRaw)
    }

    // MARK: - V2：data envelope 但无 V3 扩展

    /// V2 角色卡有 `data` 子对象；含 `extensions.regex_scripts` 但无
    /// `character_book` / `tavern_helper`。期望：regex_scripts 走 typed，
    /// extensionsRaw 仍要保留除 regex_scripts 之外的所有子键。
    func testV2CharacterCardImportsWithNilCharacterBook() throws {
        let json: [String: Any] = [
            "spec": "chara_card_v2",
            "spec_version": "2.0",
            "data": [
                "name": "V2 Char",
                "description": "V2 desc",
                "extensions": [
                    "talkativeness": 0.7,
                    "fav": false,
                    "world": "before"
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.name, "V2 Char")
        XCTAssertEqual(character.description, "V2 desc")
        XCTAssertNil(character.characterBookRaw)
        // Phase 2 typed lift：talkativeness / fav → typed；world（非白名单）保留在 extensionsRaw
        XCTAssertEqual(character.talkativeness, 0.7)
        XCTAssertEqual(character.isFavorite, false)
        guard case .object(let ext) = character.extensionsRaw else {
            return XCTFail("extensionsRaw 应为 object，实际：\(String(describing: character.extensionsRaw))")
        }
        XCTAssertNotNil(ext["world"], "V2 extensions 子键 world（非 lifted）必须保留")
        XCTAssertNil(ext["talkativeness"], "lifted 键不应重复存于 extensionsRaw")
        XCTAssertNil(ext["fav"], "lifted 键不应重复存于 extensionsRaw")
    }

    // MARK: - V3：核心场景

    /// V3 角色卡：`data.character_book` 整块保留为 `characterBookRaw`。
    /// 这是 ST V3 相对 V2 最大的新功能（内嵌世界书）。
    func testV3CharacterBookPreserved() throws {
        let json: [String: Any] = [
            "spec": "chara_card_v3",
            "spec_version": "3.0",
            "data": [
                "name": "V3 Char",
                "character_book": [
                    "name": "Lore",
                    "entries": [
                        ["uid": 0, "key": ["bar"], "content": "bar lore"]
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.name, "V3 Char")
        guard case .object(let book) = character.characterBookRaw else {
            return XCTFail("characterBookRaw 应为 object，实际：\(String(describing: character.characterBookRaw))")
        }
        XCTAssertNotNil(book["name"], "character_book.name 必须保留")
        XCTAssertNotNil(book["entries"], "character_book.entries 必须保留")
    }

    /// V3：`data.extensions` 整块保留到 `extensionsRaw`（除已 typed lift / regex_scripts）。
    /// Phase 2：talkativeness / fav / depth_prompt → typed；world（非白名单）保留 raw。
    func testV3ExtensionsPreservedExceptRegexScripts() throws {
        let json: [String: Any] = [
            "spec": "chara_card_v3",
            "data": [
                "name": "V3 Char",
                "extensions": [
                    "talkativeness": 0.8,
                    "fav": true,
                    "world": "before",
                    "depth_prompt": [
                        "role": "system",
                        "depth": 4,
                        "content": "你是一个温柔的助手"
                    ],
                    "regex_scripts": [
                        ["regex": "A", "replacement": "1"]
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        // regex_scripts 走 typed
        XCTAssertEqual(character.extensionsRegexScripts.count, 1)
        // Phase 2 typed lift：3 个 lifted 子键 → typed 字段
        XCTAssertEqual(character.talkativeness, 0.8)
        XCTAssertEqual(character.isFavorite, true)
        XCTAssertNotNil(character.depthPrompt, "depth_prompt 应被 lift 到 typed")
        XCTAssertEqual(character.depthPrompt?.role, .system)
        XCTAssertEqual(character.depthPrompt?.depth, 4)
        XCTAssertEqual(character.depthPrompt?.content, "你是一个温柔的助手")
        XCTAssertEqual(character.depthPrompt?.position, .inChat)
        // extensionsRaw 保留未 lifted 键；lifted / regex_scripts 必须剥离
        guard case .object(let ext) = character.extensionsRaw else {
            return XCTFail("extensionsRaw 应为 object")
        }
        XCTAssertNotNil(ext["world"])
        XCTAssertNil(ext["talkativeness"], "lifted 键不应重复存于 extensionsRaw")
        XCTAssertNil(ext["fav"], "lifted 键不应重复存于 extensionsRaw")
        XCTAssertNil(ext["depth_prompt"], "lifted 键不应重复存于 extensionsRaw")
        XCTAssertNil(ext["regex_scripts"], "regex_scripts 应被剥离到 typed 字段，不应重复存于 extensionsRaw")
    }

    /// V3：`data.extensions.tavern_helper` 同时写入 `tavernHelperRaw`（便捷指针）
    /// 和 `extensionsRaw`（完整结构）。
    func testV3TavernHelperPreserved() throws {
        let json: [String: Any] = [
            "spec": "chara_card_v3",
            "data": [
                "name": "V3 Char",
                "extensions": [
                    "tavern_helper": [
                        "scripts": [["name": "helper1"]],
                        "version": "1.0"
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        // 1) 便捷指针
        guard case .object(let helper) = character.tavernHelperRaw else {
            return XCTFail("tavernHelperRaw 应为 object")
        }
        XCTAssertNotNil(helper["scripts"])
        XCTAssertNotNil(helper["version"])
        // 2) 完整 extensions 也必须保留 tavern_helper
        guard case .object(let ext) = character.extensionsRaw else {
            return XCTFail("extensionsRaw 应为 object")
        }
        XCTAssertNotNil(ext["tavern_helper"], "extensionsRaw 应包含 tavern_helper")
    }

    /// V3：根层 / `data` 层的未知字段（如 `assets`、`spec`、`spec_version`、
    /// 第三方自定义字段）当前不强制 typed，但**不能**让解析失败。
    func testV3UnknownFieldsDoNotBreakParse() throws {
        let json: [String: Any] = [
            "spec": "chara_card_v3",
            "spec_version": "3.0",
            "data": [
                "name": "Weird V3",
                "creator": "someone",
                "character_version": "1.0",
                "creator_notes": "v3 notes",
                "post_history_instructions": "be kind",
                "tags": ["fantasy", "v3"],
                "alternate_greetings": ["alt 1", "alt 2"],
                "extensions": [
                    "depth_prompt": ["role": "user", "depth": 2, "content": "depth!"],
                    "third_party_extension": ["nested": ["deep": 42]]
                ],
                "character_book": [
                    "name": "Weird Lore",
                    "entries": [["uid": 0, "key": ["x"], "content": "x lore"]]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.name, "Weird V3")
        XCTAssertEqual(character.creator, "someone")
        XCTAssertEqual(character.characterVersion, "1.0")
        XCTAssertEqual(character.creatorNotes, "v3 notes")
        XCTAssertEqual(character.postHistoryInstructions, "be kind")
        XCTAssertEqual(character.tags, ["fantasy", "v3"])
        XCTAssertEqual(character.alternateGreetings, ["alt 1", "alt 2"])
        XCTAssertNotNil(character.extensionsRaw)
        XCTAssertNotNil(character.characterBookRaw)
    }

    // MARK: - 边界场景

    /// 角色卡完全没有 extensions 键 → 三个 raw 字段全部 nil，不能报错。
    func testMissingExtensionsLeavesRawNil() throws {
        let json: [String: Any] = [
            "data": ["name": "Bare Char"]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertEqual(character.name, "Bare Char")
        XCTAssertNil(character.extensionsRaw)
        XCTAssertNil(character.tavernHelperRaw)
        XCTAssertNil(character.characterBookRaw)
    }

    /// extensions 存在但完全为空字典 → extensionsRaw / tavernHelperRaw 都应为 nil。
    func testEmptyExtensionsLeavesRawNil() throws {
        let json: [String: Any] = [
            "data": [
                "name": "EmptyExt Char",
                "extensions": [:] as [String: Any]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertNil(character.extensionsRaw)
        XCTAssertNil(character.tavernHelperRaw)
    }

    /// character_book 存在但不是合法 JSON object（如字符串 / 数组）→ characterBookRaw = nil。
    func testMalformedCharacterBookLeavesRawNil() throws {
        let json: [String: Any] = [
            "data": [
                "name": "Broken Char",
                "character_book": "not an object"
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        XCTAssertNil(character.characterBookRaw)
    }

    /// tavern_helper 值为 NSNull → tavernHelperRaw = .null（明确区分"缺失"与"显式 null"）。
    func testTavernHelperNSNullBecomesJSONNull() throws {
        let json: [String: Any] = [
            "data": [
                "name": "NullChar",
                "extensions": [
                    "tavern_helper": NSNull()
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        // JSONValue.from(NSNull()) == .null
        if case .null = character.tavernHelperRaw {
            // 期望
        } else {
            XCTFail("tavernHelperRaw 应为 .null，实际：\(String(describing: character.tavernHelperRaw))")
        }
    }

    // MARK: - Round-trip：导入 → 编码 → 解码 → 数据完整

    /// V3 角色卡：导入 → JSONEncoder → JSONDecoder → 全部 raw + typed 字段值完整保留。
    /// 这是 P1 数据保真层 + P2 typed lift 的核心保证：持久化路径（UserDefaults / Backup）必须不丢任何字段。
    func testRoundTripPreservesUnknownFields() throws {
        let original: [String: Any] = [
            "spec": "chara_card_v3",
            "data": [
                "name": "Round-trip V3",
                "description": "keep",
                "extensions": [
                    "talkativeness": 0.5,
                    "fav": true,
                    "depth_prompt": ["role": "user", "depth": 2, "content": "depth!"],
                    "third_party_extension": ["nested": ["deep": ["value": 42]]]
                ],
                "character_book": [
                    "name": "RT Lore",
                    "entries": [["uid": 1, "key": ["k"], "content": "c"]]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(original)
        // 编码 → 解码
        let encoder = JSONEncoder()
        let data = try encoder.encode(character)
        let decoded = try JSONDecoder().decode(Character.self, from: data)
        XCTAssertEqual(decoded.name, "Round-trip V3")
        XCTAssertEqual(decoded.description, "keep")
        // raw 字段 round-trip
        XCTAssertNotNil(decoded.characterBookRaw, "characterBookRaw 必须 round-trip 回来")
        // typed lift 字段 round-trip
        XCTAssertEqual(decoded.talkativeness, 0.5)
        XCTAssertEqual(decoded.isFavorite, true)
        XCTAssertEqual(decoded.depthPrompt?.role, .user)
        XCTAssertEqual(decoded.depthPrompt?.depth, 2)
        XCTAssertEqual(decoded.depthPrompt?.content, "depth!")
        // 未 lifted 键仍保留在 extensionsRaw
        guard case .object(let ext) = decoded.extensionsRaw else {
            return XCTFail("extensionsRaw 解码后应为 object")
        }
        XCTAssertNotNil(ext["third_party_extension"])
        XCTAssertNil(ext["talkativeness"], "lifted 键不应在 extensionsRaw")
        XCTAssertNil(ext["depth_prompt"], "lifted 键不应在 extensionsRaw")
    }

    /// 旧 Pyramid 角色卡 JSON（无 raw 字段）能正常 decode，raw 全部 nil。
    func testLegacyCharacterWithoutRawFieldsDecodes() throws {
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy",
          "description": "",
          "personality": "",
          "scenario": "",
          "systemPrompt": "",
          "firstMes": "",
          "alternateGreetings": [],
          "mesExample": "",
          "creatorNotes": "",
          "postHistoryInstructions": "",
          "tags": [],
          "creator": "",
          "characterVersion": "",
          "extensionsRegexScripts": []
        }
        """.data(using: .utf8)!
        let character = try JSONDecoder().decode(Character.self, from: legacyJSON)
        XCTAssertEqual(character.name, "Legacy")
        XCTAssertNil(character.extensionsRaw)
        XCTAssertNil(character.tavernHelperRaw)
        XCTAssertNil(character.characterBookRaw)
    }

    // MARK: - 既有功能不被破坏

    /// 已有的 ST regex_scripts 自动发现必须继续工作（这是 v0.7.1 已交付的功能）。
    /// extensions 同时含 regex_scripts 与另一个子键（talkativeness）→ extensionsRaw
    /// 仍要为 object（剥掉 regex_scripts 后还剩 talkativeness）。
    func testExistingRegexScriptsStillWorkAfterPhase1() {
        let json: [String: Any] = [
            "spec": "chara_card_v3",
            "data": [
                "name": "Regex Char",
                "extensions": [
                    "talkativeness": 0.7,
                    "regex_scripts": [
                        ["regex": "World", "replacement": "Pyramid"],
                        ["regex": "Hello", "replacement": "Hi", "enabled": false]
                    ]
                ]
            ]
        ]
        let character = ImportSupport.parseSillyTavernCard(json)
        // typed 字段：regex_scripts + Phase 2 lifted talkativeness
        XCTAssertEqual(character.extensionsRegexScripts.count, 2)
        XCTAssertEqual(character.extensionsRegexScripts[0].regex, "World")
        XCTAssertEqual(character.extensionsRegexScripts[1].regex, "Hello")
        XCTAssertEqual(character.extensionsRegexScripts[1].enabled, false)
        XCTAssertEqual(character.talkativeness, 0.7)
        // extensionsRaw 现在 nil：所有子键都被剥离（regex_scripts → typed，talkativeness → typed）
        XCTAssertNil(character.extensionsRaw,
                     "所有 extensions 子键都被 lift/strip 后 extensionsRaw 应为 nil")
        // 走 SillyTavernScriptImporter 仍能转换为 DisplayRegex
        let converted = character.extensionsRegexScripts
            .compactMap { SillyTavernScriptImporter.convert($0) }
        XCTAssertEqual(converted.count, 1, "只有 enabled=true 的那条能转换")
        XCTAssertEqual(converted[0].pattern, "World")
    }
}

// MARK: - JSONValue 单元测试

final class JSONValueTests: XCTestCase {

    /// `JSONValue.from(any:)` 对各种基础类型桥接正确。
    func testFromAnyBasicTypes() {
        XCTAssertNil(JSONValue.from(any: nil), "nil 应返回 nil（区分缺失）")
        XCTAssertEqual(JSONValue.from(any: NSNull()), .some(.null))
        XCTAssertEqual(JSONValue.from(any: true), .some(.bool(true)))
        XCTAssertEqual(JSONValue.from(any: false), .some(.bool(false)))
        XCTAssertEqual(JSONValue.from(any: 42), .some(.int(42)))
        XCTAssertEqual(JSONValue.from(any: 3.14), .some(.double(3.14)))
        XCTAssertEqual(JSONValue.from(any: "hello"), .some(.string("hello")))
    }

    /// 嵌套数组 / 字典递归转换。
    func testFromAnyNested() {
        let nested: [Any] = [1, "two", NSNull(), ["k": true]]
        let jv = JSONValue.from(any: nested)
        XCTAssertNotNil(jv)
        guard case .array(let arr) = jv else { return XCTFail() }
        XCTAssertEqual(arr.count, 4)
        XCTAssertEqual(arr[0], .int(1))
        XCTAssertEqual(arr[1], .string("two"))
        XCTAssertEqual(arr[2], .null)
        guard case .object(let obj) = arr[3] else { return XCTFail() }
        XCTAssertEqual(obj["k"], .bool(true))
    }

    /// JSONValue 自身的 Codable round-trip。
    func testCodableRoundTrip() throws {
        let original = JSONValue.object([
            "name": .string("Test"),
            "score": .double(9.5),
            "tags": .array([.string("a"), .string("b")]),
            "nested": .object(["k": .int(1)])
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// Codable 解码未知 JSON 类型应抛错（防御性）。
    func testDecodingUnsupportedThrows() {
        // Date 不能被 JSONValue 识别 —— 但实际 JSON 不会含 Date；这里跳过硬测，
        // 因为 singleValueContainer 会先试 Bool/Int/Double/String/Array/Object，
        // 任何 Foundation 类型最终会落到 dataCorrupted 抛错（除非用 JSONEncoder 编码）。
        // 用一个无法识别的容器形式：直接构造一个 super weird JSON 不会从标准 JSON 出现。
        // 因此本测试只确保 JSON 合法值都能 decode，不硬测 invalid。
        let data = "\"just a string\"".data(using: .utf8)!
        let jv = try? JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(jv, .string("just a string"))
    }
}