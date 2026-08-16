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

    /// ST v1 字段在根层；ST v2 (chara_card_v2) 字段在 `data` 子对象。
    /// 映射：name/description/personality/scenario/system_prompt。
    private static func parseSillyTavernCard(_ json: [String: Any]) -> Character {
        let root = (json["data"] as? [String: Any]) ?? json
        var character = Character()
        character.name = (root["name"] as? String) ?? ""
        character.description = (root["description"] as? String) ?? ""
        character.personality = (root["personality"] as? String) ?? ""
        character.scenario = (root["scenario"] as? String) ?? ""
        character.systemPrompt = (root["system_prompt"] as? String) ?? ""
        if let avatar = root["avatar"] as? String,
           let imageData = Data(base64Encoded: avatar) {
            character.avatarData = imageData
        }
        return character
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
        var buffer = [UInt8](repeating: 0, count: 2_000_000)
        let decodedLength = compressed.withUnsafeBytes { src in
            buffer.withUnsafeMutableBytes { dst in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!,
                    buffer.count,
                    src.bindMemory(to: UInt8.self).baseAddress!,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedLength > 0 else { return nil }
        return Data(buffer.prefix(decodedLength))
    }
}

enum CharacterImportError: LocalizedError {
    case invalidData

    var errorDescription: String? {
        "不是 Pyramid 或 SillyTavern 角色卡格式（支持 JSON 或 PNG 内嵌角色卡）"
    }
}