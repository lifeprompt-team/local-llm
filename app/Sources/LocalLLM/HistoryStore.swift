import Foundation

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let model: String
    let prompt: String
    let response: String
}

/// 質問と回答の履歴を JSON ファイルに永続化する。
/// 保存先: ~/Library/Application Support/LocalLLM/history.json （新しい順・上限あり）
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    private let maxEntries = 500
    private let fileURL: URL
    private(set) var entries: [HistoryEntry] = []

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLM", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        entries = (try? Self.decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    func add(prompt: String, response: String, model: String) {
        let entry = HistoryEntry(
            id: UUID(),
            date: Date(),
            model: model,
            prompt: prompt,
            response: response
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        guard let data = try? Self.encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
