import Foundation
import SwiftUI

final class ChatStore: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var currentSessionID: UUID?

    var currentSession: ChatSession? {
        session(for: currentSessionID)
    }

    var currentMessages: [ChatMessage] {
        currentSession?.messages ?? []
    }

    // MARK: - Item 8 M6：SessionDetailView 去重扫描
    //
    // 旧实现每个 binding getter 都 `sessions.first { $0.id == sessionID }`：
    // N 个会话 × 6 个 binding = 6N 次线性扫描。ChatSession.id 在本进程内全局唯一，
    // 用一个 session 计数 + 缓存字典做 O(1) 查询；sessions 任何 mutation
    // 都让缓存作废，下次取时一次性重建。
    private var _sessionByIDCache: [UUID: ChatSession]?
    private var _sessionByIDCacheVersion: Int = -1
    /// 自增 ID；任何对 `sessions` 的 mutate 都必须调用一次。
    /// 提供给 ChatStore 自己的 mutator 内部使用；外部读取走 `session(for:)`。
    private var sessionsVersion: Int = 0

    func session(for id: UUID?) -> ChatSession? {
        guard let id else { return nil }
        if _sessionByIDCacheVersion != sessionsVersion || _sessionByIDCache == nil {
            // 用普通循环而非 Dictionary(uniqueKeysWithValues:)，避免重复 UUID 触发 trap。
            // 正常路径下会话 id 都是 UUID() 唯一值，但旧数据 / 损坏 JSON 可能出现重复：
            // 取首次出现的会话作为兜底，避免单条重复就把整个查询路径炸掉。
            var built: [UUID: ChatSession] = [:]
            for session in sessions {
                if built[session.id] == nil {
                    built[session.id] = session
                }
            }
            _sessionByIDCache = built
            _sessionByIDCacheVersion = sessionsVersion
        }
        return _sessionByIDCache?[id]
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
        sessionsVersion &+= 1
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
        sessionsVersion &+= 1
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
        sessionsVersion &+= 1
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
        sessionsVersion &+= 1
        save()
    }

    func appendMessage(_ message: ChatMessage, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.append(message)
        if sessions[index].title == "新会话" {
            sessions[index].title = Self.defaultTitle(for: message.content)
        }
        sessionsVersion &+= 1
        save()
    }

    func updateMessage(content: String, id: UUID, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        sessions[sessionIndex].messages[messageIndex].content = content
        sessionsVersion &+= 1
        save()
    }

    func removeMessage(id: UUID, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[sessionIndex].messages.removeAll { $0.id == id }
        sessionsVersion &+= 1
        save()
    }

    func removeMessages(from id: UUID, in sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let start = sessions[sessionIndex].messages.firstIndex(where: { $0.id == id }) else {
            return
        }
        sessions[sessionIndex].messages.removeSubrange(start...)
        sessionsVersion &+= 1
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
        sessionsVersion &+= 1
        save()
    }

    func setWorldBook(_ worldBookId: UUID?, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].worldBookId = worldBookId
        sessionsVersion &+= 1
        save()
    }

    func setSystemPrompt(_ systemPrompt: String?, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].systemPrompt = systemPrompt
        sessionsVersion &+= 1
        save()
    }

    /// Item 9 H7：一次会话级批量 mutate。
    /// `SessionDetailView.apply(preset:)` 这类一次性改三四个字段的场景走这个入口，
    /// 比连续 set 多个 setter 少触发 N 次 @Published 变更 + 多次 save 排程。
    /// `block` 在主 actor 上跑：所有字段写完后才递增 sessionsVersion + save()，
    /// 调用方对 ChatSession 内部结构无侵入。
    func mutateSession(_ id: UUID, _ block: (inout ChatSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        block(&sessions[index])
        sessionsVersion &+= 1
        save()
    }

    func setAppliedPreset(_ presetId: UUID?, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].appliedPresetId = presetId
        sessionsVersion &+= 1
        save()
    }

    func setUserDisplayNameOverride(_ name: String, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].userDisplayNameOverride = name
        sessionsVersion &+= 1
        save()
    }

    func setExtraWorldBookIds(_ ids: [UUID], for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].extraWorldBookIds = ids
        sessionsVersion &+= 1
        save()
    }

    func rename(_ sessionID: UUID, to newTitle: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[index].title = trimmed.isEmpty ? "新会话" : trimmed
        sessionsVersion &+= 1
        save()
    }

    func togglePinned(_ sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].isPinned.toggle()
        sessionsVersion &+= 1
        save()
    }

    func setDraft(_ draft: String, for sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if sessions[index].draft != draft {
            sessions[index].draft = draft
            sessionsVersion &+= 1
            // Item 2: draft 不再每键击触发 save。下次其他 mutate / 切会话 /
            // scenePhase → .background 时随主 save 落盘。
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
        // 加载后让下次 session(for:) 重建一次缓存。
        sessionsVersion &+= 1
    }

    // MARK: - 持久化（节流写盘 + 后台 encode）
    //
    // 旧实现是每次 mutate 立即 `JSONEncoder().encode(sessions)` + UserDefaults 写：
    // streaming 一个 1000-token 回复 = 主线程 1000 次全量编码 + 写盘，开销巨大。
    // Item 2 已加 250ms 去抖。Item 8 M4 再做两件事：
    //   1. 复用同一份 JSONEncoder（线程安全，节省分配）。
    //   2. 把 debounce 触发的常规保存丢到后台并发队列执行，避免主线程被大文档编码阻塞；
    //      flushPendingSave() 仍保持同步（app 进后台时数据必须立刻落盘）。
    private var pendingSaveTask: Task<Void, Never>?
    private static let saveDebounceNanoseconds: UInt64 = 250_000_000

    static let saveEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    private static let saveQueue = DispatchQueue(
        label: "pyramid.chatstore.save",
        qos: .utility,
        attributes: .concurrent
    )

    func save() {
        scheduleSave(after: Self.saveDebounceNanoseconds)
    }

    /// 强制立即落盘：取消排队的去抖任务，同步执行一次 encode + write。
    /// 退出前台 / 切到后台时调用，确保数据安全。
    func flushPendingSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        performSaveSync()
    }

    private func scheduleSave(after nanoseconds: UInt64) {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled { return }
            guard let self else { return }
            self.pendingSaveTask = nil
            self.performSaveAsync()
        }
    }

    /// 后台编码 + 写盘。在 main actor 之外执行 JSONEncoder.encode 与 UserDefaults 写。
    /// 走这个路径会晚于主线程几毫秒~几十毫秒——是可接受的代价，
    /// flushPendingSave() 走 `performSaveSync` 兜底关键时机。
    private func performSaveAsync() {
        // 主线程拷一份值类型快照再上传到后台，避开跨线程 mutable 访问。
        let snapshot = sessions
        let currentID = currentSessionID?.uuidString
        Self.saveQueue.async {
            guard let data = try? Self.saveEncoder.encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: StorageKeys.sessions)
            UserDefaults.standard.set(currentID, forKey: StorageKeys.currentSessionID)
        }
    }

    /// 同步落盘：app 即将进 inactive/background 时必须跑这一步。
    private func performSaveSync() {
        if let data = try? Self.saveEncoder.encode(sessions) {
            UserDefaults.standard.set(data, forKey: StorageKeys.sessions)
        }
        UserDefaults.standard.set(currentSessionID?.uuidString, forKey: StorageKeys.currentSessionID)
    }
}

private enum StorageKeys {
    static let sessions = "chatSessions"
    static let currentSessionID = "currentSessionID"
}
