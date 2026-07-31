import Foundation
import MLXLMCommon

/// ストリーミング中に届く差分。reasoning（思考）と content（本文）を区別する。
enum StreamEvent: Sendable {
    case reasoning(String)
    case content(String)
}

/// 1つの会話内でモデルへ渡す発言。
struct ChatMessage: Sendable {
    let role: String
    let content: String

    static func user(_ content: String) -> ChatMessage {
        ChatMessage(role: "user", content: content)
    }

    static func assistant(_ content: String) -> ChatMessage {
        ChatMessage(role: "assistant", content: content)
    }
}

/// アプリ内へ直接組み込んだMLX Swiftで推論する。
enum LLMClient {
    static func availableModels() async throws -> [String] {
        [Settings.defaultModel]
    }

    static func preload(model: String) async throws {
        try await MLXModelManager.shared.preload(model: model)
    }

    static func stream(
        model: String,
        systemPrompt: String,
        messages: [ChatMessage],
        onEvent: @escaping @MainActor @Sendable (StreamEvent) -> Void
    ) async throws {
        let container = try await MLXModelManager.shared.acquire(model: model)
        do {
            let session = ChatSession(
                container,
                instructions: systemPrompt,
                generateParameters: GenerateParameters(
                    maxTokens: 2_048,
                    temperature: 0.7
                ),
                additionalContext: ["enable_thinking": false]
            )
            let input = try messages.map(makeMLXMessage)
            for try await chunk in session.streamResponse(to: input) {
                try Task.checkCancellation()
                if !chunk.isEmpty {
                    await onEvent(.content(chunk))
                }
            }
            await MLXModelManager.shared.release()
        } catch {
            await MLXModelManager.shared.release()
            throw error
        }
    }

    private static func makeMLXMessage(_ message: ChatMessage) throws -> Chat.Message {
        switch message.role {
        case "user":
            return .user(message.content)
        case "assistant":
            return .assistant(message.content)
        case "system":
            return .system(message.content)
        default:
            throw LLMError.unsupportedRole(message.role)
        }
    }

    enum LLMError: LocalizedError {
        case unsupportedRole(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedRole(let role):
                return "未対応のメッセージロールです: \(role)"
            }
        }
    }
}
