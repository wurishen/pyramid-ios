import Foundation

/// 递归 JSON 值类型。Codable 完整，可作为"未知结构透传"通道：
/// 替代 `[String: Any]` 写入 `Character.extensionsRaw` / `tavernHelperRaw` /
/// `characterBookRaw` 等 SillyTavern V3 字段，保证导入 → 持久化 → 导出 round-trip
/// 不丢失 Pyramid 当前未建模的子结构。
///
/// 序列化优先级（与 JSON 实际类型一致）：null > bool > int > double > string > array > object。
/// `JSONSerialization` 把所有数字默认成 `NSNumber`；本类型解码时优先按 Int 试，
/// 失败再 Double —— 与 ST V3 JSON 数值实际语义匹配（ID/position 用整数，权重/概率用小数）。
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let v = try? c.decode(Bool.self) {
            self = .bool(v)
            return
        }
        if let v = try? c.decode(Int.self) {
            self = .int(v)
            return
        }
        if let v = try? c.decode(Double.self) {
            self = .double(v)
            return
        }
        if let v = try? c.decode(String.self) {
            self = .string(v)
            return
        }
        if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
            return
        }
        if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
            return
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "JSONValue: 无法识别的 JSON 类型"
        ))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:
            try c.encodeNil()
        case .bool(let v):
            try c.encode(v)
        case .int(let v):
            try c.encode(v)
        case .double(let v):
            try c.encode(v)
        case .string(let v):
            try c.encode(v)
        case .array(let v):
            try c.encode(v)
        case .object(let v):
            try c.encode(v)
        }
    }

    /// 从 `JSONSerialization` 返回的 `Any` 桥接到 `JSONValue`。
    /// nil / NSNull / 不支持的类型（Date / Data / URL 等）→ 返回 nil；
    /// 调用方应据此区分"字段缺失"与"字段存在但值为 null"。
    static func from(any: Any?) -> JSONValue? {
        guard let any = any else { return nil }
        if any is NSNull { return .null }
        if let v = any as? Bool { return .bool(v) }
        // JSONSerialization 在 ObjC 桥接下把所有数字解析为 NSNumber；
        // Swift 端先用 Bool 检查（已上一步过滤），再用 Int64、Double 顺序匹配，
        // 最后保留 Decimal 兜底（避免精度损失）。
        if let v = any as? NSNumber {
            if CFNumberGetType(v) == .charType || CFNumberGetType(v) == .sInt8Type
                || CFNumberGetType(v) == .sInt16Type || CFNumberGetType(v) == .sInt32Type
                || CFNumberGetType(v) == .sInt64Type || CFNumberGetType(v) == .nsIntegerType
                || CFNumberGetType(v) == .shortType || CFNumberGetType(v) == .intType
                || CFNumberGetType(v) == .longType || CFNumberGetType(v) == .longLongType
                || CFNumberGetType(v) == .cfIndexType {
                return .int(v.intValue)
            }
            return .double(v.doubleValue)
        }
        if let v = any as? String { return .string(v) }
        if let v = any as? [Any] {
            var arr: [JSONValue] = []
            arr.reserveCapacity(v.count)
            for item in v {
                guard let jv = from(any: item) else { return nil }
                arr.append(jv)
            }
            return .array(arr)
        }
        if let v = any as? [String: Any] {
            var obj: [String: JSONValue] = [:]
            for (k, val) in v {
                guard let jv = from(any: val) else { return nil }
                obj[k] = jv
            }
            return .object(obj)
        }
        return nil
    }
}