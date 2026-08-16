import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var input = ""
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var scrollVersion = 0

    let store: ChatStore
    private let settings: AppSettings

    init(settings: AppSettings, store: ChatStore) {
        self.settings = settings
        self.store = store
    }

    var messages: [ChatMessage] {
        store.currentMessages
    }

    func send() {
        guard let sessionID = store.currentSessionID else { return }

        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        guard !settings.baseURL.isEmpty else {
            errorMessage = "请先在「设置」中填写 API Base URL"
            return
        }
        guard !settings.modelName.isEmpty else {
            errorMessage = "请先在「设置」中填写模型名"
            return
        }

        store.appendMessage(ChatMessage(role: .user, content: text), to: sessionID)
        input = ""
        isSending = true
        errorMessage = nil
        scrollVersion += 1

        let history = store.currentMessages
        let client = OpenAIClient(
            baseURL: settings.baseURL,
            apiKey: settings.apiKey,
            model: settings.modelName,
            systemPrompt: settings.systemPrompt
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

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
