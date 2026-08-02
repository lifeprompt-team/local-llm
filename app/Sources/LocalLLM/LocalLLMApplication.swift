import AppKit

@main
struct LocalLLMApplication {
    @MainActor
    static func main() async {
        if let index = CommandLine.arguments.firstIndex(of: "--finder-smoke-test") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                fputs("FINDER_SMOKE_FAILED: パスを指定してください。\n", stderr)
                exit(1)
            }
            let path = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
            guard FileManager.default.fileExists(atPath: path.path) else {
                fputs("FINDER_SMOKE_FAILED: ファイルが見つかりません。\n", stderr)
                exit(1)
            }
            let didReveal = NSWorkspace.shared.selectFile(
                path.path,
                inFileViewerRootedAtPath: ""
            )
            guard didReveal else {
                fputs("FINDER_SMOKE_FAILED: Finderが選択要求を受け付けませんでした。\n", stderr)
                exit(1)
            }
            print("FINDER_SMOKE_OK \(path.path)")
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--tool-call-smoke-test") {
            let rootPath =
                CommandLine.arguments.indices.contains(index + 1)
                ? CommandLine.arguments[index + 1]
                : FileManager.default.currentDirectoryPath
            let root = URL(fileURLWithPath: rootPath).standardizedFileURL
            do {
                var response = ""
                var toolOutputs: [ReadOnlyToolOutput] = []
                try await LLMClient.preload(model: Settings.defaultModel)
                try await LLMClient.stream(
                    model: Settings.defaultModel,
                    systemPrompt: "日本語で簡潔に答えてください。",
                    messages: [
                        .user(
                            "\(root.path)の中から、ファイル名にPackage.swiftを含むファイルを探してください。"
                        )
                    ]
                ) { event in
                    switch event {
                    case .content(let text):
                        response += text
                    case .tool(let output):
                        toolOutputs.append(output)
                    case .reasoning:
                        break
                    }
                }
                guard
                    toolOutputs.flatMap(\.items).contains(where: {
                        $0.url.lastPathComponent == "Package.swift"
                    })
                else {
                    throw ReadOnlyToolError.invalidCommand(
                        "モデルがfind_filesを呼び出さないか、Package.swiftを見つけられませんでした。"
                            + " response=\(response.prefix(500)) tools=\(toolOutputs.count)"
                    )
                }

                var exactPhraseToolCalls = 0
                try await LLMClient.stream(
                    model: Settings.defaultModel,
                    systemPrompt: "日本語で簡潔に答えてください。",
                    messages: [
                        .user("\(root.path)から印影のファイルを探して")
                    ]
                ) { event in
                    if case .tool(let output) = event, output.title == "ファイル名検索" {
                        exactPhraseToolCalls += 1
                    }
                }
                guard exactPhraseToolCalls > 0 else {
                    throw ReadOnlyToolError.invalidCommand(
                        "『印影のファイルを探して』からfind_filesを呼び出しませんでした。"
                    )
                }
                print(
                    "TOOL_CALL_SMOKE_OK calls=\(toolOutputs.count) "
                        + "exact_phrase_calls=\(exactPhraseToolCalls) "
                        + "response=\(response.prefix(120))"
                )
                await MLXModelManager.shared.unloadImmediately()
                return
            } catch {
                let nsError = error as NSError
                fputs(
                    "TOOL_CALL_SMOKE_FAILED: \(String(reflecting: error)) "
                        + "domain=\(nsError.domain) code=\(nsError.code) "
                        + "info=\(nsError.userInfo)\n",
                    stderr
                )
                await MLXModelManager.shared.unloadImmediately()
                exit(1)
            }
        }

        if let index = CommandLine.arguments.firstIndex(of: "--tools-smoke-test") {
            let rootPath =
                CommandLine.arguments.indices.contains(index + 1)
                ? CommandLine.arguments[index + 1]
                : FileManager.default.currentDirectoryPath
            let root = URL(fileURLWithPath: rootPath)
            do {
                guard
                    let fileCommand = try ReadOnlyToolCommandParser.parse(
                        "/find exact Package.swift \"\(root.path)\""
                    )
                else {
                    throw ReadOnlyToolError.invalidCommand("findコマンドを解析できませんでした。")
                }
                let fileOutput = try await ReadOnlyToolExecutor.shared.execute(fileCommand)
                guard !fileOutput.items.isEmpty else {
                    throw ReadOnlyToolError.invalidCommand("Package.swiftを見つけられませんでした。")
                }

                guard
                    let fuzzyCommand = try ReadOnlyToolCommandParser.parse(
                        "/find fuzzy PckgSwt \"\(root.path)\""
                    )
                else {
                    throw ReadOnlyToolError.invalidCommand("fuzzyコマンドを解析できませんでした。")
                }
                let fuzzyOutput = try await ReadOnlyToolExecutor.shared.execute(fuzzyCommand)
                guard fuzzyOutput.items.contains(where: { $0.url.lastPathComponent == "Package.swift" })
                else {
                    throw ReadOnlyToolError.invalidCommand("ファジー検索が一致しませんでした。")
                }

                guard
                    let textCommand = try ReadOnlyToolCommandParser.parse(
                        "/grep \"ReadOnlyToolExecutor\" \"\(root.path)\""
                    )
                else {
                    throw ReadOnlyToolError.invalidCommand("grepコマンドを解析できませんでした。")
                }
                let textOutput = try await ReadOnlyToolExecutor.shared.execute(textCommand)
                guard !textOutput.items.isEmpty else {
                    throw ReadOnlyToolError.invalidCommand("ファイル内容検索の結果がありません。")
                }
                guard
                    let systemCommand = try ReadOnlyToolCommandParser.parse(
                        "このMacのメモリとディスク空き容量を教えて"
                    )
                else {
                    throw ReadOnlyToolError.invalidCommand("自然文をsysツールへ変換できませんでした。")
                }
                let systemOutput = try await ReadOnlyToolExecutor.shared.execute(systemCommand)

                let leakedXML = """
                    ファイル名の検索をします。

                    <function=find_files>
                    <parameter=query>
                    Package.swift
                    </parameter>
                    <parameter=mode>
                    contains
                    </parameter>
                    <parameter=root>
                    \(root.path)
                    </parameter>
                    </function>
                    </tool_call>
                    """
                let recoveredCalls = ModelToolDefinitions.recoverXMLToolCalls(from: leakedXML)
                guard recoveredCalls.count == 1 else {
                    throw ReadOnlyToolError.invalidCommand(
                        "開始タグなしのXML Tool Callを復元できませんでした。"
                    )
                }
                let recoveredCommand = try ModelToolDefinitions.command(for: recoveredCalls[0])
                let recoveredOutput = try await ReadOnlyToolExecutor.shared.execute(
                    recoveredCommand
                )
                guard recoveredOutput.items.contains(where: {
                    $0.url.lastPathComponent == "Package.swift"
                }) else {
                    throw ReadOnlyToolError.invalidCommand(
                        "復元したXML Tool Callを実行できませんでした。"
                    )
                }
                print(
                    "TOOLS_SMOKE_OK files=\(fileOutput.items.count) fuzzy=\(fuzzyOutput.items.count) "
                        + "text=\(textOutput.items.count) details=\(systemOutput.details.count) "
                        + "xml=\(recoveredCalls.count)"
                )
                return
            } catch {
                fputs("TOOLS_SMOKE_FAILED: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if CommandLine.arguments.contains("--smoke-test") {
            do {
                var response = ""
                try await LLMClient.preload(model: Settings.defaultModel)
                try await LLMClient.stream(
                    model: Settings.defaultModel,
                    systemPrompt: "簡潔に答えてください。",
                    messages: [.user("1+1の答えを数字だけで返してください。")]
                ) { event in
                    if case .content(let text) = event {
                        response += text
                    }
                }
                print("SMOKE_OK \(response.prefix(80))")
                await MLXModelManager.shared.unloadImmediately()
                return
            } catch {
                fputs("SMOKE_FAILED: \(error.localizedDescription)\n", stderr)
                await MLXModelManager.shared.unloadImmediately()
                exit(1)
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
