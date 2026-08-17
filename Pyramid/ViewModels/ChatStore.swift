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
    @discardableResult
    func createSession(character: Character) -> ChatSession {
        var session = ChatSession()
        session.characterId = character.id
        if !character.name.isEmpty {
            session.title = character.name
        }
        sessions.insert(session, at: 0)
        currentSessionID = session.id
        save()
        return session
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

    func save() {
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
