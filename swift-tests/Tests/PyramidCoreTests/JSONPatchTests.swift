import XCTest
@testable import PyramidCore

/// JSONPatchApplier 的纯算法覆盖：
/// - RFC 6902 replace / add / remove 三 op 在嵌套 JSON 树上的行为。
/// - JSON Pointer path 解析：`/foo/bar` → `["foo", "bar"]`，含 `~1` / `~0` 解码。
/// - `_` 私有前缀 path 在协议层静默 skip（fixture `mvu_output_contract.ignored_path_prefix`）。
/// - 失败路径：replace/remove 缺失 / 不支持 op → 抛错且不污染原树。
///
/// 不依赖 SwiftUI；VariableStore 类不参与本测试（apply 是 static）。
final class JSONPatchTests: XCTestCase {

    // MARK: - 路径解析

    func testParsePathRoot() {
        XCTAssertEqual(JSONPatchApplier.parsePath("/"), [])
    }

    func testParsePathSingle() {
        XCTAssertEqual(JSONPatchApplier.parsePath("/时间"), ["时间"])
    }

    func testParsePathNested() {
        XCTAssertEqual(JSONPatchApplier.parsePath("/玩家/当前所在地"), ["玩家", "当前所在地"])
    }

    func testParsePathEscapes() {
        XCTAssertEqual(JSONPatchApplier.parsePath("/foo~1bar/baz~0qux"), ["foo/bar", "baz~qux"])
    }

    func testParsePathNoLeadingSlashIsInvalid() {
        XCTAssertEqual(JSONPatchApplier.parsePath("时间"), [])
    }

    // MARK: - replace

    func testReplaceExistingKey() throws {
        var tree: JSONValue = .object(["HP": .int(100)])
        let patches = [JSONPatchOperation(op: .replace, path: "/HP", value: .int(80))]
        let count = try JSONPatchApplier.apply(patches, to: &tree)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(tree, .object(["HP": .int(80)]))
    }

    func testReplaceMissingKeyThrows() {
        var tree: JSONValue = .object([:])
        let patches = [JSONPatchOperation(op: .replace, path: "/HP", value: .int(80))]
        XCTAssertThrowsError(try JSONPatchApplier.apply(patches, to: &tree))
    }

    func testReplaceNestedPath() throws {
        var tree: JSONValue = .object([
            "玩家": .object(["当前所在地": .string("旅店")])
        ])
        let patches = [JSONPatchOperation(
            op: .replace,
            path: "/玩家/当前所在地",
            value: .string("集市")
        )]
        let count = try JSONPatchApplier.apply(patches, to: &tree)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(tree, .object([
            "玩家": .object(["当前所在地": .string("集市")])
        ]))
    }

    // MARK: - add

    func testAddToEmptyObject() throws {
        var tree: JSONValue = .object([:])
        let patches = [JSONPatchOperation(op: .add, path: "/HP", value: .int(100))]
        XCTAssertEqual(try JSONPatchApplier.apply(patches, to: &tree), 1)
        XCTAssertEqual(tree, .object(["HP": .int(100)]))
    }

    func testAddPreservesExistingKeys() throws {
        var tree: JSONValue = .object(["HP": .int(100)])
        let patches = [JSONPatchOperation(op: .add, path: "/MP", value: .int(50))]
        XCTAssertEqual(try JSONPatchApplier.apply(patches, to: &tree), 1)
        XCTAssertEqual(tree, .object(["HP": .int(100), "MP": .int(50)]))
    }

    // MARK: - remove

    func testRemoveExistingKey() throws {
        var tree: JSONValue = .object(["HP": .int(100), "MP": .int(50)])
        let patches = [JSONPatchOperation(op: .remove, path: "/MP")]
        XCTAssertEqual(try JSONPatchApplier.apply(patches, to: &tree), 1)
        XCTAssertEqual(tree, .object(["HP": .int(100)]))
    }

    func testRemoveMissingKeyThrows() {
        var tree: JSONValue = .object(["HP": .int(100)])
        let patches = [JSONPatchOperation(op: .remove, path: "/MP")]
        XCTAssertThrowsError(try JSONPatchApplier.apply(patches, to: &tree))
    }

    func testRemoveNestedPath() throws {
        var tree: JSONValue = .object([
            "玩家": .object(["当前所在地": .string("旅店"), "HP": .int(100)])
        ])
        let patches = [JSONPatchOperation(op: .remove, path: "/玩家/当前所在地")]
        XCTAssertEqual(try JSONPatchApplier.apply(patches, to: &tree), 1)
        XCTAssertEqual(tree, .object([
            "玩家": .object(["HP": .int(100)])
        ]))
    }

    // MARK: - 批量事务

    func testBatchStopsAtFirstFailure() {
        // 第二条 op 会失败 → 第一条不该写入（事务语义）。
        var tree: JSONValue = .object(["HP": .int(100)])
        let patches = [
            JSONPatchOperation(op: .replace, path: "/HP", value: .int(80)),
            JSONPatchOperation(op: .remove, path: "/NOTHING")
        ]
        XCTAssertThrowsError(try JSONPatchApplier.apply(patches, to: &tree))
        XCTAssertEqual(tree, .object(["HP": .int(100)]), "事务失败时原树不应被部分污染")
    }

    // MARK: - 私有前缀

    func testPrivatePrefixPathIsSkipped() throws {
        // /_ui/scroll 不该写入，但 applied 计数仍 +1（让 UI 知道「有 op 被协议层吃掉了」）。
        var tree: JSONValue = .object(["HP": .int(100)])
        let op = JSONPatchOperation(op: .add, path: "/_ui/scroll", value: .int(42))
        XCTAssertTrue(op.isPrivatePath)
        let count = try JSONPatchApplier.apply([op], to: &tree)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(tree, .object(["HP": .int(100)]))
    }

    func testBareUnderscorePathIsSkipped() {
        let op = JSONPatchOperation(op: .replace, path: "/_", value: .int(1))
        XCTAssertTrue(op.isPrivatePath)
    }

    func testLeadingSlashUnderscoreIsPrivate() {
        let op = JSONPatchOperation(op: .add, path: "/_anything", value: .int(1))
        XCTAssertTrue(op.isPrivatePath)
    }

    func testUnderscoreInMiddleIsNotPrivate() {
        let op = JSONPatchOperation(op: .add, path: "/foo_bar", value: .int(1))
        XCTAssertFalse(op.isPrivatePath)
    }

    // MARK: - Codable round-trip

    func testOperationCodableRoundTrip() throws {
        let original = JSONPatchOperation(op: .replace, path: "/玩家/当前所在地", value: .string("集市"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONPatchOperation.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testOperationDecodingRejectsUnknownOp() throws {
        // op=test 不在 allow-list → 解析失败。
        let json = #"{"op":"test","path":"/foo","value":1}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(JSONPatchOperation.self, from: data))
    }
}