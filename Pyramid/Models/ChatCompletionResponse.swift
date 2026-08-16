import Foundation

struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let role: String
        let content: String
    }
}

struct ChatCompletionStreamChunk: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let delta: Delta
    }

    struct Delta: Decodable {
        let content: String?
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
