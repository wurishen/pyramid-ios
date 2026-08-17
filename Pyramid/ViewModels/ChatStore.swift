import Foundation
import SwiftUI

final class ChatStore: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var currentSessionID: UUID?

    var currentSession: ChatSession? {
        sessions.first { $0.id == currentSessionID }
    }

    var currentMessages: [ChatMessage] {
        currentSession?.messages ?? []
    }

    init() {
        load()
        if sessions.isEmpty {
            _ = createSession()
        } else if currentSessionID == nil {
            currentSessionID = sessions.first?.id
        }
    }

    @discardableResult
    func createSession() -> ChatSession {
        let session = ChatSession()
        sessions.insert(session, at: 0)
        currentSessionID = session.id
        save()
        return session
    }

    /// 创建并直接绑定角色卡到新会话。用于「角色卡 → 新建对话」入口。
    /// - Parameter greeting: 非空时，会作为会话的第一条助手消息（角色卡的开场白）。
    @discardableResult
    func createSession(character: Character, greeting: String? = nil) -> ChatSession {
        var session = ChatSession()
        session.characterId = character.id
        if !character.name.isEmpty {
            session.title = Self.uniqueTitle(base: character.name, excluding: nil, in: sessions)
        }
        let trimmedGreeting = greeting?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedGreeting.isEmpty {
            session.messages.append(
                ChatMessage(role: .assistant, content: trimmedGreeting)
            )
        }
        sessions.insert(session, at: 0)
        currentSessionID = session.id
        save()
        return session
    }

    /// 同名角色卡再建新窗时，自动在名字后追加 1 / 2 / 3…，
    /// 避免「会话列表里两条同名 → 用户分不清」的问题。
    static func uniqueTitle(base: String, excluding currentID: UUID?, in sessions: [ChatSession]) -> String {
        let taken = Set(sessions.filter { $0.id != currentID }.map { $0.title })
        if !taken.contains(base) { return base }
        var index = 1
        while taken.contains("\(base)\(index)") {
            index += 1
        }
        return "\(base)\(index)"
    }

    /// 同一角色是否已绑定到其他会话（用于去重提醒）。
    func hasOtherSession(for characterID: UUID, excluding currentID: UUID) -> Bool {
        sessions.contains { $0.characterId == characterID && $0.id != currentID }
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        currentSessionID = id
        save()
    }

    func clearAllSessions() {
        sessions.removeAll()
        currentSessionID = nil
        _ = createSession()
    }

    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if currentSessionID == id {
            currentSessionID = sessions.first?.id
            if currentSessionID == nil {
                _ = createSession()
                return
            }
        }
        save()
    }

    func appendMessage(_ message: ChatMessage, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.append(message)
        if sessions[index].title == "新会话" {
            sessions[index].title = Self.defaultTitle(for: message.content)
        }
        save()
    }

    func updateMessage(content: String, id: UUID, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        sessions[sessionIndex].messages[messageIndex].content = content
        save()
    }

    func removeMessage(id: UUID, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[sessionIndex].messages.removeAll { $0.id == id }
        save()
    }

    func removeMessages(from id: UUID, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let start = sessions[sessionIndex].messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        sessions[sessionIndex].messages.removeSubrange(start...)
        save()
    }

    /// 切换某条消息的「包含在上下文」标记。被排除的消息仍会在 UI 显示，但不会送进 API。
    /// 当前正在请求的用户消息始终会被强制送入（见 ChatViewModel.applyContextTrim）。
    func setMessageIncluded(_ included: Bool, for id: UUID, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        sessions[sessionIndex].messages[messageIndex].isIncluded = included
        save()
    }

    func setWorldBook(_ worldBookId: UUID?, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].worldBookId = worldBookId
        save()
    }

    func setSystemPrompt(_ systemPrompt: String?, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].systemPrompt = systemPrompt
        save()
    }

    func setAppliedPreset(_ presetId: UUID?, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].appliedPresetId = presetId
        save()
    }

    func setCharacter(_ characterId: UUID?, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].characterId = characterId
        save()
    }

    func setUserDisplayNameOverride(_ name: String, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].userDisplayNameOverride = name
        save()
    }

    func setExtraWorldBookIds(_ ids: [UUID], for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].extraWorldBookIds = ids
        save()
    }

    func rename(_ sessionID: UUID, to newTitle: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[index].title = trimmed.isEmpty ? "新会话" : trimmed
        save()
    }

    func togglePinned(_ sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].isPinned.toggle()
        save()
    }

    func setDraft(_ draft: String, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if sessions[index].draft != draft {
            sessions[index].draft = draft
            save()
        }
    }

    /// 列表展示顺序：置顶在前，其余保持插入顺序。
    func orderedSessions() -> [ChatSession] {
        sessions.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private static func defaultTitle(for content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 20
        if trimmed.count <= maxLength {
            return trimmed
        }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<end]) + "…"
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: StorageKeys.sessions),
           let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) {
            sessions = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: StorageKeys.currentSessionID),
           let uuid = UUID(uuidString: raw) {
            currentSessionID = uuid
        }
    }

    // MARK: - 持久化（节流写盘）
    //
    // 旧实现是每次 mutate 立即 `JSONEncoder().encode(sessions)` + UserDefaults 写：
    // streaming 一个 1000-token 回复 = 主线程 1000 次全量编码 + 写盘，开销巨大。
    // 现在改为：mutate → `save()` 排一个 250ms 的去抖任务，期间重复 mutate 只重置定时器；
    // scenePhase 切到 .background/.inactive 时 `flushPendingSave()` 强制立即落盘，
    // 保证 OS kill 前数据安全。
    private var pendingSaveTask: Task<Void, Never>?
    private static let saveDebounceNanoseconds: UInt64 = 250_000_000

    func save() {
        scheduleSave(after: Self.saveDebounceNanoseconds)
    }

    /// 强制立即落盘：取消排队的去抖任务，同步执行一次 encode + write。
    /// 退出前台 / 切到后台时调用，确保数据安全。
    func flushPendingSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        performSaveNow()
    }

    private func scheduleSave(after nanoseconds: UInt64) {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled { return }
            self?.pendingSaveTask = nil
            self?.performSaveNow()
        }
    }

    private func performSaveNow() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: StorageKeys.sessions)
        }
        UserDefaults.standard.set(currentSessionID?.uuidString, forKey: StorageKeys.currentSessionID)
    }
}

private enum StorageKeys {
    static let sessions = "chatSessions"
    static let currentSessionID = "currentSessionID"
}
