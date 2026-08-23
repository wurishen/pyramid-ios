import Foundation

struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool
    let temperature: Double?
    let topP: Double?
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case temperature
        case topP = "top_p"
        case maxTokens = "max_tokens"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    init(model: String, messages: [Message], stream: Bool,
         temperature: Double? = nil, topP: Double? = nil, maxTokens: Int? = nil) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(messages, forKey: .messages)
        try c.encode(stream, forKey: .stream)
        // 只在不为 nil 时写入字段，避免被 OpenAI 兼容实现误拒。
        if let temperature { try c.encode(temperature, forKey: .temperature) }
        if let topP { try c.encode(topP, forKey: .topP) }
        if let maxTokens { try c.encode(maxTokens, forKey: .maxTokens) }
    }
}

struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let role: String
        /// 部分后端（reasoning-only 响应）会省略 content —— 缺失按空串处理。
        let content: String?
        /// DeepSeek R1 风格思维链字段；缺失为 nil。
        let reasoningContent: String?

        enum Keys: String, CodingKey {
            case role, content
            case reasoningContent = "reasoning_content"
            case reasoning
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            role = try c.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
            content = try? c.decodeIfPresent(String.self, forKey: .content)
            reasoningContent = (try? c.decodeIfPresent(String.self, forKey: .reasoningContent))
                ?? (try? c.decodeIfPresent(String.self, forKey: .reasoning))
        }
    }
}

struct ChatCompletionStreamChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta
    }

    struct Delta: Decodable {
        let content: String?
        let reasoningContent: String?

        enum Keys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
            case reasoning
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            content = try? c.decodeIfPresent(String.self, forKey: .content)
            reasoningContent = (try? c.decodeIfPresent(String.self, forKey: .reasoningContent))
                ?? (try? c.decodeIfPresent(String.self, forKey: .reasoning))
        }
    }
}

struct ModelListResponse: Decodable {
    let data: [ModelItem]

    struct ModelItem: Decodable {
        let id: String
    }
}

struct ModelListStringResponse: Decodable {
    let data: [String]
}
