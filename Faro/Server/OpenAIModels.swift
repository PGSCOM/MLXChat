import Foundation

// Wire-format DTOs for the OpenAI-compatible surface. Property names
// intentionally mirror the JSON field names (snake_case) rather than
// idiomatic Swift, to avoid a CodingKeys block per type.

/// A chat message's `content` can be a plain string or (newer clients)
/// an array of typed parts. Only the text parts are used for now —
/// `image_url` parts are ignored; see the ponytail note on `APIServer`.
enum ChatContent: Decodable, Sendable {
    struct Part: Decodable, Sendable {
        let type: String
        let text: String?
    }

    case text(String)
    case parts([Part])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else {
            self = .parts(try container.decode([Part].self))
        }
    }

    var plainText: String {
        switch self {
        case .text(let value): return value
        case .parts(let parts): return parts.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
        }
    }
}

struct ChatCompletionRequest: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let role: String
        let content: ChatContent
    }

    let model: String?
    let messages: [Message]
    let stream: Bool?
    let temperature: Double?
    let top_p: Double?
    let max_tokens: Int?
}

struct ChatCompletionResponse: Encodable {
    struct Choice: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let index: Int
        let message: Message
        let finish_reason: String
    }

    let id: String
    let object = "chat.completion"
    let created: Int
    let model: String
    let choices: [Choice]
}

struct ChatCompletionChunk: Encodable {
    struct Delta: Encodable {
        var role: String? = nil
        var content: String? = nil
    }
    struct Choice: Encodable {
        let index: Int
        let delta: Delta
        let finish_reason: String?
    }

    let id: String
    let object = "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [Choice]
}

struct ModelListResponse: Encodable {
    struct Entry: Encodable {
        let id: String
        let object = "model"
        let owned_by = "faro"
    }

    let object = "list"
    let data: [Entry]
}
