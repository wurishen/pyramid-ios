import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isSending = false
    @Published var errorMessage: String?

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

        let history = messages
        let client = OpenAIClient(
            baseURL: settings.baseURL,
            apiKey: settings.apiKey,
            model: settings.modelName
        )

        Task {
            do {
                let reply = try await client.send(messages: history)
                messages.append(ChatMessage(role: .assistant, content: reply))
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            isSending = false
        }
    }
}
