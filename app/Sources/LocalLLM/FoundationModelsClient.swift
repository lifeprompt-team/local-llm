import Foundation
import FoundationModels

enum FoundationModelsClient {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        return false
    }

    static var unavailableReason: String? {
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                return "\(reason)"
            @unknown default:
                return "unknown"
            }
        }
        return "macOS 26以降が必要です"
    }

    static func stream(
        messages: [ChatMessage],
        systemPrompt: String,
        onEvent: @escaping @MainActor @Sendable (StreamEvent) -> Void
    ) async throws {
        guard #available(macOS 26.0, *) else {
            throw FoundationModelsError.unavailable("macOS 26以降が必要です")
        }
        try await FoundationModelsBackend.stream(
            messages: messages,
            systemPrompt: systemPrompt,
            onEvent: onEvent
        )
    }
}

enum FoundationModelsError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Apple Intelligence が利用できません: \(reason)"
        }
    }
}

@available(macOS 26.0, *)
private enum FoundationModelsBackend {
    static func stream(
        messages: [ChatMessage],
        systemPrompt: String,
        onEvent: @escaping @MainActor @Sendable (StreamEvent) -> Void
    ) async throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw FoundationModelsError.unavailable("\(reason)")
        @unknown default:
            throw FoundationModelsError.unavailable("unknown")
        }

        let session = LanguageModelSession(instructions: systemPrompt)
        let prompt: String
        if messages.count == 1, let last = messages.last {
            prompt = last.content
        } else {
            let transcript = messages.map { message in
                let label = message.role == "assistant" ? "Assistant" : "User"
                return "\(label): \(message.content)"
            }.joined(separator: "\n\n")
            prompt = """
                以下の会話履歴を引き継ぎ、最後のUser発言に答えてください。

                \(transcript)

                Assistant:
                """
        }
        var emitted = ""

        for try await snapshot in session.streamResponse(to: prompt) {
            let content = snapshot.content
            let delta: String
            if content.hasPrefix(emitted) {
                delta = String(content.dropFirst(emitted.count))
            } else {
                delta = content
            }

            if !delta.isEmpty {
                await onEvent(.content(delta))
            }
            emitted = content
        }
    }
}
