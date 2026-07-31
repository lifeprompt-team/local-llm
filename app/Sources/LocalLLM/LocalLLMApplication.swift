import AppKit

@main
struct LocalLLMApplication {
    @MainActor
    static func main() async {
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
