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

    // MARK: - Item 4：流式细粒度信号
    //
    // 旧实现每个 token 都 `store.updateMessage` → `@Published var sessions` 全量重发
    // → ChatView body 失效 → 全列表 bubble 重新评估；叠加 `scrollVersion += 1`
    // → 每个 token 都触发动画 scrollTo。
    //
    // 现在流式期间只更新这两个独立的 @Published（信号范围小，仅流式那条 bubble 关心），
    // sessions 在流式结束 / 取�� / 失败时才一次性写回；scrollVersion 也只在结束时 +1。
    /// 正在流式生成的那条助手消息 ID（流式未启动 = nil）。
    @Published var streamingMessageID: UUID?
    /// 正在流式生成的那条消息的当前完整内容。
    @Published var streamingContent: String = ""

    let store: ChatStore

    /// 便捷转发：让视图层不必同时持有 ChatStore 与 ChatViewModel。
    /// P3 native transpile：MessageCard 用它 + `store.variableStore` 注入 RenderEngine.Context。
    var currentSessionID: UUID? { store.currentSessionID }

    private let settings: AppSettings
    private let worldBook: WorldBookStore
    private let characters: CharacterStore
    private let presets: PresetStore
    /// 当前进行中的流式 / 请求任务。停止生成时 cancel 它。
    private var currentTask: Task<Void, Never>?
    /// 当前请求对应的用户消息文本，停止生成后写入草稿，恢复未发送状态。
    private var pendingInputText: String?
    /// pendingInputText 所属会话，避免跨会话取消时把草稿写错会话。
    private var pendingSessionID: UUID?

    // MARK: - Item 6 H4 + H6：上下文长度估算缓存 & 去抖
    //
    // ChatView body 里 contextHintBar 每个 @Published 变化都会调用
    // trimmedContextCharacterCount，触发 applyContextTrim 全量重算和
    // activeBooks 全量匹配 + 字数估算。键入文字、scrollVersion、streamingContent
    // 都会重新跑这些昂贵计算。
    //
    // 方案：以 (historyHash, settingsHash, worldBookHash, characterHash,
    // inputHash) 作为指纹同步短路；指纹变了再起 150ms 去抖任务后台重算。
    // UI 永远读缓存值（即使短暂陈旧），避免主线程长卡顿。
    @Published private(set) var cachedTrimmedHistoryCharacterCount: Int = 0
    @Published private(set) var cachedInjectedCharacterEstimate: Int = 0
    private var pendingEstimateTask: Task<Void, Never>?
    private var lastContextFingerprint: Int = 0
    private static let estimateDebounceNanoseconds: UInt64 = 150_000_000

    init(settings: AppSettings, store: ChatStore, worldBook: WorldBookStore, characters: CharacterStore, presets: PresetStore) {
        self.settings = settings
        self.store = store
        self.worldBook = worldBook
        self.characters = characters
        self.presets = presets
        restoreDraftForCurrentSession()
        // Item 6 H4：第一时间同步算出缓存值，避免首屏 contextHintBar 显示 0 闪烁再 150ms 后跳变。
        primeContextCharacterCount(input: input)
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
            // Item 2: draft 改完不再触发 save，这里强制 flush 保证旧会话草稿落盘。
            store.flushPendingSave()
        }
        if let new = newID, let session = store.sessions.first(where: { $0.id == new }) {
            input = session.draft
        } else {
            input = ""
        }
        // 切会话时清掉「上次失败」状态，不属于本会话。
        lastFailedUserMessageID = nil
        lastFailedReason = nil
        // Item 6 H4：会话切换是世界书 / activeBooks 的强信号；同步重算并写入缓存，
        // 避免 150ms 去抖窗口里 UI 错误地展示旧会话的字符数。
        pendingEstimateTask?.cancel()
        lastContextFingerprint = 0
        primeContextCharacterCount(input: input)
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
        pendingSessionID = sessionID
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
        // Item 5：不要把 currentTask 置 nil —— 保留它，下一次 request() 才能 await
        // 旧 task 走完清理分支，避免新旧两条流同时改 store 导致重复回复。
        // Item 4：取消时清掉细粒度流式信号，避免 UI 仍把 streamingContent 当成 live 内容渲染。
        streamingMessageID = nil
        streamingContent = ""
        // 流式目标会话：若用户切到了其他会话，placeholder 清理由被取消的 task
        // 自己在 finally/异常分支里完成（它持有正确的 sessionID），cancelCurrent
        // 不再硬猜「当前会话」的消息列表。
        // 只有还在原 pendingSessionID 会话时才把 pendingInputText 写回 input，
        // 跨会话取消时应直接丢弃，避免把别会话的草稿覆盖到当前 input。
        if let pending = pendingInputText {
            if pendingSessionID == store.currentSessionID {
                input = pending
                if let sessionID = pendingSessionID {
                    store.setDraft(pending, for: sessionID)
                }
            }
            pendingInputText = nil
            pendingSessionID = nil
        }
        isSending = false
        errorMessage = nil
        scrollVersion += 1
        // Item 6 H6：取消可能紧接着新一轮发送或 session 切换，让去抖估算任务停下。
        pendingEstimateTask?.cancel()
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
        pendingSessionID = nil
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

    /// 切换某条消息的「包含在上��文」标记。被排除的消息仍会在 UI 显示，
    /// 但不会被送进 API；下次发起请求时生效。
    func toggleInclude(_ message: ChatMessage) {
        guard let sessionID = store.currentSessionID else { return }
        store.setMessageIncluded(!message.isIncluded, for: message.id, in: sessionID)
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
        pendingSessionID = nil
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
        // Item 4：新请求开始前清掉旧流式信号，避免上一条被 kill 的流把残留内容显示给用户。
        streamingMessageID = nil
        streamingContent = ""
        scrollVersion += 1

        let rawHistory = store.currentMessages
        let session = store.currentSession
        let character = characters.character(for: session?.characterId)
        let entries = worldBookEntries(input: text, history: rawHistory, session: session, character: character)
        lastInjectedCount = entries.count
        // Item 6 H4 + H6：请求发起时同步把 contextHintBar 的估算刷成与本次输入 + 历史一致，
        // 避免去抖任务把 UI 数字先停在旧的、150ms 后才跳变的体验。
        // 用本次请求实际送出的 text（不是 viewModel.input，因为 send() 已清空）。
        primeContextCharacterCount(input: text)
        let grouped = WorldBookService.groupByPosition(entries)
        let preset = currentPreset
        // 应用上下文裁剪（不写入 API 正文，仅裁剪历史；楼层号 / 时间 / 注入指示仍为纯 UI）。
        let trimmedHistory = applyContextTrim(rawHistory, userMessageID: userMessageID)
        // 宏展开：���作用于送入 API 的消息文本，不修改存储 / 显示。
        var apiHistory = expandMacros(in: trimmedHistory)
        // ST `prompt_only` 规则：在 outgoing prompt 阶段把酒馆思维链 / 状态栏等
        // 对 AI 隐藏��内容剥掉。仅作用于送入 API 的消息，不动存储 / 显示。
        let presetDisplayIds = currentPreset?.displayRegexIds ?? []
        apiHistory = apiHistory.map { msg in
            var copy = msg
            copy.content = MessageRendererCore.applyPromptOnly(
                text: msg.content,
                presetDisplayRegexIds: presetDisplayIds,
                all: displayRegexes.regexes
            )
            return copy
        }
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
        // Phase 2：ST V3 depth_prompt 运行时注入。
        // - position=.inChat 且 role∈{user, assistant} → 插到 apiHistory 指定深度
        // - position=.inChat 且 role=.system                → 拼到 afterSystemText
        // - position=.before                              → 拼到 afterSystemText
        // - position=.after                               → 拼到 afterHistoryText
        // content 为空时不注入；system role 不走 inChat（见 DepthPromptInjector 注释）。
        var afterSystemText = WorldBookService.injectionText(for: grouped[.afterSystem] ?? [])
        if let dp = character?.depthPrompt,
           !dp.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch (dp.role, dp.position) {
            case (_, .inChat):
                if dp.role == .system {
                    let appendage = DepthPromptInjector.systemAppendage(prompt: dp)
                    if !appendage.isEmpty {
                        afterSystemText += afterSystemText.isEmpty ? appendage : "\n\n" + appendage
                    }
                } else {
                    DepthPromptInjector.injectInChat(history: &apiHistory, prompt: dp)
                }
            case (_, .before):
                let appendage = DepthPromptInjector.systemAppendage(prompt: dp)
                if !appendage.isEmpty {
                    afterSystemText += afterSystemText.isEmpty ? appendage : "\n\n" + appendage
                }
            case (_, .after):
                let appendage = DepthPromptInjector.systemAppendage(prompt: dp)
                if !appendage.isEmpty {
                    afterHistory += afterHistory.isEmpty ? appendage : "\n\n" + appendage
                }
            }
        }
        let client = OpenAIClient(
            baseURL: settings.baseURL,
            apiKey: settings.apiKey,
            model: effectiveModelName,
            systemPrompt: effectiveSystemPrompt,
            userPersonaText: userPersonaText,
            beforeSystemText: WorldBookService.injectionText(for: grouped[.beforeSystem] ?? []),
            afterSystemText: afterSystemText,
            afterHistoryText: afterHistory,
            temperature: preset?.temperature,
            topP: preset?.topP,
            maxTokens: preset?.maxTokens
        )

        currentTask?.cancel()
        // Item 5：先 await 旧 task 完全停，再开新 task。旧 task 才能 flush 自己的 cancel
        // 清理（删/存 placeholder），避免两条流同时往 store 写产生重复回复。
        let previousTask = currentTask
        currentTask = Task { @MainActor [weak self] in
            _ = await previousTask?.value
            guard let self else { return }
            if settings.useStreaming {
                await streamReply(with: client, history: apiHistory, sessionID: sessionID, userMessageID: userMessageID)
            } else {
                await sendReply(with: client, history: apiHistory, sessionID: sessionID, userMessageID: userMessageID)
            }
            isSending = false
            pendingInputText = nil
            pendingSessionID = nil
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
        // Item 4：流式期间改用细粒度 @Published，sessions 仅在结束时写一次。
        streamingMessageID = assistant.id
        streamingContent = ""
        var full = ""
        do {
            for try await delta in client.stream(messages: history) {
                if Task.isCancelled { break }
                full += delta
                streamingContent = full
            }
            if Task.isCancelled {
                // 取消：把已生成部分落盘，保留给用户查看。
                if !full.isEmpty {
                    store.updateMessage(content: full, id: assistant.id, in: sessionID)
                } else {
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
            } else {
                // 流式结束：一次性把最终内容写回 sessions（触发一次 debounced save）。
                store.updateMessage(content: full, id: assistant.id, in: sessionID)
                scrollVersion += 1
            }
        } catch is CancellationError {
            if !full.isEmpty {
                store.updateMessage(content: full, id: assistant.id, in: sessionID)
            } else {
                store.removeMessage(id: assistant.id, in: sessionID)
            }
        } catch {
            let msg = message(for: error)
            errorMessage = msg
            lastFailedUserMessageID = userMessageID
            lastFailedReason = msg
            if !full.isEmpty {
                store.updateMessage(content: full, id: assistant.id, in: sessionID)
            } else {
                store.removeMessage(id: assistant.id, in: sessionID)
            }
        }
        // 清掉细粒度流式信号。
        streamingMessageID = nil
        streamingContent = ""
    }

    /// 上下文裁剪：按设置保留最近 N 条消息 / 最近 C 字符；当前用户消息始终保留。
    /// 见 SPEC §14。楼层号、时间戳、「已注入世界书N条」均为 UI 装饰，不写入 content / API。
    /// 被用户标记为「不包含在上下文」的消息也会被裁出（除非是当前用户消息本身）。
    func applyContextTrim(_ history: [ChatMessage], userMessageID: UUID?) -> [ChatMessage] {
        // 先把被排除的消息滤掉，再走裁剪策略。
        let eligible: [ChatMessage]
        if let uid = userMessageID {
            // 当前用户消息无论如何都保留（保证 AI 看到本轮提问）。
            eligible = history.filter { $0.isIncluded || $0.id == uid }
        } else {
            eligible = history.filter(\.isIncluded)
        }
        let trimmed: [ChatMessage]
        switch settings.contextTrimMode {
        case .off:
            trimmed = eligible
        case .byMessages:
            let n = max(2, settings.contextTrimMessages)
            if eligible.count <= n { trimmed = eligible } else { trimmed = Array(eligible.suffix(n)) }
        case .byCharacters:
            let budget = max(200, settings.contextTrimCharacters)
            var acc: [ChatMessage] = []
            var used = 0
            for msg in eligible.reversed() {
                let cost = msg.content.count
                if !acc.isEmpty, used + cost > budget { break }
                acc.append(msg)
                used += cost
                if used >= budget { break }
            }
            trimmed = acc.reversed()
        }
        // 兜底：万一当前用户消息被排除且裁剪规则也丢了它，仍然强制带上。
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
        // Item 6 H4 + H6：读缓存 → 后台 150ms 去抖更新。语义与旧实现一致：
        //   = 裁剪后历史字符数 + 当前世界书注入条目字符数。
        refreshContextCharacterCount()
        return cachedTrimmedHistoryCharacterCount + cachedInjectedCharacterEstimate
    }

    /// 同步算出注入条目字符数。给 `request()` / `recomputeContextCharacterCounts()` 复用。
    /// 旧 `private var injectedCharacterEstimate` 改成显式同步函数，便于缓存刷新与请求路径
    /// 共享同一份实现，不依赖 `input` getter 状态。
    private func computeInjectedCharacterEstimateNow(input rawInput: String, rawHistory: [ChatMessage]) -> Int {
        guard settings.worldBookEnabled else { return 0 }
        let session = store.currentSession
        let character = characters.character(for: session?.characterId)
        let activeBooks = worldBook.activeBooks(for: session, character: character)
        if activeBooks.isEmpty { return 0 }
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var collected: [WorldBookEntry] = []
        for book in activeBooks {
            let matched = WorldBookService.selectedEntries(for: input, history: rawHistory, entries: book.entries)
            collected.append(contentsOf: matched)
        }
        return collected.reduce(0) { $0 + $1.title.count + $1.content.count }
    }

    /// 同步执行一次完整的裁剪 + 注入估算，用于 `request()` 立即刷新 UI 缓存。
    /// `overrideInput`：调用方可注入实际使用的输入（request 文本），避免依赖
    /// `self.input` —— 该值在 `send()` 已经清空，跟请求发送时真正的 input 不同。
    func recomputeContextCharacterCounts(input overrideInput: String) -> (trimmed: Int, injected: Int) {
        let rawHistory = store.currentMessages
        let userID: UUID? = rawHistory.last(where: { $0.role == .user })?.id
        let trimmed = applyContextTrim(rawHistory, userMessageID: userID)
            .reduce(0) { $0 + $1.content.count }
        let injected = computeInjectedCharacterEstimateNow(input: overrideInput, rawHistory: rawHistory)
        return (trimmed, injected)
    }

    /// `request()` 主动调用：使用真实 input + 历史同步计算、写入缓存并更新指纹，
    /// 保证请求刚发起时 contextHintBar 立刻显示与发起请求前匹配的字符数。
    /// 请求路径要传当前 input（可能与 viewModel.input 不一致——
    /// send() 在调本方法前已经清空输入框，viewModel.input=""）。
    func primeContextCharacterCount(input overrideInput: String) {
        let fp = computeContextFingerprint(input: overrideInput)
        guard fp != lastContextFingerprint else { return }
        lastContextFingerprint = fp
        let (trimmed, injected) = recomputeContextCharacterCounts(input: overrideInput)
        cachedTrimmedHistoryCharacterCount = trimmed
        cachedInjectedCharacterEstimate = injected
        pendingEstimateTask?.cancel()
    }

    /// 上下文长度估算的缓存刷新入口。
    /// - 指纹未变 → 仅短路，不再起新去抖任务。
    /// - 指纹变化 → 起一个 150ms 去抖任务，结束后才真正重算 + 写 @Published。
    ///   期间连续调用只会 cancel 旧任务、重置 sleep，几乎零浪费。
    /// UI 读 `cachedTrimmedHistoryCharacterCount` + `cachedInjectedCharacterEstimate`，
    /// 重排计划件本身不消耗主线程时间。
    private func refreshContextCharacterCount() {
        refreshContextCharacterCount(input: input)
    }

    /// 给 `refreshContextCharacterCount` 的可注入 input 版本；启动 / 切会话时
    /// 直接用当时的 viewModel.input 即可，request() 路径必须显式传覆盖值。
    private func refreshContextCharacterCount(input refreshInput: String) {
        let fp = computeContextFingerprint(input: refreshInput)
        guard fp != lastContextFingerprint else { return }
        pendingEstimateTask?.cancel()
        pendingEstimateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.estimateDebounceNanoseconds)
            if Task.isCancelled { return }
            guard let self else { return }
            // 重算指纹：等待期间状态可能又改了。
            let lateFP = self.computeContextFingerprint(input: self.input)
            guard lateFP != self.lastContextFingerprint else { return }
            self.lastContextFingerprint = lateFP
            let (trimmed, injected) = self.recomputeContextCharacterCounts(input: self.input)
            if Task.isCancelled { return }
            self.cachedTrimmedHistoryCharacterCount = trimmed
            self.cachedInjectedCharacterEstimate = injected
        }
    }

    /// 上下文长度估算的指纹：包含会影响裁剪结果 / 世界书匹配的所有输入。
    /// 任何一位改变 → 触发去抖重算；都不变 → 复用缓存。
    private func computeContextFingerprint(input rawInput: String) -> Int {
        var hasher = Hasher()
        let rawHistory = store.currentMessages
        hasher.combine(rawHistory.count)
        for msg in rawHistory {
            hasher.combine(msg.id)
            hasher.combine(msg.role)
            hasher.combine(msg.isIncluded)
            hasher.combine(msg.content)
        }
        let session = store.currentSession
        hasher.combine(session?.id)
        hasher.combine(session?.appliedPresetId)
        hasher.combine(session?.characterId)
        hasher.combine(session?.worldBookId)
        hasher.combine(session?.extraWorldBookIds)
        hasher.combine(session?.systemPrompt)
        hasher.combine(settings.worldBookEnabled)
        hasher.combine(settings.contextTrimModeRaw)
        hasher.combine(settings.contextTrimMessages)
        hasher.combine(settings.contextTrimCharacters)
        for book in worldBook.activeBooks(
            for: session,
            character: characters.character(for: session?.characterId)
        ) {
            hasher.combine(book.id)
            for entry in book.entries {
                hasher.combine(entry.id)
                hasher.combine(entry.title)
                hasher.combine(entry.content)
                hasher.combine(entry.keywords)
                hasher.combine(entry.secondaryKeywords)
                hasher.combine(entry.scanDepth)
                hasher.combine(entry.probability)
                hasher.combine(entry.priority)
                hasher.combine(entry.isEnabled)
                hasher.combine(entry.isConstant)
                hasher.combine(entry.matchMode)
                hasher.combine(entry.insertionPosition)
            }
        }
        // Phase 2：V3 lifted character fields 影响 depth_prompt 注入，须纳入指纹。
        if let character = characters.character(for: session?.characterId) {
            hasher.combine(character.talkativeness)
            hasher.combine(character.isFavorite)
            hasher.combine(character.depthPrompt)
        }
        hasher.combine(rawInput)
        return hasher.finalize()
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
