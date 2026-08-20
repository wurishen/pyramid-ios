import Foundation

/// RFC 6902 JSON Patch operation（sub-set：replace / add / remove）。
///
/// Pyramid 原生 MVU 路径只消费这三个 op；test / move / copy 不在协议范围内，
/// 解析时静默丢弃（与 fixture `mvu_output_contract.allowed_ops` 对齐）。
///
/// **path 语义**：以 `/` 开头的 JSON Pointer；path 段需 `percent-decoded`。
/// **path 忽略规则**：以 `_` 开头的 path 被视为「私有字段 / 视图态」不写入 stat_data
///（参见 fixture `mvu_output_contract.ignored_path_prefix`）。
struct JSONPatchOperation: Codable, Equatable, Sendable {
    enum Op: String, Codable, Sendable {
        case replace
        case add
        case remove
    }

    var op: Op
    var path: String
    /// 仅 replace / add 需要；remove 允许 nil。
    var value: JSONValue?

    init(op: Op, path: String, value: JSONValue? = nil) {
        self.op = op
        self.path = path
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawOp = try c.decode(String.self, forKey: .op)
        guard let parsed = Op(rawValue: rawOp) else {
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unsupported op: \(rawOp)")
        }
        op = parsed
        path = try c.decode(String.self, forKey: .path)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey {
        case op, path, value
    }

    /// `_` 开头的 path 在协议层被忽略 —— 不参与写入。
    /// 静默 no-op，让协议对未建模的视图态保持宽容。
    var isPrivatePath: Bool {
        path.hasPrefix("/_") || path == "/_"
    }
}

/// 把 `[JSONPatchOperation]` 应用到一棵 JSON 树（mutable in-place）。
/// 单 op 失败（path 不存在 / 类型错 / remove 路径缺失）→ 抛错（不写脏数据）。
///
/// 路径解析：JSON Pointer 的最小实现 —— `/` 分段 + `~1` / `~0` 解码。
enum JSONPatchApplier {
    /// - Returns: 实际生效的 op 数量（`isPrivatePath` 的 op 计入但只 skip 不写）。
    static func apply(_ patches: [JSONPatchOperation], to root: inout JSONValue) throws -> Int {
        var snapshot = root
        var applied = 0
        for patch in patches {
            if patch.isPrivatePath {
                applied += 1
                continue
            }
            try applyOne(patch, root: &snapshot)
            applied += 1
        }
        root = snapshot
        return applied
    }

    private static func applyOne(_ patch: JSONPatchOperation, root: inout JSONValue) throws {
        let segments = parsePath(patch.path)
        guard !segments.isEmpty else {
            throw JSONPatchError.invalidPath(patch.path)
        }
        try mutateRecursive(root: &root, segments: segments, index: 0, op: patch)
    }

    /// 递归走路径，到叶子段时 mutate。
    private static func mutateRecursive(
        root: inout JSONValue,
        segments: [String],
        index: Int,
        op: JSONPatchOperation
    ) throws {
        let key = segments[index]
        let isLeaf = (index == segments.count - 1)
        switch root {
        case .object(var dict):
            if isLeaf {
                switch op.op {
                case .replace:
                    guard dict[key] != nil else { throw JSONPatchError.pathNotFound(op.path) }
                    dict[key] = op.value ?? .null
                case .add:
                    dict[key] = op.value ?? .null
                case .remove:
                    guard dict.removeValue(forKey: key) != nil else { throw JSONPatchError.pathNotFound(op.path) }
                }
                root = .object(dict)
            } else {
                guard var next = dict[key] else { throw JSONPatchError.pathNotFound(op.path) }
                try mutateRecursive(root: &next, segments: segments, index: index + 1, op: op)
                dict[key] = next
                root = .object(dict)
            }
        case .array(var arr):
            guard let idx = Int(key), idx >= 0, idx <= arr.count else {
                throw JSONPatchError.invalidPath(op.path)
            }
            if isLeaf {
                switch op.op {
                case .replace:
                    guard idx < arr.count else { throw JSONPatchError.pathNotFound(op.path) }
                    arr[idx] = op.value ?? .null
                case .add:
                    arr.insert(op.value ?? .null, at: idx)
                case .remove:
                    guard idx < arr.count else { throw JSONPatchError.pathNotFound(op.path) }
                    arr.remove(at: idx)
                }
                root = .array(arr)
            } else {
                guard idx < arr.count else { throw JSONPatchError.pathNotFound(op.path) }
                var next = arr[idx]
                try mutateRecursive(root: &next, segments: segments, index: index + 1, op: op)
                arr[idx] = next
                root = .array(arr)
            }
        default:
            throw JSONPatchError.invalidPath(op.path)
        }
    }

    /// JSON Pointer 解析：`/时间` → ["时间"]；`/玩家/当前所在地` → ["玩家", "当前所在地"]。
    /// 仅支持基本分段（按 `/` 切分 + `~1` / `~0` 解码），不实现完整 RFC 6901 —— 足够 fixture 形态。
    static func parsePath(_ path: String) -> [String] {
        guard path.hasPrefix("/") else { return [] }
        let body = String(path.dropFirst())
        if body.isEmpty { return [] }
        return body.split(separator: "/").map { segment in
            segment
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
        }
    }
}

enum JSONPatchError: Error, Equatable {
    case invalidPath(String)
    case pathNotFound(String)
}
