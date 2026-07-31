import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// MLXモデルを必要時だけロードし、最後の利用から60秒後にメモリから解放する。
actor MLXModelManager {
    static let shared = MLXModelManager()

    private let retentionNanoseconds: UInt64 = 60_000_000_000
    private var container: ModelContainer?
    private var loadedModel: String?
    private var loadingTask: Task<ModelContainer, Error>?
    private var unloadTask: Task<Void, Never>?
    private var activeRequests = 0

    private init() {}

    func preload(model: String) async throws {
        _ = try await ensureLoaded(model: model)
        scheduleUnloadIfIdle()
    }

    func acquire(model: String) async throws -> ModelContainer {
        unloadTask?.cancel()
        unloadTask = nil
        let container = try await ensureLoaded(model: model)
        activeRequests += 1
        return container
    }

    func release() {
        activeRequests = max(0, activeRequests - 1)
        scheduleUnloadIfIdle()
    }

    func unloadImmediately() {
        unloadTask?.cancel()
        unloadTask = nil
        loadingTask?.cancel()
        loadingTask = nil
        activeRequests = 0
        unloadModel()
    }

    private func ensureLoaded(model: String) async throws -> ModelContainer {
        if let container, loadedModel == model {
            return container
        }
        if let loadedModel, loadedModel != model {
            throw ModelError.differentModelLoaded(loadedModel)
        }

        if loadingTask == nil {
            let startedAt = Date()
            let configuration = modelConfiguration(for: model)
            loadingTask = Task(priority: .userInitiated) {
                let container = try await #huggingFaceLoadModelContainer(
                    configuration: configuration
                )
                let elapsed = Date().timeIntervalSince(startedAt)
                let elapsedText = String(format: "%.1f", elapsed)
                NSLog("[LocalLLM] MLX model ready: \(model) (\(elapsedText)s)")
                return container
            }
        }

        guard let loadingTask else { throw ModelError.loadCancelled }
        do {
            let loaded = try await loadingTask.value
            self.loadingTask = nil
            container = loaded
            loadedModel = model
            return loaded
        } catch {
            self.loadingTask = nil
            throw error
        }
    }

    /// mlx_lm (Python) で取得済みのHugging Faceキャッシュがあれば再利用する。
    /// 既存ユーザーがSwift版へ移行したときに、同じ数GBのモデルを再取得しないため。
    private func modelConfiguration(for model: String) -> ModelConfiguration {
        if let overridePath = ProcessInfo.processInfo.environment["LOCALLLM_MODEL_PATH"],
            isModelDirectory(URL(fileURLWithPath: overridePath))
        {
            return ModelConfiguration(directory: URL(fileURLWithPath: overridePath))
        }

        let cacheName = "models--" + model.replacingOccurrences(of: "/", with: "--")
        let repository = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
            .appendingPathComponent(cacheName, isDirectory: true)
        let revisionFile = repository.appendingPathComponent("refs/main")

        if let revision = try? String(contentsOf: revisionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !revision.isEmpty
        {
            let snapshot =
                repository
                .appendingPathComponent("snapshots", isDirectory: true)
                .appendingPathComponent(revision, isDirectory: true)
            if isModelDirectory(snapshot) {
                NSLog("[LocalLLM] reusing existing Hugging Face model cache")
                return ModelConfiguration(directory: snapshot)
            }
        }

        return ModelConfiguration(id: model)
    }

    private func isModelDirectory(_ directory: URL) -> Bool {
        let config = directory.appendingPathComponent("config.json")
        let tokenizer = directory.appendingPathComponent("tokenizer.json")
        return FileManager.default.fileExists(atPath: config.path)
            && FileManager.default.fileExists(atPath: tokenizer.path)
    }

    private func scheduleUnloadIfIdle() {
        guard activeRequests == 0, container != nil else { return }
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.retentionNanoseconds ?? 0)
            } catch {
                return
            }
            guard let self, await self.activeRequests == 0 else { return }
            await self.unloadModel()
        }
    }

    private func unloadModel() {
        guard container != nil else { return }
        NSLog("[LocalLLM] unloading MLX model after idle timeout")
        container = nil
        loadedModel = nil
        Memory.clearCache()
    }

    enum ModelError: LocalizedError {
        case loadCancelled
        case differentModelLoaded(String)

        var errorDescription: String? {
            switch self {
            case .loadCancelled:
                return "MLXモデルのロードがキャンセルされました。"
            case .differentModelLoaded(let model):
                return "別のMLXモデルがロード中です: \(model)"
            }
        }
    }
}
