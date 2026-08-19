import Foundation

struct VoiceReplacementRule: Equatable, Sendable {
    let source: String
    let replacement: String
}

enum VoiceTextProcessing {
    /// AppleのAnalysisContextは全タグ合計100フレーズまでを推奨している。
    static func vocabulary(from text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let phrase = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, !phrase.hasPrefix("#"), seen.insert(phrase).inserted else {
                continue
            }
            result.append(phrase)
            if result.count == 100 { break }
        }
        return result
    }

    /// `誤認識 => 正しい表記`、`誤認識 → 正しい表記`、タブ区切りを受け付ける。
    static func replacementRules(from text: String) -> [VoiceReplacementRule] {
        text.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

            for separator in ["=>", "→", "\t"] {
                guard let range = line.range(of: separator) else { continue }
                let source = line[..<range.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let replacement = line[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty else { return nil }
                return VoiceReplacementRule(source: source, replacement: replacement)
            }
            return nil
        }
    }

    static func apply(_ rules: [VoiceReplacementRule], to text: String) -> String {
        rules.reduce(text) { current, rule in
            current.replacingOccurrences(of: rule.source, with: rule.replacement)
        }
    }
}
