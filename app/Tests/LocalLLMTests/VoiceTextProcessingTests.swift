import XCTest
@testable import LocalLLM

final class VoiceTextProcessingTests: XCTestCase {
    func testVocabularyTrimsDeduplicatesAndSkipsComments() {
        let vocabulary = VoiceTextProcessing.vocabulary(
            from: "  Grok  \nMLX\n# メモ\n\nGrok\nKanary"
        )

        XCTAssertEqual(vocabulary, ["Grok", "MLX", "Kanary"])
    }

    func testVocabularyIsLimitedToOneHundredPhrases() {
        let source = (0..<105).map { "word\($0)" }.joined(separator: "\n")

        XCTAssertEqual(VoiceTextProcessing.vocabulary(from: source).count, 100)
    }

    func testReplacementRulesSupportArrowsTabsAndDeletion() {
        let rules = VoiceTextProcessing.replacementRules(
            from: "グロック => Grok\nエムエルエックス → MLX\nかなり\tKanary\nえーと =>"
        )

        XCTAssertEqual(
            rules,
            [
                VoiceReplacementRule(source: "グロック", replacement: "Grok"),
                VoiceReplacementRule(source: "エムエルエックス", replacement: "MLX"),
                VoiceReplacementRule(source: "かなり", replacement: "Kanary"),
                VoiceReplacementRule(source: "えーと", replacement: ""),
            ]
        )
    }

    func testReplacementsRunTopToBottom() {
        let rules = [
            VoiceReplacementRule(source: "グロック", replacement: "Grok"),
            VoiceReplacementRule(source: "Grokビルド", replacement: "Grok Build"),
        ]

        XCTAssertEqual(
            VoiceTextProcessing.apply(rules, to: "グロックビルドを使う"),
            "Grok Buildを使う"
        )
    }
}
