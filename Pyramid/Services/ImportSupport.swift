import Foundation
import Compression

enum ImportSupport {

    /// fileImporter 返回的是 security-scoped URL，必须先 start/stop 访问，
    /// 再拷贝到临时目录读取。直接 `Data(contentsOf:)` 在真机上会因权限/iCloud 占位文件失败。
    static func readImportedData(from url: URL) throws -> Data {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try FileManager.default.copyItem(at: url, to: tempURL)
        return try Data(contentsOf: tempURL)
    }

    // MARK: - 角色卡导入（Pyramid 原生 + SillyTavern chara_card JSON / PNG 内嵌）

    static func parseCharacters(from data: Data) throws -> [Character] {
        if let native = try? JSONDecoder().decode(Character.self, from: data) {
            return [native]
        }
        if let list = try? JSONDecoder().decode([Character].self, from: data) {
            return list
        }
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let dict = object as? [String: Any] {
                return [parseSillyTavernCard(dict)]
            }
            if let array = object as? [[String: Any]] {
                return array.map { parseSillyTavernCard($0) }
            }
        }
        if let png = try? parsePngCharacters(data) {
            return png
        }
        throw CharacterImportError.invalidData
    }

    /// ST v1 字段在根层；ST v2 (chara_card_v2) 与 V3 (chara_card_v3) 字段在 `data` 子对象。
    /// 映射：name/description/personality/scenario/system_prompt/first_mes/alternate_greetings/
    ///      mes_example/creator_notes/post_history_instructions/tags/creator/character_version。
    /// 同时从 `data.extensions.regex_scripts` 读出 ST 角色内嵌的 Regex Script（保留原字段）。
    ///
    /// Phase 1（P1 数据保真层）：另外把以下 V3 字段整块写入 raw 通道，保证未知子结构零丢失：
    /// - `data.extensions`（除 `regex_scripts` 已单独消费） → `extensionsRaw`
    /// - `data.extensions.tavern_helper` → `tavernHelperRaw`（冗余存于 extensionsRaw）
    /// - `data.character_book` → `characterBookRaw`
    ///
    /// `internal`（非 private）以便 `@testable import PyramidCore` 的 SPM 测试访问。
    static func parseSillyTavernCard(_ json: [String: Any]) -> Character {
        let root = (json["data"] as? [String: Any]) ?? json
        var character = Character()
        character.name = (root["name"] as? String) ?? ""
        character.description = (root["description"] as? String) ?? ""
        character.personality = (root["personality"] as? String) ?? ""
        character.scenario = (root["scenario"] as? String) ?? ""
        character.systemPrompt = (root["system_prompt"] as? String) ?? ""
        character.firstMes = (root["first_mes"] as? String) ?? ""
        character.alternateGreetings = (root["alternate_greetings"] as? [String]) ?? []
        character.mesExample = (root["mes_example"] as? String) ?? ""
        character.creatorNotes = (root["creator_notes"] as? String) ?? ""
        character.postHistoryInstructions = (root["post_history_instructions"] as? String) ?? ""
        character.tags = (root["tags"] as? [String]) ?? []
        character.creator = (root["creator"] as? String) ?? ""
        character.characterVersion = (root["character_version"] as? String) ?? ""
        if let avatar = root["avatar"] as? String,
           let imageData = Data(base64Encoded: avatar) {
            character.avatarData = imageData
        }
        // ST 角色内嵌 regex scripts：`data.extensions.regex_scripts` 是 Regex Script 数组。
        // 失败 / 缺失 / 字段不是数组 → 当作没有，角色照样入库（不影响其它字段）。
        if let scripts = parseExtensionsRegexScripts(root: root) {
            character.extensionsRegexScripts = scripts
        }
        // P1 数据保真：把 V3 未知子结构整块写入 raw 通道。
        // 失败 / 缺失 → 字段留 nil（与 typed `extensionsRegexScripts` 行为一致：不阻塞入库）。
        applyRawPassthrough(root: root, into: &character)
        return character
    }

    /// 解析 `data.extensions.regex_scripts` → [SillyTavernRegexScript]。
    /// 失败（缺字段 / 类型错 / JSON 编码失败）一律返回 nil；调用方退化为空数组。
    private static func parseExtensionsRegexScripts(root: [String: Any]) -> [SillyTavernRegexScript]? {
        guard let extensions = root["extensions"] as? [String: Any] else { return nil }
        guard let raw = extensions["regex_scripts"] else { return nil }
        guard JSONSerialization.isValidJSONObject(raw) || raw is NSNull else { return nil }
        if raw is NSNull { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: []) else { return nil }
        return try? JSONDecoder().decode([SillyTavernRegexScript].self, from: data)
    }

    /// P1 V3 透传 + P2 typed lift：
    /// - extensions 整块（剥掉已 typed 的子键避免与 typed 字段重复）→ extensionsRaw
    /// - data.extensions.tavern_helper → tavernHelperRaw 便捷指针
    /// - data.character_book → characterBookRaw 整块
    /// - data.extensions.talkativeness → character.talkativeness
    /// - data.extensions.fav → character.isFavorite
    /// - data.extensions.depth_prompt → character.depthPrompt（失败保留 raw 不动）
    /// - data.extensions.init_stat_data → character.initStatData（MVU 初始变量树）
    /// 不抛错；解析失败一律留 nil，绝不影响已有字段。
    /// **类型守门**：`character_book` / `extensions` 只接受 dict 类型 —— 数组 / 字符串
    /// 等畸形输入不写入 raw，避免下游"以为有数据"误用。
    private static func applyRawPassthrough(root: [String: Any], into character: inout Character) {
        // 1) extensions 子结构：先 typed lift 再写 raw
        if var extensions = root["extensions"] as? [String: Any] {
            // 1a) tavernHelperRaw = data.extensions.tavern_helper 便捷指针（任何 JSONValue 都收）
            character.tavernHelperRaw = JSONValue.from(any: extensions["tavern_helper"])

            // 1b) talkativeness typed lift；NSNumber / Double 都收；clamp 0-1。
            if let v = extensions["talkativeness"] {
                let d: Double?
                if let n = v as? NSNumber { d = n.doubleValue }
                else if let dd = v as? Double { d = dd }
                else { d = nil }
                if let d {
                    character.talkativeness = min(max(d, 0.0), 1.0)
                }
                extensions.removeValue(forKey: "talkativeness")
            }

            // 1c) fav typed lift；只接 Bool。
            if let fav = extensions["fav"] as? Bool {
                character.isFavorite = fav
                extensions.removeValue(forKey: "fav")
            }

            // 1d) depth_prompt typed lift；解析失败保留 raw 不动（避免静默丢字段）。
            if let dpJSON = extensions["depth_prompt"].flatMap({ JSONValue.from(any: $0) }) {
                if let dp = CharacterDepthPrompt(json: dpJSON) {
                    character.depthPrompt = dp
                    extensions.removeValue(forKey: "depth_prompt")
                }
                // 解析失败 → 保留在 extensionsRaw 里，下游可手动消费或导出
            }

            // 1e) regex_scripts 既有剥离（避免与 typed extensionsRegexScripts 字段重复��
            extensions.removeValue(forKey: "regex_scripts")

            // 1f) init_stat_data typed lift（MVU 初始变量树）→ character.initStatData。
            // 必须是顶层 object；数组 / 字符串 / 数字 → 整段忽略（保留在 extensionsRaw 走 export）。
            // 解析失败（包括非 object）→ 留 nil，不影响其他字段；不阻断角色入库。
            // 允许空 object（等同"无 init"）—— 仍 lift 进去，避免与"字段缺失"混淆。
            if let initAny = extensions["init_stat_data"] {
                if let initObj = initAny as? [String: Any] {
                    var lifted: [String: JSONValue] = [:]
                    var allKeysConvertible = true
                    for (k, v) in initObj {
                        if let jv = JSONValue.from(any: v) {
                            lifted[k] = jv
                        } else {
                            allKeysConvertible = false
                            break
                        }
                    }
                    if allKeysConvertible {
                        character.initStatData = lifted
                        extensions.removeValue(forKey: "init_stat_data")
                    }
                }
                // 解析失败 → 保留在 extensionsRaw 里（不阻断导入）
            }

            // 1g) 剩余 extensions 写 extensionsRaw；空字典算"无扩展"
            if extensions.isEmpty {
                character.extensionsRaw = nil
            } else {
                character.extensionsRaw = JSONValue.from(any: extensions)
            }
        }

        // 2) characterBookRaw = data.character_book 整块；仅接受 dict
        if let book = root["character_book"] as? [String: Any] {
            character.characterBookRaw = JSONValue.from(any: book)
        }
    }

    /// SillyTavern 角色卡常以 PNG 分发，角色数据存在 tEXt chunk 的 `chara` 关键字中。
    private static func parsePngCharacters(_ data: Data) throws -> [Character] {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count > 8, Array(data.prefix(8)).elementsEqual(signature) else {
            throw CharacterImportError.invalidData
        }
        var offset = 8
        while offset + 8 <= data.count {
            let lengthBytes = [UInt8](data.subdata(in: offset..<(offset + 4)))
            let length = Int(lengthBytes[0]) << 24 | Int(lengthBytes[1]) << 16
                | Int(lengthBytes[2]) << 8 | Int(lengthBytes[3])
            offset += 4
            let type = String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii) ?? ""
            offset += 4
            guard offset + length <= data.count else { break }
            let chunk = data.subdata(in: offset..<(offset + length))
            offset += length + 4
            if type == "tEXt", let nul = chunk.firstIndex(of: 0) {
                let keyword = String(data: Data(chunk[..<nul]), encoding: .ascii) ?? ""
                if keyword == "chara" {
                    let value = Data(chunk[(nul + 1)...])
                    if let jsonData = charaJSONData(from: value),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        return [parseSillyTavernCard(json)]
                    }
                }
            }
        }
        throw CharacterImportError.invalidData
    }

    /// 酒馆 PNG 的 chara 数据通常是 zlib 压缩 + base64；个别实现直接放明文或纯 base64 JSON。
    private static func charaJSONData(from value: Data) -> Data? {
        if (try? JSONSerialization.jsonObject(with: value)) != nil { return value }
        if let inflated = inflateBase64(value),
           (try? JSONSerialization.jsonObject(with: inflated)) != nil { return inflated }
        if let b64String = String(data: value, encoding: .utf8),
           let plain = Data(base64Encoded: b64String),
           (try? JSONSerialization.jsonObject(with: plain)) != nil { return plain }
        return nil
    }

    private static func inflateBase64(_ value: Data) -> Data? {
        guard let b64String = String(data: value, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let compressed = Data(base64Encoded: b64String) else { return nil }
        let capacity = 2_000_000
        var output = [UInt8](repeating: 0, count: capacity)
        let decodedLength: Int = compressed.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!,
                    capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedLength > 0 else { return nil }
        return Data(output.prefix(decodedLength))
    }
}

enum CharacterImportError: LocalizedError {
    case invalidData

    var errorDescription: String? {
        "不是 Pyramid 或 SillyTavern 角色卡格式（支持 JSON 或 PNG 内嵌角色卡）"
    }
}