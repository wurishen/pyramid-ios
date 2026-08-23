import XCTest
@testable import PyramidCore

/// SillyTavern OpenAI 预设 JSON 导入解析的行为锁定。
final class PresetImportTests: XCTestCase {

    /// 完整 ST 预设：prompt_order 决定顺序与启停；无 content 的注入标记跳过；
    /// 采样标量映射（含 openai_top_p / openai_max_tokens 别名）。
    func testFullChatPresetMapping() throws {
        let json: [String: Any] = [
            "temperature": 0.85,
            "openai_top_p": 0.9,
            "openai_max_tokens": 2048,
            "model": "gpt-4o",
            "prompts": [
                ["identifier": "main", "name": "Main Prompt", "role": "system", "content": "主提示词"],
                ["identifier": "worldInfoBefore", "name": "World Info"],
                ["identifier": "charDescription", "name": "Char Description", "content": ""],
                ["identifier": "jailbreak", "name": "JB", "role": "system", "content": "越狱段"],
                ["identifier": "chatHistory", "name": "Chat History"]
            ],
            "prompt_order": [
                ["character_id": 100000, "order": []],
                [
                    "character_id": 100001,
                    "order": [
                        ["identifier": "main", "enabled": true],
                        ["identifier": "worldInfoBefore", "enabled": true],
                        ["identifier": "jailbreak", "enabled": false],
                        ["identifier": "chatHistory", "enabled": true]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let presets = try ImportSupport.parsePresets(from: data, fallbackName: "我的预设")
        XCTAssertEqual(presets.count, 1)
        let preset = presets[0]
        XCTAssertEqual(preset.name, "我的预设")
        // jailbreak 被 enabled=false 关掉；无 content 的标记不进系统词。
        XCTAssertEqual(preset.systemPrompt, "主提示词")
        XCTAssertEqual(preset.temperature, 0.85)
        XCTAssertEqual(preset.topP, 0.9)
        XCTAssertEqual(preset.maxTokens, 2048)
        XCTAssertEqual(preset.modelName, "gpt-4o")
        XCTAssertNil(preset.worldBookId)
        XCTAssertTrue(preset.displayRegexIds.isEmpty)
    }

    /// 无 prompt_order → 按数组原序取全部有 content 的 prompt。
    func testFallbackWithoutPromptOrder() throws {
        let json: [String: Any] = [
            "prompts": [
                ["identifier": "a", "content": "第一段"],
                ["identifier": "b", "role": "user", "content": "第二段"]
            ],
            "top_p": 0.5
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let presets = try ImportSupport.parsePresets(from: data, fallbackName: "")
        XCTAssertEqual(presets[0].name, "导入的预设")
        XCTAssertEqual(presets[0].systemPrompt, "第一段\n\n第二段")
        XCTAssertNil(presets[0].temperature)
        XCTAssertEqual(presets[0].topP, 0.5)
    }

    /// 纯标量扁平预设（text completion 风格）也能进，系统词为 nil。
    func testFlatScalarPreset() throws {
        let json: [String: Any] = ["temperature": NSNumber(value: 1.2), "max_tokens": 512]
        let data = try JSONSerialization.data(withJSONObject: json)
        let presets = try ImportSupport.parsePresets(from: data, fallbackName: "flat")
        XCTAssertEqual(presets[0].maxTokens, 512)
        XCTAssertEqual(presets[0].name, "flat")
        XCTAssertNil(presets[0].systemPrompt)
    }

    /// 角色卡误投 → 明确报错引导去角色卡入口。
    func testCharacterCardRejectedWithHint() throws {
        let json: [String: Any] = [
            "spec": "chara_card_v3",
            "data": ["name": "某角色", "description": "x"]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try ImportSupport.parsePresets(from: data, fallbackName: "卡")) { error in
            guard case PresetImportError.characterCardHint = error else {
                return XCTFail("应抛 characterCardHint，实为 \(error)")
            }
        }
    }

    /// 非 JSON / 非对象输入 → invalidData。
    func testGarbageRejected() throws {
        XCTAssertThrowsError(try ImportSupport.parsePresets(from: Data("not json".utf8), fallbackName: "x"))
        let arrayData = try JSONSerialization.data(withJSONObject: [["prompts": []], ["temperature": 1]])
        let presets = try ImportSupport.parsePresets(from: arrayData, fallbackName: "batch")
        XCTAssertEqual(presets.count, 2)
    }
}
