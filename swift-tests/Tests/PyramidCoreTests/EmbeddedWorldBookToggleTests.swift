import XCTest
@testable import PyramidCore

/// 内嵌世界书启用开关的测试。
///
/// 用户反馈：内嵌书被藏在角色卡里，无法逐条开关 / 改内容。Phase 2 后，
/// 角色卡持有 `embeddedWorldBookId` + `isEmbeddedWorldBookEnabled`：
/// - `isEmbeddedWorldBookEnabled == true`（默认）→ 进聊天时随该角色注入。
/// - `isEmbeddedWorldBookEnabled == false` → 跳过；用户仍可在 WorldBookView 里
///   直接打开并编辑条目（UX 已修）。
///
/// 测试覆盖：
/// - Character 字段默认 / 显式 / Codable 双向。
/// - 旧数据无此字段 → decodeIfPresent 兜底为 true（不破坏老用户）。
/// - 与「全局启用」正交：embedded 书永远非全局启用，开关只影响「该角色本次聊天」注入。
final class EmbeddedWorldBookToggleTests: XCTestCase {

    // MARK: - 默认值 / 显式值

    func testDefaultsToEnabled() {
        let character = Character(name: "T")
        XCTAssertTrue(character.isEmbeddedWorldBookEnabled)
        XCTAssertNil(character.embeddedWorldBookId)
    }

    func testExplicitFalse() {
        let character = Character(
            name: "T",
            embeddedWorldBookId: UUID(),
            isEmbeddedWorldBookEnabled: false
        )
        XCTAssertFalse(character.isEmbeddedWorldBookEnabled)
        XCTAssertNotNil(character.embeddedWorldBookId)
    }

    // MARK: - Codable

    func testRoundTripPreservesFalse() throws {
        let id = UUID()
        let character = Character(
            name: "Round",
            embeddedWorldBookId: id,
            isEmbeddedWorldBookEnabled: false
        )
        let data = try JSONEncoder().encode(character)
        let decoded = try JSONDecoder().decode(Character.self, from: data)
        XCTAssertEqual(decoded.isEmbeddedWorldBookEnabled, false)
        XCTAssertEqual(decoded.embeddedWorldBookId, id)
    }

    func testRoundTripPreservesTrue() throws {
        let character = Character(
            name: "Round true",
            embeddedWorldBookId: UUID(),
            isEmbeddedWorldBookEnabled: true
        )
        let data = try JSONEncoder().encode(character)
        let decoded = try JSONDecoder().decode(Character.self, from: data)
        XCTAssertTrue(decoded.isEmbeddedWorldBookEnabled)
    }

    /// 旧角色卡 JSON 无 `isEmbeddedWorldBookEnabled` 字段 → 默认 true。
    /// 防止老用户升级后「内嵌书突然停用」行为突变。
    func testLegacyJSONDecodesAsEnabled() throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Legacy",
            "embeddedWorldBookId": UUID().uuidString
            // 故意缺 isEmbeddedWorldBookEnabled
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(Character.self, from: data)
        XCTAssertTrue(decoded.isEmbeddedWorldBookEnabled,
                      "缺字段应兜底为 true，避免老用户升级突变")
    }

    /// 全新建角色（连 embeddedWorldBookId 都没有） → 开关字段仍为 true，
    /// 字段不存在时 UI 隐藏整段，不影响其它行为。
    func testNoEmbeddedBookStillDefaultsToEnabled() throws {
        let character = Character(name: "Bare")
        XCTAssertNil(character.embeddedWorldBookId)
        XCTAssertTrue(character.isEmbeddedWorldBookEnabled)
    }

    // MARK: - 与 WorldBook 语义正交

    /// 内嵌书的「isGloballyEnabled 永远为 false」语义由
    /// `WorldBookStore.adoptEmbeddedWorldBook` 保证（不在 SPM 内）；
    /// 这里只验证 Character 字段本身与全局启用开关正交 —— 即：
    /// 用户可把「角色开关」单独置 false，而不动 WorldBook 的全局位。
    func testToggleIsIndependentOfGlobalEnabled() throws {
        let character = Character(
            name: "Orth",
            embeddedWorldBookId: UUID(),
            isEmbeddedWorldBookEnabled: false
        )
        let book = WorldBook(
            title: "Embedded",
            isGloballyEnabled: false   // adoptEmbeddedWorldBook 的语义
        )
        // 字符端：开关 = false（用户关）
        XCTAssertFalse(character.isEmbeddedWorldBookEnabled)
        // 书端：全局启用 = false（构造语义）
        XCTAssertFalse(book.isGloballyEnabled)
        // 两个字段各自携带自己的真相，互不耦合 → 角色端切回 true 后
        // activeBooks 的 embedded 分支会再次入选（参见 WorldBookStore.activeBooks）。
    }

    // MARK: - 与 V3 lift 字段共存

    /// 同一角色卡同时持有 V3 内嵌书 + lift 字段（depthPrompt / talkativeness /
    /// fav）→ toggle 应正常持久化，不与 typed lift 字段冲突。
    func testToggleCoexistsWithV3Lift() throws {
        let character = Character(
            name: "Both",
            embeddedWorldBookId: UUID(),
            isEmbeddedWorldBookEnabled: false,
            talkativeness: 0.42,
            isFavorite: true,
            depthPrompt: CharacterDepthPrompt(
                role: .system,
                depth: 0,
                content: "stay in character",
                position: .before
            )
        )
        let data = try JSONEncoder().encode(character)
        let decoded = try JSONDecoder().decode(Character.self, from: data)
        XCTAssertFalse(decoded.isEmbeddedWorldBookEnabled)
        XCTAssertEqual(decoded.talkativeness, 0.42)
        XCTAssertEqual(decoded.isFavorite, true)
        XCTAssertNotNil(decoded.depthPrompt)
        XCTAssertEqual(decoded.depthPrompt?.position, .before)
    }
}
