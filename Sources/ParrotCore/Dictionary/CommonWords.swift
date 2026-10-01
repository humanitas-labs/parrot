import Foundation
import NaturalLanguage

/// Whether a word is common English, for Fix Word's warnings (#54). A row
/// for a common word, or one that replaces a common word, changes ordinary
/// text in every later dictation.
protocol CommonWords: Sendable {
    /// True when every word of `text` is common.
    func isCommon(_ text: String) -> Bool
}

/// The vocabulary of the English word embedding that ships with macOS,
/// plus English function words. It holds everyday words ("link", "deck",
/// "weekend", "printer") and leaves out rare names and coined terms
/// ("qwilbo", "kwarn", "zorblink"). `NSSpellChecker` can't do this job: it
/// accepts many rare names, and it learns every word the user ever typed.
///
/// Without the embedding, every word counts as common, so Fix Word warns
/// rather than stays silent.
final class EmbeddingCommonWords: CommonWords, @unchecked Sendable {
    static let shared = EmbeddingCommonWords()

    private let embedding: NLEmbedding?
    private let lock = NSLock()

    init(embedding: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)) {
        self.embedding = embedding
    }

    func isCommon(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in
            if FunctionWords.all.contains(word) { return true }
            guard let embedding else { return true }
            lock.lock()
            defer { lock.unlock() }
            return embedding.contains(word)
        }
    }
}

/// A fixed list, for tests.
struct FixedCommonWords: CommonWords {
    var words: Set<String>

    func isCommon(_ text: String) -> Bool {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).allSatisfy { word in
            FunctionWords.all.contains(String(word)) || words.contains(String(word))
        }
    }
}

/// English words that carry grammar rather than meaning.
enum FunctionWords {
    static let all: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "so", "yet", "if", "then", "than", "because", "as",
        "of", "to", "in", "on", "at", "for", "with", "by", "from", "into", "onto", "about", "over", "under",
        "up", "down", "out", "off", "through", "after", "before", "between", "during", "without", "within",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "done",
        "have", "has", "had", "having", "will", "would", "shall", "should", "can", "could", "may", "might", "must",
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them",
        "my", "your", "his", "its", "our", "their", "mine", "yours", "ours", "theirs",
        "this", "that", "these", "those", "there", "here", "what", "which", "who", "whom", "whose",
        "when", "where", "why", "how", "all", "any", "some", "each", "every", "no", "not", "yes",
        "just", "also", "very", "too", "only", "even", "still", "again", "now", "once",
        "let", "lets", "let's", "i'm", "it's", "that's", "don't", "can't", "won't", "isn't", "we're", "you're",
    ]
}
