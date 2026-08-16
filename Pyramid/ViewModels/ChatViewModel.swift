import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var scrollVersion = 0

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func send() {
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

        messages.append(ChatMessage(role: .user, content: text))
        input = ""
        isSending = true
        errorMessage = nil
        scrollVersion += 1

        let history = messages
        let client = OpenAIClient(
            baseURL: settings.baseURL,
            apiKey: settings.apiKey,
            model: settings.modelName
        )

        Task {
            if settings.useStreaming {
                await streamReply(with: client, history: history)
            } else {
                await sendReply(with: client, history: history)
            }
            isSending = false
            scrollVersion += 1
        }
    }

    private func sendReply(with client: OpenAIClient, history: [ChatMessage]) async {
        do {
            let reply = try await client.send(messages: history)
            messages.append(ChatMessage(role: .assistant, content: reply))
        } catch {
            errorMessage = message(for: error)
        }
    }

    private func streamReply(with client: OpenAIClient, history: [ChatMessage]) async {
        let assistant = ChatMessage(role: .assistant, content: "")
        messages.append(assistant)
        var full = ""
        do {
            for try await delta in client.stream(messages: history) {
                full += delta
                guard let index = messages.firstIndex(where: { $0.id == assistant.id }) else {
                    continue
                }
                messages[index].content = full
                scrollVersion += 1
            }
            if full.isEmpty {
                errorMessage = "响应中没有可用的回复内容"
            }
        } catch {
            errorMessage = message(for: error)
            if full.isEmpty {
                messages.removeAll { $0.id == assistant.id }
            }
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
