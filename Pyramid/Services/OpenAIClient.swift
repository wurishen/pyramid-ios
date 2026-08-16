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
    let systemPrompt: String
    let worldBookText: String

    func send(messages: [ChatMessage]) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: makeRequest(messages: messages, stream: false))
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

    func stream(messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: makeRequest(messages: messages, stream: true))
                    guard let http = response as? HTTPURLResponse else {
                        throw ChatError.network("无效的 HTTP 响应")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                        }
                        throw ChatError.badStatus(http.statusCode, String(data: body, encoding: .utf8) ?? "")
                    }

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !payload.isEmpty else { continue }
                        if payload == "[DONE]" { break }
                        if let chunk = try? JSONDecoder().decode(ChatCompletionStreamChunk.self, from: Data(payload.utf8)),
                           let delta = chunk.choices.first?.delta.content {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as ChatError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ChatError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func makeRequest(messages: [ChatMessage], stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: try endpointURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var requestMessages: [ChatCompletionRequest.Message] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requestMessages.append(.init(role: "system", content: systemPrompt))
        }
        if !worldBookText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requestMessages.append(.init(role: "system", content: worldBookText))
        }
        requestMessages += messages.map { .init(role: $0.role.rawValue, content: $0.content) }

        let body = ChatCompletionRequest(
            model: model,
            messages: requestMessages,
            stream: stream
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        var attempts: [URL] = []
        if let url = try? Self.endpointURL(baseURL: baseURL, suffix: "/models") {
            attempts.append(url)
        }
        if let url = Self.modelsFallbackURL(baseURL: baseURL), !attempts.contains(url) {
            attempts.append(url)
        }
        guard !attempts.isEmpty else { throw ChatError.invalidEndpoint }

        var lastError: Error = ChatError.invalidEndpoint
        for url in attempts {
            do {
                return try await Self.fetchModels(from: url, apiKey: apiKey)
            } catch let error as ChatError {
                if case .badStatus(let code, _) = error, code == 404 || code == 405 {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    private static func fetchModels(from url: URL, apiKey: String) async throws -> [String] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

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

        let decoder = JSONDecoder()
        if let list = try? decoder.decode(ModelListResponse.self, from: data) {
            return list.data.map(\.id)
        }
        if let list = try? decoder.decode(ModelListStringResponse.self, from: data) {
            return list.data
        }
        throw ChatError.decoding("无法解析模型列表（期望 OpenAI 格式 data[].id）")
    }

    private static func modelsFallbackURL(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.scheme != nil else {
            return nil
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1") { path.removeLast(3) }
        components.path = path + "/models"
        return components.url
    }

    private func endpointURL() throws -> URL {
        try Self.endpointURL(baseURL: baseURL, suffix: "/chat/completions")
    }

    private static func endpointURL(baseURL: String, suffix: String) throws -> URL {
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
        components.path = path + suffix

        guard let url = components.url else {
            throw ChatError.invalidEndpoint
        }
        return url
    }
}
