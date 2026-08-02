import Foundation
import MLXLMCommon

/// ストリーミング中に届く差分。reasoning（思考）と content（本文）を区別する。
enum StreamEvent: Sendable {
    case reasoning(String)
    case content(String)
    case tool(ReadOnlyToolOutput)
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
            let toolDispatcher = ModelToolDispatcher(onEvent: onEvent)
            var transcript = try messages.map(makeMLXMessage)

            // Agents-A1のテンプレートは各生成時に元のuserメッセージを必要とする。
            // MLX Swift標準の自動dispatchは2周目へtool結果だけを渡すため、ここでは
            // 元の会話・assistantのtool call・tool結果を保持して手動で再生成する。
            agentLoop: for round in 0 ... 4 {
                let session = ChatSession(
                    container,
                    instructions: systemPrompt + toolInstructions,
                    generateParameters: GenerateParameters(
                        maxTokens: 2_048,
                        temperature: 0.7
                    ),
                    additionalContext: ["enable_thinking": false],
                    tools: ModelToolDefinitions.schemas
                )

                var roundContent = ""
                var visibleContent = ""
                var undecidedContent = ""
                var suppressedToolMarkup: String?
                var toolCalls: [ToolCall] = []
                for try await generation in session.streamDetails(to: transcript) {
                    try Task.checkCancellation()
                    switch generation {
                    case .chunk(let chunk):
                        guard !chunk.isEmpty else { continue }
                        roundContent += chunk
                        if suppressedToolMarkup != nil {
                            suppressedToolMarkup! += chunk
                            continue
                        }

                        undecidedContent += chunk
                        if let marker = firstToolMarkupRange(in: undecidedContent) {
                            let prefix = String(undecidedContent[..<marker.lowerBound])
                            if !prefix.isEmpty {
                                visibleContent += prefix
                                await onEvent(.content(prefix))
                            }
                            suppressedToolMarkup = String(undecidedContent[marker.lowerBound...])
                            undecidedContent = ""
                        } else if undecidedContent.count > toolMarkupLookbehind {
                            let safeEnd = undecidedContent.index(
                                undecidedContent.endIndex,
                                offsetBy: -toolMarkupLookbehind
                            )
                            let safeText = String(undecidedContent[..<safeEnd])
                            undecidedContent = String(undecidedContent[safeEnd...])
                            visibleContent += safeText
                            await onEvent(.content(safeText))
                        }
                    case .toolCall(let call):
                        toolCalls.append(call)
                    case .info:
                        break
                    }
                }

                if toolCalls.isEmpty {
                    toolCalls = ModelToolDefinitions.recoverXMLToolCalls(from: roundContent)
                }

                if toolCalls.isEmpty {
                    let remaining = undecidedContent + (suppressedToolMarkup ?? "")
                    if !remaining.isEmpty {
                        visibleContent += remaining
                        await onEvent(.content(remaining))
                    }
                } else if !undecidedContent.isEmpty {
                    // 正常に構造化されたTool Callでは、直前の通常文だけがlookbehindへ残る。
                    visibleContent += undecidedContent
                    await onEvent(.content(undecidedContent))
                }

                guard !toolCalls.isEmpty else { break agentLoop }
                guard round < 4 else { throw ModelToolError.callLimitExceeded }

                transcript.append(.assistant(visibleContent, toolCalls: toolCalls))
                for call in toolCalls {
                    let result = try await toolDispatcher.dispatch(call)
                    transcript.append(.tool(result, id: call.id))
                }
            }
            await MLXModelManager.shared.release()
        } catch {
            await MLXModelManager.shared.release()
            throw error
        }
    }

    private static let toolInstructions = """


        ローカルMacを読み取るためのツールが利用できます。ユーザーがファイル名検索、\
        ファイル内容検索、またはこのMacの状態確認を依頼した場合は、推測で答えたり\
        「アクセスできない」と断ったりせず、必ず適切なツールを使ってください。\
        検索先が指定されていない場合はホームフォルダを使います。ツール結果にない\
        ファイルや情報を作らず、結果を日本語で簡潔に説明してください。
        """

    private static let toolMarkupLookbehind = 16

    private static func firstToolMarkupRange(in text: String) -> Range<String.Index>? {
        ["<tool_call>", "<function="]
            .compactMap { text.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
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

enum ModelToolDefinitions {
    static let schemas: [ToolSpec] = [
        function(
            name: "find_files",
            description: "このMac上でファイル名またはフォルダ名を検索します。ファイル名を探す依頼では必ず使用します。読み取り専用です。",
            properties: [
                "query": [
                    "type": "string",
                    "description": "ファイル名に対する検索語。ユーザーが探したい名前だけを指定します。",
                ] as [String: any Sendable],
                "mode": [
                    "type": "string",
                    "enum": ["exact", "contains", "prefix", "fuzzy"] as [String],
                    "description": "一致方法。指定がなければcontains。",
                ] as [String: any Sendable],
                "root": [
                    "type": "string",
                    "description": "検索開始フォルダの絶対パス。指定がなければユーザーのホームフォルダ。",
                ] as [String: any Sendable],
            ],
            required: ["query"]
        ),
        function(
            name: "search_text",
            description: "このMac上のテキストファイル本文から文字列を検索します。ファイルの中身を探す依頼で使用します。読み取り専用です。",
            properties: [
                "query": [
                    "type": "string",
                    "description": "ファイル本文に含まれる検索文字列。正規表現ではなく固定文字列です。",
                ] as [String: any Sendable],
                "root": [
                    "type": "string",
                    "description": "検索開始フォルダの絶対パス。指定がなければユーザーのホームフォルダ。",
                ] as [String: any Sendable],
            ],
            required: ["query"]
        ),
        function(
            name: "get_system_info",
            description: "macOS、CPU、メモリ、ディスク空き容量、稼働時間を読み取り専用で取得します。",
            properties: [:],
            required: []
        ),
    ]

    static func command(for call: ToolCall) throws -> ReadOnlyToolCommand {
        switch call.function.name {
        case "find_files":
            let query = try requiredString("query", in: call)
            guard query.count <= 255 else {
                throw ReadOnlyToolError.invalidCommand("ファイル名の検索語は255文字以内にしてください。")
            }
            let modeName = optionalString("mode", in: call) ?? FileNameMatchMode.contains.rawValue
            guard let mode = FileNameMatchMode(rawValue: modeName) else {
                throw ReadOnlyToolError.invalidCommand("未対応の一致方法です: \(modeName)")
            }
            return .findFiles(
                query: query,
                root: rootURL(optionalString("root", in: call)),
                mode: mode
            )

        case "search_text":
            let query = try requiredString("query", in: call)
            guard query.count <= 500 else {
                throw ReadOnlyToolError.invalidCommand("本文の検索語は500文字以内にしてください。")
            }
            return .searchText(
                query: query,
                root: rootURL(optionalString("root", in: call))
            )

        case "get_system_info":
            return .systemInfo

        default:
            throw ReadOnlyToolError.invalidCommand("未対応のツールです: \(call.function.name)")
        }
    }

    /// 一部のMLX設定がXML Tool Callを通常テキストとして返した場合の復元処理。
    /// `<tool_call>`開始タグが欠けていても、完結したfunctionブロックだけを受理する。
    static func recoverXMLToolCalls(from text: String) -> [ToolCall] {
        let parser = XMLFunctionParser(startTag: "<tool_call>", endTag: "</tool_call>")
        let pattern = #"<function=[\s\S]*?</function>"#
        var calls: [ToolCall] = []
        var searchRange = text.startIndex ..< text.endIndex

        while calls.count < 4,
            let range = text.range(of: pattern, options: .regularExpression, range: searchRange)
        {
            if let call = parser.parse(
                content: String(text[range]),
                tools: schemas
            ) {
                calls.append(call)
            }
            searchRange = range.upperBound ..< text.endIndex
        }
        return calls
    }

    private static func function(
        name: String,
        description: String,
        properties: [String: any Sendable],
        required: [String]
    ) -> ToolSpec {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                    "additionalProperties": false,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ] as ToolSpec
    }

    private static func requiredString(_ name: String, in call: ToolCall) throws -> String {
        guard let value = optionalString(name, in: call), !value.isEmpty else {
            throw ReadOnlyToolError.invalidCommand("ツール引数 \(name) がありません。")
        }
        return value
    }

    private static func optionalString(_ name: String, in call: ToolCall) -> String? {
        guard case .string(let rawValue)? = call.function.arguments[name] else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func rootURL(_ path: String?) -> URL {
        guard let path else { return FileManager.default.homeDirectoryForCurrentUser }
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}

private actor ModelToolDispatcher {
    private let maximumCalls = 4
    private var callCount = 0
    private let onEvent: @MainActor @Sendable (StreamEvent) -> Void

    init(onEvent: @escaping @MainActor @Sendable (StreamEvent) -> Void) {
        self.onEvent = onEvent
    }

    func dispatch(_ call: ToolCall) async throws -> String {
        callCount += 1
        guard callCount <= maximumCalls else {
            throw ModelToolError.callLimitExceeded
        }

        do {
            let command = try ModelToolDefinitions.command(for: call)
            let output = try await ReadOnlyToolExecutor.shared.execute(command)
            await onEvent(.tool(output))
            return output.modelResultText
        } catch {
            // 引数の誤りはモデルへ返し、許可されたツールの範囲内で修正を1回試せるようにする。
            return "ツールを実行できませんでした: \(error.localizedDescription)"
        }
    }
}

private enum ModelToolError: LocalizedError {
    case callLimitExceeded

    var errorDescription: String? {
        "安全のため、1回の依頼で実行できるツールは4回までです。"
    }
}
