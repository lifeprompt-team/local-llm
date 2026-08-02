import Foundation

enum FileNameMatchMode: String, Sendable {
    case exact
    case contains
    case prefix
    case fuzzy

    var displayName: String {
        switch self {
        case .exact: return "完全一致"
        case .contains: return "部分一致"
        case .prefix: return "前方一致"
        case .fuzzy: return "ファジー"
        }
    }
}

enum ReadOnlyToolCommand: Sendable {
    case findFiles(query: String, root: URL, mode: FileNameMatchMode)
    case searchText(query: String, root: URL)
    case systemInfo
    case help
}

struct ReadOnlyToolItem: Sendable {
    let url: URL
    let detail: String
}

struct ReadOnlyToolOutput: Sendable {
    let title: String
    let summary: String
    let details: [String]
    let items: [ReadOnlyToolItem]
    let emptyMessage: String?

    init(
        title: String,
        summary: String,
        details: [String],
        items: [ReadOnlyToolItem],
        emptyMessage: String? = nil
    ) {
        self.title = title
        self.summary = summary
        self.details = details
        self.items = items
        self.emptyMessage = emptyMessage
    }

    /// モデルへ返すツール結果。UI用リンクは含めず、確認できた事実だけを渡す。
    var modelResultText: String {
        var lines = [title, summary]
        lines.append(contentsOf: details)
        if items.isEmpty, let emptyMessage {
            lines.append(emptyMessage)
        } else {
            lines.append(contentsOf: items.map { "\($0.url.path) — \($0.detail)" })
        }
        return lines.joined(separator: "\n")
    }
}

enum ReadOnlyToolError: LocalizedError {
    case invalidCommand(String)
    case invalidRoot(String)
    case unreadableRoot(String)

    var errorDescription: String? {
        switch self {
        case .invalidCommand(let message):
            return message
        case .invalidRoot(let path):
            return "検索先フォルダが見つかりません: \(path)"
        case .unreadableRoot(let path):
            return "検索先フォルダを読み取れません: \(path)"
        }
    }
}

/// スラッシュコマンドと、誤判定しにくい一部の自然文を読み取り専用ツールへ変換する。
enum ReadOnlyToolCommandParser {
    private static let modeAliases: [String: FileNameMatchMode] = [
        "exact": .exact,
        "完全一致": .exact,
        "contains": .contains,
        "部分一致": .contains,
        "prefix": .prefix,
        "前方一致": .prefix,
        "fuzzy": .fuzzy,
        "ファジー": .fuzzy,
    ]

    static func parse(_ input: String) throws -> ReadOnlyToolCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == "/sys" {
            return .systemInfo
        }
        if trimmed == "/tools" || trimmed == "/help" {
            return .help
        }
        if trimmed == "/find" {
            throw ReadOnlyToolError.invalidCommand(
                "使い方: /find [exact|contains|prefix|fuzzy] 検索語 [フォルダ]"
            )
        }
        if trimmed.hasPrefix("/find ") {
            return try parseFind(String(trimmed.dropFirst("/find ".count)))
        }
        if trimmed == "/grep" {
            throw ReadOnlyToolError.invalidCommand("使い方: /grep 検索文字列 [フォルダ]")
        }
        if trimmed.hasPrefix("/grep ") {
            return try parseGrep(String(trimmed.dropFirst("/grep ".count)))
        }

        return parseConservativeNaturalLanguage(trimmed)
    }

    private static func parseFind(_ rawArguments: String) throws -> ReadOnlyToolCommand {
        var arguments = tokenize(rawArguments)
        guard !arguments.isEmpty else {
            throw ReadOnlyToolError.invalidCommand(
                "使い方: /find [exact|contains|prefix|fuzzy] 検索語 [フォルダ]"
            )
        }

        let mode: FileNameMatchMode
        if let alias = modeAliases[arguments[0].lowercased()] {
            mode = alias
            arguments.removeFirst()
        } else {
            mode = .contains
        }

        guard !arguments.isEmpty else {
            throw ReadOnlyToolError.invalidCommand("検索語を指定してください。")
        }

        let root = extractRoot(from: &arguments)
        let query = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            throw ReadOnlyToolError.invalidCommand("検索語を指定してください。")
        }
        guard query.count <= 255 else {
            throw ReadOnlyToolError.invalidCommand("検索語は255文字以内にしてください。")
        }
        return .findFiles(query: query, root: root, mode: mode)
    }

    private static func parseGrep(_ rawArguments: String) throws -> ReadOnlyToolCommand {
        var arguments = tokenize(rawArguments)
        guard !arguments.isEmpty else {
            throw ReadOnlyToolError.invalidCommand("使い方: /grep 検索文字列 [フォルダ]")
        }

        let root = extractRoot(from: &arguments)
        let query = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            throw ReadOnlyToolError.invalidCommand("検索文字列を指定してください。")
        }
        guard query.count <= 500 else {
            throw ReadOnlyToolError.invalidCommand("検索文字列は500文字以内にしてください。")
        }
        return .searchText(query: query, root: root)
    }

    /// 自然文は、引用された検索語がある場合だけファイルツールへ送る。
    /// 通常の質問を検索と誤認しないことを優先する。
    private static func parseConservativeNaturalLanguage(_ input: String) -> ReadOnlyToolCommand? {
        let lower = input.lowercased()
        let systemWords = ["メモリ", "ディスク", "空き容量", "macos", "cpu", "稼働時間"]
        if (lower.contains("mac") || lower.contains("このマシン")),
            systemWords.contains(where: lower.contains)
        {
            return .systemInfo
        }

        guard let query = firstQuotedText(in: input), !query.isEmpty else { return nil }
        let root = firstPath(in: input) ?? FileManager.default.homeDirectoryForCurrentUser
        let searchWords = ["探して", "検索して", "見つけて", "ファイル"]
        guard searchWords.contains(where: input.contains) else { return nil }

        let contentWords = ["書かれて", "含まれて", "ファイル内", "本文", "grep"]
        if contentWords.contains(where: lower.contains) {
            return .searchText(query: query, root: root)
        }

        let mode: FileNameMatchMode
        if input.contains("完全一致") {
            mode = .exact
        } else if input.contains("前方一致") {
            mode = .prefix
        } else if input.contains("ファジー") {
            mode = .fuzzy
        } else {
            mode = .contains
        }
        return .findFiles(query: query, root: root, mode: mode)
    }

    private static func extractRoot(from arguments: inout [String]) -> URL {
        guard arguments.count >= 2, let last = arguments.last, isPathCandidate(last) else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        arguments.removeLast()
        return fileURL(from: last)
    }

    private static func isPathCandidate(_ value: String) -> Bool {
        if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".") {
            return true
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func firstPath(in input: String) -> URL? {
        let candidates = tokenize(input)
        guard let path = candidates.first(where: isPathCandidate) else { return nil }
        return fileURL(from: path.trimmingCharacters(in: CharacterSet(charactersIn: "、。")))
    }

    private static func fileURL(from path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func firstQuotedText(in input: String) -> String? {
        for (opening, closing) in [("「", "」"), ("『", "』"), ("\"", "\""), ("'", "'")] {
            guard let start = input.range(of: opening) else { continue }
            let remainder = input[start.upperBound...]
            guard let end = remainder.range(of: closing) else { continue }
            return String(remainder[..<end.lowerBound])
        }
        return nil
    }

    /// 空白区切り。ただし引用符・日本語の括弧内は1引数として扱う。
    private static func tokenize(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var closingQuote: Character?

        for character in input {
            if let quote = closingQuote {
                if character == quote {
                    selfAppend(&result, &current)
                    closingQuote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            switch character {
            case "\"", "'":
                closingQuote = character
            case "「":
                closingQuote = "」"
            case "『":
                closingQuote = "』"
            default:
                if character.isWhitespace {
                    selfAppend(&result, &current)
                } else {
                    current.append(character)
                }
            }
        }
        selfAppend(&result, &current)
        return result
    }

    private static func selfAppend(_ result: inout [String], _ current: inout String) {
        if !current.isEmpty {
            result.append(current)
            current = ""
        }
    }

}

/// 削除・移動・書き込み・任意コマンド実行を持たない、読み取り専用ツール群。
actor ReadOnlyToolExecutor {
    static let shared = ReadOnlyToolExecutor()

    private let fileManager = FileManager.default
    private let maximumEntries = 100_000
    private let maximumResults = 50
    private let maximumTextFiles = 20_000
    private let maximumTextFileSize = 2 * 1_024 * 1_024
    private let searchTimeout: TimeInterval = 8
    private let ignoredDirectories: Set<String> = [
        ".git", ".hg", ".svn", ".Trash", ".build", "node_modules", "DerivedData", "Caches",
    ]
    private let binaryExtensions: Set<String> = [
        "7z", "a", "app", "avi", "bin", "dmg", "doc", "docx", "dylib", "exe", "gif", "gz",
        "heic", "ico", "jpeg", "jpg", "m4a", "m4v", "mov", "mp3", "mp4", "o", "otf", "pdf",
        "pkg", "png", "ppt", "pptx", "so", "tar", "tiff", "ttf", "wav", "webp", "xlsx", "zip",
    ]

    func execute(_ command: ReadOnlyToolCommand) async throws -> ReadOnlyToolOutput {
        switch command {
        case .findFiles(let query, let root, let mode):
            return try findFiles(query: query, root: root, mode: mode)
        case .searchText(let query, let root):
            return try searchText(query: query, root: root)
        case .systemInfo:
            return systemInfo()
        case .help:
            return help()
        }
    }

    private func findFiles(
        query: String,
        root: URL,
        mode: FileNameMatchMode
    ) throws -> ReadOnlyToolOutput {
        let root = try validatedRoot(root)
        let startedAt = Date()
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            )
        else {
            throw ReadOnlyToolError.unreadableRoot(root.path)
        }

        var scanned = 0
        var matches: [(score: Int, item: ReadOnlyToolItem)] = []
        var stoppedEarly = false

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            scanned += 1
            if scanned >= maximumEntries || Date().timeIntervalSince(startedAt) >= searchTimeout {
                stoppedEarly = true
                break
            }

            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true, shouldSkipDirectory(url, root: root) {
                enumerator.skipDescendants()
                continue
            }

            guard let score = matchScore(candidate: url.lastPathComponent, query: query, mode: mode)
            else { continue }

            let kind = values.isDirectory == true ? "フォルダ" : "ファイル"
            var components = [kind]
            if let size = values.fileSize, values.isRegularFile == true {
                components.append(formatBytes(Int64(size)))
            }
            if let modified = values.contentModificationDate {
                components.append("更新 \(formatDate(modified))")
            }
            matches.append(
                (
                    score,
                    ReadOnlyToolItem(url: url, detail: components.joined(separator: " · "))
                ))
        }

        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.url.path.localizedStandardCompare(rhs.item.url.path) == .orderedAscending
        }
        let items = Array(matches.prefix(maximumResults).map(\.item))
        let truncation = stoppedEarly || matches.count > maximumResults ? "（上限まで表示）" : ""

        return ReadOnlyToolOutput(
            title: "ファイル名検索",
            summary: "「\(query)」を\(mode.displayName)で検索: \(items.count)件 \(truncation)",
            details: ["検索先: \(root.path)", "確認した項目: \(scanned.formatted())"],
            items: items,
            emptyMessage: "該当するファイルやフォルダはありません。"
        )
    }

    private func searchText(query: String, root: URL) throws -> ReadOnlyToolOutput {
        let root = try validatedRoot(root)
        let startedAt = Date()
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            )
        else {
            throw ReadOnlyToolError.unreadableRoot(root.path)
        }

        var scannedEntries = 0
        var scannedFiles = 0
        var items: [ReadOnlyToolItem] = []
        var stoppedEarly = false

        searchLoop: for case let url as URL in enumerator {
            try Task.checkCancellation()
            scannedEntries += 1
            if scannedEntries >= maximumEntries || scannedFiles >= maximumTextFiles
                || Date().timeIntervalSince(startedAt) >= searchTimeout
            {
                stoppedEarly = true
                break
            }

            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true {
                if shouldSkipDirectory(url, root: root) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard let size = values.fileSize, size <= maximumTextFileSize else { continue }
            guard !binaryExtensions.contains(url.pathExtension.lowercased()) else { continue }
            scannedFiles += 1

            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            if data.prefix(1_024).contains(0) { continue }
            guard let text = String(data: data, encoding: .utf8) else { continue }

            var matchesInFile = 0
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.localizedCaseInsensitiveContains(query) {
                    let preview = compactPreview(String(line))
                    items.append(
                        ReadOnlyToolItem(
                            url: url,
                            detail: "行 \(index + 1): \(preview)"
                        ))
                    matchesInFile += 1
                    if items.count >= maximumResults {
                        stoppedEarly = true
                        break searchLoop
                    }
                    if matchesInFile >= 3 { break }
                }
            }
        }

        let truncation = stoppedEarly ? "（上限まで表示）" : ""
        return ReadOnlyToolOutput(
            title: "ファイル内容検索",
            summary: "「\(query)」を含む箇所: \(items.count)件 \(truncation)",
            details: [
                "検索先: \(root.path)",
                "確認したテキストファイル: \(scannedFiles.formatted())",
                "1ファイル2MBまで・最大3箇所を表示",
            ],
            items: items,
            emptyMessage: "該当するテキストはありません。"
        )
    }

    private func systemInfo() -> ReadOnlyToolOutput {
        let processInfo = ProcessInfo.processInfo
        let home = fileManager.homeDirectoryForCurrentUser
        let diskValues = try? home.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])

        var details = [
            "macOS: \(processInfo.operatingSystemVersionString)",
            "アーキテクチャ: \(architectureName)",
            "CPU: \(processInfo.processorCount)コア（有効 \(processInfo.activeProcessorCount)）",
            "搭載メモリ: \(formatBytes(Int64(processInfo.physicalMemory)))",
        ]
        if let reusable = reusableMemoryBytes() {
            details.append("すぐ再利用可能なメモリ（概算）: \(formatBytes(reusable))")
        }
        if let total = diskValues?.volumeTotalCapacity,
            let available = diskValues?.volumeAvailableCapacityForImportantUsage
        {
            details.append(
                "ディスク: \(formatBytes(Int64(available))) 空き / \(formatBytes(Int64(total)))"
            )
        }
        details.append("稼働時間: \(formatDuration(processInfo.systemUptime))")

        return ReadOnlyToolOutput(
            title: "このMacの状態",
            summary: "システム情報を読み取り専用で取得しました。",
            details: details,
            items: []
        )
    }

    private func help() -> ReadOnlyToolOutput {
        ReadOnlyToolOutput(
            title: "読み取り専用ツール",
            summary: "ファイルを変更・削除する機能はありません。",
            details: [
                "/find README.md — ファイル名の部分一致",
                "/find exact README.md — 完全一致",
                "/find fuzzy readme ~/Documents — ファジー検索",
                "/grep \"検索文字列\" ~/Documents — ファイル内容検索",
                "/sys — メモリ・ディスク・macOS情報",
                "検索結果の「パスをコピー」「Finderで表示」もファイルを変更しません。",
            ],
            items: []
        )
    }

    private func validatedRoot(_ root: URL) throws -> URL {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ReadOnlyToolError.invalidRoot(resolved.path)
        }
        guard fileManager.isReadableFile(atPath: resolved.path) else {
            throw ReadOnlyToolError.unreadableRoot(resolved.path)
        }
        return resolved
    }

    private func shouldSkipDirectory(_ url: URL, root: URL) -> Bool {
        if ignoredDirectories.contains(url.lastPathComponent) { return true }
        let homeLibrary = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return root == fileManager.homeDirectoryForCurrentUser && url == homeLibrary
    }

    private func matchScore(candidate: String, query: String, mode: FileNameMatchMode) -> Int? {
        let foldedCandidate = fold(candidate)
        let foldedQuery = fold(query)
        guard !foldedQuery.isEmpty else { return nil }

        switch mode {
        case .exact:
            return foldedCandidate == foldedQuery ? 10_000 : nil
        case .contains:
            guard let range = foldedCandidate.range(of: foldedQuery) else { return nil }
            let offset = foldedCandidate.distance(from: foldedCandidate.startIndex, to: range.lowerBound)
            return 5_000 - offset - foldedCandidate.count
        case .prefix:
            return foldedCandidate.hasPrefix(foldedQuery) ? 7_500 - foldedCandidate.count : nil
        case .fuzzy:
            return fuzzyScore(candidate: foldedCandidate, query: foldedQuery)
        }
    }

    private func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func fuzzyScore(candidate: String, query: String) -> Int? {
        let candidateCharacters = Array(candidate)
        let queryCharacters = Array(query)
        var candidateIndex = 0
        var previousMatch = -2
        var score = 0

        for queryCharacter in queryCharacters {
            var found: Int?
            while candidateIndex < candidateCharacters.count {
                if candidateCharacters[candidateIndex] == queryCharacter {
                    found = candidateIndex
                    candidateIndex += 1
                    break
                }
                candidateIndex += 1
            }
            guard let found else { return nil }
            score += found == previousMatch + 1 ? 12 : 4
            if found == 0 { score += 8 }
            previousMatch = found
        }
        return score - candidateCharacters.count
    }

    private func compactPreview(_ line: String) -> String {
        let compact = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\t", with: " ")
        if compact.count <= 180 { return compact }
        return "\(compact.prefix(177))…"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)日 \(hours)時間" }
        if hours > 0 { return "\(hours)時間 \(minutes)分" }
        return "\(minutes)分"
    }

    private var architectureName: String {
        #if arch(arm64)
            return "Apple Silicon（arm64）"
        #elseif arch(x86_64)
            return "Intel（x86_64）"
        #else
            return "不明"
        #endif
    }

    /// `vm_stat`は固定パス・引数なしで実行し、ユーザー入力をプロセスへ渡さない。
    private func reusableMemoryBytes() -> Int64? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return nil }

            var pageSize: Int64 = 4_096
            var reusablePages: Int64 = 0
            for line in text.split(separator: "\n") {
                if line.contains("page size of") {
                    let numbers = line.split(whereSeparator: { !$0.isNumber })
                    if let value = numbers.compactMap({ Int64($0) }).first {
                        pageSize = value
                    }
                    continue
                }
                let reusableNames = ["Pages free", "Pages inactive", "Pages speculative"]
                guard reusableNames.contains(where: line.hasPrefix) else { continue }
                let numbers = line.split(whereSeparator: { !$0.isNumber })
                if let value = numbers.compactMap({ Int64($0) }).first {
                    reusablePages += value
                }
            }
            return reusablePages * pageSize
        } catch {
            return nil
        }
    }
}
