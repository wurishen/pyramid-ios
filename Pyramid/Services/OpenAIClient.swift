import Foundation

enum ChatError: LocalizedError {
    case invalidEndpoint
    case network(String)
    case badStatus(Int, String)
    case decoding(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "API Base URL 无效"
        case .network(let message):
            return "网络错误：\(message)"
        case .badStatus(let code, let body):
            return "请求失败，HTTP 状态码 \(code)：\(body)"
        case .decoding(let message):
            return "响应解析失败：\(message)"
        case .emptyResponse:
            return "响应中没有可用的回复内容"
        }
    }
}

struct OpenAIClient {
    let baseURL: String
    let apiKey: String
    let model: String

    func send(messages: [ChatMessage]) async throws -> String {
        var request = URLRequest(url: try endpointURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body = ChatCompletionRequest(
            model: model,
            messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) }
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ChatError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ChatError.network("无效的 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ChatError.badStatus(http.statusCode, bodyText)
        }

        do {
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
                throw ChatError.emptyResponse
            }
            return content
        } catch let error as ChatError {
            throw error
        } catch {
            throw ChatError.decoding(error.localizedDescription)
        }
    }

    private func endpointURL() throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme != nil else {
            throw ChatError.invalidEndpoint
        }

        var path = components.path
        if path.hasSuffix("/") {
            path.removeLast()
        }
        if !path.hasSuffix("/v1") {
            path += "/v1"
        }
        components.path = path + "/chat/completions"

        guard let url = components.url else {
            throw ChatError.invalidEndpoint
        }
        return url
    }
}
