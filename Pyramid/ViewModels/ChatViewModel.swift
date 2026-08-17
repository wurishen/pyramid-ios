import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var input = ""
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var scrollVersion = 0
    @Published var lastInjectedCount = 0
    /// 最近一次失败的「待重试」用户消息 ID。失败 toast 可一键重发。
    @Published var lastFailedUserMessageID: UUID?
    /// 最近一次失败原因（供重试提示）。
    @Published var lastFailedReason: String?

    let store: ChatStore
    private let settings: AppSettings
    private let worldBook: WorldBookStore
    private let characters: CharacterStore
    private let presets: PresetStore
    /// 当前进行中的流式 / 请求任务。停止生成时 cancel 它。
    private var currentTask: Task<Void, Never>?
    /// 当前请求对应的用户消息文本，停止生成后写入草稿，恢复未发送状态。
    private var pendingInputText: String?

    init(settings: AppSettings, store: ChatStore, worldBook: WorldBookStore, characters: CharacterStore, presets: PresetStore) {
        self.settings = settings
        self.store = store
        self.worldBook = worldBook
        self.characters = characters
        self.presets = presets
        restoreDraftForCurrentSession()
    }

    /// 当前会话应用的预设（含采样参数）。appliedPresetId 失效时回退 nil。
    private var currentPreset: Preset? {
        guard let id = store.currentSession?.appliedPresetId else { return nil }
        return presets.presets.first { $0.id == id }
    }

    var messages: [ChatMessage] {
        store.currentMessages
    }

    /// 切换会话时由 ChatView 调用：把当前 input 保存到旧会话草稿，再把新会话草稿装载进 input。
    func handleSessionChange(previousID: UUID?, newID: UUID?) {
        if let prev = previousID {
            store.setDraft(input, for: prev)
        }
        if let new = newID, let session = store.sessions.first(where: { $0.id == new }) {
            input = session.draft
        } else {
            input = ""
        }
        // 切会话时清掉「上次失败」状态，不属于本会话。
        lastFailedUserMessageID = nil
        lastFailedReason = nil
    }

    func restoreDraftForCurrentSession() {
        if let id = store.currentSessionID,
           let session = store.sessions.first(where: { $0.id == id }) {
            input = session.draft
        }
    }

    /// input 变更时实时同步到当前会话的 draft，保证切走前不丢。
    func persistDraft() {
        guard let id = store.currentSessionID else { return }
        store.setDraft(input, for: id)
    }

    func send() {
        guard let sessionID = store.currentSessionID else { return }

        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        guard validateSettings() else { return }

        pendingInputText = text
        store.appendMessage(ChatMessage(role: .user, content: text), to: sessionID)
        store.setDraft("", for: sessionID)
        input = ""
        lastFailedUserMessageID = nil
        lastFailedReason = nil
        request(text: text, userMessageID: store.currentMessages.last?.id)
    }

    /// 取消当前请求。把已追加的用户消息保留（便于重发），把流式中的占位空助手消息移除，
    /// 并恢复未发送的输入文本到草稿/输入框。
    func cancelCurrent() {
        currentTask?.cancel()
        currentTask = nil
        guard let sessionID = store.currentSessionID else { return }
        let msgs = store.currentMessages
        // 流式生成的占位空 assistant 消息（紧跟在用户消息之后）直接删除。
        if let lastUserIndex = msgs.lastIndex(where: { $0.role == .user }),
           lastUserIndex + 1 < msgs.count,
           msgs[lastUserIndex + 1].role == .assistant,
           msgs[lastUserIndex + 1].content.isEmpty {
            store.removeMessage(id: msgs[lastUserIndex + 1].id, in: sessionID)
        }
        // 恢复未发送的输入文本。
        if let pending = pendingInputText {
            input = pending
            store.setDraft(pending, for: sessionID)
            pendingInputText = nil
        }
        isSending = false
        errorMessage = nil
        scrollVersion += 1
    }

    /// 重试最近一次失败的请求：复用失败的用户消息重新发。
    func retryLastFailed() {
        guard !isSending, let sessionID = store.currentSessionID else { return }
        guard let failedID = lastFailedUserMessageID,
              let msg = store.currentMessages.first(where: { $0.id == failedID }),
              msg.role == .user else { return }
        guard validateSettings() else { return }
        // 删除失败时插入的空 assistant 占位（如果有）。
        if let idx = store.currentMessages.firstIndex(where: { $0.id == failedID }),
           idx + 1 < store.currentMessages.count,
           store.currentMessages[idx + 1].role == .assistant,
           store.currentMessages[idx + 1].content.isEmpty {
            store.removeMessage(id: store.currentMessages[idx + 1].id, in: sessionID)
        }
        pendingInputText = nil
        lastFailedUserMessageID = nil
        lastFailedReason = nil
        request(text: msg.content, userMessageID: failedID)
        // 静默重试不修改用户消息本身。
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
        let userID = msgs[index - 1].id
        store.removeMessages(from: msgs[index].id, in: sessionID)
        pendingInputText = nil
        lastFailedUserMessageID = nil
        lastFailedReason = nil
        request(text: original, userMessageID: userID)
    }

    private func validateSettings() -> Bool {
        guard !settings.baseURL.isEmpty else {
            errorMessage = "请先在「设置」中填写 API Base URL"
            return false
        }
        guard !effectiveModelName.isEmpty else {
            errorMessage = "请先在「设置」或预设中填写模型名"
            return false
        }
        return true
    }

    /// 实际发送使用的模型：预设的 modelName 优先（覆盖全局），否则用全局。
    /// 切预设不会修改 `settings.modelName`，仅在本请求里生效。
    private var effectiveModelName: String {
        if let presetModel = currentPreset?.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !presetModel.isEmpty {
            return presetModel
        }
        return settings.modelName
    }

    /// 当前会话的角色名（用于宏展开）。当会话未绑定角色时宏留空。
    private var currentCharacterName: String {
        characters.character(for: store.currentSession?.characterId)?.name ?? ""
    }

    /// 在送入 API 的消息上展开宏 `{{user}}` `{{char}}` 及其大小写变体。
    /// 存储与显示用的 `message.content` 永远保持原文。
    private func expandMacros(in messages: [ChatMessage]) -> [ChatMessage] {
        let user = effectiveUserDisplayName
        let char = currentCharacterName
        guard !user.isEmpty || !char.isEmpty else { return messages }
        return messages.map { msg in
            var copy = msg
            copy.content = MacroExpander.expand(msg.content, user: user, char: char)
            return copy
        }
    }

    private func request(text: String, userMessageID: UUID?) {
        guard let sessionID = store.currentSessionID else { return }

        isSending = true
        errorMessage = nil
        scrollVersion += 1

        let rawHistory = store.currentMessages
        let session = store.currentSession
        let character = characters.character(for: session?.characterId)
        let entries = worldBookEntries(input: text, history: rawHistory, session: session, character: character)
        lastInjectedCount = entries.count
        let grouped = WorldBookService.groupByPosition(entries)
        let preset = currentPreset
        // 应用上下文裁剪（不写入 API 正文，仅裁剪历史；楼层号 / 时间 / 注入指示仍为纯 UI）。
        let trimmedHistory = applyContextTrim(rawHistory, userMessageID: userMessageID)
        // 宏展开：仅作用于送入 API 的消息文本，不修改存储 / 显示。
        let apiHistory = expandMacros(in: trimmedHistory)
        // 酒馆 post_history_instructions：作为最末 system 块拼到「历史之后」。
        // 与同位置的 world book 条目合并，world book 在前、角色 PHI 在后。
        var afterHistory = WorldBookService.injectionText(for: grouped[.afterHistory] ?? [])
        if let phi = character?.postHistoryInstructions,
           !phi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !afterHistory.isEmpty {
                afterHistory += "\n\n" + phi.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                afterHistory = phi.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let client = OpenAIClient(
            baseURL: settings.baseURL,
            apiKey: settings.apiKey,
            model: effectiveModelName,
            systemPrompt: effectiveSystemPrompt,
            userPersonaText: userPersonaText,
            beforeSystemText: WorldBookService.injectionText(for: grouped[.beforeSystem] ?? []),
            afterSystemText: WorldBookService.injectionText(for: grouped[.afterSystem] ?? []),
            afterHistoryText: afterHistory,
            temperature: preset?.temperature,
            topP: preset?.topP,
            maxTokens: preset?.maxTokens
        )

        currentTask?.cancel()
        currentTask = Task {
            if settings.useStreaming {
                await streamReply(with: client, history: apiHistory, sessionID: sessionID, userMessageID: userMessageID)
            } else {
                await sendReply(with: client, history: apiHistory, sessionID: sessionID, userMessageID: userMessageID)
            }
            isSending = false
            pendingInputText = nil
            scrollVersion += 1
        }
    }

    private func sendReply(with client: OpenAIClient, history: [ChatMessage], sessionID: UUID, userMessageID: UUID?) async {
        do {
            let reply = try await client.send(messages: history)
            store.appendMessage(ChatMessage(role: .assistant, content: reply), to: sessionID)
        } catch is CancellationError {
            // 主动取消，不报错。
        } catch {
            let msg = message(for: error)
            errorMessage = msg
            lastFailedUserMessageID = userMessageID
            lastFailedReason = msg
        }
    }

    private func streamReply(with client: OpenAIClient, history: [ChatMessage], sessionID: UUID, userMessageID: UUID?) async {
        let assistant = ChatMessage(role: .assistant, content: "")
        store.appendMessage(assistant, to: sessionID)
        var full = ""
        do {
            for try await delta in client.stream(messages: history) {
                if Task.isCancelled { break }
                full += delta
                store.updateMessage(content: full, id: assistant.id, in: sessionID)
                scrollVersion += 1
            }
            if Task.isCancelled {
                // 取消：若没有内容则删掉占位，否则保留用户能看到已生成部分。
                if full.isEmpty {
                    store.removeMessage(id: assistant.id, in: sessionID)
                }
                return
            }
            if full.isEmpty {
                let msg = "响应中没有可用的回复内容"
                errorMessage = msg
                store.removeMessage(id: assistant.id, in: sessionID)
                lastFailedUserMessageID = userMessageID
                lastFailedReason = msg
            }
        } catch is CancellationError {
            if full.isEmpty {
                store.removeMessage(id: assistant.id, in: sessionID)
            }
        } catch {
            let msg = message(for: error)
            errorMessage = msg
            lastFailedUserMessageID = userMessageID
            lastFailedReason = msg
            if full.isEmpty {
                store.removeMessage(id: assistant.id, in: sessionID)
            }
        }
    }

    /// 上下文裁剪：按设置保留最近 N 条消息 / 最近 C 字符；当前用户消息始终保留。
    /// 见 SPEC §14。楼层号、时间戳、「已注入世界书N条」均为 UI 装饰，不写入 content / API。
    func applyContextTrim(_ history: [ChatMessage], userMessageID: UUID?) -> [ChatMessage] {
        let trimmed: [ChatMessage]
        switch settings.contextTrimMode {
        case .off:
            trimmed = history
        case .byMessages:
            let n = max(2, settings.contextTrimMessages)
            if history.count <= n { trimmed = history } else { trimmed = Array(history.suffix(n)) }
        case .byCharacters:
            let budget = max(200, settings.contextTrimCharacters)
            var acc: [ChatMessage] = []
            var used = 0
            for msg in history.reversed() {
                let cost = msg.content.count
                if !acc.isEmpty, used + cost > budget { break }
                acc.append(msg)
                used += cost
                if used >= budget { break }
            }
            trimmed = acc.reversed()
        }
        // 保证当前用户消息一定在历史中（防止裁剪掉导致 AI 看不到本轮提问）。
        if let id = userMessageID,
           let userMsg = history.first(where: { $0.id == id }),
           !trimmed.contains(where: { $0.id == id }) {
            var withUser = trimmed
            withUser.append(userMsg)
            return withUser
        }
        return trimmed
    }

    /// 上下文长度提示使用的「即将发送给 API 的字符数」。与裁剪后保持一致。
    var trimmedContextCharacterCount: Int {
        let rawHistory = store.currentMessages
        let userID: UUID?
        if let last = rawHistory.last(where: { $0.role == .user })?.id {
            userID = last
        } else {
            userID = nil
        }
        let trimmed = applyContextTrim(rawHistory, userMessageID: userID)
        return trimmed.reduce(0) { $0 + $1.content.count } + injectedCharacterEstimate
    }

    private var injectedCharacterEstimate: Int {
        guard settings.worldBookEnabled else { return 0 }
        let session = store.currentSession
        let character = characters.character(for: session?.characterId)
        let activeBooks = worldBook.activeBooks(for: session, character: character)
        if activeBooks.isEmpty { return 0 }
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var collected: [WorldBookEntry] = []
        for book in activeBooks {
            let matched = WorldBookService.selectedEntries(for: input, history: store.currentMessages, entries: book.entries)
            collected.append(contentsOf: matched)
        }
        return collected.reduce(0) { $0 + $1.title.count + $1.content.count }
    }

    private var effectiveSystemPrompt: String {
        var parts: [String] = []

        if let session = store.currentSession,
           let char = characters.character(for: session.characterId) {
            let charPrompt = char.systemPromptText()
            if !charPrompt.isEmpty { parts.append(charPrompt) }
        }

        // 预设的系统提示词优先；否则会话；再否则全局。
        let presetPrompt = currentPreset?.systemPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionPrompt = store.currentSession?.systemPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let basePrompt: String
        if !presetPrompt.isEmpty {
            basePrompt = presetPrompt
        } else if !sessionPrompt.isEmpty {
            basePrompt = sessionPrompt
        } else {
            basePrompt = settings.systemPrompt
        }
        if !basePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(basePrompt)
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
