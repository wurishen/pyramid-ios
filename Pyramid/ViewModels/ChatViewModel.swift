import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var input = ""
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var scrollVersion = 0
    @Published var lastInjectedCount = 0

    let store: ChatStore
    private let settings: AppSettings
    private let worldBook: WorldBookStore
    private let characters: CharacterStore
    private let presets: PresetStore

    init(settings: AppSettings, store: ChatStore, worldBook: WorldBookStore, characters: CharacterStore, presets: PresetStore) {
        self.settings = settings
        self.store = store
        self.worldBook = worldBook
        self.characters = characters
        self.presets = presets
    }

    /// 当前会话应用的预设（含采样参数）。appliedPresetId 失效时回退 nil。
    private var currentPreset: Preset? {
        guard let id = store.currentSession?.appliedPresetId else { return nil }
        return presets.presets.first { $0.id == id }
    }

    var messages: [ChatMessage] {
        store.currentMessages
    }

    func send() {
        guard let sessionID = store.currentSessionID else { return }

        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        guard validateSettings() else { return }

        store.appendMessage(ChatMessage(role: .user, content: text), to: sessionID)
        input = ""
        request(text: text)
    }

    func editMessage(_ message: ChatMessage, newContent: String) {
        guard let sessionID = store.currentSessionID else { return }
        let text = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.updateMessage(content: text, id: message.id, in: sessionID)
        scrollVersion += 1
    }

    func deleteMessage(_ message: ChatMessage) {
        guard let sessionID = store.currentSessionID else { return }
        store.removeMessage(id: message.id, in: sessionID)
        scrollVersion += 1
    }

    func regenerate(at index: Int) {
        guard !isSending, let sessionID = store.currentSessionID else { return }
        let msgs = store.currentMessages
        guard index >= 1, index < msgs.count,
              msgs[index].role == .assistant, msgs[index - 1].role == .user else { return }
        guard validateSettings() else { return }

        let original = msgs[index - 1].content
        store.removeMessages(from: msgs[index].id, in: sessionID)
        request(text: original)
    }

    private func validateSettings() -> Bool {
        guard !settings.baseURL.isEmpty else {
            errorMessage = "请先在「设置」中填写 API Base URL"
            return false
        }
        guard !settings.modelName.isEmpty else {
            errorMessage = "请先在「设置」中填写模型名"
            return false
        }
        return true
    }

    private func request(text: String) {
        guard let sessionID = store.currentSessionID else { return }

        isSending = true
        errorMessage = nil
        scrollVersion += 1

        let history = store.currentMessages
        let session = store.currentSession
        let character = characters.character(for: session?.characterId)
        let entries = worldBookEntries(input: text, history: history, session: session, character: character)
        lastInjectedCount = entries.count
        let grouped = WorldBookService.groupByPosition(entries)
        let preset = currentPreset
        let client = OpenAIClient(
            baseURL: settings.baseURL,
            apiKey: settings.apiKey,
            model: settings.modelName,
            systemPrompt: effectiveSystemPrompt,
            userPersonaText: userPersonaText,
            beforeSystemText: WorldBookService.injectionText(for: grouped[.beforeSystem] ?? []),
            afterSystemText: WorldBookService.injectionText(for: grouped[.afterSystem] ?? []),
            afterHistoryText: WorldBookService.injectionText(for: grouped[.afterHistory] ?? []),
            temperature: preset?.temperature,
            topP: preset?.topP,
            maxTokens: preset?.maxTokens
        )

        Task {
            if settings.useStreaming {
                await streamReply(with: client, history: history, sessionID: sessionID)
            } else {
                await sendReply(with: client, history: history, sessionID: sessionID)
            }
            isSending = false
            scrollVersion += 1
        }
    }

    private func sendReply(with client: OpenAIClient, history: [ChatMessage], sessionID: UUID) async {
        do {
            let reply = try await client.send(messages: history)
            store.appendMessage(ChatMessage(role: .assistant, content: reply), to: sessionID)
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func streamReply(with client: OpenAIClient, history: [ChatMessage], sessionID: UUID) async {
        let assistant = ChatMessage(role: .assistant, content: "")
        store.appendMessage(assistant, to: sessionID)
        var full = ""
        do {
            for try await delta in client.stream(messages: history) {
                full += delta
                store.updateMessage(content: full, id: assistant.id, in: sessionID)
                scrollVersion += 1
            }
            if full.isEmpty {
                errorMessage = "响应中没有可用的回复内容"
            }
        } catch {
            errorMessage = message(for: error)
            if full.isEmpty {
                store.removeMessage(id: assistant.id, in: sessionID)
            }
        }
    }

    private var effectiveSystemPrompt: String {
        var parts: [String] = []

        if let session = store.currentSession,
           let char = characters.character(for: session.characterId) {
            let charPrompt = char.systemPromptText()
            if !charPrompt.isEmpty { parts.append(charPrompt) }
        }

        let sessionPrompt = store.currentSession?.systemPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !sessionPrompt.isEmpty {
            parts.append(sessionPrompt)
        } else if parts.isEmpty {
            parts.append(settings.systemPrompt)
        }

        return parts.joined(separator: "\n\n")
    }

    private func worldBookEntries(input: String, history: [ChatMessage], session: ChatSession?, character: Character?) -> [WorldBookEntry] {
        guard settings.worldBookEnabled else { return [] }
        let activeBooks = worldBook.activeBooks(for: session, character: character)
        if activeBooks.isEmpty { return [] }
        // 多本书依次匹配，命中条目按 priority 升序合并。
        // SPEC 上限（20 条 / 2000 字符）由 WorldBookService.selectedEntries 截断保证。
        var collected: [WorldBookEntry] = []
        for book in activeBooks {
            let matched = WorldBookService.selectedEntries(for: input, history: history, entries: book.entries)
            collected.append(contentsOf: matched)
        }
        return collected
    }

    /// 用户人设正文。开关关闭或人设为空时返回空串。
    /// 顺序：用户人设 → 角色 → 会话/预设 → 世界书 → 历史 → 用户消息（与 SPEC 一致）。
    private var userPersonaText: String {
        guard settings.userPersonaInjected else { return "" }
        let persona = settings.userPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = effectiveUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !persona.isEmpty || !displayName.isEmpty else { return "" }
        var lines: [String] = []
        if !displayName.isEmpty {
            lines.append("用户在对话中自称：\(displayName)")
        }
        if !persona.isEmpty {
            lines.append(persona)
        }
        return lines.joined(separator: "\n")
    }

    /// 对 AI 显示的用户名。会话覆盖 > 全局 userDisplayName > 全局 userName。
    private var effectiveUserDisplayName: String {
        if let session = store.currentSession,
           !session.userDisplayNameOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.userDisplayNameOverride
        }
        if !settings.userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return settings.userDisplayName
        }
        return settings.userName
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
