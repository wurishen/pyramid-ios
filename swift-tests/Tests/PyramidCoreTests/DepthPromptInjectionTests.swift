import XCTest
@testable import PyramidCore

/// Phase 2 runtime injection 测试。
///
/// `DepthPromptInjector` 是 `enum` 的两个 `static func`，无副作用、无状态。
/// 测的是「`CharacterDepthPrompt` → `history` 副本的修改 / system 段拼入」。
///
/// 与 `ChatViewModel.request` 集成由 caller 负责（switch (role, position)），
/// 这里只覆盖 `DepthPromptInjector` 自身的语义。
final class DepthPromptInjectionTests: XCTestCase {

    // MARK: - injectInChat 基础

    /// depth=0 → 末条之后插入（最常见：ST 默认 depth=4 但也允许 0）。
    func testInjectInChatDepthZeroInsertsAtTail() {
        var history = sampleHistory()
        let originalCount = history.count
        let dp = CharacterDepthPrompt(role: .user, depth: 0, content: "tail!")
        DepthPromptInjector.injectInChat(history: &history, prompt: dp)
        XCTAssertEqual(history.count, originalCount + 1)
        XCTAssertEqual(history.last?.content, "tail!")
        XCTAssertEqual(history.last?.role, .user)
    }

    /// depth=history.count → 首条之前插入（depth 边界）。
    func testInjectInChatDepthEqualsCountInsertsAtHead() {
        var history = sampleHistory()
        let count = history.count
        let dp = CharacterDepthPrompt(role: .user, depth: count, content: "head!")
        DepthPromptInjector.injectInChat(history: &history, prompt: dp)
        XCTAssertEqual(history.count, count + 1)
        XCTAssertEqual(history.first?.content, "head!")
    }

    /// depth > history.count → clamp 到 count（实际等于 depth=count，插到首条之前）。
    func testInjectInChatDepthExceedsCountClamped() {
        var history = sampleHistory()
        let count = history.count
        let dp = CharacterDepthPrompt(role: .assistant, depth: 999, content: "clamp!")
        DepthPromptInjector.injectInChat(history: &history, prompt: dp)
        XCTAssertEqual(history.count, count + 1)
        // clamp(depth=999, 0, count) == count → 插到首条之前
        XCTAssertEqual(history.first?.content, "clamp!")
    }

    /// depth < 0 → clamp 到 0（等价于 depth=0 → 末条之后）。
    func testInjectInChatNegativeDepthClampedToZero() {
        var history = sampleHistory()
        let originalCount = history.count
        let dp = CharacterDepthPrompt(role: .user, depth: -5, content: "neg!")
        DepthPromptInjector.injectInChat(history: &history, prompt: dp)
        XCTAssertEqual(history.count, originalCount + 1)
        XCTAssertEqual(history.last?.content, "neg!")
    }

    /// 空 history + depth=0 → clamp 到 0 → 插到首条（也是末条）。
    func testInjectInChatEmptyHistory() {
        var history: [ChatMessage] = []
        let dp = CharacterDepthPrompt(role: .user, depth: 0, content: "solo")
        DepthPromptInjector.injectInChat(history: &history, prompt: dp)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.content, "solo")
    }

    // MARK: - injectInChat role 派发

    /// role=.assistant → ChatMessage.Role.assistant。
    func testInjectInChatAssistantRole() {
        var history = sampleHistory()
        let dp = CharacterDepthPrompt(role: .assistant, depth: 0, content: "asr")
        DepthPromptInjector.injectInChat(history: &history, prompt: dp)
        XCTAssertEqual(history.last?.role, .assistant)
        XCTAssertEqual(history.last?.content, "asr")
    }

    /// role=.user → ChatMessage.Role.user。
    func testInjectInChatUserRole() {
        var history = sampleHistory()
        let dp = CharacterDepthPrompt(role: .user, depth: 0, content: "usr")
        DepthPromptInjector.injectInChat(history: &history, prompt: dp)
        XCTAssertEqual(history.last?.role, .user)
        XCTAssertEqual(history.last?.content, "usr")
    }

    /// role=.system + position=.inChat → no-op（`ChatMessage.Role` 只 user / assistant，
    /// system 不走 history；caller 改走 `systemAppendage`）。
    func testInjectInChatSystemRoleIsNoOp() {
        var history = sampleHistory()
        let originalCount = history.count
        let dp = CharacterDepthPrompt(role: .system, depth: 2, content: "sys")
        DepthPromptInjector.injectInChat(history: &history, prompt: dp)
        XCTAssertEqual(history.count, originalCount, "system role + inChat → 静默 no-op")
    }

    // MARK: - injectInChat 空 content

    /// content 为空字符串 → 不注入（trim 后为空也算空）。
    func testInjectInChatEmptyContentNoOp() {
        var history = sampleHistory()
        let originalCount = history.count
        let dp = CharacterDepthPrompt(role: .user, depth: 0, content: "")
        DepthPromptInjector.injectInChat(history: &history, prompt: dp)
        XCTAssertEqual(history.count, originalCount)
    }

    /// content 仅含空白字符 → 同样不注入。
    func testInjectInChatWhitespaceOnlyNoOp() {
        var history = sampleHistory()
        let originalCount = history.count
        let dp = CharacterDepthPrompt(role: .user, depth: 0, content: "   \n\n\t  ")
        DepthPromptInjector.injectInChat(history: &history, prompt: dp)
        XCTAssertEqual(history.count, originalCount)
    }

    // MARK: - systemAppendage

    /// 非空 content → 原样返回（caller 自己拼 "\n\n" 前缀）。
    func testSystemAppendageReturnsContent() {
        let dp = CharacterDepthPrompt(role: .system, depth: 0, content: "before-text", position: .before)
        let result = DepthPromptInjector.systemAppendage(prompt: dp)
        XCTAssertEqual(result, "before-text")
    }

    /// 空 content → 返回空字符串（caller 看到空字符串就知道不拼接）。
    func testSystemAppendageEmptyContent() {
        let dp = CharacterDepthPrompt(role: .system, depth: 0, content: "", position: .before)
        let result = DepthPromptInjector.systemAppendage(prompt: dp)
        XCTAssertEqual(result, "")
    }

    /// systemAppendage 对所有 role 一视同仁（position=.before/after 路径共用）。
    func testSystemAppendageAllRoles() {
        for role in [CharacterDepthPrompt.Role.system, .user, .assistant] {
            let dp = CharacterDepthPrompt(role: role, depth: 0, content: "x", position: .after)
            XCTAssertEqual(DepthPromptInjector.systemAppendage(prompt: dp), "x")
        }
    }

    // MARK: - 不可变性

    /// inout 修改后的 history 不影响 caller 原本的 reference 之外的副本。
    /// （Swift 数组是 value type，inout 是「copy-in / copy-out」语义，这里只是再次确认
    /// history 的内容已被修改 —— 不要 leak 出新数组。）
    func testInOutMutationModifiesArray() {
        var history = sampleHistory()
        let snapshotBefore = history
        let dp = CharacterDepthPrompt(role: .user, depth: 1, content: "mid")
        DepthPromptInjector.injectInChat(history: &history, prompt: dp)
        XCTAssertNotEqual(history, snapshotBefore)
    }

    // MARK: - 私有辅助

    private func sampleHistory() -> [ChatMessage] {
        [
            ChatMessage(role: .user, content: "u1"),
            ChatMessage(role: .assistant, content: "a1"),
            ChatMessage(role: .user, content: "u2"),
        ]
    }
}
